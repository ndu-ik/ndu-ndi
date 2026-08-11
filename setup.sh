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
# fluidwall.sh's set_install() looks for a file literally named "_conkyrc"
# (not ".conkyrc") in the repo dir -- keep this filename in sync with that.
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

fetch "$BASE_URL/_conkyrc" "_conkyrc" || exit 1
fetch "$BASE_URL/conky_helpers.lua" "conky_helpers.lua" || exit 1
fetch "$BASE_URL/fluidwall.sh" "fluidwall.sh" || exit 1

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

    echo "Installation finished. Starting conky and picom..."

    # Run conky and picom as independent background jobs. (Using
    # 'conky && picom ...' would block picom from ever starting, since
    # conky runs in the foreground and doesn't exit on its own.)
    conky &
    picom --config "$HOME/.config/picom.conf" &

    disown -a
else
    echo "Failed to download required files."
    exit 1
fi