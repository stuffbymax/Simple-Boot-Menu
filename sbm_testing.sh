#!/bin/bash

# ==============================================================================
#  LINUX TUI DASHBOARD V2
# ==============================================================================

# --- 1. SETUP & COLORS ---
tput civis # Hide cursor
trap "tput cnorm; clear; exit" INT TERM

# Color Palette
C_RESET=$(tput sgr0)
C_BOLD=$(tput bold)
C_DIM=$(tput dim)

# Theme Colors
C_ACCENT=$(tput setaf 6)     # Cyan
C_SECOND=$(tput setaf 4)     # Blue
C_TEXT=$(tput setaf 7)       # White
C_MUTED=$(tput setaf 8)      # Grey
C_WARN=$(tput setaf 1)       # Red
C_SUCCESS=$(tput setaf 2)    # Green

# Backgrounds
C_SEL_BG=$(tput setab 4)     # Blue Background
C_SEL_FG=$(tput setaf 7)     # White Foreground

# --- 2. DATA GATHERING ---

# System Info
KERNEL=$(uname -r | cut -d'-' -f1)
UPTIME=$(uptime -p | sed 's/up //;s/ hours/h/;s/ minutes/m/')
USER_SHELL=$(basename "$SHELL")
HOSTNAME=$(hostname)
# Get Distro Name
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_NAME=$ID
    PRETTY_NAME=$PRETTY_NAME
else
    DISTRO_NAME="linux"
    PRETTY_NAME="Linux Generic"
fi

# Resource Usage (Quick & Dirty)
get_resources() {
    MEM_USED=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
    DISK_USED=$(df -h / | awk 'NR==2 {print $5}')
    LOAD_AVG=$(cut -d ' ' -f1 /proc/loadavg)
}

# Scan for Sessions
OPTIONS=()
COMMANDS=()

add_option() {
    OPTIONS+=("$1")
    COMMANDS+=("$2")
}

# Scan Desktop Files
for path in /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
    if [ -f "$path" ]; then
        name=$(grep -m 1 "^Name=" "$path" | cut -d= -f2)
        [ -z "$name" ] && name=$(basename "$path" .desktop)
        exec_cmd=$(grep -m 1 "^Exec=" "$path" | cut -d= -f2)
        
        # Prevent duplicates
        if [[ ! " ${OPTIONS[*]} " =~ " ${name} " ]]; then
            add_option "$name" "$exec_cmd"
        fi
    fi
done

# Add System Actions
add_option "Reboot" "systemctl reboot"
add_option "Shutdown" "systemctl poweroff"
add_option "Exit to Shell" "exit"

# --- 3. ASCII ART ASSETS ---

get_ascii_logo() {
    case "$DISTRO_NAME" in
        arch)
            LOGO=(
                "      /\\"
                "     /  \\"
                "    /    \\"
                "   /      \\"
                "  /   ,,   \\"
                " /   |  |   \\"
                "/_-''    ''-_\\"
            );;
        debian)
            LOGO=(
                "  _,met\$\$\$\$\$gg."
                " ,g\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$P."
                ",g\$\$P\"     \"\"\"Y\$\$."
                "\$\$P'              \`\$\$"
                "'\$\$p              ,\$\$"
                " \`Y\$\$             \$\$"
                "   \`Y\$\$.         \$\$"
            );;
        ubuntu)
            LOGO=(
                "           _  "
                "         -' '-"
                "       _|  o  |_"
                "      | |  _  | |"
                "      | | |_| | |"
                "      | '  _  ' |"
                "       '  |_|  '"
            );;
        fedora)
            LOGO=(
                "      _____"
                "     /   __|"
                "    |   |"
                "    |   |___"
                "    |____   |"
                "         |  |"
                "         |__|"
            );;
        *)
            # Generic Linux
            LOGO=(
                "    .--."
                "   |o_o |"
                "   |:_/ |"
                "  //   \ \\"
                " (|     | )"
                "/'\_   _/\`\\"
                "\\___)=(___/"
            );;
    esac
}
get_ascii_logo

# --- 4. DRAWING FUNCTIONS ---

# Center text helper
center_text() {
    local text="$1"
    local width=$(tput cols)
    local padding=$(( (width - ${#text}) / 2 ))
    tput cup $2 $padding
    echo -e "$text"
}

# Center array helper
center_block() {
    local row=$1
    local arr=("${@:2}")
    local width=$(tput cols)
    
    for line in "${arr[@]}"; do
        local padding=$(( (width - ${#line}) / 2 ))
        tput cup $row $padding
        echo -e "${C_ACCENT}${C_BOLD}$line${C_RESET}"
        ((row++))
    done
}

draw_stats_box() {
    get_resources # Refresh stats
    
    local cols=$(tput cols)
    local width=32
    local start_col=$((cols - width - 2))
    
    # Box Colors
    local B=${C_MUTED} # Border
    local L=${C_TEXT}  # Label
    local V=${C_SUCCESS} # Value

    tput cup 1 $start_col
    echo -e "${B}╭──────────────────────────────╮${C_RESET}"
    tput cup 2 $start_col
    echo -e "${B}│${C_RESET} ${L}OS:${C_RESET}   ${V}${PRETTY_NAME:0:18}..${C_RESET}\033[${start_col}G\033[31C${B}│${C_RESET}"
    tput cup 3 $start_col
    echo -e "${B}│${C_RESET} ${L}KRNL:${C_RESET} ${V}${KERNEL}${C_RESET}\033[${start_col}G\033[31C${B}│${C_RESET}"
    tput cup 4 $start_col
    echo -e "${B}│${C_RESET} ${L}TIME:${C_RESET} ${V}${UPTIME}${C_RESET}\033[${start_col}G\033[31C${B}│${C_RESET}"
    tput cup 5 $start_col
    echo -e "${B}│${C_RESET} ${L}MEM:${C_RESET}  ${V}${MEM_USED}${C_RESET}\033[${start_col}G\033[31C${B}│${C_RESET}"
    tput cup 6 $start_col
    echo -e "${B}│${C_RESET} ${L}DISK:${C_RESET} ${V}${DISK_USED}${C_RESET}\033[${start_col}G\033[31C${B}│${C_RESET}"
    tput cup 7 $start_col
    echo -e "${B}╰──────────────────────────────╯${C_RESET}"
}

draw_menu() {
    local rows=$(tput lines)
    local cols=$(tput cols)
    local total=${#OPTIONS[@]}
    
    # Calculate center position for menu
    local start_row=$(( (rows / 2) - (total / 2) + 2 )) 
    local menu_width=40
    local menu_pad=$(( (cols - menu_width) / 2 ))

    # Draw Header (Distro Logo) slightly above menu
    center_block $((start_row - 9)) "${LOGO[@]}"
    
    center_text "${C_BOLD}WELCOME BACK, ${USER^^}${C_RESET}" $((start_row - 2))

    # Draw Menu Items
    for ((i=0; i<total; i++)); do
        tput cup $((start_row + i)) $menu_pad
        
        local label="${OPTIONS[$i]}"
        local icon=" " # Default icon
        
        # Add dynamic icons (Text-based to be safe)
        [[ "$label" == "Reboot" ]] && icon="↻"
        [[ "$label" == "Shutdown" ]] && icon="⏻"
        [[ "$label" == "Exit to Shell" ]] && icon=">"
        
        if [ $i -eq $SELECTED ]; then
            # Selected Style
            printf "${C_SEL_BG}${C_SEL_FG} %-2s %-34s ${C_RESET}" "$icon" "$label"
        else
            # Normal Style
            printf "${C_MUTED} %-2s %-34s ${C_RESET}" "$icon" "$label"
        fi
    done

    # Draw Footer
    local footer_y=$((rows - 2))
    center_text "${C_MUTED}Use ${C_BOLD}↑/↓${C_RESET}${C_MUTED} to move • ${C_BOLD}ENTER${C_RESET}${C_MUTED} to select${C_RESET}" $footer_y
}

# --- 5. MAIN LOGIC ---

SELECTED=0
TOTAL_OPTS=${#OPTIONS[@]}

clear

while true; do
    draw_stats_box
    draw_menu
    
    # Input handling
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 key
        case "$key" in
            '[A') # UP
                ((SELECTED--))
                [ $SELECTED -lt 0 ] && SELECTED=$((TOTAL_OPTS - 1))
                ;;
            '[B') # DOWN
                ((SELECTED++))
                [ $SELECTED -ge $TOTAL_OPTS ] && SELECTED=0
                ;;
        esac
    elif [[ $key == "" ]]; then
        # ENTER
        break
    fi
done

# --- 6. EXECUTE ---
CMD=${COMMANDS[$SELECTED]}
NAME=${OPTIONS[$SELECTED]}

tput cnorm
clear

# Logic to handle starting sessions vs system commands
if [[ "$NAME" == "Reboot" ]] || [[ "$NAME" == "Shutdown" ]] || [[ "$NAME" == "Exit to Shell" ]]; then
    eval $CMD
else
    # It's a Desktop Environment
    echo "Starting $NAME..."
    
    if [[ -f ~/.xinitrc ]]; then
        # Sanitize .xinitrc
        sed -i '/^exec/d' ~/.xinitrc
        echo "exec $CMD" >> ~/.xinitrc
        startx
    else
        # Try direct execution (Wayland friendly)
        eval $CMD
    fi
fi
