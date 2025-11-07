#!/bin/bash

# ==================== CONFIG ====================
SCRIPT_VERSION="2.2"
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
    read -p "Cài đặt Webinoly ngay? (y/n): " INSTALL_WEBINOLY
    
    if [[ "$INSTALL_WEBINOLY" =~ ^[Yy]$ ]]; then
        log "Đang cài đặt Webinoly..."
        wget -qO weby qrok.es/wy && sudo bash weby
        
        if ! command -v webinoly &> /dev/null; then
            error "Cài đặt Webinoly thất bại"
            exit 1
        fi
        success "Webinoly đã được cài đặt"
    else
        error "Cần Webinoly để tiếp tục"
        exit 1
    fi
fi

# ==================== KIỂM TRA WEBINOLY STACK ====================
WEBINOLY_INFO=$(webinoly -info 2>/dev/null)

if [ -z "$WEBINOLY_INFO" ]; then
    error "Không thể lấy thông tin Webinoly"
    exit 1
fi

# ==================== PHƯƠNG THỨC KẾT NỐI MYSQL (ƯU TIÊN) ====================
MYSQL_ROOT_PASS=""
MYSQL_CMD=""

# 1. Ưu tiên: Dùng `sudo mysql` (unix_socket auth) → không cần pass
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

# 3. Cuối cùng: Nhập tay
if [ -z "$MYSQL_CMD" ]; then
    read -s -p "Nhập MariaDB root password: " MYSQL_ROOT_PASS
    echo
    if mysql -u root -p"$MYSQL_ROOT_PASS" -e "SELECT 1" >/dev/null 2>&1; then
        success "Kết nối MariaDB thành công"
        MYSQL_CMD="mysql -u root -p'$MYSQL_ROOT_PASS'"
    else
        error "MariaDB password không đúng hoặc MariaDB chưa chạy"
        error "Kiểm tra: sudo systemctl status mariadb"
        exit 1
    fi
fi

# Hàm chạy MySQL với phương thức đã chọn
mysql_exec() {
    eval "$MYSQL_CMD" "$@"
}

# Test lại lần cuối
if ! mysql_exec -e "SELECT 1" >/dev/null 2>&1; then
    error "Không thể kết nối MariaDB bằng phương thức đã chọn"
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
    
    # ==================== ĐỌC WP-CONFIG ====================
    WP_CONFIG="/var/www/$domain/htdocs/wp-config.php"
    
    if [ ! -f "$WP_CONFIG" ]; then
        error "  → Không tìm thấy wp-config.php"
        ((FAIL_COUNT++))
        continue
    fi
    
    DB_NAME=$(grep "DB_NAME" "$WP_CONFIG" | cut -d"'" -f4)
    DB_USER=$(grep "DB_USER" "$WP_CONFIG" | cut -d"'" -f4)
    DB_PASS=$(grep "DB_PASSWORD" "$WP_CONFIG" | cut -d"'" -f4)
    DB_HOST=$(grep "DB_HOST" "$WP_CONFIG" | cut -d"'" -f4)
    
    if [ -z "$DB_NAME" ]; then
        error "  → Không đọc được DB config"
        ((FAIL_COUNT++))
        continue
    fi
    
    log "  → DB: $DB_NAME | User: $DB_USER"
    
    # ==================== TẠO DATABASE & USER ====================
    log "  → Tạo database và user..."
    
    mysql_exec -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
    
    mysql_exec -e "
        CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
        GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
        FLUSH PRIVILEGES;
    " >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        success "  → Database created: $DB_NAME"
    else
        error "  → Lỗi tạo database"
        ((FAIL_COUNT++))
        continue
    fi
    
    # ==================== IMPORT DATABASE ====================
    if [ -f "$SQL_FILE" ]; then
        log "  → Import database..."
        
        if mysql_exec "$DB_NAME" < "$SQL_FILE" 2>/dev/null; then
            success "  → Database imported"
        else
            error "  → Lỗi import database"
            warn "  → Site vẫn tạo nhưng DB trống"
        fi
    else
        warn "  → Không tìm thấy file SQL, skip import"
    fi
    
    # ==================== CẬP NHẬT WP-CONFIG ====================
    log "  → Cập nhật wp-config.php..."
    
    if [ "$DB_HOST" != "localhost" ]; then
        sed -i "s|define( *'DB_HOST', *.*);|define( 'DB_HOST', 'localhost' );|g" "$WP_CONFIG"
    fi
    
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
        warn "  → SSL failed (chạy manual sau: webinoly -ssl=$domain)"
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