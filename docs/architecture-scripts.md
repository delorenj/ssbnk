# Supporting scripts

The `scripts/` directory now contains only host or remote-client utilities.
Runtime cleanup and URL clipboard synchronization live in the Go binary, so
the deployed image doesn't depend on a copied shell cleanup script or a FIFO
clipboard helper.

## Current scripts

These scripts remain supported:

| Script | Purpose | Runtime location |
| --- | --- | --- |
| `paste-image.sh` | Paste the latest hosted image into the active Wayland window | Desktop host |
| `remote-screenshot-upload.sh` | Watch remote folders and upload new images | Remote Linux or macOS host |
| `install-remote-client.sh` | Install and configure the remote uploader | Remote host |
| `generate-missing-metadata.sh` | Backfill metadata for existing assets | Maintenance use |
| `generate-missing-metadata.go` | Go variant of metadata backfill | Maintenance use |

## Paste-image integration

`paste-image.sh` reads
`/home/delorenj/data/ssbnk/state/last-screenshot` by default and resolves the
filename under `/home/delorenj/data/ssbnk/hosted`. You can override the paths
with `SSBNK_STATE_DIR` and `SSBNK_HOSTED_DIR`.

The script saves the current text clipboard, loads the image with `wl-copy`,
uses `ydotool` to send Ctrl+V, and restores the previous text. It must run in
the user's desktop session. It isn't part of the public container.

## Remote upload integration

`remote-screenshot-upload.sh` monitors configured screenshot directories,
waits for a new file to stabilize, and posts it to `$SSBNK_HOST/upload` with
`X-Upload-Key`. The installer puts configuration in
`~/.config/ssbnk/remote.env` and registers the appropriate user service.

On success, the remote client copies the returned URL to that machine's local
clipboard. The server independently publishes the URL into its state directory
for the server host's isolated clipboard bridge.

## Removed runtime scripts

The single-image design replaces these retired responsibilities:

- `cleanup.sh` is now `ssbnk cleanup [--dry-run]`.
- FIFO and HTTP clipboard scripts are now `ssbnk clipboard-bridge`.
- Root image build and quick-run scripts are replaced by the canonical
  `Dockerfile`, CI, and mise tasks.
- Nginx, supervisor, X11, Syncthing, and old named-volume helpers aren't part
  of the current runtime.
