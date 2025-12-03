#!/bin/bash

# ==========================================
#  TUI DASHBOARD V4 (Enhanced System Info)
# ==========================================

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${CYAN}=== Installing Linux TUI Dashboard V4 ===${NC}"

# 1. CHECK ROOT
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root (sudo ./install.sh)${NC}"
  exit 1
fi

# 2. GET TARGET USER
echo -e "\nWhich user should auto-login to the menu?"
read -p "Username: " TARGET_USER

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo -e "${RED}User '$TARGET_USER' does not exist.${NC}"
    exit 1
fi
echo -e "Target user confirmed: ${GREEN}$TARGET_USER${NC}"

# 3. WRITE THE MAIN SCRIPT
echo -e "${CYAN}Installing script to /usr/local/bin/boot_menu.sh...${NC}"

cat << 'EOF' > /usr/local/bin/boot_menu.sh
#!/bin/bash

# --- CONFIGURATION & INIT ---
CONFIG_FILE="$HOME/.config/bootmenu.conf"
mkdir -p "$(dirname "$CONFIG_FILE")"

# Defaults
THEME_COLOR="6"   # Cyan
THEME_BORDER="1"  # 1=Single, 2=Double

# Load Config
if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi

# Setup Colors & Traps
tput civis
trap "tput cnorm; clear; exit" INT TERM

C_RESET=$(tput sgr0)
C_BOLD=$(tput bold)
C_SEL_BG=$(tput setab 4); C_SEL_FG=$(tput setaf 7)

# Helper: Update Color Scheme
update_colors() {
    C_ACCENT=$(tput setaf "$THEME_COLOR")
    C_BOX=$(tput setaf 8)
    if [ "$THEME_BORDER" == "1" ]; then
        TLC="┌" TRC="┐" H="─" V="│" BLC="└" BRC="┘"
    else
        TLC="╔" TRC="╗" H="═" V="║" BLC="╚" BRC="╝"
    fi
}
update_colors

save_config() {
    echo "THEME_COLOR=\"$THEME_COLOR\"" > "$CONFIG_FILE"
    echo "THEME_BORDER=\"$THEME_BORDER\"" >> "$CONFIG_FILE"
}

# --- SYSTEM DATA ---

get_users() {
    awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd
}

get_default_user() {
    local file="/etc/systemd/system/getty@tty1.service.d/override.conf"
    if [ -f "$file" ]; then
        grep "autologin" "$file" | awk '{print $NF}'
    else
        echo "None"
    fi
}

set_default_user() {
    local target_user=$1
    local service_file="/etc/systemd/system/getty@tty1.service.d/override.conf"
    clear
    echo -e "${C_ACCENT}Setting $target_user as default boot user...${C_RESET}"
    CMD_STR="[Service]
ExecStart=
ExecStart=-/sbin/agetty --skip-login --nonewline --noissue --autologin $target_user --noclear %I \$TERM
TTYVTDisallocate=no"
    echo "$CMD_STR" | sudo tee "$service_file" > /dev/null
    sudo systemctl daemon-reload
    echo -e "${C_BOLD}Done. Reboot to see changes.${C_RESET}"
    sleep 2
}

create_new_user() {
    clear; tput cnorm
    echo -e "${C_ACCENT}--- CREATE NEW USER ---${C_RESET}"
    read -p "Enter new username: " NEW_USER
    if id "$NEW_USER" >/dev/null 2>&1; then echo "User exists!"; sleep 2; return; fi
    sudo useradd -m -G wheel -s /bin/bash "$NEW_USER"
    sudo passwd "$NEW_USER"
    tput civis
}

# --- UI DRAWING ---

draw_info_box() {
    # 1. Gather Real-Time Stats
    DISTRO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 | head -n 1)
    [ -z "$DISTRO" ] && DISTRO=$(uname -o)
    
    # CPU: Load Average
    CPU_LOAD=$(cut -d ' ' -f1 /proc/loadavg)
    
    # RAM: Used / Total
    MEM_DATA=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
    
    # Disk: Root Usage
    DISK_DATA=$(df -h / | awk 'NR==2 {print $3 "/" $2}')
    
    # IP Address (First non-loopback)
    IP_ADDR=$(hostname -I | awk '{print $1}')
    [ -z "$IP_ADDR" ] && IP_ADDR="Offline"

    DEF_USER=$(get_default_user)

    # 2. Draw Box
    local cols=$(tput cols)
    local width=35
    local start_col=$((cols - width - 2))

    # Draw Top Border
    tput cup 1 $start_col
    echo -ne "${C_BOX}${TLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done
    echo -ne "${TRC}${C_RESET}"

    # Helper for lines
    draw_line() {
        local r=$1; local l=$2; local v=$3
        tput cup $r $start_col
        echo -e "${C_BOX}${V}${C_RESET} ${C_ACCENT}${l}${C_RESET} ${v}\033[${start_col}G\033[${width}C ${C_BOX}${V}${C_RESET}"
    }

    draw_line 2 "OS:  " "${DISTRO:0:22}"
    draw_line 3 "User:" "$USER (Def: $DEF_USER)"
    draw_line 4 "─────" "────────────────────────"
    draw_line 5 "CPU: " "Load: $CPU_LOAD"
    draw_line 6 "RAM: " "$MEM_DATA"
    draw_line 7 "Disk:" "$DISK_DATA"
    draw_line 8 "IP:  " "$IP_ADDR"

    # Draw Bottom Border
    tput cup 9 $start_col
    echo -ne "${C_BOX}${BLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done
    echo -ne "${BRC}${C_RESET}"
}

draw_list() {
    local title=$1; local -n arr_opts=$2; local -n arr_sel=$3
    tput cup 2 4
    echo -e "${C_ACCENT}${C_BOLD}$title${C_RESET}"
    for ((i=0; i<${#arr_opts[@]}; i++)); do
        tput cup $((4+i)) 4
        if [ $i -eq $arr_sel ]; then
            echo -e "${C_SEL_BG}${C_SEL_FG} > ${arr_opts[$i]} ${C_RESET}"
        else
            echo -e "   ${arr_opts[$i]} "
        fi
    done
}

# --- MENUS ---

menu_user_manager() {
    local u_sel=0
    while true; do
        local u_opts=("Set Default Boot User" "Switch User (Login)" "Create New User" "Change Password" "Back")
        clear; draw_info_box; draw_list "USER MANAGER" u_opts u_sel
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((u_sel--));; '[B') ((u_sel++));; esac
            [ $u_sel -lt 0 ] && u_sel=$(( ${#u_opts[@]} - 1 )); [ $u_sel -ge ${#u_opts[@]} ] && u_sel=0
        elif [[ $key == "" ]]; then
            case $u_sel in
                0) local all_users=($(get_users)); local pick_sel=0
                   while true; do
                       clear; draw_list "SELECT DEFAULT USER" all_users pick_sel
                       read -rsn1 k
                       if [[ $k == "" ]]; then set_default_user "${all_users[$pick_sel]}"; break;
                       elif [[ $k == $'\x1b' ]]; then read -rsn2 k; case "$k" in '[A') ((pick_sel--));; '[B') ((pick_sel++));; esac
                            [ $pick_sel -lt 0 ] && pick_sel=$((${#all_users[@]}-1)); [ $pick_sel -ge ${#all_users[@]} ] && pick_sel=0; fi
                   done ;;
                1) tput cnorm; clear; echo "Enter username:"; read target_u; if id "$target_u" >/dev/null 2>&1; then su - "$target_u" -c "$0"; tput civis; else echo "Not found."; sleep 1; fi ;;
                2) create_new_user ;;
                3) tput cnorm; clear; echo "Enter user:"; read pu; sudo passwd "$pu"; tput civis ;;
                4) return ;;
            esac
        fi
    done
}

menu_customize() {
    local c_sel=0
    while true; do
        local c_opts=("Color Theme: $THEME_COLOR" "Border Style: $THEME_BORDER" "User Management >" "Save & Back")
        clear; draw_info_box; draw_list "CUSTOMIZE ARK" c_opts c_sel
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((c_sel--));; '[B') ((c_sel++));; esac
            [ $c_sel -lt 0 ] && c_sel=3; [ $c_sel -gt 3 ] && c_sel=0
        elif [[ $key == "" ]]; then
            case $c_sel in
                0) ((THEME_COLOR++)); [ $THEME_COLOR -gt 7 ] && THEME_COLOR=1; update_colors ;;
                1) if [ "$THEME_BORDER" == "1" ]; then THEME_BORDER="2"; else THEME_BORDER="1"; fi; update_colors ;;
                2) menu_user_manager ;;
                3) save_config; return ;;
            esac
        fi
    done
}

menu_debug() {
    clear
    echo -e "${C_ACCENT}--- FULL SYSTEM DEBUG ---${C_RESET}\n"
    echo -e "${C_BOLD}Network:${C_RESET}    $(hostname -I)"
    echo -e "${C_BOLD}Disk Usage:${C_RESET} $(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
    echo -e "${C_BOLD}RAM Usage:${C_RESET}  $(free -h | awk '/^Mem:/ {print $3 " / " $2}')"
    echo -e "${C_BOLD}Uptime:${C_RESET}     $(uptime -p)"
    echo -e "\n${C_BOLD}Failed Services:${C_RESET}"
    systemctl --failed --no-legend | sed 's/^/  /'
    echo -e "\nPress Key to Return"
    read -rsn1
}

# --- MAIN LOOP ---
SESSIONS=(); CMDS=()
for path in /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
    [ -f "$path" ] || continue
    name=$(grep -m 1 "^Name=" "$path" | cut -d= -f2)
    [ -z "$name" ] && name=$(basename "$path" .desktop)
    exec_cmd=$(grep -m 1 "^Exec=" "$path" | cut -d= -f2)
    if [[ ! " ${SESSIONS[*]} " =~ " ${name} " ]]; then SESSIONS+=("$name"); CMDS+=("$exec_cmd"); fi
done
SESSIONS+=("──────────────"); CMDS+=("none")
SESSIONS+=("Settings / Ark"); CMDS+=("ark")
SESSIONS+=("Debug Info"); CMDS+=("debug")
SESSIONS+=("Shell (Exit)"); CMDS+=("exit")
SESSIONS+=("Reboot"); CMDS+=("systemctl reboot")
SESSIONS+=("Shutdown"); CMDS+=("systemctl poweroff")
SEL=0
while true; do
    clear; draw_info_box; draw_list "BOOT MENU" SESSIONS SEL
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 key
        case "$key" in '[A') ((SEL--)); [[ "${SESSIONS[$SEL]}" == *"──"* ]] && ((SEL--));; '[B') ((SEL++)); [[ "${SESSIONS[$SEL]}" == *"──"* ]] && ((SEL++));; esac
        [ $SEL -lt 0 ] && SEL=$((${#SESSIONS[@]}-1)); [ $SEL -ge ${#SESSIONS[@]} ] && SEL=0
    elif [[ $key == "" ]]; then
        CMD=${CMDS[$SEL]}
        case "$CMD" in
            "none") continue ;;
            "ark") menu_customize ;;
            "debug") menu_debug ;;
            "exit") tput cnorm; clear; exit 0 ;;
            *"systemctl"*) clear; eval $CMD ;;
            *) tput cnorm; clear; if [[ -f ~/.xinitrc ]]; then sed -i '/^exec/d' ~/.xinitrc; echo "exec $CMD" >> ~/.xinitrc; startx; else eval $CMD; fi; exit 0 ;;
        esac
    fi
done
EOF

chmod +x /usr/local/bin/boot_menu.sh
echo -e "${GREEN}Script installed successfully.${NC}"

# 4. CONFIG SYSTEMD
echo -e "${CYAN}Configuring Autologin for $TARGET_USER...${NC}"
SERVICE_DIR="/etc/systemd/system/getty@tty1.service.d"
mkdir -p "$SERVICE_DIR"
cat << EOF > "$SERVICE_DIR/override.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --skip-login --nonewline --noissue --autologin $TARGET_USER --noclear %I \$TERM
TTYVTDisallocate=no
EOF
systemctl daemon-reload

# 5. CONFIG SHELL
USER_HOME=$(eval echo "~$TARGET_USER")
SHELL_FILE="$USER_HOME/.bash_profile"
[ -f "$USER_HOME/.bashrc" ] && SHELL_FILE="$USER_HOME/.bashrc"
[ -f "$USER_HOME/.zshrc" ] && SHELL_FILE="$USER_HOME/.zshrc"

if ! grep -q "boot_menu.sh" "$SHELL_FILE"; then
    echo -e "Adding hook to $SHELL_FILE"
    cat << 'EOF' >> "$SHELL_FILE"
# --- TUI BOOT DASHBOARD ---
if [[ -z $DISPLAY ]] && [[ $(tty) = /dev/tty1 ]]; then
    /usr/local/bin/boot_menu.sh
fi
EOF
    chown "$TARGET_USER" "$SHELL_FILE"
fi

echo -e "\n${GREEN}=== COMPLETE ===${NC}"
echo "Reboot to see your new Debug Info Dashboard."
