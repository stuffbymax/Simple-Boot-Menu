#!/bin/bash

# --- Configuration ---
TEXT_COLOR=$(tput setaf 7)   # White
ACCENT_COLOR=$(tput setaf 6) # Cyan
RESET_COLOR=$(tput sgr0)
BOLD=$(tput bold)

# --- Functions ---

# Function to draw text at a specific coordinate
draw_at() {
    local row=$1
    local col=$2
    local text=$3
    tput cup $row $col
    echo -e "${text}"
}

# Function to get System Info
get_sys_info() {
    # Get Distro Name
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$PRETTY_NAME
    else
        OS_NAME=$(uname -o)
    fi
    
    KERNEL=$(uname -r)
    UPTIME=$(uptime -p | sed 's/up //')
    MEMORY=$(free -h | grep Mem | awk '{print $3 "/" $2}')
}

# Function to detect Installed Window Managers / DEs
get_installed_des() {
    # Look in standard session directories
    SESSION_FILES="/usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop"
    
    INSTALLED_SESSIONS=()
    
    for session in $SESSION_FILES; do
        if [ -e "$session" ]; then
            # Extract filename without path and extension (e.g., /.../xfce.desktop -> xfce)
            name=$(basename "$session" .desktop)
            # Capitalize first letter
            name="${name^}" 
            INSTALLED_SESSIONS+=("$name")
        fi
    done
    
    # Check specifically for i3 if not found in sessions (sometimes installed without session file)
    if command -v i3 >/dev/null 2>&1 && [[ ! " ${INSTALLED_SESSIONS[*]} " =~ "i3" ]]; then
        INSTALLED_SESSIONS+=("i3 (Manual)")
    fi
}

# --- Main Draw Loop ---

clear
get_sys_info
get_installed_des

# Calculate screen dimensions
COLS=$(tput cols)
ROWS=$(tput lines)

# --- 1. Draw Top Right System Info ---
# calculate the starting column based on the longest string to ensure alignment
MAX_WIDTH=30
START_COL=$((COLS - MAX_WIDTH - 2))

# Draw a box or just text in top right
draw_at 1 $START_COL "${ACCENT_COLOR}${BOLD}SYSTEM INFO${RESET_COLOR}"
draw_at 2 $START_COL "${TEXT_COLOR}OS:      ${OS_NAME:0:20}${RESET_COLOR}"
draw_at 3 $START_COL "${TEXT_COLOR}Kernel:  ${KERNEL}${RESET_COLOR}"
draw_at 4 $START_COL "${TEXT_COLOR}Uptime:  ${UPTIME}${RESET_COLOR}"
draw_at 5 $START_COL "${TEXT_COLOR}Memory:  ${MEMORY}${RESET_COLOR}"

# --- 2. Draw Main Menu (Left Side) ---
draw_at 2 4 "${ACCENT_COLOR}${BOLD}BOOT MENU / DASHBOARD${RESET_COLOR}"
draw_at 4 4 "Select a session to launch (Conceptual):"

ROW=6
for i in "${!INSTALLED_SESSIONS[@]}"; do
    # List item number and name
    draw_at $ROW 4 "${ACCENT_COLOR}$((i+1)).${RESET_COLOR} ${INSTALLED_SESSIONS[$i]}"
    ((ROW++))
done

draw_at $((ROW+2)) 4 "Detected ${#INSTALLED_SESSIONS[@]} environments."

# --- Move cursor to bottom to prevent overwriting ---
tput cup $ROWS 0
