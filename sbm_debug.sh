#!/usr/bin/env bash
# ==============================================================================
#   SBM - System Boot Manager v1.0 (Fixed)
#   Hybrid Console/Graphical Login Manager
# ==============================================================================

set -u
SBM_VERSION="1.0.0"
CONFIG_DIR="${HOME}/.config/sbm"
CONFIG_FILE="$CONFIG_DIR/sbm.conf"
CACHE_FILE="$CONFIG_DIR/last_session"
LOG_DIR="/var/log/sbm"

mkdir -p "$CONFIG_DIR"
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Default Settings
THEME_COLOR="6"        # Cyan-like (if terminal supports more colors)
THEME_BORDER="1"       # 1=Single, 2=Double
CUSTOM_TITLE="SBM MANAGER"

# Load Config (if file present)
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Ensure cursor restored on exit or interrupt
cleanup_and_exit() {
    tput cnorm || true
    clear
    exit
}
trap cleanup_and_exit INT TERM EXIT

# Terminal Setup
tput civis || true # Hide cursor

# Colors (portable)
C_RESET="$(tput sgr0 2>/dev/null || echo)"
C_BOLD="$(tput bold 2>/dev/null || echo)"
C_RED="$(tput setaf 1 2>/dev/null || echo)"
C_GREEN="$(tput setaf 2 2>/dev/null || echo)"
C_CYAN="$(tput setaf 6 2>/dev/null || echo)"
C_WHITE="$(tput setaf 7 2>/dev/null || echo)"
# Grey: fallback to dim white or normal white
C_GREY="$( (tput setaf 7 2>/dev/null || echo)$(tput dim 2>/dev/null || echo) )"

# --- Helpers & visuals ---
update_visuals() {
    # Accent and selection colors (attempt to use true color if supported)
    C_ACCENT="$(tput setaf "$THEME_COLOR" 2>/dev/null || echo)"
    C_SEL_BG="$(tput setab "$THEME_COLOR" 2>/dev/null || echo)"
    C_SEL_FG="$(tput setaf 0 2>/dev/null || echo)" # black foreground when selected

    if [ "$THEME_BORDER" = "1" ]; then
        TLC="┌"; TRC="┐"; H="─"; V="│"; BLC="└"; BRC="┘"
    else
        TLC="╔"; TRC="╗"; H="═"; V="║"; BLC="╚"; BRC="╝"
    fi
}
update_visuals

save_config() {
    cat > "$CONFIG_FILE" <<EOF
THEME_COLOR="$THEME_COLOR"
THEME_BORDER="$THEME_BORDER"
CUSTOM_TITLE="$CUSTOM_TITLE"
EOF
}

# Robust IP detection (multiple fallbacks)
get_ip() {
    # try ip route
    local ip
    if ip route get 1.1.1.1 >/dev/null 2>&1; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
    fi
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$ip" ]; then
        echo "Offline"
    else
        echo "$ip"
    fi
}

get_users() {
    # Exclude system accounts; rely on typical UID >= 1000
    mapfile -t USER_LIST < <(awk -F: '($3 >= 1000 && $3 < 60000) {print $1}' /etc/passwd)
    if [ ${#USER_LIST[@]} -eq 0 ]; then
        USER_LIST=("root")
    fi
}

# --- SESSION SCANNING ---
scan_sessions() {
    SESSION_NAMES=()
    SESSION_CMDS=()
    SESSION_TYPES=()

    add_session() {
        local name="$1"; local cmd="$2"; local type="$3"
        for existing in "${SESSION_NAMES[@]}"; do
            if [[ "$existing" == "$name" ]]; then return; fi
        done
        SESSION_NAMES+=("$name"); SESSION_CMDS+=("$cmd"); SESSION_TYPES+=("$type")
    }

    # Wayland sessions
    for path in /usr/share/wayland-sessions/*.desktop; do
        [ -f "$path" ] || continue
        local name exec_cmd
        name=$(grep -m1 "^Name=" "$path" | cut -d= -f2-)
        exec_cmd=$(grep -m1 "^Exec=" "$path" | cut -d= -f2- | sed 's/%.//g')
        [ -z "$name" ] && name=$(basename "$path" .desktop)
        add_session "$name (Wayland)" "$exec_cmd" "wayland"
    done

    # X11 sessions
    for path in /usr/share/xsessions/*.desktop; do
        [ -f "$path" ] || continue
        local name exec_cmd
        name=$(grep -m1 "^Name=" "$path" | cut -d= -f2-)
        exec_cmd=$(grep -m1 "^Exec=" "$path" | cut -d= -f2- | sed 's/%.//g')
        [ -z "$name" ] && name=$(basename "$path" .desktop)
        add_session "$name" "$exec_cmd" "x11"
    done

    # Fallback: simple shell
    if [ ${#SESSION_NAMES[@]} -eq 0 ]; then
        add_session "Shell" "/bin/bash" "shell"
    fi
}

# --- AUTHENTICATION ---
verify_credentials() {
    local user="$1"; local pass="$2"
    # Empty password check (for NOPASSWD accounts)
    if passwd -S "$user" >/dev/null 2>&1; then
        local status_str
        status_str=$(passwd -S "$user" 2>/dev/null | awk '{print $2}')
        if [[ "$status_str" == "NP" ]]; then
            return 0
        fi
    fi
    if [ -z "$pass" ]; then
        return 1
    fi

    # Verify against shadow with python: return python exit code
    python3 - <<PYCODE
import crypt, spwd, sys
user = sys.argv[1]
pw = sys.argv[2]
try:
    s = spwd.getspnam(user).sp_pwdp
    if s in ('NP', '!', '*'):
        sys.exit(1)
    if crypt.crypt(pw, s) == s:
        sys.exit(0)
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
PYCODE
    return $?
}

# --- LAUNCH SESSION ---
launch_session() {
    local cmd="$1"; local type="$2"; local user="$3"; local name="$4"
    local logfile="$LOG_DIR/${user}.log"
    local wrapper="/tmp/sbm-launch-${user}.$$"

    tput cnorm || true
    clear
    printf "%sStarting %s...%s\n" "$C_ACCENT" "$name" "$C_RESET"

    # Get User Details
    local user_shell user_home user_uid
    user_shell=$(awk -F: -v u="$user" '$1==u {print $7}' /etc/passwd)
    [ -z "$user_shell" ] && user_shell="/bin/bash"
    user_home=$(awk -F: -v u="$user" '$1==u {print $6}' /etc/passwd)
    user_uid=$(id -u "$user")

    # Create wrapper script. Expand runtime-sensitive vars at runtime by escaping \$ where needed.
    cat > "$wrapper" <<'EOF'
#!__USER_SHELL__
# SBM Wrapper (generated)
exec > "__LOGFILE__" 2>&1
[ -f /etc/profile ] && . /etc/profile
[ -f "__USER_HOME__/ .profile" ] && . "__USER_HOME__/.profile"
export USER="__USER__"
export HOME="__USER_HOME__"
export SHELL="__USER_SHELL__"
export XDG_SEAT="seat0"
export XDG_SESSION_CLASS="user"
export XDG_SESSION_TYPE="__TYPE__"
if [ -z "\$XDG_RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="/run/user/__USER_UID__"
    if [ ! -d "\$XDG_RUNTIME_DIR" ]; then
        mkdir -p "\$XDG_RUNTIME_DIR"
        chmod 700 "\$XDG_RUNTIME_DIR"
    fi
fi
EOF

    # Substitute placeholders (safe)
    sed -i "s|__USER__|$user|g; s|__USER_HOME__|$user_home|g; s|__USER_SHELL__|$user_shell|g; s|__USER_UID__|$user_uid|g; s|__LOGFILE__|$logfile|g; s|__TYPE__|$type|g" "$wrapper"

    # Append session-specific execution
    if [ "$type" = "wayland" ]; then
        cat >> "$wrapper" <<'EOE'
# Wayland launch
export XDG_CURRENT_DESKTOP="__NAME__"
exec __CMD__
EOE
        sed -i "s|__NAME__|$name|g; s|__CMD__|$cmd|g" "$wrapper"
    elif [ "$type" = "x11" ]; then
        cat >> "$wrapper" <<'EOE'
# X11 launch
export DISPLAY=:0
if [ ! -f "__USER_HOME__/.Xauthority" ]; then
    touch "__USER_HOME__/.Xauthority"
    chown "__USER__":"__USER__" "__USER_HOME__/.Xauthority"
fi
# create a basic .xinitrc for the user
cat > "__USER_HOME__/.xinitrc" <<XINIT
#!/bin/sh
. /etc/profile
exec __CMD__
XINIT
chmod +x "__USER_HOME__/.xinitrc"
exec startx
EOE
        sed -i "s|__USER_HOME__|$user_home|g; s|__USER__|$user|g; s|__CMD__|$cmd|g" "$wrapper"
    else
        cat >> "$wrapper" <<'EOE'
# Fallback shell exec
exec __CMD__
EOE
        sed -i "s|__CMD__|$cmd|g" "$wrapper"
    fi

    chmod +x "$wrapper"
    chown "$user":"$user" "$wrapper" 2>/dev/null || true

    # Run as user; use su to preserve environment with '-' to get login shell
    su - "$user" -c "$wrapper"

    # Cleanup
    rm -f "$wrapper" 2>/dev/null || true

    tput civis || true
    sleep 1
}

# --- UI drawing helpers ---
draw_header() {
    clear
    local cols
    cols=$(tput cols)
    local width=60
    [ "$width" -gt "$cols" ] && width=$((cols-2))
    local start_col=$(( (cols - width) / 2 ))

    local distro host ip
    distro=$(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d\" -f2 || echo "Unknown OS")
    host=$(hostname 2>/dev/null || echo "host")
    ip=$(get_ip)

    # Top border
    tput cup 1 $start_col
    printf "%s%s" "$C_ACCENT" "$TLC"
    for ((i=0;i<width-2;i++)); do printf "%s" "$H"; done
    printf "%s%s\n" "$TRC" "$C_RESET"

    # Title centered
    local title=" $CUSTOM_TITLE "
    local pad=$(( (width - ${#title}) / 2 ))
    tput cup 2 $((start_col))
    printf "%s%s" "$V" ""
    tput cup 2 $((start_col + pad + 1))
    printf "%s%s%s\n" "$C_ACCENT$C_BOLD" "$title" "$C_RESET"

    # Info lines
    tput cup 3 $((start_col + 2))
    printf "%sSys:%s %s\n" "$C_ACCENT" "$C_RESET" "${distro:0:$(($width-10))}"
    tput cup 4 $((start_col + 2))
    printf "%sNet:%s %s (%s)\n" "$C_ACCENT" "$C_RESET" "$host" "$ip"

    # Bottom border
    tput cup 5 $start_col
    printf "%s%s" "$C_ACCENT" "$BLC"
    for ((i=0;i<width-2;i++)); do printf "%s" "$H"; done
    printf "%s%s\n" "$BRC" "$C_RESET"
}

draw_list() {
    local title="$1"; local -n arr="$2"; local -n sel="$3"
    local cy=8
    local cols
    cols=$(tput cols)
    local cx=$(( (cols - 30) / 2 ))
    [ "$cx" -lt 0 ] && cx=0

    tput cup $((cy-2)) $cx
    printf "%s%s%s\n" "$C_ACCENT$C_BOLD" "$title" "$C_RESET"

    for ((i=0; i<${#arr[@]}; i++)); do
        tput cup $((cy+i)) $cx
        if [ "$i" -eq "$sel" ]; then
            printf "%s%s > %s %s\n" "$C_SEL_BG" "$C_SEL_FG" "${arr[$i]}" "$C_RESET"
        else
            printf "   %s\n" "${arr[$i]}"
        fi
    done
}

# --- Menus ---
menu_customize() {
    local c_sel=0
    while true; do
        local c_opts=("Theme Color: $THEME_COLOR" "Border Style: $THEME_BORDER" "Change Title" "Back")
        draw_header; draw_list "SETTINGS" c_opts c_sel

        IFS= read -rsn1 key 2>/dev/null || key=$'\n'
        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn1 -t 0.02 key2 2>/dev/null || key2=""
            if [[ -z $key2 ]]; then
                return
            fi
            IFS= read -rsn1 -t 0.02 key3 2>/dev/null || key3=""
            case "$key3" in $'A') ((c_sel--));; $'B') ((c_sel++));; esac
        elif [[ $key == $'\n' || $key == $'\r' ]]; then
            case $c_sel in
                0)
                    ((THEME_COLOR++))
                    # wrap within 1..7
                    if [ "$THEME_COLOR" -gt 7 ] || [ "$THEME_COLOR" -lt 1 ]; then THEME_COLOR=1; fi
                    update_visuals; save_config
                    ;;
                1)
                    if [ "$THEME_BORDER" = "1" ]; then THEME_BORDER="2"; else THEME_BORDER="1"; fi
                    update_visuals; save_config
                    ;;
                2)
                    tput cnorm; clear
                    printf "Enter new title: "
                    read -r nt
                    [ -n "$nt" ] && CUSTOM_TITLE="$nt" && save_config
                    tput civis
                    ;;
                3) return ;;
            esac
        fi
        # Wrap
        if [ $c_sel -lt 0 ]; then c_sel=$((${#c_opts[@]}-1)); fi
        if [ $c_sel -ge ${#c_opts[@]} ]; then c_sel=0; fi
    done
}

menu_users() {
    local u_sel=0
    local u_opts=("Create User" "Change Password" "Back")
    while true; do
        draw_header; draw_list "USERS" u_opts u_sel
        IFS= read -rsn1 key 2>/dev/null || key=$'\n'
        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn1 -t 0.02 k2 2>/dev/null || k2=""
            if [[ -z $k2 ]]; then return; fi
            IFS= read -rsn1 -t 0.02 k3 2>/dev/null || k3=""
            case "$k3" in $'A') ((u_sel--));; $'B') ((u_sel++));; esac
        elif [[ $key == $'\n' || $key == $'\r' ]]; then
            case $u_sel in
                0)
                    tput cnorm; clear
                    printf "Username: "; read -r u
                    if [ -n "$u" ]; then
                        useradd -m -G wheel -s /bin/bash "$u"
                        passwd "$u"
                    fi
                    tput civis
                    ;;
                1)
                    tput cnorm; clear
                    printf "User: "; read -r u
                    if id "$u" >/dev/null 2>&1; then passwd "$u"; fi
                    tput civis
                    ;;
                2) return ;;
            esac
        fi
        [ $u_sel -lt 0 ] && u_sel=$((${#u_opts[@]}-1))
        [ $u_sel -ge ${#u_opts[@]} ] && u_sel=0
    done
}

# --- LOGIN SCREEN ---
screen_login() {
    get_users; scan_sessions
    local sel_u=0 sel_s=0

    if [ -f "$CACHE_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CACHE_FILE"
    fi

    # Restore indices if cache variables present
    for i in "${!USER_LIST[@]}"; do
        if [ "${USER_LIST[$i]}" = "${LAST_USER:-}" ]; then sel_u=$i; fi
    done
    for i in "${!SESSION_NAMES[@]}"; do
        if [ "${SESSION_NAMES[$i]}" = "${LAST_SESSION:-}" ]; then sel_s=$i; fi
    done

    local focus=2
    local input_pass=""
    local status=""
    local stat_col="$C_RED"

    while true; do
        draw_header
        local cy=10
        local cols
        cols=$(tput cols)
        local cx=$((cols/2))

        # Status
        if [ -n "$status" ]; then
            local msg="< $status >"
            local start=$(( (cols - ${#msg}) / 2 ))
            tput cup $((cy - 2)) $start
            printf "%s%s%s\n" "$stat_col$C_BOLD" "$msg" "$C_RESET"
        else
            tput el
        fi

        # 1. Session
        local c_foc cursor
        if [ "$focus" -eq 0 ]; then c_foc="$C_ACCENT"; else c_foc="$C_GREY"; fi
        tput cup $cy $((cx-20)); printf "%s%s%s" "$C_GREY" "session" "$C_RESET"
        tput cup $cy $((cx-5)); printf "%s< %s %s>\n" "$c_foc" "${SESSION_NAMES[$sel_s]}" "$C_RESET"

        # 2. User
        if [ "$focus" -eq 1 ]; then c_foc="$C_ACCENT"; else c_foc="$C_GREY"; fi
        tput cup $((cy+2)) $((cx-20)); printf "%s%s%s" "$C_GREY" "login" "$C_RESET"
        tput cup $((cy+2)) $((cx-5)); printf "%s< %s %s>\n" "$c_foc" "${USER_LIST[$sel_u]}" "$C_RESET"

        # 3. Password
        if [ "$focus" -eq 2 ]; then
            c_foc="$C_WHITE"
            cursor="${C_ACCENT}█${C_RESET}"
        else
            c_foc="$C_GREY"
            cursor=""
        fi
        local mask=""
        for ((i=0;i<${#input_pass};i++)); do mask+="*"; done
        tput cup $((cy+4)) $((cx-20)); printf "%s%s%s" "$C_GREY" "password" "$C_RESET"
        tput cup $((cy+4)) $((cx-5)); printf "%s%s%s      \n" "$c_foc" "$mask" "$cursor"

        # Read single key
        IFS= read -rsn1 key 2>/dev/null || key=$'\n'

        if [[ $key == $'\x1b' ]]; then
            # escape / arrow handling
            IFS= read -rsn1 -t 0.02 k2 2>/dev/null || k2=""
            if [[ -z $k2 ]]; then
                return
            fi
            IFS= read -rsn1 -t 0.02 k3 2>/dev/null || k3=""
            case "$k3" in $'A') ((focus--)); [ $focus -lt 0 ] && focus=2 ;; $'B') ((focus++)); [ $focus -gt 2 ] && focus=0 ;; $'C')
                if [ $focus -eq 0 ]; then ((sel_s++)); [ $sel_s -ge ${#SESSION_NAMES[@]} ] && sel_s=0; fi
                if [ $focus -eq 1 ]; then ((sel_u++)); [ $sel_u -ge ${#USER_LIST[@]} ] && sel_u=0; fi ;;
            $'D')
                if [ $focus -eq 0 ]; then ((sel_s--)); [ $sel_s -lt 0 ] && sel_s=$((${#SESSION_NAMES[@]}-1)); fi
                if [ $focus -eq 1 ]; then ((sel_u--)); [ $sel_u -lt 0 ] && sel_u=$((${#USER_LIST[@]}-1)); fi ;;
            esac
        elif [[ $key == $'\n' || $key == $'\r' ]]; then
            if [ $focus -ne 2 ]; then
                focus=2
            else
                # Authenticate (use stored input_pass)
                status="Verifying..."
                stat_col="$C_CYAN"
                draw_header
                if verify_credentials "${USER_LIST[$sel_u]}" "$input_pass"; then
                    printf "%s\n" "LAST_USER=\"${USER_LIST[$sel_u]}\"" > "$CACHE_FILE"
                    printf "%s\n" "LAST_SESSION=\"${SESSION_NAMES[$sel_s]}\"" >> "$CACHE_FILE"
                    # Clear password variable in memory before switching
                    local saved_pass="$input_pass"
                    input_pass=""
                    launch_session "${SESSION_CMDS[$sel_s]}" "${SESSION_TYPES[$sel_s]}" "${USER_LIST[$sel_u]}" "${SESSION_NAMES[$sel_s]}"
                    status="Logged Out"
                    stat_col="$C_RED"
                else
                    status="Access Denied"
                    stat_col="$C_RED"
                    input_pass=""
                fi
            fi
        elif [[ $key == $'\x7f' || $key == $'\x08' ]]; then
            # backspace
            if [ $focus -eq 2 ] && [ ${#input_pass} -gt 0 ]; then input_pass="${input_pass:0:-1}"; fi
        elif [[ $key == $'\t' ]]; then
            ((focus++)); [ $focus -gt 2 ] && focus=0
        else
            # Printable char append
            if [ $focus -eq 2 ]; then input_pass+="$key"; fi
        fi
    done
}

# --- DASHBOARD ---
screen_dashboard() {
    local m_sel=0
    local m_opts=("Login to Desktop" "Drop to Shell" "User Management" "Customize SBM" "Reboot" "Shutdown")

    while true; do
        draw_header; draw_list "DASHBOARD" m_opts m_sel
        IFS= read -rsn1 key 2>/dev/null || key=$'\n'
        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn1 -t 0.02 k2 2>/dev/null || k2=""
            if [[ -z $k2 ]]; then continue; fi
            IFS= read -rsn1 -t 0.02 k3 2>/dev/null || k3=""
            case "$k3" in $'A') ((m_sel--));; $'B') ((m_sel++));; esac
        elif [[ $key == $'\n' || $key == $'\r' ]]; then
            case $m_sel in
                0) screen_login ;;
                1)
                    tput cnorm; clear
                    printf "%sDropped to Root Shell.%s\n" "$C_RED" "$C_RESET"
                    printf "Type 'exit' to return to SBM.\n"
                    /bin/bash
                    tput civis
                    ;;
                2) menu_users ;;
                3) menu_customize ;;
                4) systemctl reboot ;;
                5) systemctl poweroff ;;
            esac
        fi
        [ $m_sel -lt 0 ] && m_sel=$((${#m_opts[@]}-1))
        [ $m_sel -ge ${#m_opts[@]} ] && m_sel=0
    done
}

# ENTRY
if [ "$EUID" -ne 0 ]; then
    echo "SBM Error: Must run as root."
    exit 1
fi

screen_dashboard
