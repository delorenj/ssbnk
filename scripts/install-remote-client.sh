#!/bin/bash
#
# ssbnk Remote Client Installer
# Run ON the remote machine (Linux or macOS).
#
# Installs the screenshot uploader and registers it as a user service:
#   - Linux: systemd user service (~/.config/systemd/user/ssbnk-remote-upload.service)
#   - macOS: launchd agent (~/Library/LaunchAgents/sh.delo.ss.remote-upload.plist)
#
# On macOS, if a watch directory is privacy-protected (Desktop/Documents/Downloads),
# the installer walks you through granting access in System Settings and waits
# until the permission is in place, then verifies end-to-end.
#
# Usage:
#   ./install-remote-client.sh [path-to-remote-screenshot-upload.sh]
#
# Config is read from existing ~/.config/ssbnk/remote.env if present,
# otherwise created from these env vars (prompted if unset):
#   SSBNK_HOST           e.g. https://ss.delo.sh
#   SSBNK_UPLOAD_KEY     shared secret matching the server's SSBNK_UPLOAD_KEY
#   SSBNK_SCREENSHOT_DIR colon-separated watch dirs
#                        (default: ~/Screenshots on Linux, ~/Desktop on macOS)

set -euo pipefail

OS="$(uname -s)"
SCRIPT_SRC="${1:-$(dirname "$0")/remote-screenshot-upload.sh}"
INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/ssbnk"
REMOTE_ENV="$CONFIG_DIR/remote.env"
SERVICE_NAME="ssbnk-remote-upload"
AGENT_LABEL="sh.delo.ss.remote-upload"
PROBE_LABEL="sh.delo.ss.tcc-probe"

# Homebrew isn't in the default PATH for non-interactive shells / launchd
[ "$OS" = "Darwin" ] && export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
fatal() { echo "ERROR: $*" >&2; exit 1; }

echo "ssbnk remote client installer ($OS)"

# --- Preflight ---------------------------------------------------------------

[ -f "$SCRIPT_SRC" ] || fatal "uploader script not found at: $SCRIPT_SRC"

case "$OS" in
    Linux)
        command -v inotifywait &>/dev/null || fatal "inotifywait missing. Install first, e.g.:
  sudo apt install inotify-tools    # Debian/Ubuntu
  sudo pacman -S inotify-tools      # Arch"
        ;;
    Darwin)
        if ! command -v fswatch &>/dev/null; then
            if command -v brew &>/dev/null; then
                info "fswatch missing — installing via Homebrew..."
                brew install fswatch || fatal "brew install fswatch failed"
            else
                fatal "fswatch missing and Homebrew not found. Install fswatch first: brew install fswatch"
            fi
        fi
        ;;
    *)
        fatal "unsupported OS: $OS"
        ;;
esac

command -v curl &>/dev/null || fatal "curl missing."

# --- Config ------------------------------------------------------------------

mkdir -p "$CONFIG_DIR"

if [ -f "$REMOTE_ENV" ]; then
    info "Keeping existing config: $REMOTE_ENV"
else
    DEFAULT_DIR="$HOME/Screenshots"
    [ "$OS" = "Darwin" ] && DEFAULT_DIR="$HOME/Desktop"

    SSBNK_HOST="${SSBNK_HOST:-}"
    SSBNK_UPLOAD_KEY="${SSBNK_UPLOAD_KEY:-}"
    SSBNK_SCREENSHOT_DIR="${SSBNK_SCREENSHOT_DIR:-$DEFAULT_DIR}"

    if [ -z "$SSBNK_HOST" ]; then
        read -rp "SSBNK_HOST (e.g. https://ss.delo.sh): " SSBNK_HOST
    fi
    if [ -z "$SSBNK_UPLOAD_KEY" ]; then
        read -rsp "SSBNK_UPLOAD_KEY: " SSBNK_UPLOAD_KEY
        echo ""
    fi

    umask 077
    cat > "$REMOTE_ENV" <<EOF
SSBNK_HOST=$SSBNK_HOST
SSBNK_UPLOAD_KEY=$SSBNK_UPLOAD_KEY
SSBNK_SCREENSHOT_DIR=$SSBNK_SCREENSHOT_DIR
EOF
    umask 022
    info "Wrote config: $REMOTE_ENV (mode 600)"
fi

# shellcheck disable=SC1090
. "$REMOTE_ENV"

# --- Install script ----------------------------------------------------------

mkdir -p "$INSTALL_DIR"
install -m 0755 "$SCRIPT_SRC" "$INSTALL_DIR/$SERVICE_NAME"
info "Installed: $INSTALL_DIR/$SERVICE_NAME"

# --- Service -----------------------------------------------------------------

if [ "$OS" = "Linux" ]; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/$SERVICE_NAME.service" <<EOF
[Unit]
Description=ssbnk remote screenshot uploader
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$INSTALL_DIR/$SERVICE_NAME
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME.service"
    systemctl --user restart "$SERVICE_NAME.service"
    info "systemd user service enabled and (re)started"
    echo "    Logs: journalctl --user -u $SERVICE_NAME -f"
else
    PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/ssbnk"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/$SERVICE_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/ssbnk/remote-upload.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/ssbnk/remote-upload.err</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    launchctl enable "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    launchctl kickstart "gui/$(id -u)/$AGENT_LABEL"
    info "launchd agent loaded and started: $AGENT_LABEL"
    echo "    Logs: tail -f ~/Library/Logs/ssbnk/remote-upload.log"
fi

# --- macOS: guided TCC permission flow ---------------------------------------

# Returns 0 if a launchd job (same TCC context as the agent) can read files in $1
tcc_read_test() {
    local dir="$1"
    local probe_file="$dir/.ssbnk-tcc-probe"
    echo "probe" > "$probe_file" 2>/dev/null || return 1
    local probe_plist="$HOME/Library/LaunchAgents/$PROBE_LABEL.plist"
    cat > "$probe_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PROBE_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>/bin/cat "$probe_file" &gt;/dev/null</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$PROBE_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$probe_plist" 2>/dev/null
    launchctl kickstart "gui/$(id -u)/$PROBE_LABEL" 2>/dev/null
    sleep 1
    local code
    code=$(launchctl print "gui/$(id -u)/$PROBE_LABEL" 2>/dev/null | grep "last exit code" | grep -oE '[0-9]+' | head -1)
    launchctl bootout "gui/$(id -u)/$PROBE_LABEL" 2>/dev/null || true
    rm -f "$probe_plist" "$probe_file"
    [ "$code" = "0" ]
}

tcc_wizard() {
    local protected_dirs=()
    local dir
    IFS=':' read -ra _dirs <<< "${SSBNK_SCREENSHOT_DIR:-$HOME/Desktop}"
    for dir in "${_dirs[@]}"; do
        dir="${dir/#\~/$HOME}"
        case "$dir" in
            "$HOME/Desktop"|"$HOME/Documents"|"$HOME/Downloads")
                [ -d "$dir" ] && protected_dirs+=("$dir") ;;
        esac
    done

    [ ${#protected_dirs[@]} -eq 0 ] && return 0

    local target="${protected_dirs[0]}"
    if tcc_read_test "$target"; then
        info "macOS privacy check: $target is readable by the agent"
        return 0
    fi

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│  One-time macOS permission needed                               │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "macOS blocks background services from reading $target"
    echo "until you explicitly allow it. Do ONE of the following:"
    echo ""
    echo "  A) If a system prompt pops up saying"
    echo "       \"bash\" would like to access files in your Desktop folder"
    echo "     just click \"Allow\"."
    echo ""
    echo "  B) Otherwise, grant it manually:"
    echo "       1. Open  System Settings → Privacy & Security → Files and Folders"
    echo "       2. Click '+', press Cmd+Shift+G and enter:  /bin/bash"
    echo "       3. Enable the toggle for 'Desktop Folder' next to bash"
    echo "     (If bash is already listed, just flip its toggle off and on.)"
    echo ""
    echo "  Broader alternative: System Settings → Privacy & Security →"
    echo "  Full Disk Access → enable /bin/bash (same +/- steps)."
    echo ""
    echo "Waiting for permission (Ctrl+C to abort; the agent will start"
    echo "working on its own once permission is granted)..."
    echo ""

    local elapsed=0
    while [ "$elapsed" -lt 600 ]; do
        if tcc_read_test "$target"; then
            echo ""
            info "Permission detected — $target is now readable."
            # Restart the agent so it picks up the fresh TCC grant
            launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL"
            return 0
        fi
        printf "."
        sleep 4
        elapsed=$((elapsed + 4))
    done

    echo ""
    warn "Timed out waiting for permission. The agent is installed and will"
    warn "start uploading as soon as access is granted in System Settings."
    return 1
}

# --- End-to-end verification --------------------------------------------------

e2e_test() {
    IFS=':' read -ra _dirs <<< "${SSBNK_SCREENSHOT_DIR:-$HOME/Desktop}"
    local watch_dir="${_dirs[0]/#\~/$HOME}"
    [ -d "$watch_dir" ] || { warn "watch dir $watch_dir missing — skipping e2e test"; return 0; }

    info "Checking host connectivity..."
    if ! curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$SSBNK_HOST/health" | grep -q 200; then
        warn "could not reach $SSBNK_HOST/health — check host/network."
        return 1
    fi

    info "Running end-to-end test (dropping a test screenshot)..."
    local probe="$watch_dir/ssbnk-install-test-$(date +%s).png"
    printf "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" \
        | base64 -d 2>/dev/null > "$probe" \
        || printf "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" \
        | base64 -D > "$probe"   # macOS base64 uses -D

    local i
    for i in $(seq 1 10); do
        sleep 3
        if curl -s --max-time 10 "$SSBNK_HOST/api/screenshots?limit=10" | grep -q "$(basename "$probe")"; then
            local hosted
            hosted=$(curl -s --max-time 10 "$SSBNK_HOST/api/screenshots?limit=10" \
                | grep -o '"url":"[^"]*"' | head -1 | cut -d'"' -f4)
            info "End-to-end OK: test screenshot uploaded and hosted."
            [ -n "$hosted" ] && echo "    Latest: $hosted"
            rm -f "$probe"
            return 0
        fi
    done

    warn "Test file was not uploaded within 30s."
    warn "Check the service logs (above) for errors."
    rm -f "$probe"
    return 1
}

# --- Run ---------------------------------------------------------------------

if [ "$OS" = "Darwin" ]; then
    tcc_wizard || true
fi

e2e_test || true

echo ""
info "Install complete."
if [ "$OS" = "Linux" ]; then
    echo "  Service: systemctl --user status $SERVICE_NAME"
    echo "  Logs:    journalctl --user -u $SERVICE_NAME -f"
else
    echo "  Agent:   launchctl print gui/$(id -u)/$AGENT_LABEL"
    echo "  Logs:    tail -f ~/Library/Logs/ssbnk/remote-upload.log"
fi
echo "  Config:  $REMOTE_ENV"
echo ""
echo "Take a screenshot — the hosted URL lands on your clipboard."
