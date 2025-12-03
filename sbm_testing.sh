#!/bin/bash
# ==============================================================================
#  SBM - Simple Boot Menu (Application Source)
#  Version: 8.0 (Custom Borders & Images)
# ==============================================================================

# --- CONFIGURATION LOADING ---
GLOBAL_CONF="/etc/sbm.conf"

# Default Configuration
: ${THEME_COLOR:="6"}        # Cyan
: ${BORDER_COLOR:="7"}       # White
: ${BORDER_STYLE:="rounded"} # rounded, double, bold, single
: ${DEFAULT_USER:="root"}
: ${AUTO_LOGIN:="false"}
: ${SHOW_IMAGE:="false"}
: ${IMAGE_PATH:="/usr/share/pixmaps/boot_logo.png"}

# Load Global Config
if [ -f "$GLOBAL_CONF" ]; then source "$GLOBAL_CONF"; fi

# --- INITIALIZATION ---
# Hide cursor and handle exit signals
tput civis
trap "tput cnorm; clear; exit" INT TERM

# Base Colors
C_RESET=$(tput sgr0)
C_BOLD=$(tput bold)
C_SEL_BG=$(tput setab 4); C_SEL_FG=$(tput setaf 7)
C_ERR=$(tput setaf 1)

# --- THEME ENGINE ---
apply_theme() {
    # 1. Set Colors
    C_ACCENT=$(tput setaf "$THEME_COLOR")
    C_BORDER=$(tput setaf "$BORDER_COLOR")
    
    # 2. Set Border Characters
    case "$BORDER_STYLE" in
        "double")  TLC="╔" TRC="╗" H="═" V="║" BLC="╚" BRC="╝" ;;
        "rounded") TLC="╭" TRC="╮" H="─" V="│" BLC="╰" BRC="╯" ;;
        "bold")    TLC="┏" TRC="┓" H="━" V="┃" BLC="┗" BRC="┛" ;;
        *)         TLC="┌" TRC="┐" H="─" V="│" BLC="└" BRC="┘" ;; # Default Single
    esac
}
apply_theme

save_config() {
    # Helper to update specific lines in config file using sudo sed
    update_key() {
        local key=$1; local val=$2
        if grep -q "^$key=" "$GLOBAL_CONF"; then
            sudo sed -i "s|^$key=.*|$key=\"$val\"|" "$GLOBAL_CONF"
        else
            echo "$key=\"$val\"" | sudo tee -a "$GLOBAL_CONF" >/dev/null
        fi
    }
    update_key "THEME_COLOR" "$THEME_COLOR"
    update_key "BORDER_COLOR" "$BORDER_COLOR"
    update_key "BORDER_STYLE" "$BORDER_STYLE"
    update_key "DEFAULT_USER" "$DEFAULT_USER"
    update_key "AUTO_LOGIN" "$AUTO_LOGIN"
    update_key "SHOW_IMAGE" "$SHOW_IMAGE"
}

# --- GRAPHICS FUNCTIONS ---

draw_header() {
    local cols=$(tput cols)
    local center=$(( (cols - 30) / 2 ))
    
    if [ "$SHOW_IMAGE" == "true" ] && [ -f "$IMAGE_PATH" ] && command -v chafa >/dev/null; then
        # Draw Image (max 30 cols wide, 10 lines tall)
        tput cup 1 $center
        chafa "$IMAGE_PATH" --size 30x10 --align center --stretch 2>/dev/null
    else
        # Fallback Text Header
        tput cup 2 $center; echo -e "${C_ACCENT}${C_BOLD}      SBM DASHBOARD      ${C_RESET}"
        tput cup 3 $center; echo -e "${C_BORDER}      System Boot Menu     ${C_RESET}"
    fi
}

draw_info_box() {
    # 1. Gather Live Stats
    DISTRO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 | head -n 1); [ -z "$DISTRO" ] && DISTRO=$(uname -o)
    IP=$(hostname -I | awk '{print $1}'); [ -z "$IP" ] && IP="Offline"
    CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2 + $4) "%"}')
    RAM=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
    DISK=$(df -h / | awk 'NR==2 {print $5}')
    
    # Calc Top RAM Process
    read r_n r_k <<< $(ps -eo comm,rss --sort=-rss | awk 'NR==2 {print $1, $2}')
    if [ -n "$r_k" ]; then R_HOG="$r_n ($((r_k/1024))MB)"; else R_HOG="..."; fi

    # 2. Draw Box
    local cols=$(tput cols); local width=34
    local start_col=$((cols - width - 2))

    # Top Border
    tput cup 1 $start_col
    echo -ne "${C_BORDER}${TLC}"; for ((i=0; i<width; i++)); do echo -ne "$H"; done; echo -ne "${TRC}${C_RESET}"
    
    # Line Helper
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
    
    # Separator
    tput cup 5 $start_col
    echo -e "${C_BORDER}${V}${C_RESET} \033[2m──────────────────────────────\033[0m \033[${start_col}G\033[${width}C ${C_BORDER}${V}${C_RESET}"

    d_line 6 "CPU: " "$CPU"
    d_line 7 "RAM: " "$RAM"
    d_line 8 "Disk:" "$DISK"
    d_line 9 "IP:  " "$IP"
    d_line 10 "Hog: " "$R_HOG"

    # Bottom Border
    tput cup 11 $start_col
    echo -ne "${C_BORDER}${BLC}"; for ((i=0; i<width; i++)); do echo -ne "$H"; done; echo -ne "${BRC}${C_RESET}"
}

draw_list() {
    local title=$1; local -n arr=$2; local -n sel=$3
    # Start drawing list below the header/image area
    local start_y=13 
    
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
        draw_header # Update header in case image toggled
        local c_opts=("Text Color:   $THEME_COLOR" "Border Color: $BORDER_COLOR" "Border Style: $BORDER_STYLE" "Show Image:   $SHOW_IMAGE" "Back & Save")
        draw_info_box; draw_list "CUSTOMIZE ARK" c_opts c_sel
        
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((c_sel--));; '[B') ((c_sel++));; esac
            [ $c_sel -lt 0 ] && c_sel=4; [ $c_sel -gt 4 ] && c_sel=0
        elif [[ $key == "" ]]; then
            case $c_sel in
                0) ((THEME_COLOR++)); [ $THEME_COLOR -gt 7 ] && THEME_COLOR=1; apply_theme ;;
                1) ((BORDER_COLOR++)); [ $BORDER_COLOR -gt 7 ] && BORDER_COLOR=1; apply_theme ;;
                2) # Cycle Styles
                   if [ "$BORDER_STYLE" == "single" ]; then BORDER_STYLE="double"
                   elif [ "$BORDER_STYLE" == "double" ]; then BORDER_STYLE="rounded"
                   elif [ "$BORDER_STYLE" == "rounded" ]; then BORDER_STYLE="bold"
                   else BORDER_STYLE="single"; fi; apply_theme ;;
                3) if [ "$SHOW_IMAGE" == "true" ]; then SHOW_IMAGE="false"; else SHOW_IMAGE="true"; fi; clear ;;
                4) save_config; return ;;
            esac
        fi
    done
}

# --- EXECUTION MODES ---

# ROOT MODE: Run as Greeter (Login Manager)
run_greeter() {
    # If Auto-Login is ON, skip everything and login
    if [ "$AUTO_LOGIN" == "true" ]; then
        exec /bin/login -f "$DEFAULT_USER"
    fi

    # Python script to check /etc/shadow securely
    PY_AUTH="import spwd,crypt,sys;
try: print('OK' if crypt.crypt(sys.argv[1], spwd.getspnam(sys.argv[2]).sp_pwdp) == spwd.getspnam(sys.argv[2]).sp_pwdp else 'NO')
except: print('NO')"

    # Get valid users (UID >= 1000)
    local users=($(awk -F: '$3>=1000{print $1}' /etc/passwd))
    local sel=0
    
    while true; do
        clear
        draw_header
        
        # Draw Login List
        local cx=$(( ($(tput cols)-20)/2 )); local cy=14
        tput cup $cy $cx; echo -e "${C_ACCENT}${C_BOLD}SYSTEM LOGIN${C_RESET}"
        
        for ((i=0; i<${#users[@]}; i++)); do
            tput cup $((cy+2+i)) $cx
            if [ $i -eq $sel ]; then
                echo -e "${C_SEL_BG}${C_SEL_FG} > ${users[$i]} ${C_RESET}"
            else
                echo -e "   ${users[$i]} "
            fi
        done
        
        # Key Handling
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
             read -rsn2 key
             [ "$key" == "[A" ] && ((sel--)); [ "$key" == "[B" ] && ((sel++))
             [ $sel -lt 0 ] && sel=$((${#users[@]}-1)); [ $sel -ge ${#users[@]} ] && sel=0
        elif [[ $key == "" ]]; then
             # User Selected
             tput cup $((cy+${#users[@]}+3)) $cx; echo -ne "Password: "
             tput cnorm; read -s pwd; tput civis; echo ""
             
             # Verify
             res=$(python3 -c "$PY_AUTH" "$pwd" "${users[$sel]}")
             if [ "$res" == "OK" ]; then
                 clear; exec /bin/login -f "${users[$sel]}"
             else
                 tput cup $((cy+${#users[@]}+5)) $cx
                 echo -e "${C_ERR}Incorrect Password${C_RESET}"; sleep 1
             fi
        fi
    done
}

# USER MODE: Run as Dashboard
run_dashboard() {
    OPTS=(); CMDS=()
    # Scan for DEs
    for p in /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
        [ -f "$p" ] || continue
        n=$(grep -m1 "^Name=" "$p" | cut -d= -f2); [ -z "$n" ] && n=$(basename "$p" .desktop)
        OPTS+=("$n"); CMDS+=($(grep -m1 "^Exec=" "$p" | cut -d= -f2))
    done
    
    # Add System Tools
    OPTS+=("──────────────")
    CMDS+=("none")
    OPTS+=("Customize / Ark")
    CMDS+=("ark")
    OPTS+=("Shell (Exit)")
    CMDS+=("exit")
    OPTS+=("Reboot")
    CMDS+=("systemctl reboot")
    OPTS+=("Shutdown")
    CMDS+=("systemctl poweroff")
    
    SEL=0
    
    while true; do
        draw_header
        draw_info_box
        draw_list "BOOT MENU" OPTS SEL
        
        # Wait for key with timeout (updates stats)
        read -rsn1 -t 2 key
        [ $? -gt 128 ] && continue # Timeout -> refresh
        
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((SEL--));; '[B') ((SEL++));; esac
            # Skip separator
            if [[ "${OPTS[$SEL]}" == *"──"* ]]; then
                 if [ "$key" == "[A" ]; then ((SEL--)); else ((SEL++)); fi
            fi
            [ $SEL -lt 0 ] && SEL=$((${#OPTS[@]}-1)); [ $SEL -ge ${#OPTS[@]} ] && SEL=0
        elif [[ $key == "" ]]; then
            CMD=${CMDS[$SEL]}
            case "$CMD" in
                "none") continue ;;
                "ark") menu_customize; clear ;;
                "exit") tput cnorm; clear; exit 0 ;;
                *"systemctl"*) clear; eval $CMD ;;
                *) tput cnorm; clear; 
                   if [[ -f ~/.xinitrc ]]; then
                        sed -i '/^exec/d' ~/.xinitrc
                        echo "exec $CMD" >> ~/.xinitrc
                        startx
                   else
                        eval $CMD
                   fi; exit 0 ;;
            esac
        fi
    done
}

# --- ENTRY POINT ---
# Check if running as root without specific argument
if [ "$EUID" -eq 0 ] && [ "$1" != "user_mode" ]; then
    run_greeter
else
    run_dashboard
fi
