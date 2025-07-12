#!/bin/bash

# Bloodbank Display Server Detection Script
# This script helps detect your display server and set up the environment

echo "🩸 Bloodbank Display Server Detection"
echo "======================================"

# Check for Wayland
if [ -n "$WAYLAND_DISPLAY" ] || [ "$XDG_SESSION_TYPE" = "wayland" ]; then
    echo "✅ Wayland detected!"
    echo "   WAYLAND_DISPLAY: ${WAYLAND_DISPLAY:-not set}"
    echo "   XDG_SESSION_TYPE: ${XDG_SESSION_TYPE:-not set}"
    echo "   XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-not set}"
    
    # Check if wl-clipboard is available
    if command -v wl-copy >/dev/null 2>&1; then
        echo "   wl-clipboard: ✅ installed"
    else
        echo "   wl-clipboard: ❌ not installed"
        echo "   Install with: sudo apt install wl-clipboard (Ubuntu/Debian)"
        echo "                 sudo pacman -S wl-clipboard (Arch)"
        echo "                 sudo dnf install wl-clipboard (Fedora)"
    fi
    
    echo ""
    echo "📝 For Wayland, ensure these environment variables are set:"
    echo "   export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}"
    echo "   export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    echo "   export XDG_SESSION_TYPE=wayland"
    
elif [ -n "$DISPLAY" ]; then
    echo "✅ X11 detected!"
    echo "   DISPLAY: $DISPLAY"
    
    # Check if xclip is available
    if command -v xclip >/dev/null 2>&1; then
        echo "   xclip: ✅ installed"
    else
        echo "   xclip: ❌ not installed"
        echo "   Install with: sudo apt install xclip (Ubuntu/Debian)"
        echo "                 sudo pacman -S xclip (Arch)"
        echo "                 sudo dnf install xclip (Fedora)"
    fi
    
else
    echo "❌ No display server detected!"
    echo "   Make sure you're running this in a graphical session."
fi

echo ""
echo "🐳 Docker Environment:"
echo "   The bloodbank-watcher container will automatically detect"
echo "   your display server and use the appropriate clipboard tool."
echo ""
echo "🚀 To start Bloodbank:"
echo "   docker compose up -d"
