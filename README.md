# Nextcloud AIO + Saltbox/Traefik Setup

Automated deployment script for Nextcloud All-in-One with Traefik reverse proxy integration.

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

## Requirements

- Docker & Docker Compose
- Saltbox with Traefik
- Root access (sudo)
- Domain with DNS configured

## Features

- ✅ Interactive domain configuration
- ✅ Automatic SSL certificate setup
- ✅ Backup & restore functionality
- ✅ Auto-detection of Traefik certresolver
- ✅ Initial password extraction

## Usage

The script will prompt you to:

1. Enter your base domain (e.g., `example.com`)
2. Choose subdomain or root domain setup
3. Confirm DNS and environment settings

## Post-Installation

Access your Nextcloud AIO interface at `https://aio.yourdomain.com`

View deployment info:

```
cat /srv/nextcloud-aio/DEPLOYMENT_INFO.txt
```

## Troubleshooting

Check container status:

```
cd /srv/nextcloud-aio
docker compose ps
```

View logs:

```
docker compose logs -f
```

## License

MIT
```

Now **only the actual commands** have code blocks with copy buttons - descriptions and explanations are in plain text.[1]
