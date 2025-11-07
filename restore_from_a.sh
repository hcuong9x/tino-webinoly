#!/bin/bash

# ==================== CONFIG ====================
SCRIPT_VERSION="2.3"
LOG_FILE="/var/log/wp_restore_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR="/tmp/wp_migration"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# ==================== KIỂM TRA HỆ THỐNG ====================
if [ "$EUID" -ne 0 ]; then 
    error "Script cần chạy với quyền root"
    exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
    error "Thư mục backup không tồn tại: $BACKUP_DIR"
    error "Chạy script migrate trên Server A trước"
    exit 1
fi

# ==================== KIỂM TRA WEBINOLY ====================
if ! command -v webinoly &> /dev/null; then
    warn "Webinoly chưa được cài đặt"
    exit 1
fi

# ==================== KIỂM TRA WEBINOLY STACK ====================
WEBINOLY_INFO=$(webinoly -info 2>/dev/null)

if [ -z "$WEBINOLY_INFO" ]; then
    error "Không thể lấy thông tin Webinoly"
    exit 1
fi

# ==================== PHƯƠNG THỨC KẾT NỐI MYSQL (ƯU TIÊN) ====================
MYSQL_CMD=""

# 1. Ưu tiên: sudo mysql (unix_socket)
if sudo mysql -e "SELECT 1" >/dev/null 2>&1; then
    success "Kết nối MariaDB thành công qua sudo mysql (unix_socket)"
    MYSQL_CMD="sudo mysql"
    
# 2. Nếu không, thử lấy pass từ Webinoly
elif MYSQL_ROOT_ENCODED=$(echo "$WEBINOLY_INFO" | grep "mysql-root:" | cut -d: -f2) && [ -n "$MYSQL_ROOT_ENCODED" ]; then
    MYSQL_ROOT_PASS=$(echo "$MYSQL_ROOT_ENCODED" | base64 -d 2>/dev/null)
    if [ -n "$MYSQL_ROOT_PASS" ] && mysql -u root -p"$MYSQL_ROOT_PASS" -e "SELECT 1" >/dev/null 2>&1; then
        success "Kết nối MariaDB thành công (Webinoly password)"
        MYSQL_CMD="mysql -u root -p'$MYSQL_ROOT_PASS'"
    fi
fi

# Hàm chạy MySQL
mysql_exec() {
    eval "$MYSQL_CMD" "$@"
}

# Test lại
if ! mysql_exec -e "SELECT 1" >/dev/null 2>&1; then
    error "Không thể kết nối MariaDB"
    exit 1
fi

# ==================== TÌM DOMAINS ====================
log "Quét backup files trong $BACKUP_DIR..."

SQL_FILES=($(ls "$BACKUP_DIR"/*.sql 2>/dev/null | xargs -n1 basename | sed 's/\.sql$//'))
TAR_FILES=($(ls "$BACKUP_DIR"/*_files.tar.gz 2>/dev/null | xargs -n1 basename | sed 's/_files\.tar\.gz$//'))
DOMAINS=($(printf '%s\n' "${SQL_FILES[@]}" "${TAR_FILES[@]}" | sort -u))

if [ ${#DOMAINS[@]} -eq 0 ]; then
    error "Không tìm thấy file backup nào"
    error "Kiểm tra: $BACKUP_DIR"
    exit 1
fi

log "Tìm thấy ${#DOMAINS[@]} domain(s): ${DOMAINS[*]}"
echo ""

read -p "Tiếp tục restore? (y/n): " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { log "Hủy bởi user"; exit 0; }

# ==================== RESTORE LOOP ====================
SUCCESS_COUNT=0
FAIL_COUNT=0

log "Bắt đầu restore..."
echo "--------------------------------------------------"

for domain in "${DOMAINS[@]}"; do
    log "Đang restore: $domain"
    
    SQL_FILE="$BACKUP_DIR/${domain}.sql"
    TAR_FILE="$BACKUP_DIR/${domain}_files.tar.gz"
    
    if [ ! -f "$TAR_FILE" ]; then
        error "  → Thiếu file: ${domain}_files.tar.gz"
        ((FAIL_COUNT++))
        continue
    fi
    
    # ==================== TẠO SITE WEBINOLY ====================
    log "  → Tạo site với Webinoly..."
    
    if [ -d "/var/www/$domain" ]; then
        warn "  → Site đã tồn tại, sẽ ghi đè"
        webinoly -site="$domain" -delete=force >/dev/null 2>&1
    fi
    
    if ! webinoly -site="$domain" -cache=on -wp=yes >/dev/null 2>&1; then
        error "  → Lỗi tạo site $domain"
        ((FAIL_COUNT++))
        continue
    fi
    
    success "  → Site đã được tạo"
    
    # ==================== EXTRACT FILES ====================
    log "  → Giải nén files..."
    
    TEMP_EXTRACT="/tmp/extract_${domain}"
    mkdir -p "$TEMP_EXTRACT"
    
    if ! tar xzf "$TAR_FILE" -C "$TEMP_EXTRACT" 2>/dev/null; then
        error "  → Lỗi giải nén $TAR_FILE"
        rm -rf "$TEMP_EXTRACT"
        ((FAIL_COUNT++))
        continue
    fi
    
    if [ -d "$TEMP_EXTRACT/public_html" ]; then
        rm -rf "/var/www/$domain/htdocs/"*
        cp -r "$TEMP_EXTRACT/public_html/"* "/var/www/$domain/htdocs/" 2>/dev/null || \
        cp -r "$TEMP_EXTRACT/public_html/." "/var/www/$domain/htdocs/" 2>/dev/null
    else
        error "  → Cấu trúc backup không đúng (thiếu public_html)"
        rm -rf "$TEMP_EXTRACT"
        ((FAIL_COUNT++))
        continue
    fi
    
    rm -rf "$TEMP_EXTRACT"
    success "  → Files đã được extract"
    
    # ==================== TẠO DATABASE & USER (DÙNG WEBINOLY) ====================
    log "  → Tạo database mới bằng Webinoly..."
    
    MYSQL_OUTPUT=$(sudo site -mysql 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$MYSQL_OUTPUT" ]; then
        error "  → Lỗi tạo database bằng Webinoly"
        ((FAIL_COUNT++))
        continue
    fi

    NEW_DB_NAME=$(echo "$MYSQL_OUTPUT" | grep "Database Name:" | awk '{print $NF}')
    NEW_DB_USER=$(echo "$MYSQL_OUTPUT" | grep "Database User:" | awk '{print $NF}')
    NEW_DB_PASS=$(echo "$MYSQL_OUTPUT" | grep "Password:" | awk '{print $NF}')
    NEW_DB_HOST=$(echo "$MYSQL_OUTPUT" | grep "Database Host:" | awk '{print $NF}')

    if [ -z "$NEW_DB_NAME" ] || [ -z "$NEW_DB_USER" ] || [ -z "$NEW_DB_PASS" ]; then
        error "  → Không lấy được thông tin DB từ Webinoly"
        ((FAIL_COUNT++))
        continue
    fi

    success "  → Database mới: $NEW_DB_NAME"
    info "      User: $NEW_DB_USER | Pass: $NEW_DB_PASS | Host: $NEW_DB_HOST"
    log "DB_INFO: $domain → $NEW_DB_NAME / $NEW_DB_USER / $NEW_DB_PASS"

    # ==================== IMPORT DATABASE (nếu có file SQL) ====================
    if [ -f "$SQL_FILE" ]; then
        log "  → Import dữ liệu cũ vào database mới..."
        
        if mysql_exec "$NEW_DB_NAME" < "$SQL_FILE" 2>/dev/null; then
            success "  → Database imported vào $NEW_DB_NAME"
        else
            error "  → Lỗi import database vào $NEW_DB_NAME"
            warn "  → Site vẫn hoạt động nhưng DB trống"
        fi
    else
        warn "  → Không có file .sql → DB mới nhưng trống"
    fi

    # ==================== CẬP NHẬT wp-config.php VỚI DB MỚI ====================
    log "  → Cập nhật wp-config.php với DB mới..."

    WP_CONFIG="/var/www/$domain/htdocs/wp-config.php"

    sed -i "s|define( *'DB_NAME', * *').*('|define( 'DB_NAME', '$NEW_DB_NAME' );|" "$WP_CONFIG"
    sed -i "s|define( *'DB_USER', * *').*('|define( 'DB_USER', '$NEW_DB_USER' );|" "$WP_CONFIG"
    sed -i "s|define( *'DB_PASSWORD', * *').*('|define( 'DB_PASSWORD', '$NEW_DB_PASS' );|" "$WP_CONFIG"
    sed -i "s|define( *'DB_HOST', * *').*('|define( 'DB_HOST', '$NEW_DB_HOST' );|" "$WP_CONFIG"

    if grep -q "DB_NAME.*$NEW_DB_NAME" "$WP_CONFIG" && \
       grep -q "DB_USER.*$NEW_DB_USER" "$WP_CONFIG" && \
       grep -q "DB_PASSWORD.*$NEW_DB_PASS" "$WP_CONFIG"; then
        success "  → wp-config.php đã được cập nhật"
    else
        error "  → Cập nhật wp-config.php thất bại"
        ((FAIL_COUNT++))
        continue
    fi

    # ==================== CẬP NHẬT SECURITY KEYS (nếu thiếu) ====================
    log "  → Kiểm tra security keys..."
    if ! grep -q "AUTH_KEY" "$WP_CONFIG"; then
        warn "  → Thiếu security keys, thêm mới..."
        SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
        sed -i "/\/\*.*stop editing.*\*\//i $SALT" "$WP_CONFIG" 2>/dev/null || \
        sed -i "/DB_COLLATE/a $SALT" "$WP_CONFIG"
    fi

    # ==================== FIX PERMISSIONS ====================
    log "  → Fix permissions..."
    chown -R www-data:www-data "/var/www/$domain"
    find "/var/www/$domain/htdocs" -type d -exec chmod 755 {} \;
    find "/var/www/$domain/htdocs" -type f -exec chmod 644 {} \;
    chmod 600 "$WP_CONFIG"

    # ==================== SSL (Optional) ====================
    log "  → Cài đặt SSL..."
    if webinoly -ssl="$domain" -letsencrypt=on >/dev/null 2>&1; then
        success "  → SSL installed (Let's Encrypt)"
    else
        warn "  → SSL failed (chạy manual: webinoly -ssl=$domain)"
    fi

    # ==================== CLEANUP ====================
    rm -f "$SQL_FILE" "$TAR_FILE"
    
    success "HOÀN TẤT: https://$domain"
    ((SUCCESS_COUNT++))
    echo "--------------------------------------------------"
done

# ==================== KẾT QUẢ ====================
echo ""
log "==================== KẾT QUẢ RESTORE ===================="
log "Thành công: $SUCCESS_COUNT domain(s)"
log "Thất bại:   $FAIL_COUNT domain(s)"
log "Log file:   $LOG_FILE"
echo ""

if [ $SUCCESS_COUNT -gt 0 ]; then
    info "Các bước tiếp theo:"
    echo "  1. Kiểm tra sites: sudo webinoly -info"
    echo "  2. Test từng domain trong browser"
    echo "  3. Update DNS A records về IP mới"
    echo "  4. Flush cache: wp cache flush (nếu dùng WP-CLI)"
    echo "  5. Xóa backup: rm -rf $BACKUP_DIR"
fi

exit 0