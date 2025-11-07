#!/bin/bash

# ==================== NHẬP IP + PASS 1 LẦN ====================
if [ -z "$1" ]; then
    read -p "Nhập IP Server B: " B_IP
else
    B_IP="$1"
fi

[[ ! "$B_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "IP sai"; exit 1; }

B_USER="root"
read -s -p "Nhập mật khẩu root Server B: " SSH_PASS
echo
export SSHPASS="$SSH_PASS"

# Cài sshpass
command -v sshpass >/dev/null || { yum install -y epel-release sshpass >/dev/null 2>&1; }

# ==================== PATTERN DOMAIN MỚI (TỰ ĐỘNG) ====================
DOMAIN_PATTERN="com|net|org|shop|store|gifts|info|biz"

# ==================== DOMAIN TARGET ====================
TARGET_DOMAIN="$2"

if [ -n "$TARGET_DOMAIN" ]; then
    DOMAINS=("$TARGET_DOMAIN")
    echo "BACKUP 1 DOMAIN: $TARGET_DOMAIN → $B_IP"
else
    DOMAINS=($(ls /home 2>/dev/null | grep -E "^[a-zA-Z0-9.-]+\.($DOMAIN_PATTERN)$" | sort -u))
    echo "BACKUP TOÀN BỘ: ${#DOMAINS[@]} domain(s) → $B_IP"
fi

[ ${#DOMAINS[@]} -eq 0 ] && { echo "Không tìm thấy domain nào!"; exit 1; }

echo "Bắt đầu transfer..."
echo "--------------------------------------------------"

for domain in "${DOMAINS[@]}"; do
    wp_root="/home/$domain/public_html"
    [ ! -f "$wp_root/wp-config.php" ] && { echo "BỎ QUA $domain: Không phải WP"; continue; }

    DB_NAME=$(grep "DB_NAME" "$wp_root/wp-config.php" | cut -d"'" -f4)
    DB_USER=$(grep "DB_USER" "$wp_root/wp-config.php" | cut -d"'" -f4)
    DB_PASS=$(grep "DB_PASSWORD" "$wp_root/wp-config.php" | cut -d"'" -f4)

    echo "Backup: $domain"
    mysqldump -u "$DB_USER" -p"$DB_PASS" --databases "$DB_NAME" > "/tmp/$domain.sql" 2>/dev/null || continue
    tar czf "/tmp/${domain}_files.tar.gz" -C "/home/$domain" public_html 2>/dev/null || { rm -f "/tmp/$domain.sql"; continue; }

    echo "Transfer → $B_IP"
    sshpass -e scp "/tmp/$domain.sql" "$B_USER@$B_IP:/tmp/" >/dev/null 2>&1
    sshpass -e scp "/tmp/${domain}_files.tar.gz" "$B_USER@$B_IP:/tmp/" >/dev/null 2>&1

    [ $? -eq 0 ] && echo "HOÀN TẤT $domain" || echo "LỖI transfer $domain"

    rm -f "/tmp/$domain.sql" "/tmp/${domain}_files.tar.gz"
    echo "--------------------------------------------------"
done

echo "HOÀN TẤT! Chạy restore trên Server B: ./restore_from_a.sh"