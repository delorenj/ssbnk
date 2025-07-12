#!/bin/bash

# Build and Push Script for ssbnk Docker Images
# Builds and pushes to both Docker Hub and GitHub Container Registry

set -e

# Configuration
IMAGE_NAME="ssbnk"
VERSION=${1:-"latest"}
DOCKER_HUB_USER=${DOCKER_HUB_USER:-"ssbnk"}
GITHUB_USER=${GITHUB_USER:-"delorenj"}

echo "🐳 Building and pushing ssbnk Docker images"
echo "📦 Version: $VERSION"
echo "🏷️  Docker Hub: $DOCKER_HUB_USER/$IMAGE_NAME:$VERSION"
echo "🏷️  GHCR: ghcr.io/$GITHUB_USER/$IMAGE_NAME:$VERSION"
echo ""

# Build the image
echo "🔨 Building Docker image..."
docker build -t $IMAGE_NAME:$VERSION .

# Tag for Docker Hub
echo "🏷️  Tagging for Docker Hub..."
docker tag $IMAGE_NAME:$VERSION $DOCKER_HUB_USER/$IMAGE_NAME:$VERSION
docker tag $IMAGE_NAME:$VERSION $DOCKER_HUB_USER/$IMAGE_NAME:latest

# Tag for GitHub Container Registry
echo "🏷️  Tagging for GHCR..."
docker tag $IMAGE_NAME:$VERSION ghcr.io/$GITHUB_USER/$IMAGE_NAME:$VERSION
docker tag $IMAGE_NAME:$VERSION ghcr.io/$GITHUB_USER/$IMAGE_NAME:latest

# Push to Docker Hub
echo "📤 Pushing to Docker Hub..."
docker push $DOCKER_HUB_USER/$IMAGE_NAME:$VERSION
docker push $DOCKER_HUB_USER/$IMAGE_NAME:latest

# Push to GitHub Container Registry
echo "📤 Pushing to GHCR..."
docker push ghcr.io/$GITHUB_USER/$IMAGE_NAME:$VERSION
docker push ghcr.io/$GITHUB_USER/$IMAGE_NAME:latest

echo ""
echo "✅ Build and push completed successfully!"
echo ""
echo "🚀 Users can now run:"
echo "   docker run -d \\"
echo "     --name ssbnk \\"
echo "     --network host \\"
echo "     --privileged \\"
echo "     -v /home/\$USER/screenshots:/watch \\"
echo "     -v /tmp/.X11-unix:/tmp/.X11-unix:rw \\"
echo "     -v /run/user/1000:/run/user/1000:rw \\"
echo "     -e SSBNK_URL=https://screenshots.example.com \\"
echo "     -e DISPLAY=\$DISPLAY \\"
echo "     -e WAYLAND_DISPLAY=\$WAYLAND_DISPLAY \\"
echo "     -e XDG_RUNTIME_DIR=/run/user/1000 \\"
echo "     $DOCKER_HUB_USER/$IMAGE_NAME:latest"
echo ""
echo "Or with Docker Compose:"
echo "   curl -O https://raw.githubusercontent.com/$GITHUB_USER/ssbnk/main/docker-compose.packaged.yml"
echo "   cp .env.example .env  # Edit with your settings"
echo "   docker compose -f docker-compose.packaged.yml up -d"
