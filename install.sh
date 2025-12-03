#!/bin/bash

# Colors for the installer output
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}=== Linux TUI Boot Menu Installer ===${NC}"

# 1. Check for Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo ./install.sh)${NC}"
  exit 1
fi

# 2. Get Target Username
# We need to know WHICH user to auto-login.
read -p "Enter your Linux username: " TARGET_USER

if id "$TARGET_USER" >/dev/null 2>&1; then
    echo -e "Installing for user: ${GREEN}$TARGET_USER${NC}"
else
    echo -e "${RED}User '$TARGET_USER' does not exist.${NC}"
    exit 1
fi

# 3. Create the Main Script (/usr/local/bin/boot_menu.sh)
echo -e "Writing boot menu script to /usr/local/bin/boot_menu.sh..."

cat << 'EOF' > /usr/local/bin/boot_menu.sh
#!/bin/bash

# --- CONFIG & COLORS ---
tput civis # Hide cursor
C_RESET=$(tput sgr0)
C_SEL_BG=$(tput setab 4)  # Blue BG
C_SEL_FG=$(tput setaf 7)  # White FG
C_ACCENT=$(tput setaf 6)  # Cyan
C_BOX=$(tput setaf 8)     # Grey
trap "tput cnorm; exit" INT TERM

# --- DATA GATHERING ---
DISTRO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 | head -n 1)
[ -z "$DISTRO" ] && DISTRO=$(uname -o)
KERNEL=$(uname -r)
MEM_USED=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
OPTIONS=()
COMMANDS=()

scan_sessions() {
    for path in /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
        if [ -f "$path" ]; then
            local name=$(grep -m 1 "^Name=" "$path" | cut -d= -f2)
            [ -z "$name" ] && name=$(basename "$path" .desktop)
            local exec_cmd=$(grep -m 1 "^Exec=" "$path" | cut -d= -f2)
            if [[ ! " ${OPTIONS[*]} " =~ " ${name} " ]]; then
                OPTIONS+=("$name")
                COMMANDS+=("$exec_cmd")
            fi
        fi
    done
}
scan_sessions
OPTIONS+=("Shell (Exit TUI)")
COMMANDS+=("exit")
OPTIONS+=("Reboot")
COMMANDS+=("systemctl reboot")
OPTIONS+=("Shutdown")
COMMANDS+=("systemctl poweroff")

# --- TUI DRAWING ---
draw_ui() {
    local cols=$(tput cols)
    local width=30
    local start_col=$((cols - width - 2))
    
    # Draw Info Box
    tput cup 1 $start_col
    echo -e "${C_BOX}┌────────────────────────────┐${C_RESET}"
    tput cup 2 $start_col
    echo -e "${C_BOX}│${C_RESET} ${C_ACCENT}OS:${C_RESET} ${DISTRO:0:15}...\033[${start_col}G\033[29C${C_BOX}│${C_RESET}"
    tput cup 3 $start_col
    echo -e "${C_BOX}│${C_RESET} ${C_ACCENT}Kr:${C_RESET} ${KERNEL}\033[${start_col}G\033[29C${C_BOX}│${C_RESET}"
    tput cup 4 $start_col
    echo -e "${C_BOX}│${C_RESET} ${C_ACCENT}Me:${C_RESET} ${MEM_USED}\033[${start_col}G\033[29C${C_BOX}│${C_RESET}"
    tput cup 5 $start_col
    echo -e "${C_BOX}└────────────────────────────┘${C_RESET}"

    # Draw Menu
    tput cup 2 4
    echo -e "${C_ACCENT}SELECT SESSION${C_RESET}"
    for ((i=0; i<${#OPTIONS[@]}; i++)); do
        tput cup $((4 + i)) 4
        if [ $i -eq $SELECTED ]; then
            echo -e "${C_SEL_BG}${C_SEL_FG}  > ${OPTIONS[$i]}  ${C_RESET}"
        else
            echo -e "    ${OPTIONS[$i]}   "
        fi
    done
}

# --- MAIN LOOP ---
SELECTED=0
TOTAL=${#OPTIONS[@]}
clear
while true; do
    draw_ui
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 key
        case "$key" in
            '[A') ((SELECTED--)); [ $SELECTED -lt 0 ] && SELECTED=$((TOTAL-1));;
            '[B') ((SELECTED++)); [ $SELECTED -ge $TOTAL ] && SELECTED=0;;
        esac
    elif [[ $key == "" ]]; then break; fi
done

# --- EXECUTION ---
tput cnorm
clear
CMD=${COMMANDS[$SELECTED]}
NAME=${OPTIONS[$SELECTED]}

if [[ "$NAME" == "Reboot" ]] || [[ "$NAME" == "Shutdown" ]] || [[ "$NAME" == "Shell" ]]; then
    eval $CMD
else
    # Launch Window Manager/DE
    if [[ -f ~/.xinitrc ]]; then
        # Check if we should append or replace
        if ! grep -q "$CMD" ~/.xinitrc; then
             echo "exec $CMD" > ~/.xinitrc
        fi
        startx
    else
        # Try direct execution (better for Wayland)
        eval $CMD
    fi
fi
EOF

chmod +x /usr/local/bin/boot_menu.sh
echo -e "${GREEN}Script created successfully.${NC}"

# 4. Configure Systemd Autologin (Getty Override)
echo -e "Configuring Systemd Autologin for tty1..."

SERVICE_DIR="/etc/systemd/system/getty@tty1.service.d"
mkdir -p "$SERVICE_DIR"

cat << EOF > "$SERVICE_DIR/override.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --skip-login --nonewline --noissue --autologin $TARGET_USER --noclear %I \$TERM
TTYVTDisallocate=no
EOF

# Reload daemon to pick up changes
systemctl daemon-reload
echo -e "${GREEN}Systemd override configured.${NC}"

# 5. Configure User Shell Profile
USER_HOME=$(eval echo "~$TARGET_USER")
PROFILE_FILE=""

if [ -f "$USER_HOME/.zshrc" ]; then
    PROFILE_FILE="$USER_HOME/.zshrc"
elif [ -f "$USER_HOME/.bash_profile" ]; then
    PROFILE_FILE="$USER_HOME/.bash_profile"
elif [ -f "$USER_HOME/.bashrc" ]; then
    PROFILE_FILE="$USER_HOME/.bashrc"
else
    # Fallback to creating bash_profile
    PROFILE_FILE="$USER_HOME/.bash_profile"
    touch "$PROFILE_FILE"
fi

echo -e "Adding auto-start hook to ${CYAN}$PROFILE_FILE${NC}..."

# We append the logic to the user's config
# This check ensures we don't add it twice
if ! grep -q "boot_menu.sh" "$PROFILE_FILE"; then
cat << 'EOF' >> "$PROFILE_FILE"

# --- TUI BOOT MENU START ---
if [[ -z $DISPLAY ]] && [[ $(tty) = /dev/tty1 ]]; then
    /usr/local/bin/boot_menu.sh
fi
# --- TUI BOOT MENU END ---
EOF
    echo -e "${GREEN}Hook added.${NC}"
else
    echo -e "${CYAN}Hook already exists in profile file. Skipping.${NC}"
fi

# Fix ownership if we edited user files as root
chown "$TARGET_USER:$TARGET_USER" "$PROFILE_FILE"

# 6. Final Warnings / Instructions
echo -e "\n${GREEN}=== INSTALLATION COMPLETE ===${NC}"
echo -e "To make this work, you must DISABLE your current Display Manager (GDM, SDDM, LightDM)."
echo -e "Example: ${CYAN}sudo systemctl disable gdm${NC} (or lightdm / sddm)"
echo -e "Then reboot."
