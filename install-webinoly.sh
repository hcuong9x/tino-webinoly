I. Cập nhập OS

sudo apt update && sudo apt upgrade -y && sudo reboot

II. Cập nhập locale

locale-gen en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

III. Cài đặt Webinoly

wget -qO weby qrok.es/wy && sudo bash weby

IV. Tắt firewall

sudo apt remove iptables-persistent -y
sudo ufw disable
sudo iptables -F

