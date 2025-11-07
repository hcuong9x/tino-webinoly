#!/bin/bash

# ==================== NHẬP MYSQL PASS 1 LẦN ====================
read -s -p "Nhập MySQL root password trên Server B: " MYSQL_ROOT_PASS
echo

# Kiểm tra Webinoly
if ! command -v webinoly &> /dev/null; then
    echo "Webinoly chưa được cài. Cài đặt ngay..."
    wget -qO weby qrok.es/wy && sudo bash weby
fi

# ==================== TỰ ĐỘNG NHẬN DIỆN DOMAIN ====================
SQL_FILES=($(ls /tmp/*.sql 2>/dev/null | xargs -n1 basename | sed 's/\.sql$//'))
TAR_FILES=($(ls /tmp/*_files.tar.gz 2>/dev/null | xargs -n1 basename | sed 's/_files\.tar\.gz$//'))
DOMAINS=($(printf '%s\n' "${SQL_FILES[@]}" "${TAR_FILES[@]}" | sort -u))

if [ ${#DOMAINS[@]} -eq 0 ]; then
    echo "LỖI: Không tìm thấy file backup nào trong /tmp"
    echo "Chạy script migrate trên Server A trước."
    exit 1
fi

echo "Tìm thấy ${#DOMAINS[@]} domain(s): ${DOMAINS[*]}"
echo "Bắt đầu restore..."
echo "--------------------------------------------------"

# ==================== VÒNG LẶP RESTORE ====================
for domain in "${DOMAINS[@]}"; do
    echo "Restore $domain..."

    # Tạo site Webinoly
    sudo webinoly -site="$domain" -le -cache=on > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "LỖI: Tạo site $domain thất bại (kiểm tra domain/DNS)"
        continue
    fi

    mkdir -p "/var/www/$domain/htdocs"

    # Giải nén files
    if [ -f "/tmp/${domain}_files.tar.gz" ]; then
        tar xzf "/tmp/${domain}_files.tar.gz" -C "/var/www/$domain/" 2>/dev/null
        mv "/var/www/$domain/public_html/"* "/var/www/$domain/htdocs/" 2>/dev/null || true
        rm -rf "/var/www/$domain/public_html"
    else
        echo "LỖI: Thiếu file backup: ${domain}_files.tar.gz"
        continue
    fi

    # Đọc wp-config
    wp_config="/var/www/$domain/htdocs/wp-config.php"
    if [ ! -f "$wp_config" ]; then
        echo "LỖI: Không có wp-config.php"
        continue
    fi

    DB_NAME=$(grep "DB_NAME" "$wp_config" | cut -d"'" -f4)
    DB_USER=$(grep "DB_USER" "$wp_config" | cut -d"'" -f4)
    DB_PASS=$(grep "DB_PASSWORD" "$wp_config" | cut -d"'" -f4)

    # Tạo DB + User
    mysql -u root -p"$MYSQL_ROOT_PASS" -e "
        CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
        CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
        GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
        FLUSH PRIVILEGES;
    " > /dev/null 2>&1

    # Import DB
    if [ -f "/tmp/$domain.sql" ]; then
        mysql -u root -p"$MYSQL_ROOT_PASS" "$DB_NAME" < "/tmp/$domain.sql" > /dev/null 2>&1
        [ $? -eq 0 ] && echo "Import DB: $DB_NAME"
    fi

    # Phân quyền
    chown -R www-data:www-data "/var/www/$domain"
    chmod -R 755 "/var/www/$domain"

    # Dọn dẹp
    rm -f "/tmp/$domain.sql" "/tmp/${domain}_files.tar.gz"

    echo "HOÀN TẤT: https://$domain"
    echo "--------------------------------------------------"
done

echo "TOÀN BỘ HOÀN TẤT!"
echo "Kiểm tra site. Dùng: sudo webinoly -info"