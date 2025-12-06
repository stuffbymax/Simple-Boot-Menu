#!/bin/bash

# ==========================================
#   CORE - Integrated Session Manager
# ==========================================

# --- 1. CONFIGURATION & SETUP ---
CONFIG_DIR="$HOME/.config/core"
CONFIG_FILE="$CONFIG_DIR/core.conf"
CACHE_FILE="$CONFIG_DIR/last_session"
mkdir -p "$CONFIG_DIR"

# Defaults
THEME_COLOR="6"   # 1=Red, 2=Green, 6=Cyan
THEME_BORDER="1"  # 1=Single, 2=Double

# Load Config
if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi

# Terminal Setup
tput civis # Hide cursor
trap "tput cnorm; clear; exit" INT TERM

# Colors
C_RESET=$(tput sgr0)
C_RED=$(tput setaf 1)
C_GREEN=$(tput setaf 2)
C_CYAN=$(tput setaf 6)
C_WHITE=$(tput setaf 7)
C_GREY=$(tput setaf 8)
C_BOLD=$(tput bold)
C_ACCENT=$(tput setaf "$THEME_COLOR")
C_SEL_BG=$(tput setab "$THEME_COLOR"); C_SEL_FG=$(tput setaf 0)

# Borders
if [ "$THEME_BORDER" == "1" ]; then
    TLC="┌" TRC="┐" H="─" V="│" BLC="└" BRC="┘"
else
    TLC="╔" TRC="╗" H="═" V="║" BLC="╚" BRC="╝"
fi

save_config() {
    echo "THEME_COLOR=\"$THEME_COLOR\"" > "$CONFIG_FILE"
    echo "THEME_BORDER=\"$THEME_BORDER\"" >> "$CONFIG_FILE"
}

# --- 2. DATA GATHERING ---

get_users() {
    mapfile -t USER_LIST < <(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd)
    if [ ${#USER_LIST[@]} -eq 0 ]; then USER_LIST=("root"); fi
}

scan_sessions() {
    SESSION_NAMES=()
    SESSION_CMDS=()
    SESSION_TYPES=()

    # Scan Wayland
    for path in /usr/share/wayland-sessions/*.desktop; do
        [ -f "$path" ] || continue
        name=$(grep -m 1 "^Name=" "$path" | cut -d= -f2)
        exec_cmd=$(grep -m 1 "^Exec=" "$path" | cut -d= -f2)
        [ -z "$name" ] && name=$(basename "$path" .desktop)
        SESSION_NAMES+=("$name (Wayland)")
        SESSION_CMDS+=("$exec_cmd")
        SESSION_TYPES+=("wayland")
    done

    # Scan X11
    for path in /usr/share/xsessions/*.desktop; do
        [ -f "$path" ] || continue
        name=$(grep -m 1 "^Name=" "$path" | cut -d= -f2)
        exec_cmd=$(grep -m 1 "^Exec=" "$path" | cut -d= -f2)
        [ -z "$name" ] && name=$(basename "$path" .desktop)
        # Avoid dupes
        if [[ ! " ${SESSION_NAMES[*]} " =~ " ${name} " ]]; then
            SESSION_NAMES+=("$name")
            SESSION_CMDS+=("$exec_cmd")
            SESSION_TYPES+=("x11")
        fi
    done
    
    if [ ${#SESSION_NAMES[@]} -eq 0 ]; then
        SESSION_NAMES=("Shell"); SESSION_CMDS=("/bin/bash"); SESSION_TYPES=("shell")
    fi
}

# --- 3. AUTHENTICATION (PYTHON WRAPPER) ---
verify_credentials() {
    local user=$1; local pass=$2
    if [ "$EUID" -ne 0 ]; then return 1; fi # Must be root
    python3 -c "
import crypt, spwd, sys
try:
    enc = spwd.getspnam(sys.argv[1]).sp_pwdp
    if enc in ['NP', '!', '*']: sys.exit(1)
    if crypt.crypt(sys.argv[2], enc) == enc: sys.exit(0)
    else: sys.exit(1)
except: sys.exit(1)
" "$user" "$pass"
}

# --- 4. UI: HELPERS ---

draw_header() {
    clear
    local cols=$(tput cols)
    local width=40
    local start_col=$(( (cols - width) / 2 ))
    
    DISTRO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 | head -n 1)
    MEM=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
    
    tput cup 1 $start_col; echo -ne "${C_GREY}${TLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done; echo -ne "${TRC}${C_RESET}"

    # Centered Title
    local title=" CORE MANAGER "
    local title_len=${#title}
    local pad=$(( (width - title_len) / 2 ))
    tput cup 1 $((start_col + pad + 1)); echo -e "${C_ACCENT}${C_BOLD}${title}${C_RESET}"

    tput cup 2 $start_col; echo -e "${C_GREY}${V}${C_RESET} ${C_ACCENT}OS:${C_RESET}   ${DISTRO:0:25}\033[${start_col}G\033[${width}C ${C_GREY}${V}${C_RESET}"
    tput cup 3 $start_col; echo -e "${C_GREY}${V}${C_RESET} ${C_ACCENT}MEM:${C_RESET}  ${MEM} ${width}C ${C_GREY}${V}${C_RESET}"

    tput cup 4 $start_col; echo -ne "${C_GREY}${BLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done; echo -ne "${BRC}${C_RESET}"
}

# --- 5. SCREEN: LOGIN (The Visual Style) ---

screen_login() {
    get_users
    scan_sessions
    
    # Load defaults
    local sel_u=0; local sel_s=0
    if [ -f "$CACHE_FILE" ]; then source "$CACHE_FILE"; fi
    for i in "${!USER_LIST[@]}"; do [[ "${USER_LIST[$i]}" == "$LAST_USER" ]] && sel_u=$i; done
    for i in "${!SESSION_NAMES[@]}"; do [[ "${SESSION_NAMES[$i]}" == "$LAST_SESSION" ]] && sel_s=$i; done

    local focus=2 # Start on password
    local input_pass=""
    local status=""
    local stat_col=$C_RED

    while true; do
        clear
        draw_header # Keeps the nice box at top
        
        local cy=10
        local cols=$(tput cols); local cx=$((cols/2))
        
        # Draw Status
        tput cup $((cy - 2)) 0
        if [ ! -z "$status" ]; then
            local msg="< $status >"
            local start=$(( (cols - ${#msg}) / 2 ))
            tput cup $((cy - 2)) $start
            echo -e "${stat_col}${C_BOLD}${msg}${C_RESET}"
        fi

        # 1. Session
        local c_foc=$C_GREY
        [ $focus -eq 0 ] && c_foc=$C_ACCENT
        tput cup $cy $((cx - 20)); echo -e "${C_GREY}session${C_RESET}"
        tput cup $cy $((cx - 5)); echo -e "${c_foc}< ${C_WHITE}${SESSION_NAMES[$sel_s]} ${c_foc}>${C_RESET}"

        # 2. User
        c_foc=$C_GREY
        [ $focus -eq 1 ] && c_foc=$C_ACCENT
        tput cup $((cy+2)) $((cx - 20)); echo -e "${C_GREY}login${C_RESET}"
        tput cup $((cy+2)) $((cx - 5)); echo -e "${c_foc}< ${C_WHITE}${USER_LIST[$sel_u]} ${c_foc}>${C_RESET}"

        # 3. Password
        c_foc=$C_GREY; local cursor=""
        if [ $focus -eq 2 ]; then c_foc=$C_WHITE; cursor="${C_ACCENT}█${C_RESET}"; fi
        local mask=""; for ((i=0; i<${#input_pass}; i++)); do mask+="*"; done
        
        tput cup $((cy+4)) $((cx - 20)); echo -e "${C_GREY}password${C_RESET}"
        tput cup $((cy+4)) $((cx - 5)); echo -e "${c_foc}${mask}${cursor}    "

        # Input Handling
        IFS= read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in
                '[A') ((focus--)); [ $focus -lt 0 ] && focus=2 ;;
                '[B') ((focus++)); [ $focus -gt 2 ] && focus=0 ;;
                '[C') # Right
                     if [ $focus -eq 0 ]; then ((sel_s++)); [ $sel_s -ge ${#SESSION_NAMES[@]} ] && sel_s=0; fi
                     if [ $focus -eq 1 ]; then ((sel_u++)); [ $sel_u -ge ${#USER_LIST[@]} ] && sel_u=0; fi ;;
                '[D') # Left
                     if [ $focus -eq 0 ]; then ((sel_s--)); [ $sel_s -lt 0 ] && sel_s=$((${#SESSION_NAMES[@]}-1)); fi
                     if [ $focus -eq 1 ]; then ((sel_u--)); [ $sel_u -lt 0 ] && sel_u=$((${#USER_LIST[@]}-1)); fi ;;
            esac
            # Escape to go back to menu
            if [[ $key == "" ]]; then return; fi 
        elif [[ $key == "" ]]; then
            if [ $focus -ne 2 ]; then focus=2; else
                # Login Attempt
                status="Verifying..."; stat_col=$C_CYAN; input_pass=""
                if verify_credentials "${USER_LIST[$sel_u]}" "$input_pass"; then
                     # Launch Logic
                     echo "LAST_USER=\"${USER_LIST[$sel_u]}\"" > "$CACHE_FILE"
                     echo "LAST_SESSION=\"${SESSION_NAMES[$sel_s]}\"" >> "$CACHE_FILE"
                     
                     local cmd="${SESSION_CMDS[$sel_s]}"
                     local type="${SESSION_TYPES[$sel_s]}"
                     local user="${USER_LIST[$sel_u]}"
                     local log="/home/$user/.core-session.log"
                     
                     tput cnorm; clear; echo "Launching..."
                     
                     if [ "$type" == "wayland" ]; then
                        su - "$user" -c "export XDG_SESSION_TYPE=wayland; export XDG_CURRENT_DESKTOP=${SESSION_NAMES[$sel_s]}; exec $cmd" > "$log" 2>&1
                     elif [ "$type" == "x11" ]; then
                        su - "$user" -c "echo 'exec $cmd' > ~/.xinitrc; startx" > "$log" 2>&1
                     else
                        su - "$user" -c "$cmd"
                     fi
                     
                     tput civis; status="Logged Out"; stat_col=$C_RED
                else
                     status="failed to get lock state"; stat_col=$C_RED; input_pass=""
                fi
            fi
        elif [[ $key == $'\x7f' || $key == $'\x08' ]]; then
            if [ $focus -eq 2 ] && [ ${#input_pass} -gt 0 ]; then input_pass="${input_pass::-1}"; fi
        elif [[ $key == $'\t' ]]; then
             ((focus++)); [ $focus -gt 2 ] && focus=0
        else
            if [ $focus -eq 2 ]; then input_pass+="$key"; fi
        fi
        
        # Handle password input correctly inside loop
        if [ "$focus" -eq 2 ] && [[ "$key" != "" && "$key" != $'\x1b' && "$key" != $'\t' && "$key" != $'\x7f' ]]; then
             # This extra check handles the fact that we already read the key
             # but mapped it to var inside the else block above
             :
        fi
    done
}

# --- 6. SCREEN: MAIN MENU ---

screen_menu() {
    local m_sel=0
    local m_opts=("Login to Desktop" "Core Settings" "System Info" "Reboot" "Shutdown")
    
    while true; do
        draw_header
        
        # Draw Menu List
        local cy=7
        local cols=$(tput cols)
        local cx=$(( (cols - 30) / 2 ))
        
        for ((i=0; i<${#m_opts[@]}; i++)); do
            tput cup $((cy+i)) $cx
            if [ $i -eq $m_sel ]; then
                echo -e "${C_SEL_BG}${C_SEL_FG} > ${m_opts[$i]}            ${C_RESET}"
            else
                echo -e "   ${m_opts[$i]}            "
            fi
        done
        
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((m_sel--));; '[B') ((m_sel++));; esac
            [ $m_sel -lt 0 ] && m_sel=$(( ${#m_opts[@]} - 1 ))
            [ $m_sel -ge ${#m_opts[@]} ] && m_sel=0
        elif [[ $key == "" ]]; then
            case $m_sel in
                0) screen_login ;;
                1) 
                   # Simple Setting Toggle
                   ((THEME_COLOR++)); [ $THEME_COLOR -gt 7 ] && THEME_COLOR=1
                   C_ACCENT=$(tput setaf "$THEME_COLOR"); C_SEL_BG=$(tput setab "$THEME_COLOR")
                   save_config ;;
                2) # Info
                   clear; echo -e "${C_ACCENT}IP:${C_RESET} $(hostname -I)"; read -rsn1 ;;
                3) systemctl reboot ;;
                4) systemctl poweroff ;;
            esac
        fi
    done
}

# --- 7. START ---
# Ensure we are on a clean screen
tput cnorm
screen_menu
