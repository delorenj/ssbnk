# Troubleshooting Guide

Common issues and solutions for ssbnk.

## Clipboard Issues

### Clipboard not working

**Symptoms**: URLs are not copied to clipboard after screenshot processing.

**Solutions**:

1. **Check display server detection**:
   ```bash
   ./scripts/detect-display-server.sh
   ```

2. **Verify clipboard tools are installed**:
   ```bash
   # For X11
   which xclip
   
   # For Wayland
   which wl-copy
   ```

3. **Test clipboard manually**:
   ```bash
   # X11
   echo "test" | xclip -selection clipboard
   
   # Wayland
   echo "test" | wl-copy
   ```

4. **Check container logs**:
   ```bash
   docker compose logs -f ssbnk-watcher
   ```

### Permission denied errors

**Symptoms**: Container cannot access clipboard or display server.

**Solutions**:

1. **Check XDG_RUNTIME_DIR permissions**:
   ```bash
   ls -la $XDG_RUNTIME_DIR
   ```

2. **Verify user ID matches**:
   ```bash
   id -u  # Should match the user running Docker
   ```

3. **Check X11 permissions** (if using X11):
   ```bash
   xhost +local:docker
   ```

## File Detection Issues

### Files not being detected

**Symptoms**: Screenshots saved but not processed by ssbnk.

**Solutions**:

1. **Check watch directory**:
   ```bash
   docker compose exec ssbnk-watcher ls -la /watch
   ```

2. **Verify file permissions**:
   ```bash
   ls -la /path/to/your/screenshot/directory
   ```

3. **Check watcher logs**:
   ```bash
   docker compose logs -f ssbnk-watcher
   ```

4. **Test with a manual file**:
   ```bash
   cp test.png /path/to/your/screenshot/directory/
   ```

### Files processed but not accessible

**Symptoms**: Files are processed but return 404 when accessed via URL.

**Solutions**:

1. **Check hosted directory**:
   ```bash
   docker compose exec ssbnk-watcher ls -la /data/hosted
   ```

2. **Check nginx logs**:
   ```bash
   docker compose logs -f ssbnk-web
   ```

3. **Verify file was not archived**:
   ```bash
   docker compose exec ssbnk-watcher ls -la /data/archive/$(date +%Y-%m-%d)
   ```

## Network Issues

### Cannot access via domain

**Symptoms**: Service not accessible via configured domain.

**Solutions**:

1. **Check Traefik configuration**:
   ```bash
   docker compose logs traefik
   ```

2. **Verify DNS settings**:
   ```bash
   nslookup your-domain.com
   ```

3. **Check SSL certificate**:
   ```bash
   curl -I https://your-domain.com
   ```

4. **Test local access**:
   ```bash
   curl -I http://localhost:80
   ```

## Container Issues

### Container won't start

**Symptoms**: Services fail to start or crash immediately.

**Solutions**:

1. **Check Docker logs**:
   ```bash
   docker compose logs
   ```

2. **Verify environment file**:
   ```bash
   cat .env
   ```

3. **Check disk space**:
   ```bash
   df -h
   ```

4. **Rebuild containers**:
   ```bash
   docker compose down
   docker compose up --build
   ```

### High memory usage

**Symptoms**: Containers consuming excessive memory.

**Solutions**:

1. **Check container stats**:
   ```bash
   docker stats
   ```

2. **Review cleanup logs**:
   ```bash
   docker compose logs ssbnk-cleanup
   ```

3. **Manual cleanup**:
   ```bash
   docker compose exec ssbnk-cleanup /cleanup.sh
   ```

## Archive Issues

### Files archived too early

**Symptoms**: Recent files are moved to archive immediately.

**Solutions**:

1. **Check retention setting**:
   ```bash
   echo $SSBNK_RETENTION_DAYS
   ```

2. **Review cleanup logs**:
   ```bash
   docker compose logs ssbnk-cleanup
   ```

3. **Check file timestamps**:
   ```bash
   docker compose exec ssbnk-watcher stat /data/hosted/filename.png
   ```

## Debug Commands

### General debugging

```bash
# Check all container status
docker compose ps

# View all logs
docker compose logs

# Check volumes
docker volume ls
docker volume inspect ssbnk_data

# Check networks
docker network ls

# Enter container for debugging
docker compose exec ssbnk-watcher sh
```

### File system debugging

```bash
# Check data directory structure
docker compose exec ssbnk-watcher find /data -type f -ls

# Check permissions
docker compose exec ssbnk-watcher ls -la /data/hosted

# Check disk usage
docker compose exec ssbnk-watcher du -sh /data/*
```

### Network debugging

```bash
# Test internal connectivity
docker compose exec ssbnk-watcher wget -O- http://ssbnk-web/

# Check port bindings
docker compose port ssbnk-web 80

# Test external access
curl -I https://your-domain.com/hosted/test.png
```

## Getting Help

If you're still experiencing issues:

1. **Check the logs** with maximum verbosity
2. **Search existing issues** on GitHub
3. **Create a new issue** with:
   - Your environment details (OS, Docker version, display server)
   - Complete error logs
   - Steps to reproduce
   - Expected vs actual behavior

## Common Error Messages

### "Permission denied" when accessing clipboard

This usually indicates the container doesn't have proper access to the display server. Check the display server setup and container permissions.

### "No such file or directory" for clipboard tools

The required clipboard tools (xclip or wl-copy) are not installed in the container. This should be handled automatically, but you may need to rebuild the container.

### "Connection refused" for HTTP clipboard service

The HTTP clipboard fallback service is not running on the host. This is optional and only used as a fallback.

### "Invalid date" in cleanup logs

This indicates an issue with the date command in the Alpine container. The cleanup script should handle this automatically with fallbacks.
