#!/bin/bash
# Nextcloud AIO + Saltbox Traefik Setup (full reset + optional health check)
# Run as root: sudo ./deploy-nextcloud-aio.sh

set -e

# User-configurable external access settings
PUBLIC_DOMAIN="nextcloud.meatf.art"        # Your Nextcloud domain
PUBLIC_PORT="443"                          # External port for PUBLIC_DOMAIN (usually 443)
APACHE_PORT="11000"                        # Internal AIO Apache port (matches APACHE_PORT env)
TRAEFIK_DYNAMIC_DIR="/opt/traefik/dynamic" # Traefik dynamic config directory used by Saltbox

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

# ============================================================================
# FULL AIO RESET (CONTAINERS + VOLUMES + DIR)
# ============================================================================
echo ""
echo "🧨 Performing full Nextcloud AIO reset..."
echo ""
echo "⚠️  This will remove ALL Nextcloud AIO containers, volumes, and config under /srv/nextcloud-aio."
read -p "Proceed with full reset? (y/n): " RESET_CONFIRM
if [[ ! "$RESET_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Full reset cancelled. Exiting."
    exit 0
fi

echo ""
echo "🛑 Stopping and removing any existing AIO containers..."
docker rm -f $(docker ps -aq --filter "name=nextcloud-aio") 2>/dev/null || true

echo "🗑️  Removing AIO-related volumes..."
docker volume rm $(docker volume ls -q | grep -E '^nextcloud_aio' ) 2>/dev/null || true

echo "🧹 Removing /srv/nextcloud-aio directory..."
rm -rf /srv/nextcloud-aio

echo "✅ Full AIO reset complete"
echo ""

# ============================================================================
# ENVIRONMENT VALIDATION
# ============================================================================
echo "🔍 Validating environment (Docker, Compose, Saltbox, Traefik)..."

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
echo ""

# ============================================================================
# GENERATE TRAEFIK DYNAMIC CONFIG FOR NEXTCLOUD AIO
# ============================================================================
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
echo ""

# ============================================================================
# PORT AVAILABILITY CHECK
# ============================================================================
echo "🔍 Checking port availability..."
if ss -tulpn | grep -q ":8080 "; then
    echo "⚠️  WARNING: Port 8080 already in use!"
    ss -tulpn | grep ":8080 "
    read -p "Continue anyway? (y/n): " REPLY
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi
echo "✅ Port 8080 available"
echo ""

# ============================================================================
# DOCKER COMPOSE GENERATION
# ============================================================================
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
echo ""

# ============================================================================
# DEPLOYMENT
# ============================================================================
echo "🚀 Starting Nextcloud AIO..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

docker compose up -d
echo ""

# ============================================================================
# OPTIONAL HEALTH CHECK PROMPT
# ============================================================================
read -p "Run post-install health checks (backend + public URL)? (y/n): " HC_CONFIRM
if [[ ! "$HC_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "✅ Setup finished. Skipping health checks."
    exit 0
fi

echo ""
echo "🩺 Running post-install health checks..."
echo ""

# ============================================================================
# WAIT FOR LOGIN PAGE TO BE READY
# ============================================================================
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

# 1) Public domain via Traefik/Cloudflare (HTTPS)
if [ -n "$PUBLIC_DOMAIN" ]; then
    PUBLIC_URL="https://${PUBLIC_DOMAIN}"
    if [ "$PUBLIC_PORT" != "443" ]; then
        PUBLIC_URL="https://${PUBLIC_DOMAIN}:${PUBLIC_PORT}"
    fi

    HTTP_CODE_PUBLIC=$(curl -k -s -o /dev/null -w "%{http_code}" "$PUBLIC_URL" 2>/dev/null || echo "000")
    echo "   • Public domain: $PUBLIC_URL → HTTP $HTTP_CODE_PUBLIC"
else
    HTTP_CODE_PUBLIC="---"
    echo "   • Public domain: (not configured in script, set PUBLIC_DOMAIN to enable check)"
fi

# 2) Bare IP + Apache port (direct backend check)
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
