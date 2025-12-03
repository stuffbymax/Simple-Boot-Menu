#!/bin/bash

# ===============================================
#  TUI DASHBOARD V7 (Login Manager / Greeter)
# ===============================================

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${CYAN}=== Installing Linux TUI Dashboard V7 (Login Manager) ===${NC}"

# 1. CHECK ROOT
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root (sudo ./install.sh)${NC}"
  exit 1
fi

# 2. DEPENDENCY CHECK
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python3 is required for password verification.${NC}"
    echo "Please install python3 and run this again."
    exit 1
fi

# 3. INITIAL SETUP
echo -e "\nWhich user should be the DEFAULT selected user?"
read -p "Username: " TARGET_USER

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo -e "${RED}User '$TARGET_USER' does not exist.${NC}"
    exit 1
fi

# 4. CREATE GLOBAL CONFIG
echo -e "${CYAN}Creating global config at /etc/bootmenu.conf...${NC}"
cat << EOF > /etc/bootmenu.conf
# Global Boot Menu Configuration
DEFAULT_USER="$TARGET_USER"
AUTO_LOGIN="true"
THEME_COLOR="6"
THEME_BORDER="1"
EOF
chmod 644 /etc/bootmenu.conf

# 5. WRITE MAIN SCRIPT
echo -e "${CYAN}Installing script to /usr/local/bin/boot_menu.sh...${NC}"

cat << 'EOF' > /usr/local/bin/boot_menu.sh
#!/bin/bash

# --- CONFIGURATION ---
GLOBAL_CONF="/etc/bootmenu.conf"

# Load Config
if [ -f "$GLOBAL_CONF" ]; then source "$GLOBAL_CONF"; fi

# Defaults if config missing
: ${THEME_COLOR:="6"}
: ${THEME_BORDER:="1"}
: ${DEFAULT_USER:="root"}
: ${AUTO_LOGIN:="false"}

# --- COLORS & UTILS ---
tput civis
trap "tput cnorm; clear; exit" INT TERM

C_RESET=$(tput sgr0)
C_BOLD=$(tput bold)
C_SEL_BG=$(tput setab 4); C_SEL_FG=$(tput setaf 7)
C_ERR=$(tput setaf 1)

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
    # We use sed to edit the specific lines in the file to preserve structure
    sudo sed -i "s/^THEME_COLOR=.*/THEME_COLOR=\"$THEME_COLOR\"/" "$GLOBAL_CONF"
    sudo sed -i "s/^THEME_BORDER=.*/THEME_BORDER=\"$THEME_BORDER\"/" "$GLOBAL_CONF"
    sudo sed -i "s/^DEFAULT_USER=.*/DEFAULT_USER=\"$DEFAULT_USER\"/" "$GLOBAL_CONF"
    sudo sed -i "s/^AUTO_LOGIN=.*/AUTO_LOGIN=\"$AUTO_LOGIN\"/" "$GLOBAL_CONF"
}

# --- ROOT MODE: LOGIN MANAGER (GREETER) ---
# This part runs when the script is started by systemd as ROOT
run_greeter_mode() {
    # 1. Check Auto-Login
    if [ "$AUTO_LOGIN" == "true" ]; then
        # Hand off to standard login
        exec /bin/login -f "$DEFAULT_USER"
    fi

    # 2. Show Login Screen
    local users_list=($(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd))
    # Ensure default user is in list
    if [[ ! " ${users_list[*]} " =~ " ${DEFAULT_USER} " ]]; then
        users_list+=("$DEFAULT_USER")
    fi
    
    local sel=0
    # Find index of default user
    for i in "${!users_list[@]}"; do
       if [[ "${users_list[$i]}" = "${DEFAULT_USER}" ]]; then sel=$i; break; fi
    done

    while true; do
        clear
        
        # Draw Box
        local cols=$(tput cols)
        local width=40
        local start_col=$((cols - width - 2))
        local center_start=$(( (cols - 30) / 2 ))
        
        # Draw big header
        tput cup 2 $center_start
        echo -e "${C_ACCENT}${C_BOLD}SYSTEM LOGIN${C_RESET}"
        
        # Draw User List
        tput cup 4 $center_start
        echo -e "Select User:"
        
        for ((i=0; i<${#users_list[@]}; i++)); do
            tput cup $((6+i)) $center_start
            if [ $i -eq $sel ]; then
                echo -e "${C_SEL_BG}${C_SEL_FG} > ${users_list[$i]} ${C_RESET}"
            else
                echo -e "   ${users_list[$i]} "
            fi
        done
        
        local info_y=$((6 + ${#users_list[@]} + 2))
        tput cup $info_y $center_start
        echo -e "${C_BOX}Press Enter to Login${C_RESET}"

        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((sel--));; '[B') ((sel++));; esac
            [ $sel -lt 0 ] && sel=$((${#users_list[@]}-1))
            [ $sel -ge ${#users_list[@]} ] && sel=0
        elif [[ $key == "" ]]; then
            # USER SELECTED -> ASK PASSWORD
            local u="${users_list[$sel]}"
            tput cup $((info_y + 2)) $center_start
            echo -ne "Password: "
            tput cnorm
            read -s password
            tput civis
            echo ""
            
            # VERIFY PASSWORD (Python Wrapper)
            # We use a tiny python script to check /etc/shadow securely
            verify=$(python3 -c "import spwd, crypt, sys; 
try: 
    enc = spwd.getspnam('$u').sp_pwdp; 
    print('OK' if crypt.crypt(sys.argv[1], enc) == enc else 'FAIL')
except: print('FAIL')" "$password")

            if [ "$verify" == "OK" ]; then
                clear
                echo "Welcome, $u."
                exec /bin/login -f "$u"
            else
                tput cup $((info_y + 4)) $center_start
                echo -e "${C_ERR}Incorrect Password${C_RESET}"
                sleep 1
            fi
        fi
    done
}

# --- USER MODE: DASHBOARD ---
# This part runs when logged in as a regular user

get_users() { awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd; }

create_new_user() {
    clear; tput cnorm
    echo -e "${C_ACCENT}--- CREATE NEW USER ---${C_RESET}"
    read -p "Enter new username: " NEW_USER
    if id "$NEW_USER" >/dev/null 2>&1; then echo "User exists!"; sleep 2; return; fi
    sudo useradd -m -G wheel -s /bin/bash "$NEW_USER"
    sudo passwd "$NEW_USER"
    tput civis
}

draw_info_box() {
    # GATHER STATS
    DISTRO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 | head -n 1)
    [ -z "$DISTRO" ] && DISTRO=$(uname -o)
    IP_ADDR=$(hostname -I | awk '{print $1}')
    [ -z "$IP_ADDR" ] && IP_ADDR="Offline"
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2 + $4) "%"}')
    MEM_DATA=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
    DISK_DATA=$(df -h / | awk 'NR==2 {print $5 " used"}')

    # Top App Logic
    read ram_name ram_kb <<< $(ps -eo comm,rss --sort=-rss | awk 'NR==2 {print $1, $2}')
    if [ -n "$ram_kb" ]; then
        if [ "$ram_kb" -gt 1048576 ]; then
            ram_display=$(awk -v val=$ram_kb 'BEGIN {printf "%.1fGB", val/1024/1024}')
        else
            ram_display=$(awk -v val=$ram_kb 'BEGIN {printf "%.0fMB", val/1024}')
        fi
        RAM_HOG="$ram_name ($ram_display)"
    else RAM_HOG="Calculating..."; fi

    read cpu_name cpu_val <<< $(ps -eo comm,pcpu --sort=-pcpu | awk 'NR==2 {print $1, $2}')
    if [ -n "$cpu_val" ]; then CPU_HOG="$cpu_name ($cpu_val%)"; else CPU_HOG="Calculating..."; fi

    # DRAW BOX
    local cols=$(tput cols)
    local width=36
    local start_col=$((cols - width - 2))

    tput cup 1 $start_col
    echo -ne "${C_BOX}${TLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done
    echo -ne "${TRC}${C_RESET}"

    draw_line() {
        local r=$1; local l=$2; local v=$3
        local max_len=$((width - ${#l} - 2))
        if [ ${#v} -gt $max_len ]; then v="${v:0:$((max_len-1))}…"; fi
        tput cup $r $start_col
        echo -e "${C_BOX}${V}${C_RESET} ${C_ACCENT}${l}${C_RESET} ${v}\033[${start_col}G\033[${width}C ${C_BOX}${V}${C_RESET}"
    }

    draw_line 2 "OS:   " "${DISTRO}"
    draw_line 3 "User: " "$USER"
    draw_line 4 "Def.: " "$DEFAULT_USER"
    draw_line 5 "Auto: " "$AUTO_LOGIN"
    
    tput cup 6 $start_col
    echo -e "${C_BOX}${V}${C_RESET} \033[2m────────────────────────────────\033[0m \033[${start_col}G\033[${width}C ${C_BOX}${V}${C_RESET}"

    draw_line 7 "CPU:  " "$CPU_USAGE (Load)"
    draw_line 8 "RAM:  " "$MEM_DATA"
    draw_line 9 "Disk: " "$DISK_DATA"
    draw_line 10 "IP:   " "$IP_ADDR"
    
    tput cup 11 $start_col
    echo -e "${C_BOX}${V}${C_RESET} \033[2m── Top Processes ───────────────\033[0m \033[${start_col}G\033[${width}C ${C_BOX}${V}${C_RESET}"
    
    draw_line 12 "RAM+: " "$RAM_HOG"
    draw_line 13 "CPU+: " "$CPU_HOG"

    tput cup 14 $start_col
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

menu_user_manager() {
    local u_sel=0
    while true; do
        local u_opts=("Toggle Auto-Login (Current: $AUTO_LOGIN)" "Set Default User (Current: $DEFAULT_USER)" "Switch User (Login)" "Create New User" "Change Password" "Back")
        clear; draw_info_box; draw_list "USER MANAGER" u_opts u_sel
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((u_sel--));; '[B') ((u_sel++));; esac
            [ $u_sel -lt 0 ] && u_sel=$(( ${#u_opts[@]} - 1 )); [ $u_sel -ge ${#u_opts[@]} ] && u_sel=0
        elif [[ $key == "" ]]; then
            case $u_sel in
                0) # Toggle Auto Login
                   if [ "$AUTO_LOGIN" == "true" ]; then AUTO_LOGIN="false"; else AUTO_LOGIN="true"; fi
                   save_config ;;
                1) # Set Default User
                   local all_users=($(get_users)); local pick_sel=0
                   while true; do
                       clear; draw_list "SELECT DEFAULT USER" all_users pick_sel
                       read -rsn1 k
                       if [[ $k == "" ]]; then DEFAULT_USER="${all_users[$pick_sel]}"; save_config; break;
                       elif [[ $k == $'\x1b' ]]; then read -rsn2 k; case "$k" in '[A') ((pick_sel--));; '[B') ((pick_sel++));; esac
                            [ $pick_sel -lt 0 ] && pick_sel=$((${#all_users[@]}-1)); [ $pick_sel -ge ${#all_users[@]} ] && pick_sel=0; fi
                   done ;;
                2) tput cnorm; clear; echo "Enter username:"; read target_u; if id "$target_u" >/dev/null 2>&1; then su - "$target_u" -c "$0"; tput civis; else echo "Not found."; sleep 1; fi ;;
                3) create_new_user ;;
                4) tput cnorm; clear; echo "Enter user:"; read pu; sudo passwd "$pu"; tput civis ;;
                5) return ;;
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
    echo -e "${C_BOLD}Network IPs:${C_RESET}"
    ip -4 addr | grep inet | awk '{print "  " $2 " (" $NF ")"}'
    echo -e "\n${C_BOLD}Top 5 Memory Hogs (MB):${C_RESET}"
    ps -eo comm,rss --sort=-rss | head -6 | awk 'NR>1 {printf "  %-20s %d MB\n", $1, $2/1024}'
    echo -e "\n${C_BOLD}Failed Services:${C_RESET}"
    systemctl --failed --no-legend | sed 's/^/  /'
    echo -e "\nPress Key to Return"
    read -rsn1
}

# --- MAIN DISPATCHER ---
if [ "$EUID" -eq 0 ] && [ "$1" != "user_mode" ]; then
    run_greeter_mode
else
    # --- USER MODE MAIN LOOP ---
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
        draw_info_box
        draw_list "BOOT MENU" SESSIONS SEL
        read -rsn1 -t 2 key
        if [ $? -gt 128 ]; then continue; fi
        
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((SEL--)); [[ "${SESSIONS[$SEL]}" == *"──"* ]] && ((SEL--));; '[B') ((SEL++)); [[ "${SESSIONS[$SEL]}" == *"──"* ]] && ((SEL++));; esac
            [ $SEL -lt 0 ] && SEL=$((${#SESSIONS[@]}-1)); [ $SEL -ge ${#SESSIONS[@]} ] && SEL=0
        elif [[ $key == "" ]]; then
            CMD=${CMDS[$SEL]}
            case "$CMD" in
                "none") continue ;;
                "ark") menu_customize; clear ;;
                "debug") menu_debug; clear ;;
                "exit") tput cnorm; clear; exit 0 ;;
                *"systemctl"*) clear; eval $CMD ;;
                *) tput cnorm; clear; if [[ -f ~/.xinitrc ]]; then sed -i '/^exec/d' ~/.xinitrc; echo "exec $CMD" >> ~/.xinitrc; startx; else eval $CMD; fi; exit 0 ;;
            esac
        fi
    done
fi
EOF

chmod +x /usr/local/bin/boot_menu.sh
echo -e "${GREEN}Script installed successfully.${NC}"

# 6. SETUP SYSTEMD SERVICE (ROOT MODE)
echo -e "${CYAN}Configuring Boot Menu Service...${NC}"
SERVICE_FILE="/etc/systemd/system/bootmenu.service"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=TUI Boot Menu Greeter
After=systemd-user-sessions.service plymouth-quit-wait.service
Conflicts=getty@tty1.service

[Service]
ExecStart=/usr/local/bin/boot_menu.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
Type=idle
Environment=TERM=linux
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 7. CLEANUP OLD OVERRIDES
echo -e "${CYAN}Removing old agetty overrides...${NC}"
rm -f /etc/systemd/system/getty@tty1.service.d/override.conf

# 8. ENABLE SERVICE
systemctl daemon-reload
systemctl disable getty@tty1.service
systemctl enable bootmenu.service

# 9. CONFIGURE SHELL HOOK
# This catches the 'login -f' and launches the dashboard in user mode
USER_HOME=$(eval echo "~$TARGET_USER")
SHELL_FILE="$USER_HOME/.bash_profile"
[ -f "$USER_HOME/.bashrc" ] && SHELL_FILE="$USER_HOME/.bashrc"
[ -f "$USER_HOME/.zshrc" ] && SHELL_FILE="$USER_HOME/.zshrc"

if ! grep -q "boot_menu.sh" "$SHELL_FILE"; then
    echo -e "Adding hook to $SHELL_FILE"
    cat << 'EOF' >> "$SHELL_FILE"
# --- TUI BOOT DASHBOARD ---
if [[ -z $DISPLAY ]] && [[ $(tty) = /dev/tty1 ]]; then
    # Signal we are in user mode
    /usr/local/bin/boot_menu.sh user_mode
fi
EOF
    chown "$TARGET_USER" "$SHELL_FILE"
fi

echo -e "\n${GREEN}=== INSTALLATION COMPLETE ===${NC}"
echo "1. Reboot your system."
echo "2. If 'AUTO_LOGIN' is true, it will boot to dashboard."
echo "3. Go to 'Settings / Ark > User Management' to toggle Auto-Login OFF."
echo "4. Next reboot, you will see the Login Screen."
