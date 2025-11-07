#!/bin/bash

# ==================== CONFIG ====================
SCRIPT_VERSION="2.0"
LOG_FILE="/var/log/wp_migration_$(date +%Y%m%d_%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

# ==================== NHẬP THÔNG TIN ====================
if [ -z "$1" ]; then
    read -p "Nhập IP Server B: " B_IP
else
    B_IP="$1"
fi

# Validate IP
if [[ ! "$B_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    error "IP không hợp lệ: $B_IP"
    exit 1
fi

# Kiểm tra SSH port (mặc định 22)
read -p "SSH Port Server B (mặc định 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

B_USER="root"
read -s -p "Nhập mật khẩu root Server B: " SSH_PASS
echo
export SSHPASS="$SSH_PASS"

# Cài sshpass nếu chưa có
if ! command -v sshpass >/dev/null 2>&1; then
    log "Cài đặt sshpass..."
    yum install -y epel-release sshpass >/dev/null 2>&1 || {
        error "Không thể cài sshpass"
        exit 1
    }
fi

# ==================== KIỂM TRA KẾT NỐI ====================
log "Kiểm tra kết nối SSH tới $B_IP:$SSH_PORT..."
if ! sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$SSH_PORT" "$B_USER@$B_IP" "echo test" >/dev/null 2>&1; then
    error "Không thể kết nối SSH tới Server B"
    error "Kiểm tra: IP, port, firewall, password"
    exit 1
fi
success "Kết nối SSH thành công"

# ==================== DOMAIN PATTERN (MỞ RỘNG) ====================
DOMAIN_PATTERN="com|net|org|shop|store|gifts|info|biz|vn|io|app|dev|xyz|online|tech|cloud|asia|site"

# ==================== LỰA CHỌN DOMAIN ====================
TARGET_DOMAIN="$2"

if [ -n "$TARGET_DOMAIN" ]; then
    # Kiểm tra domain có tồn tại không
    if [ ! -d "/home/$TARGET_DOMAIN/public_html" ]; then
        error "Domain không tồn tại: $TARGET_DOMAIN"
        exit 1
    fi
    DOMAINS=("$TARGET_DOMAIN")
    log "BACKUP 1 DOMAIN: $TARGET_DOMAIN → $B_IP"
else
    DOMAINS=($(ls /home 2>/dev/null | grep -E "^[a-zA-Z0-9.-]+\.($DOMAIN_PATTERN)$" | sort -u))
    log "BACKUP TOÀN BỘ: ${#DOMAINS[@]} domain(s) → $B_IP"
fi

if [ ${#DOMAINS[@]} -eq 0 ]; then
    error "Không tìm thấy domain nào trong /home"
    exit 1
fi

# Confirm trước khi chạy
echo ""
echo "Danh sách domain sẽ migrate:"
printf '%s\n' "${DOMAINS[@]}"
echo ""
read -p "Tiếp tục? (y/n): " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { log "Hủy bởi user"; exit 0; }

# ==================== TẠO REMOTE DIR ====================
log "Tạo thư mục backup trên Server B..."
sshpass -e ssh -p "$SSH_PORT" "$B_USER@$B_IP" "mkdir -p /tmp/wp_migration" 2>/dev/null

# ==================== TRANSFER DOMAINS ====================
SUCCESS_COUNT=0
FAIL_COUNT=0

log "Bắt đầu migration..."
echo "--------------------------------------------------"

for domain in "${DOMAINS[@]}"; do
    wp_root="/home/$domain/public_html"
    
    # Kiểm tra WordPress
    if [ ! -f "$wp_root/wp-config.php" ]; then
        warn "BỎ QUA $domain: Không phải WordPress site"
        ((FAIL_COUNT++))
        continue
    fi

    log "Đang xử lý: $domain"
    
    # Đọc DB credentials
    DB_NAME=$(grep "DB_NAME" "$wp_root/wp-config.php" | cut -d"'" -f4)
    DB_USER=$(grep "DB_USER" "$wp_root/wp-config.php" | cut -d"'" -f4)
    DB_PASS=$(grep "DB_PASSWORD" "$wp_root/wp-config.php" | cut -d"'" -f4)
    
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        error "Không đọc được DB config cho $domain"
        ((FAIL_COUNT++))
        continue
    fi
    
    # Backup database
    log "  → Backup database: $DB_NAME"
    if ! mysqldump -u "$DB_USER" -p"$DB_PASS" --single-transaction --quick --databases "$DB_NAME" > "/tmp/${domain}.sql" 2>/dev/null; then
        error "  → Lỗi backup DB $domain (check MySQL user/pass)"
        ((FAIL_COUNT++))
        continue
    fi
    
    DB_SIZE=$(du -h "/tmp/${domain}.sql" | cut -f1)
    log "  → DB size: $DB_SIZE"
    
    # Backup files
    log "  → Backup files..."
    if ! tar czf "/tmp/${domain}_files.tar.gz" -C "/home/$domain" public_html 2>/dev/null; then
        error "  → Lỗi backup files $domain"
        rm -f "/tmp/${domain}.sql"
        ((FAIL_COUNT++))
        continue
    fi
    
    FILE_SIZE=$(du -h "/tmp/${domain}_files.tar.gz" | cut -f1)
    log "  → Files size: $FILE_SIZE"
    
    # Transfer qua Server B
    log "  → Transfer tới $B_IP..."
    
    if ! sshpass -e scp -P "$SSH_PORT" "/tmp/${domain}.sql" "$B_USER@$B_IP:/tmp/wp_migration/" >/dev/null 2>&1; then
        error "  → Lỗi transfer SQL $domain"
        rm -f "/tmp/${domain}.sql" "/tmp/${domain}_files.tar.gz"
        ((FAIL_COUNT++))
        continue
    fi
    
    if ! sshpass -e scp -P "$SSH_PORT" "/tmp/${domain}_files.tar.gz" "$B_USER@$B_IP:/tmp/wp_migration/" >/dev/null 2>&1; then
        error "  → Lỗi transfer files $domain"
        rm -f "/tmp/${domain}.sql" "/tmp/${domain}_files.tar.gz"
        ((FAIL_COUNT++))
        continue
    fi
    
    success "  → HOÀN TẤT $domain"
    ((SUCCESS_COUNT++))
    
    # Cleanup local
    rm -f "/tmp/${domain}.sql" "/tmp/${domain}_files.tar.gz"
    echo "--------------------------------------------------"
done

# ==================== KẾT QUẢ ====================
echo ""
log "==================== KẾT QUẢ MIGRATION ===================="
log "Thành công: $SUCCESS_COUNT domain(s)"
log "Thất bại:   $FAIL_COUNT domain(s)"
log "Log file:   $LOG_FILE"
echo ""

if [ $SUCCESS_COUNT -gt 0 ]; then
    success "Chạy restore trên Server B:"
    echo "  ssh root@$B_IP"
    echo "  cd /tmp/wp_migration"
    echo "  bash restore_from_a.sh"
fi

exit 0