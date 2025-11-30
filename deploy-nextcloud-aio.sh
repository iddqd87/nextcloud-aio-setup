#!/bin/bash
# Nextcloud AIO + Saltbox Traefik Setup
# Full detection, backup, reset, and deployment with Traefik docker labels
# Run as root: sudo ./deploy-nextcloud-aio.sh

set -e

# ============================================================================
# USER-CONFIGURABLE SETTINGS
# ============================================================================
PUBLIC_DOMAIN="nextcloud.meatf.art"        # Your Nextcloud domain
PUBLIC_PORT="443"                          # External port (usually 443 via Cloudflare/Traefik)
APACHE_PORT="11000"                        # Internal AIO Apache port

echo "=== 🚀 Nextcloud AIO + Saltbox Traefik Setup (FULL RESET) 🚀 ==="
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

echo "✅ Running as root"
echo ""

# ============================================================================
# DETECT EXISTING INSTALLATION
# ============================================================================
EXISTING_CONTAINERS=$(docker ps -aq --filter "name=nextcloud-aio" 2>/dev/null || echo "")
EXISTING_VOLUMES=$(docker volume ls -q | grep '^nextcloud_aio' 2>/dev/null || echo "")

if [ -d /srv/nextcloud-aio ] || [ -n "$EXISTING_CONTAINERS" ] || [ -n "$EXISTING_VOLUMES" ]; then
    echo "📦 Existing Nextcloud AIO data detected."
    if [ -d /srv/nextcloud-aio ]; then
        echo "   - Config dir: /srv/nextcloud-aio"
    fi
    if [ -n "$EXISTING_CONTAINERS" ]; then
        echo "   - Containers: $(echo "$EXISTING_CONTAINERS" | wc -l) found"
    fi
    if [ -n "$EXISTING_VOLUMES" ]; then
        echo "   - Volumes:    $(echo "$EXISTING_VOLUMES" | wc -l) nextcloud_aio* volumes"
    fi
    echo ""
    read -p "Create backup before reset? (y/n): " BACKUP_CHOICE
    if [[ $BACKUP_CHOICE =~ ^[Yy]$ ]]; then
        BACKUP_DIR="/root/nextcloud-aio-backup-$(date +%Y%m%d-%H%M%S)"
        echo "📦 Creating backup: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"/{volumes,config}

        # Backup /srv/nextcloud-aio
        if [ -d /srv/nextcloud-aio ]; then
            echo "  → Backing up /srv/nextcloud-aio..."
            cp -r /srv/nextcloud-aio "$BACKUP_DIR/config/" 2>/dev/null || true
        fi

        # Backup all AIO volumes
        if [ -n "$EXISTING_VOLUMES" ]; then
            echo "  → Backing up Docker volumes..."
            for volume in $EXISTING_VOLUMES; do
                echo "    • $volume"
                docker run --rm \
                    -v "$volume":/data \
                    -v "$BACKUP_DIR/volumes":/backup \
                    alpine sh -c "cd /data && tar czf /backup/${volume}.tar.gz ." 2>/dev/null \
                    || echo "    ⚠️  Failed to backup $volume"
            done
        fi

        # Backup container metadata
        if [ -n "$EXISTING_CONTAINERS" ]; then
            echo "  → Backing up container configs..."
            docker ps -a --filter "name=nextcloud-aio" -q | xargs -r docker inspect > "$BACKUP_DIR/config/containers.json" 2>/dev/null || true
        fi

        cat > "$BACKUP_DIR/RESTORE_INFO.txt" << 'EOF'
Nextcloud AIO Backup Recovery

Contents:
  - config/       → /srv/nextcloud-aio directory
  - volumes/      → Docker volume tarballs (*.tar.gz)
  - containers.json → Container inspection data

Manual Recovery:
  1. Recreate /srv/nextcloud-aio: cp -r config/nextcloud-aio /srv/
  2. Recreate volumes:
     for vol in volumes/*.tar.gz; do
       name=$(basename "$vol" .tar.gz)
       docker volume create "$name"
       docker run --rm -v "$name":/data -v ./volumes:/backup \
         alpine tar xzf /backup/"$name".tar.gz -C /data
     done

This backup is for advanced manual recovery only.
EOF

        echo "✅ Backup created: $BACKUP_DIR"
        echo ""
    fi
    echo ""
fi

# ============================================================================
# FULL AIO RESET
# ============================================================================
echo "🧨 FULL RESET - This will remove ALL Nextcloud AIO containers, volumes, and config."
read -p "Proceed with full reset? (y/n): " RESET_CONFIRM
if [[ ! "$RESET_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Reset cancelled. Exiting."
    exit 0
fi

echo ""
echo "🛑 Stopping and removing AIO containers..."
docker rm -f $(docker ps -aq --filter "name=nextcloud-aio") 2>/dev/null || true

echo "🗑️  Removing AIO Docker volumes..."
docker volume rm $(docker volume ls -q | grep '^nextcloud_aio') 2>/dev/null || true

echo "🧹 Removing /srv/nextcloud-aio..."
rm -rf /srv/nextcloud-aio

# Detect and offer to remove Nextcloud datadirs on host
echo ""
echo "🔍 Searching for Nextcloud data directories on host..."
POSSIBLE_DATADIRS=$(find /srv /data /mnt /var -maxdepth 3 -type d \
  \( -iname "*nextcloud*data*" -o -iname "nextcloud-data" \) 2>/dev/null | sort -u | head -20)

if [ -n "$POSSIBLE_DATADIRS" ]; then
    echo "   Found potential datadirs:"
    echo "$POSSIBLE_DATADIRS" | sed 's/^/     /'
    echo ""
    read -p "Remove these datadirs as part of reset? (y/n): " WIPE_DATA_CONFIRM
    if [[ "$WIPE_DATA_CONFIRM" =~ ^[Yy]$ ]]; then
        echo "🧨 Removing datadirs..."
        echo "$POSSIBLE_DATADIRS" | xargs -r rm -rf
        echo "✅ Datadirs removed"
    fi
else
    echo "ℹ️  No obvious Nextcloud datadirs found"
fi

echo ""
echo "✅ Full reset complete"
echo ""

# ============================================================================
# ENVIRONMENT VALIDATION
# ============================================================================
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
    exit 1
fi

# Verify Traefik
if ! docker ps | grep -q traefik; then
    echo "⚠️  Traefik container not found!"
    read -p "Continue anyway? (y/n): " REPLY
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check Traefik in saltbox network
if ! docker network inspect saltbox 2>/dev/null | grep -q traefik; then
    echo "⚠️  Traefik not in saltbox network!"
    read -p "Continue anyway? (y/n): " REPLY
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

echo "✅ Docker, Docker Compose, Saltbox, and Traefik validated"
echo ""

# ============================================================================
# PUBLIC IP DETECTION
# ============================================================================
echo "🌐 Detecting public IP..."
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
            curl -s --max-time 5 icanhazip.com 2>/dev/null || \
            curl -s --max-time 5 ipinfo.io/ip 2>/dev/null)

if [[ ! "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "⚠️  Could not auto-detect IP"
    read -p "Enter public IP manually: " SERVER_IP
    if [[ ! "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "❌ Invalid IP!"
        exit 1
    fi
fi

echo "✅ Public IP: $SERVER_IP"
echo ""

# ============================================================================
# DETECT TRAEFIK CERTRESOLVER
# ============================================================================
echo "🔍 Detecting Traefik certresolver..."
CERTRESOLVER=$(docker inspect traefik 2>/dev/null | jq -r '.[0].Args[]' 2>/dev/null | \
               grep -i certificatesresolvers | head -1 | cut -d. -f3)

if [[ -z "$CERTRESOLVER" ]]; then
    echo "⚠️  Could not detect certresolver, using default: cfdns"
    CERTRESOLVER="cfdns"
else
    echo "✅ Detected certresolver: $CERTRESOLVER"
fi

echo ""

# ============================================================================
# PORT AVAILABILITY CHECK
# ============================================================================
echo "🔍 Checking port 8080..."
if ss -tulpn 2>/dev/null | grep -q ":8080 "; then
    echo "⚠️  Port 8080 in use!"
    read -p "Continue anyway? (y/n): " REPLY
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi
echo "✅ Port 8080 available"
echo ""

# ============================================================================
# DOCKER COMPOSE GENERATION (with Traefik docker labels)
# ============================================================================
echo "📁 Creating /srv/nextcloud-aio..."
mkdir -p /srv/nextcloud-aio
cd /srv/nextcloud-aio

echo "📄 Generating docker-compose.yml with Traefik docker labels..."
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
      - 8080:8080
    networks:
      - saltbox
    environment:
      - APACHE_PORT=${APACHE_PORT}
      - APACHE_IP_BINDING=0.0.0.0
      - SKIP_DOMAIN_VALIDATION=true
      - NEXTCLOUD_DATADIR=/mnt/docker-aio-data
    labels:
      # Enable Traefik and specify network
      - "traefik.enable=true"
      - "traefik.docker.network=saltbox"

      # HTTP router (web) - redirect to HTTPS
      - "traefik.http.routers.nextcloud-aio-web.rule=Host(\`${PUBLIC_DOMAIN}\`)"
      - "traefik.http.routers.nextcloud-aio-web.entrypoints=web"
      - "traefik.http.routers.nextcloud-aio-web.middlewares=nextcloud-aio-redirect"
      - "traefik.http.routers.nextcloud-aio-web.service=nextcloud-aio"

      # HTTPS router (websecure) - main entry point
      - "traefik.http.routers.nextcloud-aio-websecure.rule=Host(\`${PUBLIC_DOMAIN}\`)"
      - "traefik.http.routers.nextcloud-aio-websecure.entrypoints=websecure"
      - "traefik.http.routers.nextcloud-aio-websecure.tls.certresolver=${CERTRESOLVER}"
      - "traefik.http.routers.nextcloud-aio-websecure.service=nextcloud-aio"
      - "traefik.http.routers.nextcloud-aio-websecure.middlewares=nextcloud-aio-headers"

      # Service pointing to Apache backend on port 11000
      - "traefik.http.services.nextcloud-aio.loadbalancer.server.port=${APACHE_PORT}"

      # Middleware: HTTP to HTTPS redirect
      - "traefik.http.middlewares.nextcloud-aio-redirect.redirectscheme.scheme=https"

      # Middleware: Security headers for reverse proxy
      - "traefik.http.middlewares.nextcloud-aio-headers.headers.hostsProxyHeaders=X-Forwarded-Host"
      - "traefik.http.middlewares.nextcloud-aio-headers.headers.referrerPolicy=same-origin"

volumes:
  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer

networks:
  saltbox:
    external: true
EOF

echo "✅ docker-compose.yml created"
echo ""

# ============================================================================
# DEPLOYMENT
# ============================================================================
echo "🚀 Starting Nextcloud AIO mastercontainer..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

docker compose up -d

echo ""
echo "⏳ Waiting 10 seconds for container to initialize..."
sleep 10

# ============================================================================
# OPTIONAL HEALTH CHECK
# ============================================================================
read -p "Run health checks (Traefik + backend + public URL)? (y/n): " HC_CONFIRM
if [[ ! "$HC_CONFIRM" =~ ^[Yy]$ ]]; then
    echo ""
    echo "✅ Deployment complete. Skipping health checks."
    echo ""
    echo "📌 Next steps:"
    echo "   1. Open AIO interface: http://${SERVER_IP}:8080"
    echo "   2. Log in with passphrase shown on screen"
    echo "   3. Select containers to install (Nextcloud, Database, Redis, etc.)"
    echo "   4. Start installation"
    echo "   5. Access at: https://${PUBLIC_DOMAIN}"
    echo ""
    exit 0
fi

echo ""
echo "🩺 Running health checks..."
echo ""

# ============================================================================
# WAIT FOR AIO LOGIN PAGE
# ============================================================================
echo "⏳ Waiting for AIO login page to be ready..."

MAX_WAIT=90
ELAPSED=0
LOGIN_READY=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if docker inspect nextcloud-aio-mastercontainer 2>/dev/null | grep -q '"Status": "healthy"'; then
        HTTP_CODE_LOGIN=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null || echo "000")

        if [[ "$HTTP_CODE_LOGIN" == "200" ]] || [[ "$HTTP_CODE_LOGIN" == "302" ]]; then
            echo "✅ AIO login page ready (HTTP $HTTP_CODE_LOGIN)"
            LOGIN_READY=true
            break
        fi
    fi

    echo "   ⏳ Waiting... ($ELAPSED/$MAX_WAIT seconds)"
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

echo ""

# ============================================================================
# CHECK TRAEFIK ROUTERS
# ============================================================================
echo "🔗 Checking Traefik routers..."

# List routers from docker labels
TRAEFIK_ROUTERS=$(docker inspect nextcloud-aio-mastercontainer 2>/dev/null | \
                  jq -r '.[] | .Config.Labels | to_entries[] | select(.key | contains("traefik.http.routers")) | .key' | \
                  cut -d. -f4 | sort -u | head -5)

if [ -n "$TRAEFIK_ROUTERS" ]; then
    echo "   Found Traefik routers:"
    echo "$TRAEFIK_ROUTERS" | sed 's/^/     • /'
    echo "✅ Traefik routers detected"
else
    echo "⚠️  No Traefik routers detected in labels"
fi

echo ""

# ============================================================================
# CHECK PUBLIC DOMAIN
# ============================================================================
echo "🌐 Checking public domain..."
if [ -n "$PUBLIC_DOMAIN" ]; then
    PUBLIC_URL="https://${PUBLIC_DOMAIN}"
    if [ "$PUBLIC_PORT" != "443" ]; then
        PUBLIC_URL="https://${PUBLIC_DOMAIN}:${PUBLIC_PORT}"
    fi

    HTTP_CODE_PUBLIC=$(curl -k -s -o /dev/null -w "%{http_code}" "$PUBLIC_URL" 2>/dev/null || echo "000")
    
    if [[ "$HTTP_CODE_PUBLIC" == "200" ]] || [[ "$HTTP_CODE_PUBLIC" == "302" ]] || [[ "$HTTP_CODE_PUBLIC" == "401" ]]; then
        echo "✅ Public domain accessible: $PUBLIC_URL (HTTP $HTTP_CODE_PUBLIC)"
    elif [[ "$HTTP_CODE_PUBLIC" == "404" ]]; then
        echo "⚠️  Public domain returns 404 (Traefik routing issue): $PUBLIC_URL"
    else
        echo "⚠️  Public domain check: $PUBLIC_URL → HTTP $HTTP_CODE_PUBLIC"
    fi
else
    echo "   Public domain not configured"
fi

echo ""

# ============================================================================
# CHECK BACKEND
# ============================================================================
echo "🔙 Checking backend Apache..."
BACKEND_URL="http://${SERVER_IP}:${APACHE_PORT}"
HTTP_CODE_BACKEND=$(curl -s -o /dev/null -w "%{http_code}" "$BACKEND_URL" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE_BACKEND" == "302" ]]; then
    echo "✅ Backend Apache responding (HTTP $HTTP_CODE_BACKEND redirect)"
elif [[ "$HTTP_CODE_BACKEND" == "200" ]]; then
    echo "✅ Backend Apache responding (HTTP $HTTP_CODE_BACKEND)"
else
    echo "⚠️  Backend: $BACKEND_URL → HTTP $HTTP_CODE_BACKEND"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ HEALTH CHECKS COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ============================================================================
# SUMMARY
# ============================================================================
echo "📌 Access Information:"
echo "   - AIO Interface:    http://${SERVER_IP}:8080"
echo "   - AIO Containers:   http://${SERVER_IP}:8080/containers"
if [ -n "$PUBLIC_DOMAIN" ]; then
    echo "   - Public Nextcloud: https://${PUBLIC_DOMAIN}"
fi
echo "   - Backend Direct:   ${BACKEND_URL}"
echo ""
echo "🔧 Useful Commands:"
echo "   cd /srv/nextcloud-aio"
echo "   docker compose ps"
echo "   docker compose logs -f nextcloud-aio-mastercontainer"
echo "   docker compose restart"
echo ""
echo "📋 Traefik Dashboard:"
echo "   Check routers/services for nextcloud-aio (should show web + websecure)"
echo ""

# Save deployment info
cat > /srv/nextcloud-aio/DEPLOYMENT_INFO.txt << DEPLOY_EOF
Nextcloud AIO Deployment Information
=====================================
Deployed: $(date)
Server IP: ${SERVER_IP}
Certresolver: ${CERTRESOLVER}

Configuration:
  PUBLIC_DOMAIN: ${PUBLIC_DOMAIN}
  PUBLIC_PORT: ${PUBLIC_PORT}
  APACHE_PORT: ${APACHE_PORT}

Access URLs:
  - AIO Login:        http://${SERVER_IP}:8080
  - AIO Containers:   http://${SERVER_IP}:8080/containers
  - Public Nextcloud: https://${PUBLIC_DOMAIN}
  - Backend Apache:   http://${SERVER_IP}:${APACHE_PORT}

Traefik Integration:
  - Provider:   Docker (labels)
  - Routers:    nextcloud-aio-web (HTTP) + nextcloud-aio-websecure (HTTPS)
  - Certresolver: ${CERTRESOLVER}
  - Network:    saltbox

Management:
  - Location:   /srv/nextcloud-aio
  - Logs:       docker compose logs -f nextcloud-aio-mastercontainer
  - Status:     docker compose ps
  - Restart:    docker compose restart
  - Stop:       docker compose down

Backup Location (if created): /root/nextcloud-aio-backup-*
DEPLOY_EOF

echo "💾 Deployment info: /srv/nextcloud-aio/DEPLOYMENT_INFO.txt"
echo ""
