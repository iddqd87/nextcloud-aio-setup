#!/bin/bash
# Nextcloud AIO + Saltbox Traefik - PRODUCTION READY (All Safety Checks)
# Run as root: sudo ./deploy-nextcloud-aio.sh

set -e

echo "=== 🚀 Nextcloud AIO + Saltbox Traefik SETUP 🚀 ==="
echo ""

# ============================================================================
# INTERACTIVE DOMAIN CONFIGURATION
# ============================================================================
echo "📝 Domain Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Enter your base domain (e.g., meatf.art): " BASE_DOMAIN

if [[ -z "$BASE_DOMAIN" ]]; then
    echo "❌ Base domain required!"
    exit 1
fi

echo ""
echo "Choose domain configuration:"
echo "  1) Subdomain:    nextcloud.${BASE_DOMAIN}"
echo "  2) Root domain:  ${BASE_DOMAIN}"
echo "  3) Custom:       [specify]"
echo ""
read -p "Selection (1-3): " DOMAIN_CHOICE

case $DOMAIN_CHOICE in
    1)
        NEXTCLOUD_DOMAIN="nextcloud.${BASE_DOMAIN}"
        AIO_DOMAIN="aio.${BASE_DOMAIN}"
        ;;
    2)
        NEXTCLOUD_DOMAIN="${BASE_DOMAIN}"
        AIO_DOMAIN="aio.${BASE_DOMAIN}"
        ;;
    3)
        read -p "Enter Nextcloud domain: " NEXTCLOUD_DOMAIN
        read -p "Enter AIO interface domain: " AIO_DOMAIN
        ;;
    *)
        echo "❌ Invalid selection"
        exit 1
        ;;
esac

echo ""
echo "✅ Configuration:"
echo "   Nextcloud: ${NEXTCLOUD_DOMAIN}"
echo "   AIO:       ${AIO_DOMAIN}"
echo ""

# ============================================================================
# SAFETY CHECKS
# ============================================================================
echo "🔒 Running safety checks..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (sudo)" 
   exit 1
fi

# Check for existing installation
if [ -d /srv/nextcloud-aio ] && [ -n "$(docker volume ls -q | grep nextcloud_aio)" ]; then
    echo ""
    echo "⚠️  WARNING: Existing Nextcloud AIO installation detected!"
    echo "   Location: /srv/nextcloud-aio"
    echo "   Volumes:  $(docker volume ls -q | grep nextcloud_aio | wc -l) found"
    echo ""
    echo "⚠️  This will DESTROY all existing data!"
    echo ""
    read -p "Create backup first? (Y/n): " -n 1 -r BACKUP_CHOICE
    echo
    if [[ $BACKUP_CHOICE =~ ^[Yy]$ ]] || [[ -z $BACKUP_CHOICE ]]; then
        BACKUP_DIR="/root/nextcloud-aio-backup-$(date +%Y%m%d-%H%M%S)"
        echo "📦 Creating backup: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
        cp -r /srv/nextcloud-aio "$BACKUP_DIR/" 2>/dev/null || true
        docker volume ls -q | grep nextcloud_aio | xargs -I {} docker run --rm -v {}:/data -v "$BACKUP_DIR":/backup alpine tar czf /backup/{}.tar.gz -C /data . 2>/dev/null || true
        echo "✅ Backup created: $BACKUP_DIR"
    fi
    
    echo ""
    read -p "Continue with clean installation? (yes/NO): " CONFIRM
    if [[ ! "$CONFIRM" == "yes" ]]; then
        echo "❌ Installation cancelled"
        exit 0
    fi
fi

# ============================================================================
# CLEANUP
# ============================================================================
echo ""
echo "🧹 Cleaning previous installation..."
cd /srv 2>/dev/null || true
docker compose down --remove-orphans --volumes 2>/dev/null || true
docker stop $(docker ps -q --filter "name=nextcloud-aio") 2>/dev/null || true
docker rm $(docker ps -a -q --filter "name=nextcloud-aio") 2>/dev/null || true
docker volume rm $(docker volume ls -q | grep nextcloud_aio) 2>/dev/null || true
rm -rf /srv/nextcloud-aio/
echo "✅ Cleanup complete"

# ============================================================================
# ENVIRONMENT VALIDATION
# ============================================================================
echo ""
echo "🔍 Validating environment..."

# Check Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker not found!"
    exit 1
fi

# Check Docker Compose
if ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose not found!"
    exit 1
fi

# Verify Saltbox network
if ! docker network ls | grep -q saltbox; then
    echo "❌ Saltbox network 'saltbox' not found!"
    echo "Available networks:"
    docker network ls | grep -E "(traefik|saltbox)"
    exit 1
fi

# Verify Traefik is running
if ! docker ps | grep -q traefik; then
    echo "⚠️  WARNING: Traefik container not found!"
    echo "Available containers:"
    docker ps --format "{{.Names}}"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check if Traefik is in saltbox network
if ! docker network inspect saltbox | grep -q traefik 2>/dev/null; then
    echo "⚠️  WARNING: Traefik not detected in saltbox network!"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

echo "✅ Environment validated"

# ============================================================================
# PUBLIC IP DETECTION
# ============================================================================
echo ""
echo "🌐 Detecting public IP..."
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || curl -s --max-time 5 ipinfo.io/ip 2>/dev/null)

# Validate IP format
if [[ ! "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "⚠️  Could not auto-detect valid public IP"
    read -p "Enter your public IP manually: " SERVER_IP
    if [[ ! "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "❌ Invalid IP format!"
        exit 1
    fi
fi

echo "✅ Public IP: $SERVER_IP"

# ============================================================================
# PORT AVAILABILITY CHECK
# ============================================================================
echo ""
echo "🔍 Checking port availability..."
if ss -tulpn | grep -q ":8080 "; then
    echo "⚠️  WARNING: Port 8080 already in use!"
    ss -tulpn | grep ":8080 "
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi
echo "✅ Port 8080 available"

# ============================================================================
# SETUP
# ============================================================================
echo ""
echo "📁 Creating /srv/nextcloud-aio..."
mkdir -p /srv/nextcloud-aio
cd /srv/nextcloud-aio

echo "📄 Generating docker-compose.yml..."
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
      - 8080:8080    # AIO Interface
      # - 11000:11000  # COMMENTED: Domaincheck needs exclusive access
    networks:
      - saltbox
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=saltbox"
      
      # HTTP → HTTPS redirect (Nextcloud)
      - "traefik.http.routers.nextcloud-http.rule=Host(\`${NEXTCLOUD_DOMAIN}\`)"
      - "traefik.http.routers.nextcloud-http.entrypoints=web"
      - "traefik.http.routers.nextcloud-http.middlewares=redirect-to-https@docker"
      
      # HTTPS Nextcloud
      - "traefik.http.routers.nextcloud-https.rule=Host(\`${NEXTCLOUD_DOMAIN}\`)"
      - "traefik.http.routers.nextcloud-https.entrypoints=websecure"
      - "traefik.http.routers.nextcloud-https.tls.certresolver=cfdns"
      - "traefik.http.services.nextcloud.loadbalancer.server.port=11000"
      - "traefik.http.services.nextcloud.loadbalancer.server.scheme=http"
      
      # HTTP → HTTPS redirect (AIO)
      - "traefik.http.routers.aio-http.rule=Host(\`${AIO_DOMAIN}\`)"
      - "traefik.http.routers.aio-http.entrypoints=web"
      - "traefik.http.routers.aio-http.middlewares=redirect-to-https@docker"
      
      # HTTPS AIO Interface
      - "traefik.http.routers.aio-https.rule=Host(\`${AIO_DOMAIN}\`)"
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

echo "✅ Configuration complete"

# ============================================================================
# SECURITY WARNING
# ============================================================================
echo ""
echo "⚠️  SECURITY NOTICE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "This container has access to Docker daemon via socket mount."
echo "Only run on trusted infrastructure!"
echo ""
read -p "Acknowledge and continue? (yes/NO): " SECURITY_ACK
if [[ ! "$SECURITY_ACK" == "yes" ]]; then
    echo "❌ Deployment cancelled"
    exit 0
fi

# ============================================================================
# DEPLOYMENT
# ============================================================================
echo ""
echo "🚀 Deploying Nextcloud AIO..."
docker compose pull
docker compose up -d

echo "⏳ Waiting for container startup (10s)..."
sleep 10

# ============================================================================
# POST-DEPLOYMENT VALIDATION
# ============================================================================
echo ""
echo "📊 Deployment Status:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker compose ps

# Check if container is healthy
if ! docker ps | grep -q "nextcloud-aio-mastercontainer.*healthy"; then
    echo ""
    echo "⚠️  WARNING: Container not healthy yet. Check logs:"
    echo "   docker compose logs -f"
fi

# ============================================================================
# SUCCESS OUTPUT
# ============================================================================
echo ""
echo "✅ DEPLOYMENT COMPLETE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🌐 ACCESS POINTS:"
echo "   Direct IP:        http://${SERVER_IP}:8080"
echo "   AIO Interface:    https://${AIO_DOMAIN}"
echo "   Nextcloud:        https://${NEXTCLOUD_DOMAIN}"
echo ""
echo "📋 NEXT STEPS:"
echo "   1. Visit http://${SERVER_IP}:8080 (use IP, not domain)"
echo "   2. Copy the initial password shown"
echo "   3. Click 'Start Containers' (domaincheck will succeed)"
echo "   4. Configure domain: ${NEXTCLOUD_DOMAIN}"
echo ""
echo "🌐 DNS REQUIREMENTS:"
echo "   ${NEXTCLOUD_DOMAIN} → ${SERVER_IP} (A record)"
echo "   ${AIO_DOMAIN} → ${NEXTCLOUD_DOMAIN} (CNAME)"
echo ""
echo "📊 MANAGEMENT:"
echo "   Logs:     docker compose logs -f"
echo "   Restart:  docker compose restart"
echo "   Stop:     docker compose down"
echo "   Status:   docker compose ps"
echo ""
echo "💾 FILES:"
echo "   Config:   /srv/nextcloud-aio/docker-compose.yml"
echo "   Volume:   nextcloud_aio_mastercontainer"
echo ""
echo "✅ Installation complete!"
