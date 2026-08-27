# Deployment guide

Production deployment is intentionally separate from application development.
The source repository publishes one tested image. The DeLoContainers hub pins
that image by digest and defines how it runs on this host.

## Ownership boundary

Use these repositories for distinct changes:

| Repository | Owns |
| --- | --- |
| `/home/delorenj/code/ssbnk` | Go and UI source, tests, `Dockerfile`, `compose.dev.yml`, mise tasks, and image CI |
| `/home/delorenj/docker/stacks/utils/ssbnk` | Production digest, Compose services, mounts, secret references, Traefik routing, and systemd units |

Don't copy application source or a cleanup script into the deployment hub.
Don't put production host paths, live image promotion, or service scheduling in
the source repository.

## Canonical image

The root source `Dockerfile` publishes one image at
`docker.io/delorenj/ssbnk`. It contains:

- `/usr/local/bin/ssbnk`, with `serve`, `cleanup`, and `clipboard-bridge`;
- the Astro static build at `/ui`;
- `ffmpeg` for screencast conversion; and
- `wl-copy` for the isolated clipboard role.

CI publishes `sha-<commit>`, semantic-version, and default-branch tags to
Docker Hub and GitHub Container Registry. Production Compose uses a tag plus
its `sha256` digest so a registry tag change cannot alter a running deployment.

## Production services

The production Compose file reuses the pinned image in three roles:

| Service | Command | Network | Sensitive mounts |
| --- | --- | --- | --- |
| `ssbnk` | `serve` | External `proxy` | Media input and `/data`; no display socket |
| `clipboard` | `clipboard-bridge` | `none` | Read-only `/data/state` and the exact Wayland socket |
| `cleanup` | `cleanup` | `none` | Read-write `/data`; maintenance profile only |

All roles run as UID and GID 1000 with a read-only root filesystem, dropped
capabilities, and `no-new-privileges`. The public service receives a small
writable `/tmp` mount for media conversion. Only that service joins the
Traefik network, and it exposes no host port.

The screenshot and screencast source mounts are intentionally read-write.
Successful ingestion removes the original after storing the hosted copy, so a
read-only source mount would silently change the service into an accumulating
copy-only workflow.

The cleanup role receives the production `SSBNK_URL` and explicit
`SSBNK_STATE_DIR=/data/state`. These values let it repair a latest marker even
when the chosen remaining asset doesn't have metadata.

The clipboard service mounts one path:

```text
${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}
```

It doesn't mount the full runtime directory or `/tmp/.X11-unix`, and it has no
network. The public service can't access the desktop session.

## Secrets and routing

The deployment hub keeps `SSBNK_UPLOAD_KEY` as an `op://` reference in
`.env.op`. The system service launches the public Compose operation through
`op run`, so the credential exists only in that runtime environment. The
cleanup and clipboard units don't receive the upload key.

Traefik routes `https://ss.delo.sh` to port 80 of the public service on the
external `proxy` network. The application serves the UI, API, and hosted assets
directly. There is no Nginx or frontend proxy inside the stack.

## systemd operation

Versioned units under `/home/delorenj/docker/systemd` and
`/home/delorenj/docker/systemd/user` control three lifecycles:

- `docker-stack-ssbnk.service` validates the production environment, pulls the
  pinned image, and starts the public service.
- The cleanup timer invokes a one-shot service that runs the maintenance
  profile with `ssbnk cleanup`.
- The `ssbnk-clipboard.service` user unit follows the graphical session and
  starts only the network-disabled desktop profile.

The timer runs daily at 02:00 local time and uses `Persistent=true`, so a missed
run occurs after the host returns. Scheduling stays outside the image; the
cleanup container exits after one execution.

## Promotion procedure

Promote a release only after the source checks and image build succeed:

1. Land the source commit on `main` and wait for the canonical image workflow.
2. Record the published `sha-<commit>` tag and `sha256` digest.
3. Replace the image reference in the deployment hub's `compose.yml` with that
   exact tag and digest.
4. Validate the rendered configuration without printing secret values.
5. Commit and push the deployment change.
6. Restart the stack systemd service, then restart the graphical-session
   clipboard user service so both roles use the promoted image.
7. Inspect Compose health and logs.
8. Verify the public UI, `/health`, an uploaded test image, state publication,
   and clipboard delivery.
9. Run cleanup in `--dry-run` mode before relying on the scheduled mutation.

The deployment commit and prior digest provide rollback. Revert the deployment
commit, restart the stack service, and verify health to restore the previous
image.

## Remote upload clients

Remote machines run `scripts/remote-screenshot-upload.sh`, installed by
`scripts/install-remote-client.sh`. Each client stores its local endpoint and
secret configuration outside the repository, watches configured screenshot
directories, and posts to `https://ss.delo.sh/upload`.

The remote uploader keeps the source file and copies the returned URL to the
remote machine's clipboard. It doesn't need access to production Compose or
the server host's Wayland session.

## Historical routing evidence

The [latest endpoint investigation](./latest-endpoint-investigation-report.md)
documents a November 2025 incident and an older layout. Keep it as evidence,
but don't use its Nginx or multi-container details as the current runbook.
