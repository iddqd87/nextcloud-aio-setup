#!/bin/bash
# Nextcloud AIO + Saltbox Traefik Setup
# Run as root: sudo ./deploy-nextcloud-aio.sh

set -e

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
cat > docker-compose.yml << 'EOF'
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
      - APACHE_PORT=11000
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

echo ""
echo "⏳ Waiting for container to initialize (10 seconds)..."
sleep 10

# ============================================================================
# FINAL STATUS
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ NEXTCLOUD AIO DEPLOYED!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Access Information:"
echo "   AIO Interface: http://${SERVER_IP}:8080"
echo "   Server IP:     ${SERVER_IP}"
echo "   Certresolver:  ${CERTRESOLVER}"
echo ""
echo "📚 Next Steps:"
echo "   1. Open: http://${SERVER_IP}:8080"
echo "   2. Copy the password shown on screen"
echo "   3. Enter your domain when prompted"
echo "   4. Complete the AIO setup wizard"
echo ""
echo "💡 Tip: The AIO interface will show your initial password"
echo ""
echo "🔧 Useful Commands:"
echo "   Location:  cd /srv/nextcloud-aio"
echo "   Status:    docker compose ps"
echo "   Logs:      docker compose logs -f"
echo "   Restart:   docker compose restart"
echo "   Stop:      docker compose down"
echo ""

# Save deployment info
cat > /srv/nextcloud-aio/DEPLOYMENT_INFO.txt << DEPLOY_EOF
Nextcloud AIO Deployment Information
=====================================
Deployed: $(date)
Server IP: ${SERVER_IP}
Certresolver: ${CERTRESOLVER}

Access:
- AIO Interface: http://${SERVER_IP}:8080

Management:
- Location: /srv/nextcloud-aio
- Logs: docker compose logs -f
- Status: docker compose ps

Backup Location (if created): /root/nextcloud-aio-backup-*
DEPLOY_EOF

echo "💾 Deployment info saved: /srv/nextcloud-aio/DEPLOYMENT_INFO.txt"
echo ""
