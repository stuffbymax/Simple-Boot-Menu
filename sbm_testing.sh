#!/bin/bash
# ==============================================================================
#  SBM - Simple Boot Menu (The Application)
# ==============================================================================

# --- CONFIGURATION ---
GLOBAL_CONF="/etc/sbm.conf"

# Defaults
: ${THEME_COLOR:="6"}       # Cyan
: ${BORDER_COLOR:="7"}      # White
: ${BORDER_STYLE:="rounded"} # rounded, double, bold, single
: ${DEFAULT_USER:="root"}
: ${AUTO_LOGIN:="false"}
: ${SHOW_IMAGE:="false"}
: ${IMAGE_PATH:=""}

# Load Config if exists
if [ -f "$GLOBAL_CONF" ]; then source "$GLOBAL_CONF"; fi

# --- INIT & COLORS ---
tput civis
trap "tput cnorm; clear; exit" INT TERM
C_RESET=$(tput sgr0); C_BOLD=$(tput bold)
C_SEL_BG=$(tput setab 4); C_SEL_FG=$(tput setaf 7); C_ERR=$(tput setaf 1)

# --- THEME ENGINE ---
update_theme() {
    C_ACCENT=$(tput setaf "$THEME_COLOR")
    C_BORDER=$(tput setaf "$BORDER_COLOR")
    
    case "$BORDER_STYLE" in
        "double")  TLC="╔" TRC="╗" H="═" V="║" BLC="╚" BRC="╝" ;;
        "rounded") TLC="╭" TRC="╮" H="─" V="│" BLC="╰" BRC="╯" ;;
        "bold")    TLC="┏" TRC="┓" H="━" V="┃" BLC="┗" BRC="┛" ;;
        *)         TLC="┌" TRC="┐" H="─" V="│" BLC="└" BRC="┘" ;;
    esac
}
update_theme

save_config() {
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
draw_header() {
    local cols=$(tput cols); local center=$(( (cols - 30) / 2 ))
    if [ "$SHOW_IMAGE" == "true" ] && [ -f "$IMAGE_PATH" ] && command -v chafa >/dev/null; then
        tput cup 1 $center; chafa "$IMAGE_PATH" --size 30x10 --align center 2>/dev/null
    else
        tput cup 2 $center; echo -e "${C_ACCENT}${C_BOLD}      SBM DASHBOARD      ${C_RESET}"
        tput cup 3 $center; echo -e "${C_BORDER}      System Boot Menu     ${C_RESET}"
    fi
}

draw_info_box() {
    # Stats
    DISTRO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 | head -n 1); [ -z "$DISTRO" ] && DISTRO=$(uname -o)
    IP=$(hostname -I | awk '{print $1}'); [ -z "$IP" ] && IP="Offline"
    CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2 + $4) "%"}')
    RAM=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
    DISK=$(df -h / | awk 'NR==2 {print $5}')
    read r_n r_k <<< $(ps -eo comm,rss --sort=-rss | awk 'NR==2 {print $1, $2}')
    [ -n "$r_k" ] && R_HOG="$r_n ($((r_k/1024))MB)" || R_HOG="..."

    local cols=$(tput cols); local width=34; local start_col=$((cols - width - 2))

    tput cup 1 $start_col; echo -ne "${C_BORDER}${TLC}"; for ((i=0; i<width; i++)); do echo -ne "$H"; done; echo -ne "${TRC}${C_RESET}"
    
    d_line() {
        local r=$1; local l=$2; local v=$3; local max=$((width - ${#l} - 2))
        if [ ${#v} -gt $max ]; then v="${v:0:$((max-1))}…"; fi
        tput cup $r $start_col
        echo -e "${C_BORDER}${V}${C_RESET} ${C_ACCENT}${l}${C_RESET} ${v}\033[${start_col}G\033[${width}C ${C_BORDER}${V}${C_RESET}"
    }

    d_line 2 "OS:  " "${DISTRO}"; d_line 3 "User:" "$USER"; d_line 4 "Def: " "$DEFAULT_USER"
    tput cup 5 $start_col; echo -e "${C_BORDER}${V}${C_RESET} \033[2m──────────────────────────────\033[0m \033[${start_col}G\033[${width}C ${C_BORDER}${V}${C_RESET}"
    d_line 6 "CPU: " "$CPU"; d_line 7 "RAM: " "$RAM"; d_line 8 "Disk:" "$DISK"; d_line 9 "IP:  " "$IP"; d_line 10 "Hog: " "$R_HOG"
    tput cup 11 $start_col; echo -ne "${C_BORDER}${BLC}"; for ((i=0; i<width; i++)); do echo -ne "$H"; done; echo -ne "${BRC}${C_RESET}"
}

draw_list() {
    local title=$1; local -n arr=$2; local -n sel=$3; local start_y=13
    tput cup $start_y 4; echo -e "${C_ACCENT}${C_BOLD}$title${C_RESET}"
    for ((i=0; i<${#arr[@]}; i++)); do
        tput cup $((start_y + 2 + i)) 4
        if [ $i -eq $sel ]; then echo -e "${C_SEL_BG}${C_SEL_FG} > ${arr[$i]} ${C_RESET}"; else echo -e "   ${arr[$i]} "; fi
    done
}

# --- MENUS ---
menu_customize() {
    local c_sel=0
    while true; do
        draw_header
        local c_opts=("Text Color:   $THEME_COLOR" "Border Color: $BORDER_COLOR" "Border Style: $BORDER_STYLE" "Show Image:   $SHOW_IMAGE" "Back & Save")
        draw_info_box; draw_list "CUSTOMIZE" c_opts c_sel
        read -rsn1 key
        [[ $key == $'\x1b' ]] && { read -rsn2 key; [ "$key" == "[A" ] && ((c_sel--)); [ "$key" == "[B" ] && ((c_sel++)); [ $c_sel -lt 0 ] && c_sel=4; [ $c_sel -gt 4 ] && c_sel=0; }
        [[ $key == "" ]] && {
            case $c_sel in
                0) ((THEME_COLOR++)); [ $THEME_COLOR -gt 7 ] && THEME_COLOR=1; update_theme ;;
                1) ((BORDER_COLOR++)); [ $BORDER_COLOR -gt 7 ] && BORDER_COLOR=1; update_theme ;;
                2) [[ "$BORDER_STYLE" == "single" ]] && BORDER_STYLE="double" || { [[ "$BORDER_STYLE" == "double" ]] && BORDER_STYLE="rounded" || { [[ "$BORDER_STYLE" == "rounded" ]] && BORDER_STYLE="bold" || BORDER_STYLE="single"; }; }; update_theme ;;
                3) [[ "$SHOW_IMAGE" == "true" ]] && SHOW_IMAGE="false" || SHOW_IMAGE="true"; clear ;;
                4) save_config; return ;;
            esac
        }
    done
}

# --- MODES ---
run_greeter() {
    [ "$AUTO_LOGIN" == "true" ] && exec /bin/login -f "$DEFAULT_USER"
    PY_AUTH="import spwd,crypt,sys;
try: print('OK' if crypt.crypt(sys.argv[1], spwd.getspnam(sys.argv[2]).sp_pwdp) == spwd.getspnam(sys.argv[2]).sp_pwdp else 'NO')
except: print('NO')"
    local users=($(awk -F: '$3>=1000{print $1}' /etc/passwd)); local sel=0
    while true; do
        clear; draw_header; local cx=$(( ($(tput cols)-20)/2 )); local cy=14
        tput cup $cy $cx; echo -e "${C_ACCENT}${C_BOLD}SYSTEM LOGIN${C_RESET}"
        for ((i=0; i<${#users[@]}; i++)); do
            tput cup $((cy+2+i)) $cx; [ $i -eq $sel ] && echo -e "${C_SEL_BG}${C_SEL_FG} > ${users[$i]} ${C_RESET}" || echo -e "   ${users[$i]} "
        done
        read -rsn1 key
        [[ $key == $'\x1b' ]] && { read -rsn2 key; [ "$key" == "[A" ] && ((sel--)); [ "$key" == "[B" ] && ((sel++)); [ $sel -lt 0 ] && sel=$((${#users[@]}-1)); [ $sel -ge ${#users[@]} ] && sel=0; }
        [[ $key == "" ]] && {
            tput cup $((cy+${#users[@]}+3)) $cx; echo -ne "Password: "
            tput cnorm; read -s pwd; tput civis; echo ""
            res=$(python3 -c "$PY_AUTH" "$pwd" "${users[$sel]}")
            [[ "$res" == "OK" ]] && { clear; exec /bin/login -f "${users[$sel]}"; } || { echo "Fail"; sleep 1; }
        }
    done
}

# --- MAIN ---
if [ "$EUID" -eq 0 ] && [ "$1" != "user_mode" ]; then
    run_greeter
else
    OPTS=(); CMDS=()
    for p in /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
        [ -f "$p" ] || continue
        n=$(grep -m1 "^Name=" "$p" | cut -d= -f2); [ -z "$n" ] && n=$(basename "$p" .desktop)
        OPTS+=("$n"); CMDS+=($(grep -m1 "^Exec=" "$p" | cut -d= -f2))
    done
    OPTS+=("──────────" "Customize / Ark" "Shell (Exit)" "Reboot" "Shutdown")
    CMDS+=("none" "ark" "exit" "systemctl reboot" "systemctl poweroff")
    SEL=0
    while true; do
        draw_header; draw_info_box; draw_list "BOOT MENU" OPTS SEL
        read -rsn1 -t 2 key; [ $? -gt 128 ] && continue
        [[ $key == $'\x1b' ]] && { read -rsn2 key; [ "$key" == "[A" ] && ((SEL--)); [[ "${OPTS[$SEL]}" == *"──"* ]] && ((SEL--)); [ "$key" == "[B" ] && ((SEL++)); [[ "${OPTS[$SEL]}" == *"──"* ]] && ((SEL++)); [ $SEL -lt 0 ] && SEL=$((${#OPTS[@]}-1)); [ $SEL -ge ${#OPTS[@]} ] && SEL=0; }
        [[ $key == "" ]] && {
            C=${CMDS[$SEL]}
            case "$C" in
                "none") continue ;; "ark") menu_customize; clear ;; "exit") tput cnorm; clear; exit 0 ;; *"systemctl"*) clear; eval $C ;;
                *) tput cnorm; clear; if [[ -f ~/.xinitrc ]]; then sed -i '/^exec/d' ~/.xinitrc; echo "exec $C" >> ~/.xinitrc; startx; else eval $C; fi; exit 0 ;;
            esac
        }
    done
fi
