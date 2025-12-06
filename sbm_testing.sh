#!/bin/bash

# ==========================================
#   CORE - Login Manager & Session Starter
# ==========================================

# --- 1. INIT & CONFIG ---
CONFIG_DIR="$HOME/.config/core"
mkdir -p "$CONFIG_DIR"
CACHE_FILE="$CONFIG_DIR/last_session"

# Color Definitions
tput civis # Hide cursor
trap "tput cnorm; clear; exit" INT TERM

C_RESET=$(tput sgr0)
C_RED=$(tput setaf 1)
C_GREEN=$(tput setaf 2)
C_CYAN=$(tput setaf 6)
C_WHITE=$(tput setaf 7)
C_GREY=$(tput setaf 8)
C_BOLD=$(tput bold)

# State Variables
STATUS_MSG=""
STATUS_COLOR="$C_RED"
INPUT_PASSWORD=""
SELECTED_SESSION_IDX=0
SELECTED_USER_IDX=0
FOCUS_IDX=2 # 0=Session, 1=User, 2=Password (default focus)

# --- 2. DATA GATHERING ---

# Get Users (UID >= 1000)
mapfile -t USER_LIST < <(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd)
if [ ${#USER_LIST[@]} -eq 0 ]; then USER_LIST=("root"); fi

# Get Sessions (X11 & Wayland)
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
    SESSION_NAMES+=("$name")
    SESSION_CMDS+=("$exec_cmd")
    SESSION_TYPES+=("x11")
done

# Fallback session if none found
if [ ${#SESSION_NAMES[@]} -eq 0 ]; then
    SESSION_NAMES=("Shell")
    SESSION_CMDS=("/bin/bash")
    SESSION_TYPES=("shell")
fi

# Restore last used session/user if available
if [ -f "$CACHE_FILE" ]; then
    source "$CACHE_FILE"
    # Find indices
    for i in "${!USER_LIST[@]}"; do
        [[ "${USER_LIST[$i]}" == "$LAST_USER" ]] && SELECTED_USER_IDX=$i
    done
    for i in "${!SESSION_NAMES[@]}"; do
        [[ "${SESSION_NAMES[$i]}" == "$LAST_SESSION" ]] && SELECTED_SESSION_IDX=$i
    done
fi

# --- 3. AUTHENTICATION LOGIC ---

# Verify password using Python (Needs Root to read /etc/shadow)
verify_credentials() {
    local user=$1
    local pass=$2
    
    # If not root, we can't check shadow. Use dummy check or sudo trick (unreliable in TUI)
    if [ "$EUID" -ne 0 ]; then
        STATUS_MSG="Error: Script must run as Root"
        return 1
    fi

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

# --- 4. SESSION LAUNCHER ---

start_session() {
    local user="${USER_LIST[$SELECTED_USER_IDX]}"
    local session_cmd="${SESSION_CMDS[$SELECTED_SESSION_IDX]}"
    local session_type="${SESSION_TYPES[$SELECTED_SESSION_IDX]}"
    local session_name="${SESSION_NAMES[$SELECTED_SESSION_IDX]}"

    # Save preference
    echo "LAST_USER=\"$user\"" > "$CACHE_FILE"
    echo "LAST_SESSION=\"$session_name\"" >> "$CACHE_FILE"

    tput cnorm; clear
    echo "Starting $session_name for $user..."

    # Setup Logging
    local log="/home/$user/.core-session.log"
    
    # Switch to user and launch
    # We use 'su -' to simulate a fresh login shell environment
    
    if [ "$session_type" == "wayland" ]; then
        # Wayland Launch
        su - "$user" -c "export XDG_SESSION_TYPE=wayland; export XDG_CURRENT_DESKTOP=$session_name; exec $session_cmd" > "$log" 2>&1
    elif [ "$session_type" == "x11" ]; then
        # X11 Launch (Requires tricking startx)
        # Create a temp xinitrc for the user
        su - "$user" -c "echo 'exec $session_cmd' > ~/.xinitrc; startx" > "$log" 2>&1
    else
        # Shell fallback
        su - "$user" -c "$session_cmd"
    fi
    
    # If session ends, return to login loop
    tput civis
    INPUT_PASSWORD=""
    STATUS_MSG="Session Logged Out"
    STATUS_COLOR="$C_CYAN"
}

# --- 5. UI DRAWING ---

draw_ui() {
    #tput clear # Flicker reduction: don't full clear, just overwrite lines
    local rows=$(tput lines)
    local cols=$(tput cols)
    local cy=$((rows / 2 - 4))
    local cx=$((cols / 2))

    # Calculate centered positions
    # We assume a drawing width of roughly 60 chars
    
    # 1. Status Message (Top)
    tput cup $((cy - 2)) 0
    if [ ! -z "$STATUS_MSG" ]; then
        local msg="<  $STATUS_MSG  >"
        local start=$(( (cols - ${#msg}) / 2 ))
        tput cup $((cy - 2)) $start
        echo -e "${STATUS_COLOR}${C_BOLD}${msg}${C_RESET}"
    else
        tput el # Clear line
    fi

    # 2. Session Selector
    local s_name="${SESSION_NAMES[$SELECTED_SESSION_IDX]}"
    local s_label="session"
    if [ $FOCUS_IDX -eq 0 ]; then C_FOC="$C_CYAN"; else C_FOC="$C_GREY"; fi
    
    tput cup $cy $((cx - 20)); echo -e "${C_GREY}${s_label}${C_RESET}"
    tput cup $cy $((cx - 5)); echo -e "${C_FOC}< ${C_WHITE}${s_name} ${C_FOC}>${C_RESET}   "

    # 3. User Selector
    local u_name="${USER_LIST[$SELECTED_USER_IDX]}"
    local u_label="login"
    if [ $FOCUS_IDX -eq 1 ]; then C_FOC="$C_CYAN"; else C_FOC="$C_GREY"; fi
    
    tput cup $((cy + 2)) $((cx - 20)); echo -e "${C_GREY}${u_label}${C_RESET}"
    tput cup $((cy + 2)) $((cx - 5)); echo -e "${C_FOC}< ${C_WHITE}${u_name} ${C_FOC}>${C_RESET}   "

    # 4. Password Input
    local p_label="password"
    # Mask password
    local p_mask=""
    for ((i=0; i<${#INPUT_PASSWORD}; i++)); do p_mask+="*"; done
    
    if [ $FOCUS_IDX -eq 2 ]; then 
        C_FOC="$C_WHITE"; CURSOR="${C_CYAN}█${C_RESET}" 
    else 
        C_FOC="$C_GREY"; CURSOR=""
    fi

    tput cup $((cy + 4)) $((cx - 20)); echo -e "${C_GREY}${p_label}${C_RESET}"
    tput cup $((cy + 4)) $((cx - 5)); echo -e "${C_FOC}${p_mask}${CURSOR}      " # Trailing spaces to clear deletion
}

# --- 6. MAIN LOOP ---

clear
while true; do
    draw_ui
    
    # Read 1 byte
    IFS= read -rsn1 key

    # Handle Special Keys (Escape Sequences)
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 key
        case "$key" in
            '[A') # Up
                ((FOCUS_IDX--)); [ $FOCUS_IDX -lt 0 ] && FOCUS_IDX=2 ;;
            '[B') # Down
                ((FOCUS_IDX++)); [ $FOCUS_IDX -gt 2 ] && FOCUS_IDX=0 ;;
            '[C') # Right
                if [ $FOCUS_IDX -eq 0 ]; then
                    ((SELECTED_SESSION_IDX++))
                    [ $SELECTED_SESSION_IDX -ge ${#SESSION_NAMES[@]} ] && SELECTED_SESSION_IDX=0
                elif [ $FOCUS_IDX -eq 1 ]; then
                    ((SELECTED_USER_IDX++))
                    [ $SELECTED_USER_IDX -ge ${#USER_LIST[@]} ] && SELECTED_USER_IDX=0
                fi
                ;;
            '[D') # Left
                if [ $FOCUS_IDX -eq 0 ]; then
                    ((SELECTED_SESSION_IDX--))
                    [ $SELECTED_SESSION_IDX -lt 0 ] && SELECTED_SESSION_IDX=$((${#SESSION_NAMES[@]} - 1))
                elif [ $FOCUS_IDX -eq 1 ]; then
                    ((SELECTED_USER_IDX--))
                    [ $SELECTED_USER_IDX -lt 0 ] && SELECTED_USER_IDX=$((${#USER_LIST[@]} - 1))
                fi
                ;;
        esac
    
    # Handle Enter (Submit or Next Field)
    elif [[ $key == "" ]]; then
        if [ $FOCUS_IDX -ne 2 ]; then
            FOCUS_IDX=2 # Jump to password
        else
            # Submit Login
            STATUS_MSG="Verifying..."
            STATUS_COLOR="$C_CYAN"
            draw_ui
            
            if verify_credentials "${USER_LIST[$SELECTED_USER_IDX]}" "$INPUT_PASSWORD"; then
                start_session
            else
                STATUS_MSG="Authentication Failed"
                STATUS_COLOR="$C_RED"
                INPUT_PASSWORD=""
            fi
        fi
        
    # Handle Backspace (127 or 08)
    elif [[ $key == $'\x7f' || $key == $'\x08' ]]; then
        if [ $FOCUS_IDX -eq 2 ] && [ ${#INPUT_PASSWORD} -gt 0 ]; then
            INPUT_PASSWORD="${INPUT_PASSWORD::-1}"
        fi

    # Handle Tab (Cycle Focus)
    elif [[ $key == $'\t' ]]; then
        ((FOCUS_IDX++)); [ $FOCUS_IDX -gt 2 ] && FOCUS_IDX=0

    # Handle Typing (Password Field Only)
    else
        if [ $FOCUS_IDX -eq 2 ]; then
            INPUT_PASSWORD+="$key"
        fi
    fi
done
