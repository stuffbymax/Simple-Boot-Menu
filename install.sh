#!/bin/bash
# ==============================================================================
#  SBM INSTALLER V9 (Final Core)
# ==============================================================================

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

clear; echo -e "${CYAN}=== SBM Installer V9 ===${NC}"

# 1. PRE-CHECKS
[ ! -f "./sbm.sh" ] && { echo -e "${RED}Error: sbm.sh missing.${NC}"; exit 1; }
[ "$EUID" -ne 0 ] && { echo -e "${RED}Error: Run as root.${NC}"; exit 1; }

# 2. DEPS
if ! command -v python3 &> /dev/null; then echo -e "${RED}Python3 required.${NC}"; exit 1; fi
if ! command -v chafa &> /dev/null; then
    echo "Installing optional chafa..."
    apt-get install -y chafa 2>/dev/null || pacman -S --noconfirm chafa 2>/dev/null || dnf install -y chafa 2>/dev/null
fi

# 3. CONFIG
echo -e "\nWho is the default user?"
read -p "Username: " TARGET_USER
! id "$TARGET_USER" >/dev/null 2>&1 && { echo -e "${RED}User not found.${NC}"; exit 1; }

CONFIG_FILE="/etc/sbm.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating config..."
    cat << EOF > "$CONFIG_FILE"
DEFAULT_USER="$TARGET_USER"
AUTO_LOGIN="true"
THEME_COLOR="6"
BORDER_COLOR="7"
BORDER_STYLE="rounded"
SHOW_IMAGE="false"
IMAGE_PATH="/usr/share/pixmaps/boot_logo.png"
EOF
fi

# 4. INSTALL APP
echo "Installing sbm..."
cp ./sbm.sh /usr/local/bin/sbm
chmod +x /usr/local/bin/sbm

# 5. SERVICE
echo "Configuring Service..."
cat << EOF > /etc/systemd/system/sbm.service
[Unit]
Description=SBM Boot Interface
After=systemd-user-sessions.service plymouth-quit-wait.service
Conflicts=getty@tty1.service
[Service]
ExecStart=/usr/local/bin/sbm
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
Type=idle
Environment=TERM=linux
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable getty@tty1.service
systemctl enable sbm.service

# 6. SHELL HOOK
echo "Adding Shell Hook..."
UH=$(eval echo "~$TARGET_USER"); SF="$UH/.bash_profile"
[ -f "$UH/.bashrc" ] && SF="$UH/.bashrc"
if ! grep -q "/usr/local/bin/sbm" "$SF"; then
    echo 'if [[ -z $DISPLAY ]] && [[ $(tty) = /dev/tty1 ]]; then /usr/local/bin/sbm user_mode; fi' >> "$SF"
    chown "$TARGET_USER" "$SF"
fi

echo -e "\n${GREEN}=== SBM V9 INSTALLED ===${NC}"
echo "Run 'sudo systemctl reboot' to verify."
