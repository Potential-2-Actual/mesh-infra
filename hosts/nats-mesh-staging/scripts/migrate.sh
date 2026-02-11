#!/bin/bash
# Migration script: systemd services → Docker Compose
# Run on nats-mesh-staging VM
set -euo pipefail

echo "=== Pre-migration checks ==="

# Verify Docker is installed
if ! command -v docker &>/dev/null; then
  echo "❌ Docker not installed. Run: curl -fsSL https://get.docker.com | sh"
  exit 1
fi

if ! command -v docker compose &>/dev/null; then
  echo "❌ Docker Compose not available. Ensure Docker >= 23.0"
  exit 1
fi

echo "✅ Docker and Compose available"

# Verify .env exists
if [ ! -f .env ]; then
  echo "❌ .env not found. Copy .env.example and fill in secrets."
  exit 1
fi
echo "✅ .env found"

echo ""
echo "=== Step 1: Back up JetStream data ==="
BACKUP_DIR="/tmp/nats-backup-$(date +%Y%m%d-%H%M%S)"
sudo cp -r /data/nats "$BACKUP_DIR"
echo "✅ JetStream data backed up to $BACKUP_DIR"

echo ""
echo "=== Step 2: Copy JetStream data to Docker volume ==="
# Create the volume and copy data
docker volume create nats-mesh-staging_nats-data || true
docker run --rm -v nats-mesh-staging_nats-data:/data/nats -v /data/nats:/source alpine sh -c "cp -a /source/. /data/nats/"
echo "✅ JetStream data copied to Docker volume"

echo ""
echo "=== Step 3: Build and start containers (parallel mode) ==="
echo "Starting containers on alternate ports to verify before cutover..."
docker compose up -d --build
echo "✅ Containers started"

echo ""
echo "=== Step 4: Health checks ==="
echo "Waiting for services to be healthy..."
sleep 10

for svc in nats dashboard caddy; do
  status=$(docker compose ps --format json "$svc" 2>/dev/null | jq -r '.Health // .State' 2>/dev/null || echo "unknown")
  echo "  $svc: $status"
done

echo ""
echo "=== Step 5: Verify NATS data ==="
echo "Check JetStream streams and KV buckets are intact."
echo "Run: docker exec nats nats stream ls --server nats://localhost:4222"
echo ""
echo "=== Manual cutover steps ==="
echo "Once verified:"
echo "  1. sudo systemctl stop nats-server"
echo "  2. sudo systemctl stop mesh-dashboard"
echo "  3. sudo systemctl stop caddy"
echo "  4. sudo systemctl disable nats-server mesh-dashboard caddy"
echo "  5. Verify containers are handling traffic"
echo ""
echo "Rollback: docker compose down && sudo systemctl start nats-server mesh-dashboard caddy"
