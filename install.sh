#!/bin/bash
# ==============================================================================
#  SBM INSTALLER V8
# ==============================================================================

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${CYAN}=== SBM Installer (V8) ===${NC}"

# 1. VERIFY FILES
if [ ! -f "./sbm.sh" ]; then
    echo -e "${RED}Error: 'sbm.sh' not found in this folder.${NC}"
    echo "Please ensure install.sh and sbm.sh are in the same directory."
    exit 1
fi

# 2. CHECK ROOT
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root (sudo ./install.sh)${NC}"
  exit 1
fi

# 3. DEPENDENCIES
echo -e "${CYAN}Checking dependencies...${NC}"

# Python3 is needed for login verification
if ! command -v python3 &> /dev/null; then 
    echo -e "${RED}Error: python3 missing.${NC}"
    echo "Install python3 to use the login manager."
    exit 1
fi

# Chafa is optional but needed for images
if ! command -v chafa &> /dev/null; then
    echo "Installing chafa (for image support)..."
    apt-get install -y chafa 2>/dev/null || pacman -S --noconfirm chafa 2>/dev/null || dnf install -y chafa 2>/dev/null || echo -e "${RED}Failed to install chafa. Image mode might not work.${NC}"
fi

# 4. CONFIGURATION
echo -e "\nWhich user should be the DEFAULT selected user?"
read -p "Username: " TARGET_USER

if ! id "$TARGET_USER" >/dev/null 2>&1; then 
    echo -e "${RED}User not found.${NC}"
    exit 1
fi

CONFIG_FILE="/etc/sbm.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${CYAN}Creating config...${NC}"
    cat << EOF > "$CONFIG_FILE"
# SBM Configuration
DEFAULT_USER="$TARGET_USER"
AUTO_LOGIN="true"
THEME_COLOR="6"
BORDER_COLOR="7"
BORDER_STYLE="rounded"
SHOW_IMAGE="false"
IMAGE_PATH="/usr/share/pixmaps/boot_logo.png"
EOF
else
    echo "Config exists at $CONFIG_FILE. Preserving it."
fi

# 5. INSTALL BINARY
echo -e "${CYAN}Copying sbm.sh to /usr/local/bin/sbm ...${NC}"
cp ./sbm.sh /usr/local/bin/sbm
chmod +x /usr/local/bin/sbm

# 6. SYSTEMD SERVICE
# This replaces the standard TTY login prompt
echo -e "${CYAN}Configuring Systemd Service...${NC}"
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

# Reload services
systemctl daemon-reload
# Disable standard login on tty1
systemctl disable getty@tty1.service
# Enable SBM
systemctl enable sbm.service

# 7. SHELL HOOK
# This ensures that when SBM logs the user in, the dashboard appears
echo -e "${CYAN}Adding Shell Hook...${NC}"
UH=$(eval echo "~$TARGET_USER")
SF="$UH/.bash_profile"
[ -f "$UH/.bashrc" ] && SF="$UH/.bashrc"
[ -f "$UH/.zshrc" ] && SF="$UH/.zshrc"

if ! grep -q "/usr/local/bin/sbm" "$SF"; then
    echo "" >> "$SF"
    echo '# --- SBM HOOK ---' >> "$SF"
    echo 'if [[ -z $DISPLAY ]] && [[ $(tty) = /dev/tty1 ]]; then /usr/local/bin/sbm user_mode; fi' >> "$SF"
    chown "$TARGET_USER" "$SF"
fi

echo -e "\n${GREEN}=== INSTALLED SUCCESSFULLY ===${NC}"
echo "1. Reboot to see SBM."
echo "2. Default is Auto-Login enabled."
echo "3. To enable the Login Screen, go to 'Settings / Ark' -> 'Auto-Login: false'."
