#!/bin/bash

# --- CONFIGURATION & INIT ---
CONFIG_FILE="$HOME/.config/bootmenu.conf"
mkdir -p "$(dirname "$CONFIG_FILE")"

# Defaults
THEME_COLOR="6"   # Cyan
THEME_BORDER="1"  # 1=Single, 2=Double
THEME_STYLE="box" 

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

# --- 2. USER MANAGEMENT LOGIC ---

# Get list of "real" users (UID >= 1000)
get_users() {
    awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd
}

# Get current auto-login user
get_default_user() {
    # grep the override file for the username
    local file="/etc/systemd/system/getty@tty1.service.d/override.conf"
    if [ -f "$file" ]; then
        grep "autologin" "$file" | awk '{print $NF}'
    else
        echo "None"
    fi
}

set_default_user() {
    local target_user=$1
    local service_dir="/etc/systemd/system/getty@tty1.service.d"
    local service_file="$service_dir/override.conf"

    # We need sudo to write to /etc/
    clear
    echo -e "${C_ACCENT}Setting $target_user as default boot user...${C_RESET}"
    echo "Enter sudo password if requested:"
    
    # Create the override file content
    CMD_STR="[Service]
ExecStart=
ExecStart=-/sbin/agetty --skip-login --nonewline --noissue --autologin $target_user --noclear %I \$TERM
TTYVTDisallocate=no"

    # Write file using sudo bash -c
    echo "$CMD_STR" | sudo tee "$service_file" > /dev/null
    sudo systemctl daemon-reload
    
    echo -e "${C_BOLD}Done. Reboot to see changes.${C_RESET}"
    sleep 2
}

create_new_user() {
    clear
    tput cnorm
    echo -e "${C_ACCENT}--- CREATE NEW USER ---${C_RESET}"
    read -p "Enter new username: " NEW_USER
    
    if id "$NEW_USER" >/dev/null 2>&1; then
        echo "User already exists!"
        sleep 2; return
    fi
    
    echo "Creating user $NEW_USER..."
    sudo useradd -m -G wheel -s /bin/bash "$NEW_USER"
    
    echo "Set password for $NEW_USER:"
    sudo passwd "$NEW_USER"
    
    echo "User created."
    sleep 2
    tput civis
}

# --- 3. UI DRAWING ---

draw_info_box() {
    DISTRO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 | head -n 1)
    KERNEL=$(uname -r)
    MEM=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
    
    local cols=$(tput cols)
    local width=32
    local start_col=$((cols - width - 2))

    tput cup 1 $start_col
    echo -ne "${C_BOX}${TLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done
    echo -ne "${TRC}${C_RESET}"

    tput cup 2 $start_col; echo -e "${C_BOX}${V}${C_RESET} ${C_ACCENT}OS:${C_RESET}   ${DISTRO:0:20}\033[${start_col}G\033[${width}C ${C_BOX}${V}${C_RESET}"
    tput cup 3 $start_col; echo -e "${C_BOX}${V}${C_RESET} ${C_ACCENT}MEM:${C_RESET}  ${MEM} ${width}C ${C_BOX}${V}${C_RESET}"
    tput cup 4 $start_col; echo -e "${C_BOX}${V}${C_RESET} ${C_ACCENT}User:${C_RESET} ${USER}\033[${start_col}G\033[${width}C ${C_BOX}${V}${C_RESET}"

    tput cup 5 $start_col
    echo -ne "${C_BOX}${BLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done
    echo -ne "${BRC}${C_RESET}"
}

draw_list() {
    local title=$1
    local -n arr_opts=$2 # Nameref for array
    local -n arr_sel=$3  # Nameref for selection index
    
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

# --- 4. MENUS ---

menu_user_manager() {
    local u_sel=0
    while true; do
        local u_opts=("Set Default Boot User" "Switch User (Login)" "Create New User" "Change Password" "Back")
        clear
        draw_info_box
        draw_list "USER MANAGER" u_opts u_sel
        
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((u_sel--));; '[B') ((u_sel++));; esac
            [ $u_sel -lt 0 ] && u_sel=$(( ${#u_opts[@]} - 1 ))
            [ $u_sel -ge ${#u_opts[@]} ] && u_sel=0
        elif [[ $key == "" ]]; then
            case $u_sel in
                0) # Set Default
                   # Create a list of users to pick from
                   local all_users=($(get_users))
                   local pick_sel=0
                   while true; do
                       clear; draw_list "SELECT DEFAULT USER" all_users pick_sel
                       read -rsn1 k
                       if [[ $k == "" ]]; then
                           set_default_user "${all_users[$pick_sel]}"
                           break
                       elif [[ $k == $'\x1b' ]]; then
                            read -rsn2 k
                            case "$k" in '[A') ((pick_sel--));; '[B') ((pick_sel++));; esac
                            [ $pick_sel -lt 0 ] && pick_sel=$((${#all_users[@]}-1))
                            [ $pick_sel -ge ${#all_users[@]} ] && pick_sel=0
                       fi
                   done
                   ;;
                1) # Switch User
                    tput cnorm; clear
                    echo "Enter username to login as:"
                    read target_u
                    # Check if user exists
                    if id "$target_u" >/dev/null 2>&1; then
                        # Switch user and run this script again
                        su - "$target_u" -c "$0"
                        # When they exit that shell, we return here
                        tput civis
                    else
                        echo "User not found."; sleep 1
                    fi
                   ;;
                2) create_new_user ;;
                3) tput cnorm; clear; echo "Enter user to change password:"; read pu; sudo passwd "$pu"; tput civis ;;
                4) return ;;
            esac
        fi
    done
}

menu_customize() {
    local c_sel=0
    while true; do
        local c_opts=("Color Theme: $THEME_COLOR" "Border Style: $THEME_BORDER" "User Management >" "Save & Back")
        clear
        draw_info_box
        draw_list "CUSTOMIZE ARK" c_opts c_sel
        
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((c_sel--));; '[B') ((c_sel++));; esac
            [ $c_sel -lt 0 ] && c_sel=3; [ $c_sel -gt 3 ] && c_sel=0
        elif [[ $key == "" ]]; then
            case $c_sel in
                0) # Color
                   ((THEME_COLOR++)); [ $THEME_COLOR -gt 7 ] && THEME_COLOR=1
                   update_colors ;;
                1) # Border
                   if [ "$THEME_BORDER" == "1" ]; then THEME_BORDER="2"; else THEME_BORDER="1"; fi
                   update_colors ;;
                2) menu_user_manager ;;
                3) save_config; return ;;
            esac
        fi
    done
}

menu_debug() {
    clear
    echo -e "${C_ACCENT}--- DEBUG INFO ---${C_RESET}\n"
    echo -e "${C_BOLD}IP:${C_RESET} $(hostname -I)"
    echo -e "${C_BOLD}Disk:${C_RESET} $(df -h / | awk 'NR==2 {print $5}')"
    echo -e "${C_BOLD}Failed Services:${C_RESET}"
    systemctl --failed --no-legend | sed 's/^/  /'
    echo -e "\nPress Key to Return"
    read -rsn1
}

# --- 5. MAIN LOOP ---

# Scan Sessions
SESSIONS=()
CMDS=()
for path in /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
    [ -f "$path" ] || continue
    name=$(grep -m 1 "^Name=" "$path" | cut -d= -f2)
    [ -z "$name" ] && name=$(basename "$path" .desktop)
    exec_cmd=$(grep -m 1 "^Exec=" "$path" | cut -d= -f2)
    if [[ ! " ${SESSIONS[*]} " =~ " ${name} " ]]; then
        SESSIONS+=("$name"); CMDS+=("$exec_cmd")
    fi
done

# Add Tools
SESSIONS+=("──────────────"); CMDS+=("none")
SESSIONS+=("Settings / Ark"); CMDS+=("ark")
SESSIONS+=("Debug Info"); CMDS+=("debug")
SESSIONS+=("Shell (Exit)"); CMDS+=("exit")
SESSIONS+=("Reboot"); CMDS+=("systemctl reboot")
SESSIONS+=("Shutdown"); CMDS+=("systemctl poweroff")

SEL=0

while true; do
    clear
    draw_info_box
    draw_list "BOOT MENU" SESSIONS SEL
    
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 key
        case "$key" in
            '[A') ((SEL--)); [[ "${SESSIONS[$SEL]}" == *"──"* ]] && ((SEL--));;
            '[B') ((SEL++)); [[ "${SESSIONS[$SEL]}" == *"──"* ]] && ((SEL++));;
        esac
        [ $SEL -lt 0 ] && SEL=$((${#SESSIONS[@]}-1))
        [ $SEL -ge ${#SESSIONS[@]} ] && SEL=0
    elif [[ $key == "" ]]; then
        CMD=${CMDS[$SEL]}
        case "$CMD" in
            "none") continue ;;
            "ark") menu_customize ;;
            "debug") menu_debug ;;
            "exit") tput cnorm; clear; exit 0 ;;
            *"systemctl"*) clear; eval $CMD ;;
            *) 
                tput cnorm; clear
                if [[ -f ~/.xinitrc ]]; then
                    sed -i '/^exec/d' ~/.xinitrc
                    echo "exec $CMD" >> ~/.xinitrc
                    startx
                else
                    eval $CMD
                fi
                exit 0
                ;;
        esac
    fi
done
