# Multi-stage Dockerfile for ssbnk (ScreenShot Bank)
# Creates a single image with all components

# Stage 1: Build the Go watcher
FROM golang:1.21-alpine AS watcher-builder

WORKDIR /build
COPY watcher/go.mod watcher/go.sum ./
RUN go mod download

COPY watcher/main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o ssbnk-watcher .

# Stage 2: Build the final image
FROM nginx:alpine

# Install required packages
RUN apk add --no-cache \
  supervisor \
  xclip \
  wl-clipboard \
  curl \
  ca-certificates \
  tzdata \
  && rm -rf /var/cache/apk/*

# Copy the Go watcher binary
COPY --from=watcher-builder /build/ssbnk-watcher /usr/local/bin/ssbnk-watcher
RUN chmod +x /usr/local/bin/ssbnk-watcher

# Copy nginx configuration
COPY web/nginx.conf /etc/nginx/nginx.conf
COPY web/default.conf /etc/nginx/conf.d/default.conf

# Copy scripts
COPY scripts/cleanup.sh /usr/local/bin/cleanup.sh
COPY scripts/detect-display-server.sh /usr/local/bin/detect-display-server.sh
RUN chmod +x /usr/local/bin/cleanup.sh /usr/local/bin/detect-display-server.sh

# Create supervisor configuration
RUN mkdir -p /etc/supervisor/conf.d

# Supervisor configuration for all services
COPY <<EOF /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/nginx.err.log
stdout_logfile=/var/log/supervisor/nginx.out.log

[program:ssbnk-watcher]
command=/usr/local/bin/ssbnk-watcher
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/watcher.err.log
stdout_logfile=/var/log/supervisor/watcher.out.log
environment=SSBNK_SCREENSHOT_DIR="/media/screenshots",SSBNK_DATA_DIR="/data",SSBNK_URL="%(ENV_SSBNK_URL)s"

[program:cleanup-cron]
command=/bin/sh -c 'echo "0 2 * * * /usr/local/bin/cleanup.sh" | crontab - && crond -f'
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/cleanup.err.log
stdout_logfile=/var/log/supervisor/cleanup.out.log
environment=SSBNK_RETENTION_DAYS="%(ENV_SSBNK_RETENTION_DAYS)s"
EOF

# Create necessary directories
RUN mkdir -p /data/hosted /data/metadata /data/archive /media/screenshots /media/screencasts /media/screencasts /var/log/supervisor

# Create startup script
COPY <<EOF /usr/local/bin/start-ssbnk.sh
#!/bin/sh
set -e

echo "🚀 Starting ssbnk (ScreenShot Bank)"
echo "📸 Screenshot sharing that hits different"
echo ""

# Display configuration
echo "Configuration:"
echo "  📁 Screenshot Directory: \${SSBNK_SCREENSHOT_DIR:-/media/screenshots}"
echo "  📁 Screencast Directory: \${SSBNK_SCREENCAST_DIR:-/media/screencasts}"
echo "  🌐 Service URL: \${SSBNK_URL:-http://localhost}"
echo "  🗑️  Retention Days: \${SSBNK_RETENTION_DAYS:-30}"
echo ""

# Detect display server
echo "🖥️  Display Server Detection:"
if [ -n "\$WAYLAND_DISPLAY" ] || [ "\$XDG_SESSION_TYPE" = "wayland" ]; then
    echo "  ✅ Wayland detected (WAYLAND_DISPLAY=\$WAYLAND_DISPLAY)"
elif [ -n "\$DISPLAY" ]; then
    echo "  ✅ X11 detected (DISPLAY=\$DISPLAY)"
else
    echo "  ⚠️  No display server detected - clipboard may not work"
fi
echo ""

# Check clipboard tools
echo "🔧 Clipboard Tools:"
if command -v wl-copy >/dev/null 2>&1; then
    echo "  ✅ wl-copy available (Wayland)"
fi
if command -v xclip >/dev/null 2>&1; then
    echo "  ✅ xclip available (X11)"
fi
echo ""

# Set default environment variables
export SSBNK_SCREENSHOT_DIR=\${SSBNK_SCREENSHOT_DIR:-/media/screenshots}
export SSBNK_SCREENCAST_DIR=\${SSBNK_SCREENCAST_DIR:-/media/screencasts}
export SSBNK_DATA_DIR=\${SSBNK_DATA_DIR:-/data}
export SSBNK_URL=\${SSBNK_URL:-http://localhost}
export SSBNK_RETENTION_DAYS=\${SSBNK_RETENTION_DAYS:-30}

# Ensure directories exist with proper permissions
mkdir -p "\$SSBNK_DATA_DIR/hosted" "\$SSBNK_DATA_DIR/metadata" "\$SSBNK_DATA_DIR/archive" "\$SSBNK_SCREENSHOT_DIR"

# Start supervisor
echo "🎬 Starting all services..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
EOF

RUN chmod +x /usr/local/bin/start-ssbnk.sh

# Set up volumes
VOLUME ["/media", "/data"]

# Expose HTTP port
EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost/ || exit 1

# Environment variables with defaults
ENV SSBNK_URL=http://localhost
ENV SSBNK_SCREENSHOT_DIR=/media/screenshots
ENV SSBNK_SCREENCAST_DIR=/media/screencasts
ENV SSBNK_DATA_DIR=/data
ENV SSBNK_RETENTION_DAYS=30

# Labels for metadata
LABEL org.opencontainers.image.title="ssbnk"
LABEL org.opencontainers.image.description="ScreenShot Bank - Lightweight, lighning-fast screenshot hosting that hits different."
LABEL org.opencontainers.image.url="https://github.com/delorenj/ssbnk"
LABEL org.opencontainers.image.source="https://github.com/delorenj/ssbnk"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.licenses="MIT"

# Start the application
CMD ["/usr/local/bin/start-ssbnk.sh"]
