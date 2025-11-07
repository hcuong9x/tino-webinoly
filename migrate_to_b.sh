#!/bin/bash

# ==================== CẤU HÌNH ====================
B_IP="YOUR_SERVER_B_IP"          # ← THAY BẰNG IP SERVER B
B_USER="root"                    # User SSH trên Server B

# ==================== NHẬP MẬT KHẨU 1 LẦN ====================
read -s -p "Nhập mật khẩu root Server B: " SSH_PASS
echo
export SSHPASS="$SSH_PASS"

# Cài sshpass nếu chưa có
if ! command -v sshpass &> /dev/null; then
    echo "Cài đặt sshpass..."
    yum install -y epel-release > /dev/null 2>&1
    yum install -y sshpass > /dev/null 2>&1
fi

# ==================== XÁC ĐỊNH DOMAIN ====================
TARGET_DOMAIN="$1"  # Nếu có tham số → backup 1 domain

if [ -n "$TARGET_DOMAIN" ]; then
    # Backup 1 domain
    if [[ ! "$TARGET_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "LỖI: Domain không hợp lệ: $TARGET_DOMAIN"
        exit 1
    fi
    if [ ! -d "/home/$TARGET_DOMAIN" ]; then
        echo "LỖI: Không tìm thấy thư mục /home/$TARGET_DOMAIN"
        exit 1
    fi
    DOMAINS=("$TARGET_DOMAIN")
    echo "CHẾ ĐỘ: Backup 1 domain → $TARGET_DOMAIN"
else
    # Backup toàn bộ
    DOMAINS=($(ls /home 2>/dev/null | grep -E '^[a-zA-Z0-9.-]+\.(com|net|shop|store|info|uk|co.uk|gifts)$' | sort -u))
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo "LỖI: Không tìm thấy domain nào trong /home"
        exit 1
    fi
    echo "CHẾ ĐỘ: Backup toàn bộ → ${#DOMAINS[@]} domain(s): ${DOMAINS[*]}"
fi

echo "Bắt đầu backup & transfer..."
echo "--------------------------------------------------"

# ==================== VÒNG LẶP BACKUP ====================
for domain in "${DOMAINS[@]}"; do
    wp_root="/home/$domain/public_html"

    # Kiểm tra WordPress
    if [ ! -f "$wp_root/wp-config.php" ]; then
        echo "BỎ QUA $domain: Không phải WordPress (không có wp-config.php)"
        continue
    fi

    # Đọc DB info
    DB_NAME=$(grep "DB_NAME" "$wp_root/wp-config.php" | cut -d"'" -f4)
    DB_USER=$(grep "DB_USER" "$wp_root/wp-config.php" | cut -d"'" -f4)
    DB_PASS=$(grep "DB_PASSWORD" "$wp_root/wp-config.php" | cut -d"'" -f4)

    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        echo "LỖI $domain: Không đọc được DB từ wp-config.php"
        continue
    fi

    echo "Backup $domain..."

    # Backup DB
    mysqldump -u "$DB_USER" -p"$DB_PASS" --databases "$DB_NAME" > "/tmp/$domain.sql" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "LỖI: Backup DB $domain thất bại"
        continue
    fi

    # Backup files
    tar czf "/tmp/${domain}_files.tar.gz" -C "/home/$domain" public_html 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "LỖI: Backup file $domain thất bại"
        rm -f "/tmp/$domain.sql"
        continue
    fi

    # Transfer
    echo "Transfer $domain → $B_USER@$B_IP"
    sshpass -e scp "/tmp/$domain.sql" "$B_USER@$B_IP:/tmp/" > /dev/null 2>&1
    sshpass -e scp "/tmp/${domain}_files.tar.gz" "$B_USER@$B_IP:/tmp/" > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "HOÀN TẤT transfer $domain"
    else
        echo "LỖI: Transfer $domain thất bại"
    fi

    # Dọn dẹp
    rm -f "/tmp/$domain.sql" "/tmp/${domain}_files.tar.gz"
    echo "--------------------------------------------------"
done

echo "HOÀN TẤT! Chạy script restore trên Server B."
echo "Lệnh: ./restore_from_a.sh"