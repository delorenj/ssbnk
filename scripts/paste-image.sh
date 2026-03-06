#!/bin/bash
#
# Paste Image - pastes the last screenshot as image data into the active window
#
# Bind to Ctrl+Shift+V in GNOME:
#   gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
#     "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']"
#   dconf write /org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/name "'Paste Image'"
#   dconf write /org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/command "'/home/delorenj/.local/bin/ssbnk-paste-image'"
#   dconf write /org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/binding "'<Shift><Control>v'"

set -euo pipefail

# GNOME custom shortcuts don't inherit session env; set what we need
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

LAST_FILE="/tmp/ssbnk/last-screenshot"

if [ ! -f "$LAST_FILE" ]; then
    notify-send "ssbnk" "No recent screenshot" 2>/dev/null || true
    exit 1
fi

# last-screenshot contains just the filename; resolve to host path
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FILENAME=$(cat "$LAST_FILE")
IMAGE_PATH="${PROJECT_DIR}/web/html/${FILENAME}"

if [ ! -f "$IMAGE_PATH" ]; then
    notify-send "ssbnk" "Screenshot file not found: $IMAGE_PATH" 2>/dev/null || true
    exit 1
fi

# Determine MIME type from extension
case "${IMAGE_PATH,,}" in
    *.png)  MIME="image/png" ;;
    *.jpg|*.jpeg) MIME="image/jpeg" ;;
    *.gif)  MIME="image/gif" ;;
    *.webp) MIME="image/webp" ;;
    *)      MIME="image/png" ;;
esac

# Save current clipboard text so we can restore it after pasting the image
SAVED_CLIP=$(wl-paste --no-newline 2>/dev/null || true)

# Set image data on clipboard
wl-copy --type "$MIME" < "$IMAGE_PATH"

# Small delay to let the clipboard settle and the shortcut keys to release
sleep 0.2

# Simulate Ctrl+V to paste into the active window
# ydotool key codes: 29=ctrl, 47=v
ydotool key 29:1 47:1 47:0 29:0

# Restore the original clipboard text after a brief delay
(sleep 0.5 && echo -n "$SAVED_CLIP" | wl-copy) &
