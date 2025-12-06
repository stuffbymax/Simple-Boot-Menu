#!/bin/bash

# ==============================================================================
#   SBM - System Boot Manager v1.0.0 (Stable)
#    TUI Display Manager for Linux.
# ==============================================================================

# --- 1. CORE CONFIGURATION & CONSTANTS ---
SBM_VERSION="1.0.0"
CONFIG_DIR="/etc/sbm"
CONFIG_FILE="$CONFIG_DIR/sbm.conf"
LOG_DIR="/var/log/sbm"
CACHE_FILE="/var/cache/sbm/last_session"

# Default Configuration
THEME_COLOR="6"        # 1=Red, 2=Green, 4=Blue, 6=Cyan
THEME_BORDER="1"       # 1=Single, 2=Double
CUSTOM_TITLE="SBM LOGIN"

# Ensure Environment
mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$(dirname "$CACHE_FILE")"
touch "$LOG_DIR/sbm.log"
chmod 700 "$CONFIG_DIR" # Secure config if we store settings

# Load Config
if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; fi

# --- 2. TERMINAL & VISUALS ---

# Trap Signals for Clean Exit
cleanup() {
    tput cnorm      # Restore cursor
    tput sgr0       # Reset colors
    clear
}
trap cleanup EXIT INT TERM

setup_colors() {
    # Check terminal capabilities
    local colors=$(tput colors)

    C_RESET=$(tput sgr0)
    C_BOLD=$(tput bold)
    C_DIM=$(tput dim)
    
    # Accent Color
    C_ACCENT=$(tput setaf "$THEME_COLOR")
    
    # Selection Colors (Reverse video of accent)
    C_SEL_BG=$(tput setab "$THEME_COLOR")
    C_SEL_FG=$(tput setaf 0) # Black text
    
    # Box Color (Handle 8-color vs 256-color terms)
    if [[ "$colors" -ge 256 ]]; then
        C_BOX=$(tput setaf 240)  # Dark Grey
        C_GREY=$(tput setaf 245) # Light Grey
    else
        C_BOX=$(tput setaf 4)    # Blue fallback
        C_GREY=$(tput setaf 7)   # White fallback
    fi
    
    # Border Characters
    if [[ "$THEME_BORDER" == "1" ]]; then
        TLC="┌" TRC="┐" H="─" V="│" BLC="└" BRC="┘"
    else
        TLC="╔" TRC="╗" H="═" V="║" BLC="╚" BRC="╝"
    fi
}
tput civis # Hide cursor initially
setup_colors

save_config() {
    cat <<EOF > "$CONFIG_FILE"
THEME_COLOR="$THEME_COLOR"
THEME_BORDER="$THEME_BORDER"
CUSTOM_TITLE="$CUSTOM_TITLE"
EOF
}

# --- 3. SYSTEM INFORMATION & DISCOVERY ---

get_ip() {
    # Method 1: ip route (most robust)
    local ip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    # Method 2: hostname
    if [[ -z "$ip" ]]; then ip=$(hostname -I 2>/dev/null | awk '{print $1}'); fi
    echo "${ip:-Offline}"
}

get_users() {
    # Enumerate real users (UID 1000-60000), exclude nobody/system
    USER_LIST=()
    while IFS=: read -r username _ uid _ _ home shell; do
        if [[ "$uid" -ge 1000 && "$uid" -lt 60000 && "$shell" != "/bin/false" && "$shell" != "/usr/sbin/nologin" ]]; then
            USER_LIST+=("$username")
        fi
    done < /etc/passwd
    
    if [[ ${#USER_LIST[@]} -eq 0 ]]; then USER_LIST=("root"); fi
}

scan_sessions() {
    SESSION_NAMES=()
    SESSION_CMDS=()
    SESSION_TYPES=()

    add_session() {
        local name="$1"
        local cmd="$2"
        local type="$3"
        # Prevent duplicates
        for existing in "${SESSION_NAMES[@]}"; do
            [[ "$existing" == "$name" ]] && return
        done
        SESSION_NAMES+=("$name")
        SESSION_CMDS+=("$cmd")
        SESSION_TYPES+=("$type")
    }

    # Scan Wayland
    for path in /usr/share/wayland-sessions/*.desktop; do
        [[ -f "$path" ]] || continue
        local name=$(grep -m 1 "^Name=" "$path" | cut -d= -f2)
        local exec_cmd=$(grep -m 1 "^Exec=" "$path" | cut -d= -f2)
        [[ -z "$name" ]] && name=$(basename "$path" .desktop)
        add_session "$name (Wayland)" "$exec_cmd" "wayland"
    done

    # Scan X11
    for path in /usr/share/xsessions/*.desktop; do
        [[ -f "$path" ]] || continue
        local name=$(grep -m 1 "^Name=" "$path" | cut -d= -f2)
        local exec_cmd=$(grep -m 1 "^Exec=" "$path" | cut -d= -f2)
        [[ -z "$name" ]] && name=$(basename "$path" .desktop)
        add_session "$name" "$exec_cmd" "x11"
    done

    # Fallback if no DE found
    if [[ ${#SESSION_NAMES[@]} -eq 0 ]]; then
        add_session "Shell" "/bin/bash" "shell"
    fi
}

# --- 4. AUTHENTICATION BACKEND ---

verify_credentials() {
    local user="$1"
    local pass="$2"
    
    # 1. Check for NOPASSWD users (passwd -S output varies, check "NP")
    local status_str
    status_str=$(passwd -S "$user" 2>/dev/null | awk '{print $2}')
    if [[ "$status_str" == "NP" ]]; then return 0; fi 

    # 2. Prevent empty password submission for standard users
    if [[ -z "$pass" ]]; then return 1; fi

    # 3. Secure Python verification (Requires Root)
    python3 -c "
import crypt, spwd, sys
try:
    # Get shadow entry
    enc = spwd.getspnam(sys.argv[1]).sp_pwdp
    # Check for locked accounts
    if enc in ['NP', '!', '*']: sys.exit(1)
    # Hash input and compare
    if crypt.crypt(sys.argv[2], enc) == enc: sys.exit(0)
    else: sys.exit(1)
except:
    sys.exit(1)
" "$user" "$pass"
    
    # Return Python's exit code
    return $?
}

# --- 5. SESSION LAUNCHER ---

launch_session() {
    local cmd="$1"
    local type="$2"
    local user="$3"
    local name="$4"
    
    local logfile="$LOG_DIR/${user}-session.log"
    local wrapper="/tmp/sbm-wrapper-${user}.sh"

    tput cnorm; clear
    echo -e "${C_ACCENT}Starting session: $name...${C_RESET}"

    # Get User Info
    local user_shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
    local user_home=$(awk -F: -v u="$user" '$1==u {print $6}' /etc/passwd)
    local user_uid=$(id -u "$user")

    # --- WRAPPER SCRIPT GENERATION ---
    # We use unquoted heredoc to inject $type/$cmd, 
    # but we escape user-context variables (\$HOME, \$PATH) 
    # so they expand when the USER runs the script, not root.
    
    cat <<EOF > "$wrapper"
#!$user_shell
# SBM Session Wrapper

# 1. Redirect Output
exec > "$logfile" 2>&1

# 2. Source Profiles
[ -f /etc/profile ] && . /etc/profile
[ -f "\$HOME/.profile" ] && . "\$HOME/.profile"
[ -f "\$HOME/.bash_profile" ] && . "\$HOME/.bash_profile"

# 3. Export XDG Variables
export USER="$user"
export HOME="$user_home"
export SHELL="$user_shell"
export XDG_SEAT="seat0"
export XDG_VTNR="\$(tty | tr -dc '0-9')"
export XDG_SESSION_CLASS="user"
export XDG_SESSION_TYPE="$type"

# 4. Setup Runtime Directory (Vital for Wayland/Pipewire)
if [ -z "\$XDG_RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="/run/user/$user_uid"
    if [ ! -d "\$XDG_RUNTIME_DIR" ]; then
        mkdir -p "\$XDG_RUNTIME_DIR"
        chmod 700 "\$XDG_RUNTIME_DIR"
    fi
fi

# 5. Launch Logic
if [ "$type" == "wayland" ]; then
    export XDG_CURRENT_DESKTOP="$name"
    exec $cmd
elif [ "$type" == "x11" ]; then
    export DISPLAY=:0
    # Xauthority Magic
    touch "\$HOME/.Xauthority"
    xauth generate :0 . trusted >/dev/null 2>&1
    
    # Create xinitrc for startx
    echo "#!/bin/sh" > "\$HOME/.xinitrc"
    echo ". /etc/profile" >> "\$HOME/.xinitrc"
    echo "exec $cmd" >> "\$HOME/.xinitrc"
    chmod +x "\$HOME/.xinitrc"
    
    exec startx
else
    exec $cmd
fi
EOF

    # Set Permissions
    chmod +x "$wrapper"
    chown "$user:$user" "$wrapper"
    
    # Handoff to User
    # 'su -' ensures a login shell environment
    su - "$user" -c "$wrapper"
    
    # Cleanup after logout
    rm -f "$wrapper"
    
    # Return to SBM loop
    tput civis
    sleep 1
}

# --- 6. INPUT HANDLING ENGINE ---

# Reads a key reliably, handling Escape sequences for Arrow keys
get_key() {
    local k1 k2 k3
    IFS= read -rsn1 k1
    
    if [[ "$k1" == $'\x1b' ]]; then
        # It's an escape sequence (or just ESC)
        # Read with timeout to detect sequence
        read -rsn1 -t 0.01 k2
        if [[ -z "$k2" ]]; then
            echo "ESC"
            return
        fi
        read -rsn1 -t 0.01 k3
        if [[ "$k2" == "[" ]]; then
            case "$k3" in
                'A') echo "UP" ;;
                'B') echo "DOWN" ;;
                'C') echo "RIGHT" ;;
                'D') echo "LEFT" ;;
            esac
        fi
    elif [[ -z "$k1" ]]; then
        echo "ENTER"
    elif [[ "$k1" == $'\x7f' || "$k1" == $'\x08' ]]; then
        echo "BACKSPACE"
    elif [[ "$k1" == $'\t' ]]; then
        echo "TAB"
    else
        echo "$k1"
    fi
}

# --- 7. UI DRAWING ROUTINES ---

draw_box() {
    clear
    local cols=$(tput cols)
    local width=50
    local start_col=$(( (cols - width) / 2 ))
    
    # Info
    local distro=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 | head -n 1)
    local host=$(hostname)
    
    # Top Border
    tput cup 1 $start_col
    echo -ne "${C_BOX}${TLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done
    echo -ne "${TRC}${C_RESET}"

    # Title (Centered)
    local title=" $CUSTOM_TITLE "
    local t_len=${#title}
    local pad=$(( (width - t_len) / 2 ))
    tput cup 1 $((start_col + pad + 1))
    echo -e "${C_ACCENT}${C_BOLD}${title}${C_RESET}"

    # Content Area (Rows 2,3,4)
    for r in 2 3 4 5; do
        tput cup $r $start_col
        echo -ne "${C_BOX}${V}"
        tput cup $r $((start_col + width + 1))
        echo -ne "${V}${C_RESET}"
    done

    # Info Text
    tput cup 2 $((start_col + 2))
    echo -e "${C_GREY}System:${C_RESET} ${distro:0:30}"
    tput cup 3 $((start_col + 2))
    echo -e "${C_GREY}Host:${C_RESET}   ${host} ($(get_ip))"

    # Bottom Border
    tput cup 6 $start_col
    echo -ne "${C_BOX}${BLC}"
    for ((i=0; i<width; i++)); do echo -ne "$H"; done
    echo -ne "${BRC}${C_RESET}"
}

draw_menu_list() {
    local title="$1"
    local -n arr_opts=$2
    local sel_idx="$3"
    
    local cy=9
    local cols=$(tput cols)
    local cx=$(( (cols - 40) / 2 ))
    
    tput cup $((cy - 2)) $cx
    echo -e "${C_ACCENT}${C_BOLD}:: $title ::${C_RESET}"
    
    for ((i=0; i<${#arr_opts[@]}; i++)); do
        tput cup $((cy + i)) $cx
        if [[ $i -eq $sel_idx ]]; then
            echo -e "${C_SEL_BG}${C_SEL_FG} > ${arr_opts[$i]} ${C_RESET}\033[K"
        else
            echo -e "   ${arr_opts[$i]} \033[K"
        fi
    done
}

# --- 8. STATE SCREENS ---

screen_login() {
    get_users
    scan_sessions
    
    local sel_u=0
    local sel_s=0
    
    # Load Cache (Last logged in user)
    if [[ -f "$CACHE_FILE" ]]; then source "$CACHE_FILE"; fi
    
    # Match cache to index
    for i in "${!USER_LIST[@]}"; do [[ "${USER_LIST[$i]}" == "$LAST_USER" ]] && sel_u=$i; done
    for i in "${!SESSION_NAMES[@]}"; do [[ "${SESSION_NAMES[$i]}" == "$LAST_SESSION" ]] && sel_s=$i; done

    local focus=2   # 0=Session, 1=User, 2=Pass
    local pass_buf=""
    local status_msg=""
    local status_color="$C_RED"

    while true; do
        draw_box
        
        local cy=10
        local cols=$(tput cols); local cx=$((cols/2))

        # Status Line
        tput cup $((cy - 2)) 0
        if [[ -n "$status_msg" ]]; then
            local slen=${#status_msg}
            local start=$(( (cols - slen) / 2 ))
            tput cup $((cy - 2)) $start
            echo -e "${status_color}${C_BOLD}${status_msg}${C_RESET}"
        else tput el; fi

        # Render Form
        local c_foc cursor
        
        # 1. Session
        [[ $focus -eq 0 ]] && c_foc=$C_ACCENT || c_foc=$C_GREY
        tput cup $cy $((cx - 20)); echo -e "${C_GREY}Session:${C_RESET}"
        tput cup $cy $((cx - 5)); echo -e "${c_foc}< ${C_WHITE}${SESSION_NAMES[$sel_s]} ${c_foc}>${C_RESET}   "

        # 2. User
        [[ $focus -eq 1 ]] && c_foc=$C_ACCENT || c_foc=$C_GREY
        tput cup $((cy+2)) $((cx - 20)); echo -e "${C_GREY}User:${C_RESET}"
        tput cup $((cy+2)) $((cx - 5)); echo -e "${c_foc}< ${C_WHITE}${USER_LIST[$sel_u]} ${c_foc}>${C_RESET}   "

        # 3. Password
        [[ $focus -eq 2 ]] && { c_foc=$C_WHITE; cursor="${C_ACCENT}█${C_RESET}"; } || { c_foc=$C_GREY; cursor=""; }
        local mask=""; for ((i=0; i<${#pass_buf}; i++)); do mask+="*"; done
        tput cup $((cy+4)) $((cx - 20)); echo -e "${C_GREY}Password:${C_RESET}"
        tput cup $((cy+4)) $((cx - 5)); echo -e "${c_foc}${mask}${cursor}      "

        # Input Loop
        local key=$(get_key)
        
        case "$key" in
            ESC) return ;; # Back to Dashboard
            
            UP) ((focus--)); [[ $focus -lt 0 ]] && focus=2 ;;
            DOWN|TAB) ((focus++)); [[ $focus -gt 2 ]] && focus=0 ;;
            
            LEFT)
                if [[ $focus -eq 0 ]]; then ((sel_s--)); [[ $sel_s -lt 0 ]] && sel_s=$((${#SESSION_NAMES[@]}-1)); fi
                if [[ $focus -eq 1 ]]; then ((sel_u--)); [[ $sel_u -lt 0 ]] && sel_u=$((${#USER_LIST[@]}-1)); fi ;;
            
            RIGHT)
                if [[ $focus -eq 0 ]]; then ((sel_s++)); [[ $sel_s -ge ${#SESSION_NAMES[@]} ]] && sel_s=0; fi
                if [[ $focus -eq 1 ]]; then ((sel_u++)); [[ $sel_u -ge ${#USER_LIST[@]} ]] && sel_u=0; fi ;;
            
            BACKSPACE)
                if [[ $focus -eq 2 && ${#pass_buf} -gt 0 ]]; then pass_buf="${pass_buf::-1}"; fi ;;
                
            ENTER)
                if [[ $focus -ne 2 ]]; then
                    focus=2
                else
                    # Authenticate
                    status_msg="Verifying..."; status_color="$C_CYAN"
                    # Force redraw of status before blocking call
                    tput cup $((cy - 2)) 0; tput el; tput cup $((cy - 2)) $(( (cols - 12) / 2 )); echo -e "${C_CYAN}${C_BOLD}Verifying...${C_RESET}"
                    
                    if verify_credentials "${USER_LIST[$sel_u]}" "$pass_buf"; then
                        # Cache success
                        mkdir -p "$(dirname "$CACHE_FILE")"
                        echo "LAST_USER=\"${USER_LIST[$sel_u]}\"" > "$CACHE_FILE"
                        echo "LAST_SESSION=\"${SESSION_NAMES[$sel_s]}\"" >> "$CACHE_FILE"
                        
                        launch_session "${SESSION_CMDS[$sel_s]}" "${SESSION_TYPES[$sel_s]}" "${USER_LIST[$sel_u]}" "${SESSION_NAMES[$sel_s]}"
                        
                        status_msg="Logged Out"; status_color="$C_DIM"
                        pass_buf=""
                    else
                        status_msg="Authentication Failed"; status_color="$C_RED"
                        pass_buf=""
                    fi
                fi
                ;;
            *)
                # Typing password
                if [[ $focus -eq 2 && ${#key} -eq 1 ]]; then pass_buf+="$key"; fi ;;
        esac
    done
}

screen_customize() {
    local sel=0
    local opts=("Theme Color" "Border Style" "Change Title" "Back")
    
    while true; do
        draw_box
        draw_menu_list "SETTINGS" opts sel
        
        local key=$(get_key)
        case "$key" in
            ESC) return ;;
            UP) ((sel--)); [[ $sel -lt 0 ]] && sel=$((${#opts[@]}-1)) ;;
            DOWN) ((sel++)); [[ $sel -ge ${#opts[@]} ]] && sel=0 ;;
            ENTER)
                case $sel in
                    0) ((THEME_COLOR++)); [[ $THEME_COLOR -gt 7 ]] && THEME_COLOR=1; setup_colors; save_config ;;
                    1) [[ "$THEME_BORDER" == "1" ]] && THEME_BORDER="2" || THEME_BORDER="1"; setup_colors; save_config ;;
                    2) 
                        tput cnorm; clear
                        echo -e "${C_ACCENT}Enter new title:${C_RESET}"
                        read -r new_title
                        if [[ -n "$new_title" ]]; then CUSTOM_TITLE="$new_title"; save_config; fi
                        tput civis
                        ;;
                    3) return ;;
                esac
                ;;
        esac
    done
}

screen_users() {
    local sel=0
    local opts=("Create User" "Change Password" "Back")
    
    while true; do
        draw_box
        draw_menu_list "USER ADMIN" opts sel
        
        local key=$(get_key)
        case "$key" in
            ESC) return ;;
            UP) ((sel--)); [[ $sel -lt 0 ]] && sel=$((${#opts[@]}-1)) ;;
            DOWN) ((sel++)); [[ $sel -ge ${#opts[@]} ]] && sel=0 ;;
            ENTER)
                case $sel in
                    0) 
                        tput cnorm; clear; echo "--- CREATE USER ---"
                        read -p "Username: " nu
                        if [[ -n "$nu" ]]; then 
                            useradd -m -G wheel -s /bin/bash "$nu" && passwd "$nu"
                        fi; tput civis ;;
                    1)
                        tput cnorm; clear; echo "--- CHANGE PASS ---"
                        read -p "Username: " tu
                        if id "$tu" &>/dev/null; then passwd "$tu"; fi; tput civis ;;
                    2) return ;;
                esac
                ;;
        esac
    done
}

screen_dashboard() {
    local sel=0
    local opts=("Login" "Terminal (Shell)" "User Management" "Settings" "Reboot" "Shutdown")
    
    while true; do
        draw_box
        draw_menu_list "MAIN MENU" opts sel
        
        local key=$(get_key)
        case "$key" in
            UP) ((sel--)); [[ $sel -lt 0 ]] && sel=$((${#opts[@]}-1)) ;;
            DOWN) ((sel++)); [[ $sel -ge ${#opts[@]} ]] && sel=0 ;;
            ENTER)
                case $sel in
                    0) screen_login ;;
                    1) 
                        tput cnorm; clear
                        echo -e "${C_RED}${C_BOLD}Entering Root Shell.${C_RESET}"
                        echo "Type 'exit' to return to SBM."
                        /bin/bash
                        tput civis
                        ;;
                    2) screen_users ;;
                    3) screen_customize ;;
                    4) systemctl reboot ;;
                    5) systemctl poweroff ;;
                esac
                ;;
        esac
    done
}

# --- 9. STARTUP VERIFICATION ---

if [[ "$EUID" -ne 0 ]]; then
    echo "Error: SBM must run as root."
    exit 1
fi

screen_dashboard
