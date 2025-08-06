FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o watcher .

FROM alpine:latest
RUN apk --no-cache add ca-certificates xclip wl-clipboard ffmpeg xdg-utils alsa-utils pulseaudio-utils
WORKDIR /root/

COPY --from=builder /app/watcher .

CMD ["./watcher"]
