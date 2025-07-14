# Deployment Guide for ssbnk

This guide covers deploying ssbnk using the packaged Docker image.

## 🐳 Docker Image Deployment

### Quick Start

The fastest way to get ssbnk running:

```bash
curl -sSL https://raw.githubusercontent.com/delorenj/ssbnk/main/scripts/run-ssbnk.sh | bash
```

### Manual Docker Run

```bash
docker run -d \
  --name ssbnk \
  --restart unless-stopped \
  --network host \
  --privileged \
  -v $HOME/screenshots:/watch \
  -v ssbnk_data:/data \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v /run/user/1000:/run/user/1000:rw \
  -e SSBNK_URL=https://screenshots.example.com \
  -e SSBNK_RETENTION_DAYS=30 \
  -e DISPLAY=$DISPLAY \
  -e WAYLAND_DISPLAY=$WAYLAND_DISPLAY \
  -e XDG_RUNTIME_DIR=/run/user/1000 \
  ssbnk/ssbnk:latest
```

### Docker Compose (Packaged)

1. **Download configuration:**
   ```bash
   curl -O https://raw.githubusercontent.com/delorenj/ssbnk/main/docker-compose.packaged.yml
   curl -O https://raw.githubusercontent.com/delorenj/ssbnk/main/.env.example
   ```

2. **Configure:**
   ```bash
   cp .env.example .env
   vi .env  # Edit with your settings
   ```

3. **Deploy:**
   ```bash
   docker compose -f docker-compose.packaged.yml up -d
   ```

## 🏗️ Building and Publishing

### For Maintainers

Build and push to registries:

```bash
# Set your usernames
export DOCKER_HUB_USER="ssbnk"
export GITHUB_USER="delorenj"

# Build and push
./scripts/build-and-push.sh v1.0.0
```

### GitHub Actions

The repository includes automated builds via GitHub Actions:

1. **Set up secrets** in your GitHub repository:
   - `DOCKERHUB_USERNAME`: Your Docker Hub username
   - `DOCKERHUB_TOKEN`: Your Docker Hub access token

2. **Push to main branch** or create a tag to trigger builds

3. **Images are automatically published** to:
   - Docker Hub: `ssbnk/ssbnk:latest`
   - GHCR: `ghcr.io/delorenj/ssbnk:latest`

## 🔧 Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SSBNK_URL` | `https://screenshots.example.com` | Full URL to your service |
| `SSBNK_RETENTION_DAYS` | `30` | Days to keep files before archiving |
| `DISPLAY` | `:0` | X11 display server |
| `WAYLAND_DISPLAY` | `wayland-0` | Wayland display server |
| `XDG_RUNTIME_DIR` | `/run/user/1000` | Runtime directory |

### Volume Mounts

| Host Path | Container Path | Purpose |
|-----------|----------------|---------|
| `$HOME/screenshots` | `/watch` | Screenshot source directory |
| `ssbnk_data` | `/data` | Persistent data storage |
| `/tmp/.X11-unix` | `/tmp/.X11-unix` | X11 socket (read-write) |
| `/run/user/1000` | `/run/user/1000` | Wayland runtime (read-write) |

## 🌐 Reverse Proxy Setup

### Traefik

The packaged compose file includes Traefik labels:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.ssbnk.entrypoints=websecure"
  - "traefik.http.routers.ssbnk.rule=Host(`${SSBNK_DOMAIN}`)"
  - "traefik.http.routers.ssbnk.tls=true"
  - "traefik.http.routers.ssbnk.tls.certresolver=letsencrypt"
```

### Nginx

Example nginx configuration:

```nginx
server {
    listen 443 ssl http2;
    server_name screenshots.example.com;
    
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    
    location / {
        proxy_pass http://localhost:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Caddy

Example Caddyfile:

```
screenshots.example.com {
    reverse_proxy localhost:80
}
```

## 🔍 Monitoring

### Health Check

The Docker image includes a health check:

```bash
# Check container health
docker ps | grep ssbnk

# View health check logs
docker inspect ssbnk | grep -A 10 Health
```

### Logs

```bash
# View all logs
docker logs -f ssbnk

# View specific service logs
docker exec ssbnk supervisorctl tail -f ssbnk-watcher
docker exec ssbnk supervisorctl tail -f nginx
docker exec ssbnk supervisorctl tail -f cleanup-cron
```

### Service Status

```bash
# Check supervisor status
docker exec ssbnk supervisorctl status

# Restart specific service
docker exec ssbnk supervisorctl restart ssbnk-watcher
```

## 🛠️ Maintenance

### Updates

```bash
# Pull latest image
docker pull ssbnk/ssbnk:latest

# Recreate container
docker stop ssbnk
docker rm ssbnk
# Run with new image (use your original run command)
```

### Backup

```bash
# Backup data volume
docker run --rm -v ssbnk_data:/data -v $(pwd):/backup alpine tar czf /backup/ssbnk-backup.tar.gz /data

# Restore data volume
docker run --rm -v ssbnk_data:/data -v $(pwd):/backup alpine tar xzf /backup/ssbnk-backup.tar.gz -C /
```

### Cleanup

```bash
# Manual cleanup
docker exec ssbnk /usr/local/bin/cleanup.sh

# View cleanup logs
docker exec ssbnk supervisorctl tail cleanup-cron
```

## 🐛 Troubleshooting

### Common Issues

1. **Clipboard not working**: Check display server detection and permissions
2. **Files not detected**: Verify watch directory mount and permissions
3. **Service not accessible**: Check reverse proxy configuration and DNS

### Debug Commands

```bash
# Enter container
docker exec -it ssbnk sh

# Check display server
docker exec ssbnk /usr/local/bin/detect-display-server.sh

# Test clipboard
docker exec ssbnk echo "test" | wl-copy  # Wayland
docker exec ssbnk echo "test" | xclip -selection clipboard  # X11

# Check file permissions
docker exec ssbnk ls -la /watch /data
```

## 📊 Performance

### Resource Usage

Typical resource usage:
- **CPU**: < 1% idle, < 5% during processing
- **Memory**: ~50MB base + nginx overhead
- **Disk**: Depends on screenshot volume and retention

### Scaling

For high-volume deployments:
- Use external storage for `/data` volume
- Consider load balancing multiple instances
- Monitor disk usage and adjust retention policy
- Use CDN for static file serving

## 🔒 Security

### Best Practices

1. **Use HTTPS**: Always serve over HTTPS with valid certificates
2. **Firewall**: Restrict access to necessary ports only
3. **Updates**: Keep Docker image updated
4. **Monitoring**: Monitor for unusual activity
5. **Backup**: Regular backups of data volume

### Network Security

- Container uses `--network host` for clipboard access
- Consider network isolation if clipboard not needed
- Use reverse proxy for SSL termination
- Implement rate limiting at proxy level
