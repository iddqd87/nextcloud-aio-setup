# Nextcloud AIO + Saltbox/Traefik Setup

Automated deployment script for Nextcloud All-in-One with Traefik reverse proxy integration on Saltbox servers.

## Features

- ✅ One-command deployment
- ✅ Automatic environment validation
- ✅ Backup & restore functionality
- ✅ Auto-detection of Traefik certresolver
- ✅ Skip domain validation (prevents common VPS issues)

## Requirements

- Docker & Docker Compose
- Saltbox with Traefik
- Root access (sudo)

## Quick Start

### One-Command Install

```
curl -fsSL https://raw.githubusercontent.com/iddqd87/nextcloud-aio-setup/main/deploy-nextcloud-aio.sh -o deploy-nextcloud-aio.sh && chmod +x deploy-nextcloud-aio.sh && sudo ./deploy-nextcloud-aio.sh
```

### Step-by-Step Install

Download the script:

```
curl -fsSL https://raw.githubusercontent.com/iddqd87/nextcloud-aio-setup/main/deploy-nextcloud-aio.sh -o deploy-nextcloud-aio.sh
```

Make it executable:

```
chmod +x deploy-nextcloud-aio.sh
```

Run with sudo:

```
sudo ./deploy-nextcloud-aio.sh
```

## Post-Installation

After the script completes, you'll see output like:

```
✅ NEXTCLOUD AIO DEPLOYED!
   
   AIO Interface: http://0.0.0.0:8080
```

### Setup Steps

1. Open the AIO interface URL shown (e.g., `http://YOUR_IP:8080`)
2. Copy the initial password displayed on screen
3. Enter your domain name (e.g., `nextcloud.example.com`)
4. Complete the AIO setup wizard
5. AIO will automatically configure Traefik labels and SSL

## Management

View deployment info:

```
cat /srv/nextcloud-aio/DEPLOYMENT_INFO.txt
```

Check container status:

```
cd /srv/nextcloud-aio
docker compose ps
```

View logs:

```
docker compose logs -f
```

Restart services:

```
docker compose restart
```

Stop services:

```
docker compose down
```

## Troubleshooting

### Port 8080 Already in Use

Check what's using the port:

```
ss -tulpn | grep :8080
```

Stop the conflicting service or choose a different port in the docker-compose.yml.

### Container Won't Start

Check logs for errors:

```
cd /srv/nextcloud-aio
docker compose logs
```

### Traefik Not Detected

Verify Traefik is running:

```
docker ps | grep traefik
```

Check if it's in the saltbox network:

```
docker network inspect saltbox | grep traefik
```

### Complete Reinstall

Remove everything and start over:

```
cd /srv/nextcloud-aio
docker compose down --volumes
rm -rf /srv/nextcloud-aio
# Run the deployment script again
```

## Backups

The script automatically offers to backup existing installations before removal.

Backups are stored in `/root/nextcloud-aio-backup-YYYYMMDD-HHMMSS/`

To restore a backup:

```
cd /root/nextcloud-aio-backup-YYYYMMDD-HHMMSS
sudo ./restore.sh
```

## What This Script Does

1. Validates environment (Docker, Traefik, Saltbox network)
2. Offers to backup existing installations
3. Cleans up any previous installations
4. Auto-detects your public IP and Traefik certresolver
5. Creates `/srv/nextcloud-aio/` with docker-compose.yml
6. Sets `SKIP_DOMAIN_VALIDATION=true` (prevents VPS domain validation errors)
7. Deploys Nextcloud AIO container on port 8080
8. Shows access URL for web-based setup

## Technical Details

- **Installation directory**: `/srv/nextcloud-aio`
- **AIO interface port**: `8080`
- **Apache port** (for Nextcloud): `11000`
- **Docker network**: `saltbox`
- **Volume**: `nextcloud_aio_mastercontainer`

The docker-compose.yml includes:
- `SKIP_DOMAIN_VALIDATION=true` - Bypasses domain validation (required for VPS/Traefik setups)
- `APACHE_PORT=11000` - Internal Nextcloud port for Traefik routing
- `APACHE_IP_BINDING=0.0.0.0` - Allows Traefik to connect

## Why SKIP_DOMAIN_VALIDATION?

Nextcloud AIO normally validates that domains are reachable from within the container. On VPS setups with Traefik reverse proxy, this check fails because:
- The container can't reach its own public domain (routing loop)
- Traefik handles all external routing and SSL

Setting `SKIP_DOMAIN_VALIDATION=true` is the recommended approach for Traefik/reverse proxy deployments.

## License

MIT
```
