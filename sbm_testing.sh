#!/bin/bash

# ==========================================
#   CORE - Console Login & Session Manager
# ==========================================

# --- CONFIGURATION & INIT ---
CONFIG_DIR="$HOME/.config/core"
CONFIG_FILE="$CONFIG_DIR/core.conf"
mkdir -p "$CONFIG_DIR"

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

get_users() {
    awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd
}

set_default_user() {
    local target_user=$1
    local service_dir="/etc/systemd/system/getty@tty1.service.d"
    local service_file="$service_dir/override.conf"

    clear
    echo -e "${C_ACCENT}Setting $target_user as default Core user...${C_RESET}"
    echo "Enter sudo password if requested:"
    
    CMD_STR="[Service]
ExecStart=
ExecStart=-/sbin/agetty --skip-login --nonewline --noissue --autologin $target_user --noclear %I \$TERM
TTYVTDisallocate=no"

    if echo "$CMD_STR" | sudo tee "$service_file" > /dev/null; then
        sudo systemctl daemon-reload
        echo -e "${C_BOLD}Success. Reboot to auto-login as $target_user.${C_RESET}"
    else
        echo -e "${C_BOLD}Failed. Ensure you have sudo privileges.${C_RESET}"
    fi
    sleep 2
}

create_new_user() {
    clear
    tput cnorm
    echo -e "${C_ACCENT}--- CREATE NEW USER ---${C_RESET}"
    read -p "Enter new username: " NEW_USER
    
    if [ -z "$NEW_USER" ]; then return; fi

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
    MEM=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
    
    local cols=$(tput cols)
    local width=32
    local start_col=$((cols - width - 2))

    tput cup 1 $start_col
    echo -ne "${C_BOX}${TLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done
    echo -ne "${TRC}${C_RESET}"

    # Centered Title
    local title=" CORE MANAGER "
    local title_len=${#title}
    local pad=$(( (width - title_len) / 2 ))
    tput cup 1 $((start_col + pad + 1)); echo -e "${C_ACCENT}${C_BOLD}${title}${C_RESET}"

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
    local -n arr_opts=$2 
    local -n arr_sel=$3
    
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

# --- 4. SESSION LAUNCHER (LOGIN MANAGER LOGIC) ---

launch_session() {
    local cmd="$1"
    local type="$2" # "x11" or "wayland"
    local name="$3"

    tput cnorm; clear
    echo -e "${C_ACCENT}Starting ${name}...${C_RESET}"
    
    # 1. Source Profiles (Important for PATH and Env Vars)
    if [ -f /etc/profile ]; then source /etc/profile; fi
    if [ -f "$HOME/.profile" ]; then source "$HOME/.profile"; fi

    # 2. Setup Logging
    local logfile="$HOME/.core-session.log"
    echo "--- Starting Session: $(date) ---" > "$logfile"
    
    # 3. Launch Logic
    if [ "$type" == "x11" ]; then
        # Handle X11: Safely modify .xinitrc
        local xinitrc="$HOME/.xinitrc"
        local xinitrc_bak="$HOME/.xinitrc.core.bak"

        [ -f "$xinitrc" ] && cp "$xinitrc" "$xinitrc_bak"

        # Create temporary xinitrc
        echo "#!/bin/sh" > "$xinitrc"
        echo "if [ -f /etc/xprofile ]; then . /etc/xprofile; fi" >> "$xinitrc"
        echo "if [ -f ~/.xprofile ]; then . ~/.xprofile; fi" >> "$xinitrc"
        echo "exec $cmd" >> "$xinitrc"
        
        # Start X
        startx >> "$logfile" 2>&1
        
        # Restore original if it existed
        if [ -f "$xinitrc_bak" ]; then
            mv "$xinitrc_bak" "$xinitrc"
        else
            rm "$xinitrc"
        fi

    elif [ "$type" == "wayland" ]; then
        # Handle Wayland: Set env vars and exec
        export XDG_SESSION_TYPE=wayland
        export XDG_CURRENT_DESKTOP=$name
        
        # Direct execution redirecting output
        eval exec "$cmd" >> "$logfile" 2>&1
    else
        # Fallback
        eval "$cmd"
    fi
    
    # If we are here, the session failed or exited
    tput civis
    clear
    echo "Session exited."
    sleep 1
}

# --- 5. MENUS ---

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
                       fi
                   done
                   ;;
                1) # Switch User
                    tput cnorm; clear
                    echo -e "${C_ACCENT}Login as:${C_RESET}"
                    read target_u
                    if id "$target_u" >/dev/null 2>&1; then
                        # Clear screen and switch
                        clear
                        su - "$target_u" -c "$0"
                        # Reset terminal on return
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
        draw_list "CUSTOMIZE CORE" c_opts c_sel
        
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
    echo -e "${C_ACCENT}--- CORE DEBUG INFO ---${C_RESET}\n"
    echo -e "${C_BOLD}IP:${C_RESET} $(hostname -I)"
    echo -e "${C_BOLD}Display Server:${C_RESET} ${XDG_SESSION_TYPE:-TTY}"
    echo -e "${C_BOLD}Disk:${C_RESET} $(df -h / | awk 'NR==2 {print $5}')"
    echo -e "${C_BOLD}Failed Services:${C_RESET}"
    systemctl --failed --no-legend | sed 's/^/  /'
    echo -e "\nPress Key to Return"
    read -rsn1
}

# --- 6. MAIN LOOP ---

# Scan Sessions (Distinguish X11 vs Wayland)
SESSIONS=()
CMDS=()
TYPES=()

# Scan X11
for path in /usr/share/xsessions/*.desktop; do
    [ -f "$path" ] || continue
    name=$(grep -m 1 "^Name=" "$path" | cut -d= -f2)
    [ -z "$name" ] && name=$(basename "$path" .desktop)
    exec_cmd=$(grep -m 1 "^Exec=" "$path" | cut -d= -f2)
    
    SESSIONS+=("$name")
    CMDS+=("$exec_cmd")
    TYPES+=("x11")
done

# Scan Wayland
for path in /usr/share/wayland-sessions/*.desktop; do
    [ -f "$path" ] || continue
    name=$(grep -m 1 "^Name=" "$path" | cut -d= -f2)
    [ -z "$name" ] && name=$(basename "$path" .desktop)
    exec_cmd=$(grep -m 1 "^Exec=" "$path" | cut -d= -f2)
    
    # Avoid duplicates if they exist in both
    if [[ ! " ${SESSIONS[*]} " =~ " ${name} " ]]; then
        SESSIONS+=("$name (Wayland)")
        CMDS+=("$exec_cmd")
        TYPES+=("wayland")
    fi
done

# Add Tools
SESSIONS+=("──────────────"); CMDS+=("none"); TYPES+=("none")
SESSIONS+=("Settings / Core"); CMDS+=("core_settings"); TYPES+=("internal")
SESSIONS+=("Debug Info"); CMDS+=("debug"); TYPES+=("internal")
SESSIONS+=("Shell (Exit)"); CMDS+=("exit"); TYPES+=("internal")
SESSIONS+=("Reboot"); CMDS+=("systemctl reboot"); TYPES+=("cmd")
SESSIONS+=("Shutdown"); CMDS+=("systemctl poweroff"); TYPES+=("cmd")

SEL=0

while true; do
    clear
    draw_info_box
    draw_list "CORE MENU" SESSIONS SEL
    
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
        TYPE=${TYPES[$SEL]}
        NAME=${SESSIONS[$SEL]}

        case "$TYPE" in
            "none") continue ;;
            "internal")
                if [ "$CMD" == "core_settings" ]; then menu_customize; fi
                if [ "$CMD" == "debug" ]; then menu_debug; fi
                if [ "$CMD" == "exit" ]; then tput cnorm; clear; exit 0; fi
                ;;
            "cmd")
                clear; eval $CMD
                ;;
            "x11"|"wayland")
                launch_session "$CMD" "$TYPE" "$NAME"
                exit 0
                ;;
        esac
    fi
done
