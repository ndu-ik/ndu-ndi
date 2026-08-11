#!/bin/bash
#distro=debian

# --- Global Configuration ---
# Uses the globally installed fluidwall command (via fluidwall.sh set-install)
export FW_CMD="fluidwall"
export ICON_TRAY="preferences-desktop-wallpaper"

# --- Core Functions ---

# Retrieves the current daemon status to dynamically adjust menu items
get_status() {
    # Use word-boundary match so "INACTIVE" doesn't get picked up by a
    # plain substring grep for "ACTIVE" (INACTIVE contains "ACTIVE").
    if $FW_CMD status | grep -qE '\bACTIVE\b'; then
        echo "ACTIVE"
    else
        echo "INACTIVE"
    fi
}
export -f get_status

# Handles the execution of options selected from the yad list
handle_action() {
    local action=$1
    case "$action" in
        START|RESTART)
            local action_cmd=$( [ "$action" == "START" ] && echo "start" || echo "restart" )
            
            # Prompts for duration using yad
            local duration=$(yad --entry --title="Fluidwall" \
                --text="Enter change duration (e.g., 5m, 1h-30m):" \
                --entry-text="5m" --window-icon="$ICON_TRAY" --center)
            
            if [[ -n "$duration" ]]; then
                # Applies start/restart with the --change flag[cite: 1]
                $FW_CMD "$action_cmd" -c "$duration"
                notify-send "Fluidwall" "Daemon $action_cmd initiated with a ${duration} interval."
            fi
            ;;
        STOP)
            # Stops the fluidwall daemon[cite: 1]
            $FW_CMD stop
            notify-send "Fluidwall" "Daemon stopped."
            ;;
        STATUS)
            # Displays the active or inactive status in a text box[cite: 1]
            $FW_CMD status | yad --text-info --width=500 --height=250 \
                --title="Fluidwall Status" --window-icon="$ICON_TRAY" --center
            ;;
        CHANGE_DURATION)
            # Changes duration on the fly[cite: 1]
            local duration=$(yad --entry --title="Fluidwall" \
                --text="Enter new duration (e.g., 5m, 10m, 2h):" \
                --entry-text="5m" --window-icon="$ICON_TRAY" --center)
            
            if [[ -n "$duration" ]]; then
                $FW_CMD change "$duration"
                notify-send "Fluidwall" "Live duration updated to $duration."
            fi
            ;;
        SET_LIVE_EVERY)
            # Changes set-live-every on the fly[cite: 1]
            local n=$(yad --entry --title="Fluidwall" \
                --text="Enter new 'live every' value (integer):" \
                --entry-text="3" --window-icon="$ICON_TRAY" --center)
            
            if [[ -n "$n" ]]; then
                $FW_CMD set-live-every "$n"
                notify-send "Fluidwall" "Live every frequency updated to $n."
            fi
            ;;
        EXIT_APP)
            # Terminates the tray app[cite: 2]
            killall yad
            exit 0
            ;;
    esac
}
export -f handle_action

# Generates the undecorated popup menu
open_menu() {
    local status=$(get_status)
    local menu_items=()

    # Dynamically inject start or restart options based on current daemon status
    if [[ "$status" == "ACTIVE" ]]; then
        menu_items+=("media-playback-start" "Restart Fluidwall" "RESTART")
        menu_items+=("media-playback-stop" "Stop Fluidwall" "STOP")
        menu_items+=("emblem-default" "Status: Active (Click for details)" "STATUS")
    else
        menu_items+=("media-playback-start" "Start Fluidwall" "START")
        menu_items+=("emblem-readonly" "Status: Inactive (Click for details)" "STATUS")
    fi

    menu_items+=("appointment-new" "Change Duration" "CHANGE_DURATION")
    menu_items+=("view-refresh" "Set Live Every" "SET_LIVE_EVERY")
    menu_items+=("system-log-out" "Exit Manager" "EXIT_APP")

    # Calculate height dynamically based on the number of options[cite: 2]
    local row_count=$((${#menu_items[@]} / 3))
    local calculated_height=$((row_count * 32 + 15))

    # Render menu[cite: 2]
    selected=$(yad --list \
        --undecorated --no-headers --close-on-unfocus --mouse --borders=0 \
        --width=260 --height=$calculated_height \
        --column="Icon:IMG" --column="Action" --column="ID:HD" \
        --print-column=3 --separator="" \
        "${menu_items[@]}")

    if [[ -n "$selected" ]]; then
        handle_action "$selected"
    fi
}
export -f open_menu

# --- Main Execution ---

main() {
    # Dependency Check[cite: 2]
    if ! command -v yad &>/dev/null; then
        echo "Error: 'yad' is required to run this wrapper. Please install it."
        exit 1
    fi

    # Launch Tray Icon via yad[cite: 2]
    yad --notification \
        --listen \
        --image="$ICON_TRAY" \
        --text="Fluidwall Manager" \
        --command="bash -c open_menu"
}

main