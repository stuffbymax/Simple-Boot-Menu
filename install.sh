#!/bin/bash

# ===============================================
#  TUI DASHBOARD V8 (Custom Borders & Images)
# ===============================================

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${CYAN}=== Installing Linux TUI Dashboard V8 ===${NC}"

# 1. CHECK ROOT
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root (sudo ./install.sh)${NC}"
  exit 1
fi

# 2. DEPENDENCY CHECK (Python & Chafa)
echo -e "${CYAN}Checking dependencies...${NC}"
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python3 is required for login.${NC}"; exit 1
fi

# Install Chafa for Image support if missing
if ! command -v chafa &> /dev/null; then
    echo "Installing 'chafa' for image support..."
    apt-get install -y chafa 2>/dev/null || pacman -S --noconfirm chafa 2>/dev/null || dnf install -y chafa 2>/dev/null
    if ! command -v chafa &> /dev/null; then
        echo -e "${RED}Warning: 'chafa' could not be installed. Image mode will fail gracefully.${NC}"
    fi
fi

# 3. USER CONFIG
echo -e "\nWhich user should be the DEFAULT selected user?"
read -p "Username: " TARGET_USER

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo -e "${RED}User '$TARGET_USER' does not exist.${NC}"; exit 1
fi

# 4. GLOBAL CONFIG
CONFIG_FILE="/etc/bootmenu.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${CYAN}Creating global config at $CONFIG_FILE...${NC}"
    cat << EOF > "$CONFIG_FILE"
# Global Boot Menu Configuration
DEFAULT_USER="$TARGET_USER"
AUTO_LOGIN="true"
THEME_COLOR="6"        # 1=Red, 2=Green, 3=Yellow, 4=Blue, 5=Purple, 6=Cyan, 7=White
BORDER_COLOR="7"       # Independent Border Color
BORDER_STYLE="rounded" # single, double, rounded, bold
SHOW_IMAGE="false"     # Set to true to show image
IMAGE_PATH="/usr/share/pixmaps/boot_logo.png" # Put your png/jpg here
EOF
    chmod 644 "$CONFIG_FILE"
else
    echo -e "${CYAN}Updating existing config...${NC}"
    # Append new vars if missing
    grep -q "BORDER_COLOR" "$CONFIG_FILE" || echo 'BORDER_COLOR="7"' >> "$CONFIG_FILE"
    grep -q "BORDER_STYLE" "$CONFIG_FILE" || echo 'BORDER_STYLE="rounded"' >> "$CONFIG_FILE"
    grep -q "SHOW_IMAGE" "$CONFIG_FILE" || echo 'SHOW_IMAGE="false"' >> "$CONFIG_FILE"
    grep -q "IMAGE_PATH" "$CONFIG_FILE" || echo 'IMAGE_PATH="/usr/share/pixmaps/boot_logo.png"' >> "$CONFIG_FILE"
fi

# 5. WRITE MAIN SCRIPT
echo -e "${CYAN}Installing script to /usr/local/bin/boot_menu.sh...${NC}"

cat << 'EOF' > /usr/local/bin/boot_menu.sh
#!/bin/bash

# --- CONFIGURATION ---
GLOBAL_CONF="/etc/bootmenu.conf"
if [ -f "$GLOBAL_CONF" ]; then source "$GLOBAL_CONF"; fi

# Defaults
: ${THEME_COLOR:="6"}
: ${BORDER_COLOR:="7"}
: ${BORDER_STYLE:="rounded"}
: ${DEFAULT_USER:="root"}
: ${AUTO_LOGIN:="false"}
: ${SHOW_IMAGE:="false"}
: ${IMAGE_PATH:=""}

# --- INIT ---
tput civis
trap "tput cnorm; clear; exit" INT TERM
C_RESET=$(tput sgr0); C_BOLD=$(tput bold)
C_SEL_BG=$(tput setab 4); C_SEL_FG=$(tput setaf 7); C_ERR=$(tput setaf 1)

# --- THEME ENGINE ---
update_theme() {
    # Text Color
    C_ACCENT=$(tput setaf "$THEME_COLOR")
    # Border Color
    C_BORDER=$(tput setaf "$BORDER_COLOR")
    
    # Border Styles
    case "$BORDER_STYLE" in
        "double")  TLC="╔" TRC="╗" H="═" V="║" BLC="╚" BRC="╝" ;;
        "rounded") TLC="╭" TRC="╮" H="─" V="│" BLC="╰" BRC="╯" ;;
        "bold")    TLC="┏" TRC="┓" H="━" V="┃" BLC="┗" BRC="┛" ;;
        *)         TLC="┌" TRC="┐" H="─" V="│" BLC="└" BRC="┘" ;; # Single
    esac
}
update_theme

save_config() {
    # Helper to sed in place
    update_conf() {
        local key=$1; local val=$2
        if grep -q "^$key=" "$GLOBAL_CONF"; then
            sudo sed -i "s|^$key=.*|$key=\"$val\"|" "$GLOBAL_CONF"
        else
            echo "$key=\"$val\"" | sudo tee -a "$GLOBAL_CONF" >/dev/null
        fi
    }
    update_conf "THEME_COLOR" "$THEME_COLOR"
    update_conf "BORDER_COLOR" "$BORDER_COLOR"
    update_conf "BORDER_STYLE" "$BORDER_STYLE"
    update_conf "DEFAULT_USER" "$DEFAULT_USER"
    update_conf "AUTO_LOGIN" "$AUTO_LOGIN"
    update_conf "SHOW_IMAGE" "$SHOW_IMAGE"
}

# --- GRAPHICS ---

draw_image_or_logo() {
    local cols=$(tput cols)
    local center=$(( (cols - 30) / 2 ))
    
    if [ "$SHOW_IMAGE" == "true" ] && [ -f "$IMAGE_PATH" ] && command -v chafa >/dev/null; then
        # Draw Image using Chafa (Sized to fit above menu)
        tput cup 1 $center
        # We limit size to 30 cols wide, 10 lines high
        chafa "$IMAGE_PATH" --size 30x10 --align center 2>/dev/null
    else
        # Fallback ASCII Logo
        tput cup 2 $center
        echo -e "${C_ACCENT}${C_BOLD}    LINUX DASHBOARD    ${C_RESET}"
        tput cup 3 $center
        echo -e "${C_BORDER}    V8 Custom Edition    ${C_RESET}"
    fi
}

draw_info_box() {
    # Live Stats
    DISTRO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 | head -n 1)
    [ -z "$DISTRO" ] && DISTRO=$(uname -o)
    IP=$(hostname -I | awk '{print $1}')
    [ -z "$IP" ] && IP="Offline"
    CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2 + $4) "%"}')
    RAM=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
    DISK=$(df -h / | awk 'NR==2 {print $5}')
    
    # Top Processes
    read r_n r_k <<< $(ps -eo comm,rss --sort=-rss | awk 'NR==2 {print $1, $2}')
    [ -n "$r_k" ] && R_HOG="$r_n ($((r_k/1024))MB)" || R_HOG="..."

    # Draw Box
    local cols=$(tput cols); local width=34
    local start_col=$((cols - width - 2))

    # Box Borders
    tput cup 1 $start_col
    echo -ne "${C_BORDER}${TLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done
    echo -ne "${TRC}${C_RESET}"

    # Helper
    d_line() {
        local r=$1; local l=$2; local v=$3
        local max=$((width - ${#l} - 2))
        if [ ${#v} -gt $max ]; then v="${v:0:$((max-1))}…"; fi
        tput cup $r $start_col
        echo -e "${C_BORDER}${V}${C_RESET} ${C_ACCENT}${l}${C_RESET} ${v}\033[${start_col}G\033[${width}C ${C_BORDER}${V}${C_RESET}"
    }

    d_line 2 "OS:  " "${DISTRO}"
    d_line 3 "User:" "$USER"
    d_line 4 "Def: " "$DEFAULT_USER"
    d_line 5 "Auto:" "$AUTO_LOGIN"
    
    tput cup 6 $start_col; echo -e "${C_BORDER}${V}${C_RESET} \033[2m──────────────────────────────\033[0m \033[${start_col}G\033[${width}C ${C_BORDER}${V}${C_RESET}"

    d_line 7 "CPU: " "$CPU"
    d_line 8 "RAM: " "$RAM"
    d_line 9 "Disk:" "$DISK"
    d_line 10 "IP:  " "$IP"
    d_line 11 "Hog: " "$R_HOG"

    tput cup 12 $start_col
    echo -ne "${C_BORDER}${BLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done
    echo -ne "${BRC}${C_RESET}"
}

draw_list() {
    local title=$1; local -n arr=$2; local -n sel=$3
    
    # Header placement (below image area)
    local start_y=14 
    
    tput cup $start_y 4
    echo -e "${C_ACCENT}${C_BOLD}$title${C_RESET}"
    
    for ((i=0; i<${#arr[@]}; i++)); do
        tput cup $((start_y + 2 + i)) 4
        if [ $i -eq $sel ]; then
            echo -e "${C_SEL_BG}${C_SEL_FG} > ${arr[$i]} ${C_RESET}"
        else
            echo -e "   ${arr[$i]} "
        fi
    done
}

# --- MENUS ---

menu_customize() {
    local c_sel=0
    while true; do
        draw_image_or_logo
        local c_opts=(
            "Text Color:   $THEME_COLOR" 
            "Border Color: $BORDER_COLOR" 
            "Border Style: $BORDER_STYLE" 
            "Show Image:   $SHOW_IMAGE"
            "User Management >" 
            "Save & Back"
        )
        draw_info_box
        draw_list "CUSTOMIZE ARK" c_opts c_sel
        
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((c_sel--));; '[B') ((c_sel++));; esac
            [ $c_sel -lt 0 ] && c_sel=5; [ $c_sel -gt 5 ] && c_sel=0
        elif [[ $key == "" ]]; then
            case $c_sel in
                0) ((THEME_COLOR++)); [ $THEME_COLOR -gt 7 ] && THEME_COLOR=1; update_theme ;;
                1) ((BORDER_COLOR++)); [ $BORDER_COLOR -gt 7 ] && BORDER_COLOR=1; update_theme ;;
                2) # Cycle Styles
                   if [ "$BORDER_STYLE" == "single" ]; then BORDER_STYLE="double"
                   elif [ "$BORDER_STYLE" == "double" ]; then BORDER_STYLE="rounded"
                   elif [ "$BORDER_STYLE" == "rounded" ]; then BORDER_STYLE="bold"
                   else BORDER_STYLE="single"; fi; update_theme ;;
                3) if [ "$SHOW_IMAGE" == "true" ]; then SHOW_IMAGE="false"; else SHOW_IMAGE="true"; fi; clear ;;
                4) menu_user_manager; clear ;;
                5) save_config; return ;;
            esac
        fi
    done
}

menu_user_manager() {
    local u_sel=0
    while true; do
        local u_opts=("Toggle Auto-Login ($AUTO_LOGIN)" "Set Default ($DEFAULT_USER)" "Switch User" "Create User" "Back")
        draw_info_box; draw_list "USER MANAGER" u_opts u_sel
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((u_sel--));; '[B') ((u_sel++));; esac
            [ $u_sel -lt 0 ] && u_sel=4; [ $u_sel -gt 4 ] && u_sel=0
        elif [[ $key == "" ]]; then
            case $u_sel in
                0) [ "$AUTO_LOGIN" == "true" ] && AUTO_LOGIN="false" || AUTO_LOGIN="true"; save_config ;;
                1) local all=($(awk -F: '$3>=1000{print $1}' /etc/passwd)); local p_sel=0;
                   while true; do clear; draw_list "PICK USER" all p_sel; read -rsn1 k;
                   [[ $k == "" ]] && { DEFAULT_USER="${all[$p_sel]}"; save_config; break; };
                   [[ $k == $'\x1b' ]] && { read -rsn2 k; [ "$k" == "[A" ] && ((p_sel--)); [ "$k" == "[B" ] && ((p_sel++)); };
                   [ $p_sel -lt 0 ] && p_sel=$((${#all[@]}-1)); [ $p_sel -ge ${#all[@]} ] && p_sel=0; done ;;
                2) tput cnorm; clear; read -p "User: " tu; id "$tu" >/dev/null && su - "$tu" -c "$0" || sleep 1; tput civis; clear ;;
                3) tput cnorm; clear; read -p "New User: " nu; sudo useradd -m -s /bin/bash "$nu" && sudo passwd "$nu"; tput civis; clear ;;
                4) return ;;
            esac
        fi
    done
}

menu_debug() {
    clear; echo -e "${C_ACCENT}SYSTEM DEBUG${C_RESET}\n"
    ip -4 addr | grep inet; echo ""
    systemctl --failed --no-legend
    read -rsn1
}

# --- MODES ---

run_greeter() {
    [ "$AUTO_LOGIN" == "true" ] && exec /bin/login -f "$DEFAULT_USER"
    
    # Python Auth Script
    PY_AUTH="import spwd,crypt,sys;
try: print('OK' if crypt.crypt(sys.argv[1], spwd.getspnam(sys.argv[2]).sp_pwdp) == spwd.getspnam(sys.argv[2]).sp_pwdp else 'NO')
except: print('NO')"

    local users=($(awk -F: '$3>=1000{print $1}' /etc/passwd))
    local sel=0
    
    while true; do
        clear
        draw_image_or_logo
        # Center Login
        local cx=$(( ($(tput cols)-20)/2 )); local cy=14
        tput cup $cy $cx; echo -e "${C_ACCENT}${C_BOLD}SYSTEM LOGIN${C_RESET}"
        
        for ((i=0; i<${#users[@]}; i++)); do
            tput cup $((cy+2+i)) $cx
            [ $i -eq $sel ] && echo -e "${C_SEL_BG}${C_SEL_FG} > ${users[$i]} ${C_RESET}" || echo -e "   ${users[$i]} "
        done
        
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
             read -rsn2 key; [ "$key" == "[A" ] && ((sel--)); [ "$key" == "[B" ] && ((sel++));
             [ $sel -lt 0 ] && sel=$((${#users[@]}-1)); [ $sel -ge ${#users[@]} ] && sel=0
        elif [[ $key == "" ]]; then
             tput cup $((cy+${#users[@]}+3)) $cx; echo -ne "Password: "
             tput cnorm; read -s pwd; tput civis; echo ""
             res=$(python3 -c "$PY_AUTH" "$pwd" "${users[$sel]}")
             if [ "$res" == "OK" ]; then clear; exec /bin/login -f "${users[$sel]}"; else echo "Fail"; sleep 1; fi
        fi
    done
}

# --- MAIN ---
if [ "$EUID" -eq 0 ] && [ "$1" != "user_mode" ]; then
    run_greeter
else
    # SESSIONS
    OPTS=(); CMDS=()
    for p in /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
        [ -f "$p" ] || continue
        n=$(grep -m1 "^Name=" "$p" | cut -d= -f2); [ -z "$n" ] && n=$(basename "$p" .desktop)
        OPTS+=("$n"); CMDS+=($(grep -m1 "^Exec=" "$p" | cut -d= -f2))
    done
    OPTS+=("──────────"); CMDS+=("none")
    OPTS+=("Settings / Ark"); CMDS+=("ark")
    OPTS+=("Debug Info"); CMDS+=("debug")
    OPTS+=("Exit"); CMDS+=("exit")
    OPTS+=("Reboot"); CMDS+=("systemctl reboot")
    OPTS+=("Shutdown"); CMDS+=("systemctl poweroff")
    SEL=0
    
    while true; do
        draw_image_or_logo
        draw_info_box
        draw_list "BOOT MENU" OPTS SEL
        
        read -rsn1 -t 2 key
        [ $? -gt 128 ] && continue
        
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((SEL--)); [[ "${OPTS[$SEL]}" == *"──"* ]] && ((SEL--));; '[B') ((SEL++)); [[ "${OPTS[$SEL]}" == *"──"* ]] && ((SEL++));; esac
            [ $SEL -lt 0 ] && SEL=$((${#OPTS[@]}-1)); [ $SEL -ge ${#OPTS[@]} ] && SEL=0
        elif [[ $key == "" ]]; then
            C=${CMDS[$SEL]}
            case "$C" in
                "none") continue ;;
                "ark") menu_customize; clear ;;
                "debug") menu_debug; clear ;;
                "exit") tput cnorm; clear; exit 0 ;;
                *"systemctl"*) clear; eval $C ;;
                *) tput cnorm; clear; if [[ -f ~/.xinitrc ]]; then sed -i '/^exec/d' ~/.xinitrc; echo "exec $C" >> ~/.xinitrc; startx; else eval $C; fi; exit 0 ;;
            esac
        fi
    done
fi
EOF

chmod +x /usr/local/bin/boot_menu.sh
echo -e "${GREEN}Script V8 installed.${NC}"

# 6. SYSTEMD & SHELL
cat << EOF > /etc/systemd/system/bootmenu.service
[Unit]
Description=TUI Boot V8
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

systemctl daemon-reload
systemctl disable getty@tty1.service
systemctl enable bootmenu.service

UH=$(eval echo "~$TARGET_USER"); SF="$UH/.bash_profile"
[ -f "$UH/.bashrc" ] && SF="$UH/.bashrc"
if ! grep -q "boot_menu.sh" "$SF"; then
    echo 'if [[ -z $DISPLAY ]] && [[ $(tty) = /dev/tty1 ]]; then /usr/local/bin/boot_menu.sh user_mode; fi' >> "$SF"
    chown "$TARGET_USER" "$SF"
fi

echo -e "\n${GREEN}=== V8 INSTALLED ===${NC}"
echo "To use an image:"
echo "1. Place a .png or .jpg at /etc/boot_logo.png (or any path)"
echo "2. Edit /etc/bootmenu.conf and set IMAGE_PATH"
echo "3. In the menu, go to Settings and toggle 'Show Image'"
