# syntax=docker/dockerfile:1.7

FROM golang:1.26.7-alpine3.23 AS go-builder

WORKDIR /src/watcher
COPY watcher/go.mod watcher/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY watcher/*.go ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags='-s -w' \
      -o /out/ssbnk .

FROM node:22-alpine3.23 AS ui-builder

WORKDIR /src/ui
COPY ui/package.json ui/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci
COPY ui/ ./
RUN npm run build

FROM alpine:3.23

ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown

RUN apk upgrade --no-cache \
    && apk add --no-cache \
      ca-certificates \
      ffmpeg \
      tzdata \
      wl-clipboard \
    && addgroup -g 1000 -S ssbnk \
    && adduser -u 1000 -S -D -H -G ssbnk ssbnk \
    && mkdir -p \
      /data/archive \
      /data/hosted \
      /data/metadata \
      /data/state \
      /media/screencasts \
      /media/screenshots \
      /run/user/1000 \
    && chown -R ssbnk:ssbnk /data /media /run/user/1000

COPY --from=go-builder /out/ssbnk /usr/local/bin/ssbnk
COPY --from=ui-builder /src/ui/dist /ui

ENV HOME=/tmp \
    TMPDIR=/tmp \
    SSBNK_API_PORT=80 \
    SSBNK_DATA_DIR=/data \
    SSBNK_SCREENCAST_DIR=/media/screencasts \
    SSBNK_SCREENSHOT_DIR=/media/screenshots \
    SSBNK_STATE_DIR=/data/state \
    SSBNK_UI_DIR=/ui

LABEL org.opencontainers.image.title="ssbnk" \
      org.opencontainers.image.description="Self-hosted screenshot ingestion, gallery, and retention service" \
      org.opencontainers.image.source="https://github.com/delorenj/ssbnk" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"

USER 1000:1000
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -T 3 -O /dev/null http://127.0.0.1/health || exit 1

ENTRYPOINT ["/usr/local/bin/ssbnk"]
CMD ["serve"]
