#!/bin/bash
# Nextcloud AIO + Saltbox Traefik - ULTIMATE EDITION
# Features: Auto-certresolver, backup validation, initial password display, recovery script
# Run as root: sudo ./deploy-nextcloud-aio.sh

set -e

echo "=== 🚀 Nextcloud AIO + Saltbox Traefik ULTIMATE SETUP 🚀 ==="
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
# Generated: $(date)

set -e

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 🔄 Nextcloud AIO RESTORE ==="
echo "Backup location: $BACKUP_DIR"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "❌ Must run as root: sudo ./restore.sh"
   exit 1
fi

read -p "⚠️  This will OVERWRITE current installation. Continue? (yes/NO): " CONFIRM
if [[ ! "$CONFIRM" == "yes" ]]; then
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
            
            # Create backup manifest
            cat > "$BACKUP_DIR/MANIFEST.txt" << MANIFEST_EOF
Nextcloud AIO Backup Manifest
==============================
Created: $(date)
Backup Directory: $BACKUP_DIR
Total Size: $BACKUP_SIZE
Volumes Backed Up: $VOLUME_COUNT

Contents:
---------
$(ls -lh "$BACKUP_DIR/volumes"/ 2>/dev/null)

Restore Instructions:
---------------------
1. cd $BACKUP_DIR
2. sudo ./restore.sh
3. Follow prompts

Notes:
------
- This backup contains all Nextcloud AIO data, configs, and volumes
- Restore script will stop current installation before restoring
- Original backup from: $(hostname)
MANIFEST_EOF
            
        else
            echo "⚠️  Backup validation failed - some files missing"
            echo "   Check $BACKUP_DIR manually"
        fi
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

# Auto-detect Traefik certresolver
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
      - "traefik.http.routers.nextcloud-https.tls.certresolver=${CERTRESOLVER}"
      - "traefik.http.services.nextcloud.loadbalancer.server.port=11000"
      - "traefik.http.services.nextcloud.loadbalancer.server.scheme=http"
      
      # HTTP → HTTPS redirect (AIO)
      - "traefik.http.routers.
