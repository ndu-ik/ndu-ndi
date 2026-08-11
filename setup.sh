#!/bin/bash
set -uo pipefail

# Define target directory
TARGET_DIR="$HOME/ndu-ndi"

# Create the directory if it doesn't exist and navigate into it
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR" || exit 1

echo "Downloading top-level files directly... and picom"

# Base URL for raw content from the wallpaper branch
BASE_URL="https://raw.githubusercontent.com/ndu-ik/ndu-ndi/wallpaper"

# Download a file and abort with a clear message if it fails or comes back empty.
fetch() {
    local url="$1" dest="$2"
    if ! curl -sL -f "$url" -o "$dest"; then
        echo "Failed to download $url"
        return 1
    fi
    if [ ! -s "$dest" ]; then
        echo "Downloaded $dest but it is empty."
        return 1
    fi
}

fetch "$BASE_URL/.conkyrc" ".conkyrc" || exit 1
fetch "$BASE_URL/conky_helpers.lua" "conky_helpers.lua" || exit 1
fetch "$BASE_URL/fluidwall.sh" "fluidwall.sh" || exit 1
fetch "$BASE_URL/fluidwall-tray.sh" "fluidwall-tray.sh" || exit 1

# Download and place picom.conf into ~/.config/
mkdir -p "$HOME/.config"
fetch "$BASE_URL/picom.conf" "$HOME/.config/picom.conf" || exit 1

# Check if downloads were successful
if [ -f "fluidwall.sh" ]; then
    # Make fluidwall.sh executable just in case
    chmod +x fluidwall.sh

    # Run the fluidwall.sh script with set-install parameter and wait for it to finish
    if ! ./fluidwall.sh set-install; then
        echo "fluidwall.sh set-install failed. Aborting before starting conky/picom."
        exit 1
    fi

    echo "Installation finished. Starting picom..."
    # Conky is no longer started here -- fluidwall.sh now manages conky
    # itself (starts it on 'fluidwall start'/'restart' and monitors it every
    # 30s), gated by the CONKY config flag (--conky/--no-conky).
    picom --config "$HOME/.config/picom.conf" &
    disown -a
else
    echo "Failed to download required files."
    exit 1
fi