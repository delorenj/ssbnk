#!/bin/bash

# Instant Screenshot for Bloodbank
# Takes screenshot and immediately places it in Bloodbank watch directory

SCREENSHOT_DIR="$HOME/ss"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
FILENAME="screenshot-$TIMESTAMP.png"

echo "📸 Taking instant screenshot..."

# Detect screenshot tool and take screenshot
if command -v gnome-screenshot >/dev/null 2>&1; then
    gnome-screenshot -a -f "$SCREENSHOT_DIR/$FILENAME"
elif command -v scrot >/dev/null 2>&1; then
    scrot -s "$SCREENSHOT_DIR/$FILENAME"
elif command -v maim >/dev/null 2>&1; then
    maim -s "$SCREENSHOT_DIR/$FILENAME"
elif command -v grim >/dev/null 2>&1 && command -v slurp >/dev/null 2>&1; then
    # Wayland screenshot
    grim -g "$(slurp)" "$SCREENSHOT_DIR/$FILENAME"
else
    echo "❌ No screenshot tool found!"
    echo "Install one of: gnome-screenshot, scrot, maim, or grim+slurp"
    exit 1
fi

if [ -f "$SCREENSHOT_DIR/$FILENAME" ]; then
    echo "✅ Screenshot saved: $FILENAME"
    echo "🩸 Bloodbank will process it shortly..."
    
    # Optional: Force Syncthing sync if needed
    if command -v curl >/dev/null 2>&1; then
        curl -s -X POST -H "X-API-Key: CAGmzQmefZA5ykZTv5EhK45KfXw3zq6f" \
          "http://localhost:8384/rest/db/scan?folder=ss" > /dev/null 2>&1
    fi
else
    echo "❌ Screenshot failed or cancelled"
fi
