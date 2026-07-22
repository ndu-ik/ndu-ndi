#!/bin/bash

# Define target directory
TARGET_DIR="$HOME/ndu-ndi"

# Create the directory if it doesn't exist and navigate into it
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR" || exit

echo "Downloading top-level files directly..."

# Base URL for raw content from the wallpaper branch
BASE_URL="https://raw.githubusercontent.com/ndu-ik/ndu-ndi/wallpaper"

# Download the required files directly
curl -sL "$BASE_URL/.conkyrc" -o .conkyrc
curl -sL "$BASE_URL/conky_helpers.lua" -o conky_helpers.lua
curl -sL "$BASE_URL/fluidwall.sh" -o fluidwall.sh

# Check if downloads were successful
if [ -f "fluidwall.sh" ]; then
    # Make fluidwall.sh executable just in case
    chmod +x fluidwall.sh
    
    # Run the fluidwall.sh script with set-install parameter
    ./fluidwall.sh set-install
else
    echo "Failed to download required files."
    exit 1
fi