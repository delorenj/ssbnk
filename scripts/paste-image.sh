#!/usr/bin/env bash
# Paste the latest hosted image into the focused Wayland app, then restore its URL.
set -euo pipefail

# GNOME custom shortcuts may omit both variables.
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

STATE_DIR="${SSBNK_STATE_DIR:-/home/delorenj/data/ssbnk/state}"
HOSTED_DIR="${SSBNK_HOSTED_DIR:-/home/delorenj/data/ssbnk/hosted}"

fail() {
    notify-send "ssbnk" "$1" 2>/dev/null || true
    printf 'ssbnk: %s\n' "$1" >&2
    exit 1
}

[ -f "$STATE_DIR/last-screenshot" ] || fail "No recent screenshot"
IFS= read -r filename < "$STATE_DIR/last-screenshot" || [ -n "${filename:-}" ] || fail "Empty screenshot marker"
# State is written by the server, but do not allow a malformed marker to escape the host root.
case "$filename" in
    ''|'.'|'..'|*/*|*\\*) fail "Invalid screenshot marker" ;;
esac
image="$HOSTED_DIR/$filename"
[ -f "$image" ] || fail "Screenshot file not found: $image"

case "${filename,,}" in
    *.png) mime=image/png ;;
    *.jpg|*.jpeg) mime=image/jpeg ;;
    *.gif) mime=image/gif ;;
    *.webp) mime=image/webp ;;
    *) fail "Unsupported screenshot format: $filename" ;;
esac

# Never destroy a clipboard we cannot read. In particular, do not turn a failed
# wl-paste into an empty clipboard on restoration.
saved_clip=$(wl-paste --no-newline) || fail "Could not read text clipboard"
restore=false
restore_clipboard() {
    if [ "$restore" = true ]; then
        printf '%s' "$saved_clip" | wl-copy --type 'text/plain;charset=utf-8' ||
            notify-send "ssbnk" "Could not restore text clipboard" 2>/dev/null || true
    fi
}
trap restore_clipboard EXIT
restore=true
wl-copy --type "$mime" < "$image"
sleep 0.2
# ydotool key codes: 29=Ctrl, 47=V. Requires a working ydotoold.
ydotool key 29:1 47:1 47:0 29:0
# Let the focused app request the image while it is still offered.
sleep 0.5
