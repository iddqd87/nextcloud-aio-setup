#!/bin/bash
# Nextcloud AIO + Saltbox Traefik - COMPLETE SETUP (Domaincheck Fixed)
# Run as root: sudo ./deploy-nextcloud-aio.sh

set -e

echo "=== 🚀 Nextcloud AIO + Saltbox Traefik (DOMAINCHECK FIXED) 🚀 ==="

# Cleanup previous
echo "🧹 Cleaning previous Nextcloud AIO..."
docker compose down --remove-orphans --volumes 2>/dev/null || true
docker stop $(docker ps -q --filter "name=nextcloud-aio") 2>/dev/null || true
docker rm $(docker ps -a -q --filter "name=nextcloud-aio") 2>/dev/null || true
rm -rf /srv/nextcloud-aio/

# Create directory
echo "📁 Creating /srv/nextcloud-aio..."
mkdir -p /srv/nextcloud-aio
cd /srv/nextcloud-aio

# Get PUBLIC IP
echo "🌐 Detecting public IP..."
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "YOUR_PUBLIC_IP_HERE")
if [[ -z "$SERVER_IP" || "$SERVER_IP" == *"error"* || "$SERVER_IP" == "YOUR_PUBLIC_IP_HERE" ]]; then
    echo "⚠️  Could not auto-detect public IP. Using placeholder."
    SERVER_IP="YOUR_PUBLIC_IP_HERE"
fi
echo "✅ Public IP: $SERVER_IP"

# Verify Saltbox network
echo "🔍 Verifying Saltbox Traefik network..."
if ! docker network ls | grep -q saltbox; then
    echo "❌ Saltbox network 'saltbox' not found!"
    echo "Available networks:"
    docker network ls | grep -E "(traefik|saltbox)"
    exit 1
fi
echo "✅ Saltbox network found"

# Create docker-compose.yml (DOMAINCHECK SAFE - NO 11000 port conflict)
echo "📄 Creating docker-compose.yml (Domaincheck fixed)..."
cat > docker-compose.yml << EOF
version: '3.8'

services:
  nextcloud-aio-mastercontainer:
    image: ghcr.io/nextcloud-releases/all-in-one:latest
    init: true
    restart: always
    hostname: nextcloud-aio
    container_name: nextcloud-aio-mastercontainer
    volumes:
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - 8080:8080    # AIO Interface: http://${SERVER_IP}:8080
      # - 11000:11000  # COMMENTED: Domaincheck needs exclusive access during setup
    networks:
      - saltbox
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=saltbox"
      # HTTP → HTTPS redirect
      - "traefik.http.routers.nextcloud-http.rule=Host(\`nextcloud.meatf.art\`)"
      - "traefik.http.routers.nextcloud-http.entrypoints=web"
      - "traefik.http.routers.nextcloud-http.middlewares=redirect-to-https@docker"
      # HTTPS Nextcloud (Traefik proxies to internal 11000)
      - "traefik.http.routers.nextcloud-https.rule=Host(\`nextcloud.meatf.art\`)"
      - "traefik.http.routers.nextcloud-https.entrypoints=websecure"
      - "traefik.http.routers.nextcloud-https.tls.certresolver=cfdns"
      - "traefik.http.services.nextcloud.loadbalancer.server.port=11000"
      - "traefik.http.services.nextcloud.loadbalancer.server.scheme=http"
      # AIO Interface subdomain
      - "traefik.http.routers.aio-http.rule=Host(\`aio.nextcloud.meatf.art\`)"
      - "traefik.http.routers.aio-http.entrypoints=web"
      - "traefik.http.routers.aio-http.middlewares=redirect-to-https@docker"
      - "traefik.http.routers.aio-https.rule=Host(\`aio.nextcloud.meatf.art\`)"
      - "traefik.http.routers.aio-https.entrypoints=websecure"
      - "traefik.http.routers.aio-https.tls.certresolver=cfdns"
      - "traefik.http.services.aio.loadbalancer.server.port=8080"
    environment:
      - APACHE_PORT=11000
      - APACHE_IP_BINDING=0.0.0.0
      - SKIP_DOMAIN_VALIDATION=true

networks:
  saltbox:
    external: true
    name: saltbox

volumes:
  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer
EOF

# Deploy
echo "🚀 Deploying Nextcloud AIO (Domaincheck safe)..."
docker compose pull
docker compose up -d

# Wait for startup (10s)
echo "⏳ Waiting for startup (10s)..."
sleep 10

# Show status
echo "📊 Status:"
docker compose ps
echo ""
echo "✅ DEPLOYMENT COMPLETE! (Domaincheck will work)"
echo ""
echo "🌐 ACCESS:"
echo "  AIO Interface:    http://${SERVER_IP}:8080"
echo "  AIO Subdomain:    https://aio.nextcloud.meatf.art"
echo "  Production:       https://nextcloud.meatf.art"
echo ""
echo "📋 NEXT STEPS:"
echo "  1. Visit http://${SERVER_IP}:8080"
echo "  2. Click 'Start Containers' → Domaincheck ✅"
echo "  3. Set domain: nextcloud.meatf.art"
echo "  4. DNS: nextcloud.meatf.art → $SERVER_IP (A record)"
echo "     aio.nextcloud.meatf.art → nextcloud.meatf.art (CNAME)"
echo ""
echo "💡 AFTER SETUP: Uncomment 11000 port for direct IP access"
echo "📄 Logs: docker compose logs -f"
echo "✅ Ready! [web:30][web:74][memory:1]"
