#!/bin/bash

# ==========================================
#  SBM V3 INSTALLER (System Boot Manager)
# ==========================================

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${CYAN}=== Installing SBM (System Boot Manager) v0.0.1 ===${NC}"

# 1. CHECK ROOT
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root (sudo ./install.sh)${NC}"
  exit 1
fi

# 2. INSTALL DEPENDENCIES
echo -e "\n${CYAN}[1/4] Checking dependencies...${NC}"

# Check for Python3 (Crucial for password hashing)
if ! command -v python3 &> /dev/null; then
    echo "Installing python3..."
    apt-get install -y python3 2>/dev/null || pacman -S --noconfirm python3 2>/dev/null || dnf install -y python3 2>/dev/null
fi

# Check for Tput/Ncurses
if ! command -v tput &> /dev/null; then
    echo "Installing ncurses-bin..."
    apt-get install -y ncurses-bin 2>/dev/null || pacman -S --noconfirm ncurses 2>/dev/null || dnf install -y ncurses 2>/dev/null
fi

# 3. WRITE THE SBM SCRIPT
echo -e "${CYAN}[2/4] Installing SBM to /usr/local/bin/sbm...${NC}"

cat << 'EOF' > /usr/local/bin/sbm
#!/bin/bash

# ==============================================================================
#   SBM - System Boot Manager v0.0.1
#   A lightweight, hybrid console/graphical login manager.
# ==============================================================================

# --- 1. INITIALIZATION & CONFIG ---
SBM_VERSION="0.0.1"
CONFIG_DIR="$HOME/.config/sbm"
CONFIG_FILE="$CONFIG_DIR/sbm.conf"
CACHE_FILE="$CONFIG_DIR/last_session"
LOG_DIR="/var/log/sbm"

mkdir -p "$CONFIG_DIR"
mkdir -p "$LOG_DIR"

# Defaults
THEME_COLOR="6"   # Cyan
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
C_BOX=$(tput setaf 8)

# Borders
if [ "$THEME_BORDER" == "1" ]; then
    TLC="┌" TRC="┐" H="─" V="│" BLC="└" BRC="┘"
else
    TLC="╔" TRC="╗" H="═" V="║" BLC="╚" BRC="╝"
fi

# --- 2. UTILITIES ---

save_config() {
    echo "THEME_COLOR=\"$THEME_COLOR\"" > "$CONFIG_FILE"
    echo "THEME_BORDER=\"$THEME_BORDER\"" >> "$CONFIG_FILE"
}

update_colors() {
    C_ACCENT=$(tput setaf "$THEME_COLOR")
    C_SEL_BG=$(tput setab "$THEME_COLOR")
}

get_ip() {
    local ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    if [ -z "$ip" ]; then echo "Offline"; else echo "$ip"; fi
}

get_users() {
    # Get users UID >= 1000
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

# --- 3. AUTHENTICATION & SECURITY ---

verify_credentials() {
    local user=$1; local pass=$2
    
    # Check for empty password users (NOPASSWD)
    local status_str=$(passwd -S "$user" 2>/dev/null | awk '{print $2}')
    if [[ "$status_str" == "NP" ]]; then return 0; fi

    # If input empty but user has password, fail
    if [ -z "$pass" ]; then return 1; fi

    # Python Shadow Check
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

# --- 4. SESSION LAUNCHER (The Core Logic) ---

prepare_env_script() {
    local user=$1
    local type=$2
    local cmd=$3
    local desktop_name=$4
    local script_path="/tmp/sbm-start-$user.sh"
    
    # Get user shell
    local user_shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
    if [ -z "$user_shell" ]; then user_shell="/bin/bash"; fi

    # Create the launch script
    cat <<EOF > "$script_path"
#!$user_shell
# SBM Session Wrapper

# 1. Source Profiles
[ -f /etc/profile ] && . /etc/profile
[ -f \$HOME/.profile ] && . \$HOME/.profile
[ -f \$HOME/.bash_profile ] && . \$HOME/.bash_profile

# 2. Set XDG Variables
export XDG_SEAT="seat0"
export XDG_VTNR="\$(tty | tr -dc '0-9')"
export XDG_SESSION_CLASS="user"
export XDG_SESSION_TYPE="$type"
export HOME="/home/$user"
export USER="$user"
export SHELL="$user_shell"

# 3. Type Specifics
if [ "$type" == "wayland" ]; then
    export XDG_CURRENT_DESKTOP="$desktop_name"
    # Ensure Runtime Dir exists (handled by logind usually, but safety check)
    if [ -z "\$XDG_RUNTIME_DIR" ]; then
        export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
    fi
    exec $cmd
elif [ "$type" == "x11" ]; then
    # Generate Xauthority if missing
    if [ ! -f \$HOME/.Xauthority ]; then
        xauth generate :0 . trusted >/dev/null 2>&1
    fi
    
    # Create temp xinitrc
    echo "exec $cmd" > \$HOME/.xinitrc
    exec startx
else
    exec $cmd
fi
EOF

    chmod +x "$script_path"
    chown "$user:$user" "$script_path"
    echo "$script_path"
}

launch_session() {
    local cmd="$1"
    local type="$2"
    local user="$3"
    local name="$4"
    local logfile="$LOG_DIR/${user}.log"

    tput cnorm; clear
    echo -e "${C_ACCENT}Initializing session for $user...${C_RESET}"
    
    # Prepare Log
    touch "$logfile"
    chown "$user:$user" "$logfile"
    
    # Create wrapper script
    local starter_script
    starter_script=$(prepare_env_script "$user" "$type" "$cmd" "$name")
    
    # Execute as user
    # We use 'su -' to ensure login shell behavior
    su - "$user" -c "$starter_script" > "$logfile" 2>&1
    
    # Cleanup
    rm -f "$starter_script"
    
    tput civis
}

# --- 5. UI COMPONENTS ---

draw_header() {
    clear
    local cols=$(tput cols)
    local width=44
    local start_col=$(( (cols - width) / 2 ))
    
    DISTRO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 | head -n 1)
    
    tput cup 1 $start_col; echo -ne "${C_BOX}${TLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done; echo -ne "${TRC}${C_RESET}"

    local title=" SBM v$SBM_VERSION "
    local title_len=${#title}
    local pad=$(( (width - title_len) / 2 ))
    tput cup 1 $((start_col + pad + 1)); echo -e "${C_ACCENT}${C_BOLD}${title}${C_RESET}"

    tput cup 2 $start_col; echo -e "${C_BOX}${V}${C_RESET} ${C_ACCENT}System:${C_RESET} ${DISTRO:0:25}\033[${start_col}G\033[${width}C ${C_BOX}${V}${C_RESET}"
    tput cup 3 $start_col; echo -e "${C_BOX}${V}${C_RESET} ${C_ACCENT}Host:${C_RESET}   $(hostname) ($(get_ip))\033[${start_col}G\033[${width}C ${C_BOX}${V}${C_RESET}"

    tput cup 4 $start_col; echo -ne "${C_BOX}${BLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done; echo -ne "${BRC}${C_RESET}"
}

draw_list() {
    local title=$1; local -n arr=$2; local -n sel=$3
    local cy=8
    local cols=$(tput cols)
    local cx=$(( (cols - 30) / 2 ))
    
    tput cup $((cy-2)) $cx; echo -e "${C_ACCENT}${C_BOLD}$title${C_RESET}"
    
    for ((i=0; i<${#arr[@]}; i++)); do
        tput cup $((cy+i)) $cx
        if [ $i -eq $sel ]; then
            echo -e "${C_SEL_BG}${C_SEL_FG} > ${arr[$i]}            ${C_RESET}"
        else
            echo -e "   ${arr[$i]}            "
        fi
    done
}

# --- 6. SUB-MENUS (User Mgmt) ---

menu_users() {
    local u_sel=0
    local u_opts=("Create New User" "Change Password" "Set Auto-Login" "Back")
    
    while true; do
        draw_header
        draw_list "USER MANAGEMENT" u_opts u_sel
        
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((u_sel--));; '[B') ((u_sel++));; esac
            [ $u_sel -lt 0 ] && u_sel=$(( ${#u_opts[@]} - 1 ))
            [ $u_sel -ge ${#u_opts[@]} ] && u_sel=0
        elif [[ $key == "" ]]; then
            case $u_sel in
                0) # Create
                   tput cnorm; clear; echo "--- NEW USER ---"
                   read -p "Username: " nu
                   if [ ! -z "$nu" ]; then 
                       useradd -m -G wheel -s /bin/bash "$nu" && passwd "$nu"
                       echo "Done."
                   fi
                   tput civis; sleep 1 ;;
                1) # Password
                   tput cnorm; clear; echo "--- CHANGE PASS ---"
                   read -p "Target Username: " tu
                   if id "$tu" >/dev/null 2>&1; then passwd "$tu"; else echo "User not found"; fi
                   tput civis; sleep 1 ;;
                2) # Auto Login
                   get_users
                   local al_sel=0
                   while true; do
                       draw_header
                       draw_list "SELECT AUTO-LOGIN USER" USER_LIST al_sel
                       read -rsn1 k
                       if [[ $k == "" ]]; then
                           local target="${USER_LIST[$al_sel]}"
                           local sdir="/etc/systemd/system/getty@tty1.service.d"
                           mkdir -p "$sdir"
                           echo -e "[Service]\nExecStart=\nExecStart=-/sbin/agetty --skip-login --nonewline --noissue --autologin $target --noclear %I \$TERM" > "$sdir/override.conf"
                           systemctl daemon-reload
                           clear; echo "Auto-login set for $target."; sleep 1; break
                       elif [[ $k == $'\x1b' ]]; then break; fi
                   done
                   ;;
                3) return ;;
            esac
        fi
    done
}

# --- 7. MAIN LOGIN SCREEN (Visual Mode) ---

screen_login() {
    get_users; scan_sessions
    local sel_u=0; local sel_s=0
    if [ -f "$CACHE_FILE" ]; then source "$CACHE_FILE"; fi
    
    # Restore selection index based on name
    for i in "${!USER_LIST[@]}"; do [[ "${USER_LIST[$i]}" == "$LAST_USER" ]] && sel_u=$i; done
    for i in "${!SESSION_NAMES[@]}"; do [[ "${SESSION_NAMES[$i]}" == "$LAST_SESSION" ]] && sel_s=$i; done

    local focus=2; local input_pass=""; local status=""; local stat_col=$C_RED

    while true; do
        draw_header
        local cy=10; local cols=$(tput cols); local cx=$((cols/2))
        
        # Status
        tput cup $((cy - 2)) 0
        if [ ! -z "$status" ]; then
            local msg="< $status >"
            local start=$(( (cols - ${#msg}) / 2 ))
            tput cup $((cy - 2)) $start; echo -e "${stat_col}${C_BOLD}${msg}${C_RESET}"
        else tput el; fi

        # Controls
        local c_foc; local cursor
        
        # Session
        [ $focus -eq 0 ] && c_foc=$C_ACCENT || c_foc=$C_GREY
        tput cup $cy $((cx-20)); echo -e "${C_GREY}session${C_RESET}"
        tput cup $cy $((cx-5)); echo -e "${c_foc}< ${C_WHITE}${SESSION_NAMES[$sel_s]} ${c_foc}>${C_RESET}   "

        # User
        [ $focus -eq 1 ] && c_foc=$C_ACCENT || c_foc=$C_GREY
        tput cup $((cy+2)) $((cx-20)); echo -e "${C_GREY}login${C_RESET}"
        tput cup $((cy+2)) $((cx-5)); echo -e "${c_foc}< ${C_WHITE}${USER_LIST[$sel_u]} ${c_foc}>${C_RESET}   "

        # Password
        [ $focus -eq 2 ] && { c_foc=$C_WHITE; cursor="${C_ACCENT}█${C_RESET}"; } || { c_foc=$C_GREY; cursor=""; }
        local mask=""; for ((i=0; i<${#input_pass}; i++)); do mask+="*"; done
        tput cup $((cy+4)) $((cx-20)); echo -e "${C_GREY}password${C_RESET}"
        tput cup $((cy+4)) $((cx-5)); echo -e "${c_foc}${mask}${cursor}      "

        # Input
        IFS= read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in
                '[A') ((focus--)); [ $focus -lt 0 ] && focus=2 ;;
                '[B') ((focus++)); [ $focus -gt 2 ] && focus=0 ;;
                '[C') 
                     if [ $focus -eq 0 ]; then ((sel_s++)); [ $sel_s -ge ${#SESSION_NAMES[@]} ] && sel_s=0; fi
                     if [ $focus -eq 1 ]; then ((sel_u++)); [ $sel_u -ge ${#USER_LIST[@]} ] && sel_u=0; fi ;;
                '[D') 
                     if [ $focus -eq 0 ]; then ((sel_s--)); [ $sel_s -lt 0 ] && sel_s=$((${#SESSION_NAMES[@]}-1)); fi
                     if [ $focus -eq 1 ]; then ((sel_u--)); [ $sel_u -lt 0 ] && sel_u=$((${#USER_LIST[@]}-1)); fi ;;
            esac
            if [[ $key == "" ]]; then return; fi
        elif [[ $key == "" ]]; then
            if [ $focus -ne 2 ]; then focus=2; else
                status="Verifying..."; stat_col=$C_CYAN; input_pass=""
                draw_header # redraw status
                
                if verify_credentials "${USER_LIST[$sel_u]}" "$input_pass"; then
                     echo "LAST_USER=\"${USER_LIST[$sel_u]}\"" > "$CACHE_FILE"
                     echo "LAST_SESSION=\"${SESSION_NAMES[$sel_s]}\"" >> "$CACHE_FILE"
                     launch_session "${SESSION_CMDS[$sel_s]}" "${SESSION_TYPES[$sel_s]}" "${USER_LIST[$sel_u]}" "${SESSION_NAMES[$sel_s]}"
                     status="Logged Out"; stat_col=$C_RED
                else
                     status="Access Denied"; stat_col=$C_RED; input_pass=""
                fi
            fi
        elif [[ $key == $'\x7f' || $key == $'\x08' ]]; then
            if [ $focus -eq 2 ] && [ ${#input_pass} -gt 0 ]; then input_pass="${input_pass::-1}"; fi
        elif [[ $key == $'\t' ]]; then ((focus++)); [ $focus -gt 2 ] && focus=0
        else
            if [ $focus -eq 2 ]; then input_pass+="$key"; fi
        fi
    done
}

# --- 8. DASHBOARD MENU ---

screen_dashboard() {
    local m_sel=0
    local m_opts=("Login to Desktop" "User Management" "Customize Theme" "System Info" "Reboot" "Shutdown")
    
    while true; do
        draw_header
        draw_list "DASHBOARD" m_opts m_sel
        
        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in '[A') ((m_sel--));; '[B') ((m_sel++));; esac
            [ $m_sel -lt 0 ] && m_sel=$((${#m_opts[@]}-1)); [ $m_sel -ge ${#m_opts[@]} ] && m_sel=0
        elif [[ $key == "" ]]; then
            case $m_sel in
                0) screen_login ;;
                1) menu_users ;;
                2) ((THEME_COLOR++)); [ $THEME_COLOR -gt 7 ] && THEME_COLOR=1; update_colors; save_config ;;
                3) clear; echo -e "${C_ACCENT}DISK:${C_RESET} $(df -h / | awk 'NR==2 {print $5}')"; read -rsn1 ;;
                4) systemctl reboot ;;
                5) systemctl poweroff ;;
            esac
        fi
    done
}

# --- 9. STARTUP CHECK ---

if [ "$EUID" -ne 0 ]; then
    echo "SBM Error: Must run as root."
    exit 1
fi

screen_dashboard
EOF

chmod +x /usr/local/bin/sbm
echo -e "${GREEN}Script installed successfully.${NC}"

# 4. CREATE SYSTEMD SERVICE
echo -e "\n${CYAN}[3/4] Configuring Systemd Service (sbm.service)...${NC}"

# This service will start SBM on TTY1 instead of the standard login prompt (getty)
cat << 'EOF' > /etc/systemd/system/sbm.service
[Unit]
Description=SBM Display Manager
After=systemd-user-sessions.service plymouth-quit-wait.service
After=rc-local.service
Before=getty@tty1.service
Conflicts=getty@tty1.service
Conflicts=plymouth-quit.service

[Service]
ExecStart=/usr/local/bin/sbm
StandardInput=tty
TTYPath=/dev/tty1
Type=idle
Restart=always

[Install]
WantedBy=multi-user.target
Alias=display-manager.service
EOF

echo "Reloading systemd daemon..."
systemctl daemon-reload
echo "Enabling SBM service..."
systemctl enable sbm.service > /dev/null 2>&1

# 5. DISABLE EXISTING DISPLAY MANAGERS
echo -e "\n${CYAN}[4/4] Handling conflicts...${NC}"

DMS=("gdm" "sddm" "lightdm" "xdm" "lxdm")
for dm in "${DMS[@]}"; do
    if systemctl is-active --quiet "$dm"; then
        echo -e "${RED}Found active Display Manager: $dm${NC}"
        echo -e "Disabling $dm to allow SBM to take over..."
        systemctl disable "$dm" > /dev/null 2>&1
        systemctl stop "$dm" > /dev/null 2>&1
        echo -e "${GREEN}Disabled $dm.${NC}"
    fi
done

# 6. FINISH
echo -e "\n${GREEN}=== INSTALLATION COMPLETE ===${NC}"
echo -e "SBM v0.0.1 has been installed as your system's Display Manager."
echo -e "Please ${CYAN}reboot${NC} your system to start SBM."
