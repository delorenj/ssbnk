# Display Server Support

Bloodbank supports both X11 and Wayland display servers for clipboard functionality.

## Automatic Detection

The watcher service automatically detects your display server and uses the appropriate clipboard tool:

- **X11**: Uses `xclip` for clipboard access
- **Wayland**: Uses `wl-copy` from `wl-clipboard` package

## X11 Setup

X11 support works out of the box on most systems. The container needs:

- `DISPLAY` environment variable
- `/tmp/.X11-unix` socket mounted

```bash
# Usually automatically set
export DISPLAY=:0
```

## Wayland Setup

For Wayland, you need to set additional environment variables:

```bash
export WAYLAND_DISPLAY=wayland-0  # Usually wayland-0
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export XDG_SESSION_TYPE=wayland
```

### Required Packages

Make sure you have the clipboard tools installed on your host system:

**Ubuntu/Debian:**
```bash
sudo apt install wl-clipboard xclip
```

**Arch Linux:**
```bash
sudo pacman -S wl-clipboard xclip
```

**Fedora:**
```bash
sudo dnf install wl-clipboard xclip
```

## Detection Script

Run the detection script to check your setup:

```bash
./scripts/detect-display-server.sh
```

This will:
- Detect your current display server
- Check if required tools are installed
- Show environment variables needed
- Provide setup instructions

## Troubleshooting

### Clipboard Not Working

1. **Check display server detection:**
   ```bash
   docker compose logs bloodbank-watcher
   ```
   Look for lines like:
   - `Display server: Wayland (WAYLAND_DISPLAY=wayland-0, XDG_SESSION_TYPE=wayland)`
   - `Display server: X11 (DISPLAY=:0)`

2. **Verify tools are available in container:**
   ```bash
   docker compose exec bloodbank-watcher which wl-copy
   docker compose exec bloodbank-watcher which xclip
   ```

3. **Test clipboard manually:**
   ```bash
   # For Wayland
   echo "test" | wl-copy
   wl-paste
   
   # For X11
   echo "test" | xclip -selection clipboard
   xclip -selection clipboard -o
   ```

### Environment Variables

If automatic detection fails, you can force the environment in your `.env` file:

```bash
# For Wayland
WAYLAND_DISPLAY=wayland-0
XDG_RUNTIME_DIR=/run/user/1000
XDG_SESSION_TYPE=wayland

# For X11
DISPLAY=:0
```

### Permission Issues

The container runs with host networking to access clipboard services. If you encounter permission issues:

1. Check that your user can access the clipboard tools
2. Verify the XDG_RUNTIME_DIR permissions (should be owned by your user)
3. For Wayland, ensure the compositor socket is accessible

## Technical Details

The detection logic in order of precedence:

1. `WAYLAND_DISPLAY` environment variable is set → Use Wayland
2. `XDG_SESSION_TYPE=wayland` → Use Wayland  
3. `wl-copy --version` succeeds → Use Wayland
4. Fallback to X11 with `xclip`

The container includes both clipboard tools, so switching between display servers doesn't require rebuilding the image.
