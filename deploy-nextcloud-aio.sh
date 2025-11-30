#!/bin/bash
# Nextcloud AIO + Saltbox Traefik Setup
# Run as root: sudo ./deploy-nextcloud-aio.sh

set -e

# User-configurable external access settings
PUBLIC_DOMAIN="nextcloud.meatf.art"   # Your Nextcloud domain
PUBLIC_PORT="443"                     # External port for PUBLIC_DOMAIN (usually 443)
APACHE_PORT="11000"                   # Internal AIO Apache port (matches APACHE_PORT env)
TRAEFIK_DYNAMIC_DIR="/opt/traefik/dynamic"  # Traefik dynamic config directory used by Saltbox

echo "=== 🚀 Nextcloud AIO + Saltbox Traefik Setup 🚀 ==="
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
    read -p "Create backup first? (y/n): " BACKUP_CHOICE
    if [[ $BACKUP_CHOICE =~ ^[Yy]$ ]]; then
        BACKUP_DIR="/root/nextcloud-aio-backup-$(date +%Y%m%d-%H%M%S)"
        echo "📦 Creating comprehensive backup: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"/{volumes,config}

        # Backup directory structure
        echo "  → Backing up /srv/nextcloud-aio..."
        cp -r /srv/nextcloud-aio "$BACKUP_DIR/config/" 2>/dev/null || true

        # Backup all AIO volumes
        echo "  → Backing up Docker volumes..."
        for volume in $(docker volume ls -q | grep nextcloud_aio); do
            echo "    • $volume"
            docker run --rm \
                -v "$volume":/data \
                -v "$BACKUP_DIR/volumes":/backup \
                alpine tar czf "/backup/${volume}.tar.gz" -C /data . 2>/dev/null || echo "    ⚠️  Failed to backup $volume"
        done

        # Backup container metadata
        echo "  → Backing up container configs..."
        docker inspect $(docker ps -a -q --filter "name=nextcloud-aio") > "$BACKUP_DIR/config/containers.json" 2>/dev/null || true

        # Create restore script
        cat > "$BACKUP_DIR/restore.sh" << 'RESTORE_EOF'
#!/bin/bash
# Nextcloud AIO Backup Restore Script

set -e

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 🔄 Nextcloud AIO RESTORE ==="
echo "Backup location: $BACKUP_DIR"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "❌ Must run as root: sudo ./restore.sh"
   exit 1
fi

read -p "⚠️  This will OVERWRITE current installation. Continue? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Restore cancelled"
    exit 0
fi

echo "🛑 Stopping Nextcloud AIO..."
cd /srv/nextcloud-aio 2>/dev/null && docker compose down 2>/dev/null || true

echo "🗑️  Removing current volumes..."
docker volume ls -q | grep nextcloud_aio | xargs -r docker volume rm 2>/dev/null || true

echo "📁 Restoring directory structure..."
mkdir -p /srv/nextcloud-aio
cp -r "$BACKUP_DIR/config/nextcloud-aio/"* /srv/nextcloud-aio/ 2>/dev/null || true

echo "💾 Restoring volumes..."
for volume_tar in "$BACKUP_DIR/volumes"/*.tar.gz; do
    if [ -f "$volume_tar" ]; then
        volume_name=$(basename "$volume_tar" .tar.gz)
        echo "  → Restoring $volume_name"
        docker volume create "$volume_name" >/dev/null
        docker run --rm \
            -v "$volume_name":/data \
            -v "$BACKUP_DIR/volumes":/backup \
            alpine tar xzf "/backup/${volume_name}.tar.gz" -C /data
    fi
done

echo "🚀 Starting containers..."
cd /srv/nextcloud-aio
docker compose up -d

echo ""
echo "✅ RESTORE COMPLETE!"
echo "   Check status: docker compose ps"
echo "   View logs: docker compose logs -f"
RESTORE_EOF

        chmod +x "$BACKUP_DIR/restore.sh"

        # Validate backup
        echo ""
        echo "🔍 Validating backup..."
        BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
        VOLUME_COUNT=$(ls -1 "$BACKUP_DIR/volumes"/*.tar.gz 2>/dev/null | wc -l)

        if [ -f "$BACKUP_DIR/restore.sh" ] && [ "$VOLUME_COUNT" -gt 0 ]; then
            echo "✅ Backup created successfully!"
            echo "   Location: $BACKUP_DIR"
            echo "   Size: $BACKUP_SIZE"
            echo "   Volumes: $VOLUME_COUNT backed up"
            echo "   Restore: sudo $BACKUP_DIR/restore.sh"
            echo ""
        else
            echo "⚠️  Backup validation failed - some files missing"
            echo "   Check $BACKUP_DIR manually"
        fi
    fi

    echo ""
    read -p "Continue with clean installation? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
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
    read -p "Continue anyway? (y/n): " REPLY
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check if Traefik is in saltbox network
if ! docker network inspect saltbox | grep -q traefik 2>/dev/null; then
    echo "⚠️  WARNING: Traefik not detected in saltbox network!"
    read -p "Continue anyway? (y/n): " REPLY
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

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
# DETECT TRAEFIK CERTRESOLVER
# ============================================================================
echo ""
echo "🔍 Detecting Traefik SSL certresolver..."
CERTRESOLVER=$(docker inspect traefik 2>/dev/null | jq -r '.[0].Args[]' 2>/dev/null | grep -i certificatesresolvers | head -1 | cut -d. -f3)

if [[ -z "$CERTRESOLVER" ]]; then
    echo "⚠️  Could not auto-detect certresolver, using default: cfdns"
    CERTRESOLVER="cfdns"
else
    echo "✅ Detected certresolver: $CERTRESOLVER"
fi

echo "✅ Environment validated"

# ============================================================================
# GENERATE TRAEFIK DYNAMIC CONFIG FOR NEXTCLOUD AIO
# ============================================================================
echo ""
echo "🧩 Writing Traefik dynamic config for Nextcloud AIO..."
mkdir -p "$TRAEFIK_DYNAMIC_DIR"

cat > "${TRAEFIK_DYNAMIC_DIR}/nextcloud-aio.yml" << EOF
http:
  routers:
    nextcloud-aio:
      rule: "Host(\`${PUBLIC_DOMAIN}\`)"
      entryPoints:
        - websecure
      service: nextcloud-aio
      middlewares:
        - nextcloud-aio-chain
      tls:
        certResolver: "${CERTRESOLVER}"

  services:
    nextcloud-aio:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${APACHE_PORT}"

  middlewares:
    nextcloud-aio-secure-headers:
      headers:
        hostsProxyHeaders:
          - "X-Forwarded-Host"
        referrerPolicy: "same-origin"

    nextcloud-aio-https-redirect:
      redirectScheme:
        scheme: https

    nextcloud-aio-chain:
      chain:
        middlewares:
          - nextcloud-aio-https-redirect
          - nextcloud-aio-secure-headers
EOF

echo "✅ Traefik dynamic config written to ${TRAEFIK_DYNAMIC_DIR}/nextcloud-aio.yml"
echo "🔄 Restarting Traefik to apply config..."
docker restart traefik >/dev/null
echo "✅ Traefik restarted"

# ============================================================================
# PORT AVAILABILITY CHECK
# ============================================================================
echo ""
echo "🔍 Checking port availability..."
if ss -tulpn | grep -q ":8080 "; then
    echo "⚠️  WARNING: Port 8080 already in use!"
    ss -tulpn | grep ":8080 "
    read -p "Continue anyway? (y/n): " REPLY
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi
echo "✅ Port 8080 available"

# ============================================================================
# DOCKER COMPOSE GENERATION
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
      - 8080:8080
    networks:
      - saltbox
    environment:
      - APACHE_PORT=${APACHE_PORT}
      - APACHE_IP_BINDING=0.0.0.0
      - SKIP_DOMAIN_VALIDATION=true
      - NEXTCLOUD_DATADIR=/mnt/docker-aio-data

volumes:
  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer

networks:
  saltbox:
    external: true
EOF

echo "✅ docker-compose.yml created"

# ============================================================================
# DEPLOYMENT
# ============================================================================
echo ""
echo "🚀 Starting Nextcloud AIO..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

docker compose up -d

# ============================================================================
# WAIT FOR LOGIN PAGE TO BE READY
# ============================================================================
echo ""
echo "⏳ Waiting for AIO login page to become ready..."
echo ""

MAX_WAIT=90
ELAPSED=0
LOGIN_READY=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Check if container is healthy
    if docker inspect nextcloud-aio-mastercontainer 2>/dev/null | grep -q '"Status": "healthy"'; then
        echo "   ✅ Container is healthy"

        # Check if web interface (login page) is responding
        HTTP_CODE_LOGIN=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null || echo "000")

        if [[ "$HTTP_CODE_LOGIN" == "200" ]] || [[ "$HTTP_CODE_LOGIN" == "302" ]]; then
            echo "   ✅ Login page is responding (HTTP $HTTP_CODE_LOGIN)"
            LOGIN_READY=true
            break
        else
            echo "   ⏳ Login page not ready yet (HTTP $HTTP_CODE_LOGIN) - waiting..."
        fi
    else
        echo "   ⏳ Container initializing... ($ELAPSED/$MAX_WAIT seconds)"
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

echo ""

if [ "$LOGIN_READY" = true ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ AIO LOGIN PAGE IS READY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⚠️  AIO DEPLOYED (login page may need a few more seconds)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

echo ""
echo "📋 Access Information:"
echo "   🌐 AIO Login:       http://${SERVER_IP}:8080"
echo ""
echo "➡️  In your browser:"
echo "   1) Open:  http://${SERVER_IP}:8080"
echo "   2) Copy the passphrase shown on screen"
echo "   3) Paste it into the login field and submit"
echo ""

# ============================================================================
# WAIT FOR CONTAINERS PAGE AFTER LOGIN
# ============================================================================
echo "⏳ Waiting for installer / containers page after login..."
echo ""

POST_MAX_WAIT=120
POST_ELAPSED=0
CONTAINERS_READY=false

while [ $POST_ELAPSED -lt $POST_MAX_WAIT ]; do
    HTTP_CODE_CONTAINERS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/containers" 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE_CONTAINERS" == "200" ]] || [[ "$HTTP_CODE_CONTAINERS" == "302" ]]; then
        echo "   ✅ Containers page is responding (HTTP $HTTP_CODE_CONTAINERS)"
        CONTAINERS_READY=true
        break
    else
        echo "   ⏳ Installer still initializing... (HTTP $HTTP_CODE_CONTAINERS)"
    fi

    sleep 5
    POST_ELAPSED=$((POST_ELAPSED + 5))
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$CONTAINERS_READY" = true ]; then
    echo "✅ NEXTCLOUD AIO INSTALLER / CONTAINERS PAGE IS READY"
else
    echo "⚠️  AIO installer may still be initializing, but should be reachable."
endif
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📚 In the AIO web UI:"
echo "   • Select the containers/services you want to install"
echo "   • Click the button to start the installation"
echo "   • This script will now monitor container startup and check your URLs"
echo ""

# ============================================================================
# MONITOR AIO CHILD CONTAINERS
# ============================================================================
echo "⏳ Monitoring Nextcloud AIO containers (this may take several minutes)..."
echo ""

CHILD_MAX_WAIT=600
CHILD_ELAPSED=0
ALL_UP=false

while [ $CHILD_ELAPSED -lt $CHILD_MAX_WAIT ]; do
    echo "   ⏳ Checking container states... (t+${CHILD_ELAPSED}s)"

    # List containers starting with nextcloud-aio-
    AIO_CONTAINERS=$(docker ps --format '{{.Names}}' | grep '^nextcloud-aio-' || true)

    if [ -z "$AIO_CONTAINERS" ]; then
        echo "   ⚠️  No child containers found yet. Waiting..."
    else
        # Assume all are good until one fails
        ALL_RUNNING=true
        for c in $AIO_CONTAINERS; do
            STATUS=$(docker inspect "$c" 2>/dev/null | jq -r '.[0].State.Status' 2>/dev/null || echo "unknown")
            HEALTH=$(docker inspect "$c" 2>/dev/null | jq -r '.[0].State.Health.Status' 2>/dev/null || echo "none")
            echo "      • $c → status=$STATUS health=$HEALTH"
            if [[ "$STATUS" != "running" ]] && [[ "$HEALTH" != "healthy" ]]; then
                ALL_RUNNING=false
            fi
        done

        if [ "$ALL_RUNNING" = true ]; then
            echo ""
            echo "   ✅ All Nextcloud AIO containers appear to be running/healthy"
            ALL_UP=true
            break
        else
            echo "   ⏳ Not all containers are ready yet..."
        fi
    fi

    sleep 10
    CHILD_ELAPSED=$((CHILD_ELAPSED + 10))
    echo ""
done

echo ""
if [ "$ALL_UP" != true ]; then
    echo "⚠️  Timed out waiting for all child containers. URLs may still become available shortly."
    echo ""
fi

# ============================================================================
# FINAL URL CHECKS (PUBLIC DOMAIN + BACKEND IP:PORT)
# ============================================================================
echo "🌐 Checking external/public access URLs..."
echo ""

# 1) Check public domain via Traefik/Cloudflare (HTTPS)
if [ -n "$PUBLIC_DOMAIN" ]; then
    PUBLIC_URL="https://${PUBLIC_DOMAIN}"
    if [ "$PUBLIC_PORT" != "443" ]; then
        PUBLIC_URL="https://${PUBLIC_DOMAIN}:${PUBLIC_PORT}"
    fi

    HTTP_CODE_PUBLIC=$(curl -k -s -o /dev/null -w "%{http_code}" "$PUBLIC_URL" 2>/dev/null || echo "000")
    echo "   • Public domain: $PUBLIC_URL → HTTP $HTTP_CODE_PUBLIC"
else
    echo "   • Public domain: (not configured in script, set PUBLIC_DOMAIN to enable check)"
fi

# 2) Check bare IP + Apache port (direct backend check)
BACKEND_URL="http://${SERVER_IP}:${APACHE_PORT}"
HTTP_CODE_BACKEND=$(curl -s -o /dev/null -w "%{http_code}" "$BACKEND_URL" 2>/dev/null || echo "000")
echo "   • Backend (Apache/APACHE_PORT): $BACKEND_URL → HTTP $HTTP_CODE_BACKEND"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ POST-INSTALL CHECKS COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📌 Summary:"
echo "   - AIO login:       http://${SERVER_IP}:8080"
echo "   - AIO containers:  http://${SERVER_IP}:8080/containers"
if [ -n "$PUBLIC_DOMAIN" ]; then
    echo "   - Public Nextcloud: $PUBLIC_URL (HTTP $HTTP_CODE_PUBLIC)"
fi
echo "   - Backend Apache:   $BACKEND_URL (HTTP $HTTP_CODE_BACKEND)"
echo ""
echo "If any of the above show HTTP 000 or 4xx/5xx, check Traefik/Cloudflare and container logs."
echo ""
echo "🔧 Useful Commands:"
echo "   cd /srv/nextcloud-aio"
echo "   docker compose ps"
echo "   docker compose logs -f"
echo ""

# Save deployment info
cat > /srv/nextcloud-aio/DEPLOYMENT_INFO.txt << DEPLOY_EOF
Nextcloud AIO Deployment Information
=====================================
Deployed: $(date)
Server IP: ${SERVER_IP}
Certresolver: ${CERTRESOLVER}

Access:
- AIO Login:       http://${SERVER_IP}:8080
- AIO Containers:  http://${SERVER_IP}:8080/containers
- Public Nextcloud: ${PUBLIC_DOMAIN:-"(set PUBLIC_DOMAIN in script)"} (port ${PUBLIC_PORT})
- Backend Apache:   ${SERVER_IP}:${APACHE_PORT}

Management:
- Location: /srv/nextcloud-aio
- Logs:     docker compose logs -f
- Status:   docker compose ps

Backup Location (if created): /root/nextcloud-aio-backup-*
DEPLOY_EOF

echo "💾 Deployment info saved: /srv/nextcloud-aio/DEPLOYMENT_INFO.txt"
echo ""
