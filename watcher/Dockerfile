FROM golang:1.21-alpine AS go-builder

WORKDIR /app
COPY watcher/go.mod watcher/go.sum ./
RUN go mod download
COPY watcher/*.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o watcher .

FROM node:22-alpine AS ui-builder

WORKDIR /ui
COPY ui/package.json ui/package-lock.json ./
RUN npm ci
COPY ui/ .
RUN npm run build

FROM alpine:latest
RUN apk --no-cache add ca-certificates xclip wl-clipboard ffmpeg xdg-utils alsa-utils pulseaudio-utils
RUN adduser -D -u 1000 ssbnk
WORKDIR /home/ssbnk

COPY --from=go-builder /app/watcher .
COPY --from=ui-builder /ui/dist /ui

USER ssbnk

EXPOSE 80

CMD ["./watcher"]
