#!/bin/bash

# Simple run script for ssbnk
# Downloads and runs the latest ssbnk Docker image

set -e

echo "📸 ssbnk (ScreenShot Bank) - Quick Start"
echo "Screenshot sharing that hits different"
echo "Pronounced 'spank' - because your screenshots deserve good hosting!"
echo ""

# Configuration
SSBNK_URL=${SSBNK_URL:-"https://screenshots.example.com"}
SSBNK_SCREENSHOT_DIR=${SSBNK_SCREENSHOT_DIR:-"$HOME/screenshots"}
SSBNK_RETENTION_DAYS=${SSBNK_RETENTION_DAYS:-30}

echo "🔧 Configuration:"
echo "  📁 Watch Directory: $SSBNK_SCREENSHOT_DIR"
echo "  🌐 Service URL: $SSBNK_URL"
echo "  🗑️  Retention Days: $SSBNK_RETENTION_DAYS"
echo ""

# Create screenshot directory if it doesn't exist
if [ ! -d "$SSBNK_SCREENSHOT_DIR" ]; then
  echo "📁 Creating screenshot directory: $SSBNK_SCREENSHOT_DIR"
  mkdir -p "$SSBNK_SCREENSHOT_DIR"
fi

# Detect display server
echo "🖥️  Display Server Detection:"
if [ -n "$WAYLAND_DISPLAY" ] || [ "$XDG_SESSION_TYPE" = "wayland" ]; then
  echo "  ✅ Wayland detected"
  DISPLAY_ARGS="-e WAYLAND_DISPLAY=$WAYLAND_DISPLAY -e XDG_SESSION_TYPE=wayland"
elif [ -n "$DISPLAY" ]; then
  echo "  ✅ X11 detected"
  DISPLAY_ARGS="-e DISPLAY=$DISPLAY"
else
  echo "  ⚠️  No display server detected - clipboard may not work"
  DISPLAY_ARGS=""
fi
echo ""

# Stop existing container if running
if docker ps -q -f name=ssbnk >/dev/null 2>&1; then
  echo "🛑 Stopping existing ssbnk container..."
  docker stop ssbnk >/dev/null 2>&1
  docker rm ssbnk >/dev/null 2>&1
fi

# Pull latest image
echo "📥 Pulling latest ssbnk image..."
docker pull ssbnk/ssbnk:latest

# Run the container
echo "🚀 Starting ssbnk..."
docker run -d \
  --name ssbnk \
  --restart unless-stopped \
  --network host \
  --privileged \
  -v "$SSBNK_SCREENSHOT_DIR:/watch" \
  -v ssbnk_data:/data \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v "${XDG_RUNTIME_DIR:-/run/user/1000}:/run/user/1000:rw" \
  -e SSBNK_URL="$SSBNK_URL" \
  -e SSBNK_RETENTION_DAYS="$SSBNK_RETENTION_DAYS" \
  -e XDG_RUNTIME_DIR=/run/user/1000 \
  $DISPLAY_ARGS \
  ssbnk/ssbnk:latest

echo ""
echo "✅ ssbnk is now running!"
echo ""
echo "📋 Next steps:"
echo "  1. Take a screenshot and save it to: $SSBNK_SCREENSHOT_DIR"
echo "  2. The URL will be automatically copied to your clipboard"
echo "  3. Your screenshot will be available at: $SSBNK_URL/hosted/[filename]"
echo ""
echo "🔍 Useful commands:"
echo "  📊 Check status: docker ps | grep ssbnk"
echo "  📜 View logs: docker logs -f ssbnk"
echo "  🛑 Stop service: docker stop ssbnk"
echo "  🗑️  Remove service: docker rm ssbnk"
echo ""
echo "🌐 Configure your reverse proxy (Traefik/nginx) to point to localhost:80"
echo "📚 Full documentation: https://github.com/delorenj/ssbnk"
