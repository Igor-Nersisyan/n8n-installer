# n8n Production Installer

🚀 **Automated production-ready n8n installation script for Ubuntu servers**

[![Version](https://img.shields.io/badge/version-3.23-blue.svg)](https://github.com/Igor-Nersisyan/n8n-installer)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20|%2022.04%20|%2024.04-orange.svg)](https://ubuntu.com/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

## 🎯 What is this?

A battle-tested installation script that sets up n8n workflow automation platform with enterprise-grade configuration in minutes. No Docker knowledge required. This Production Grade Edition includes queue mode for scalability, Redis integration, worker management, and fixes for common issues like binary data preview and trust proxy configuration.

## ✨ Features

### Core Setup
- ✅ **PostgreSQL 15** database (port 5433 - no conflicts with Supabase)
- ✅ **Redis 7** for queue mode and high performance
- ✅ **SSL/HTTPS** with Let's Encrypt auto-renewal
- ✅ **Nginx reverse proxy** with optimized configs (including trust proxy and rate limiting)
- ✅ **Docker & Docker Compose** latest versions
- ✅ **UFW firewall** auto-configuration

### Production Optimizations
- 🔄 **Queue Mode** enabled for scalability with worker concurrency (default: 5 jobs per worker)
- 🧑‍💻 **Worker management script** for easy scaling (add/remove workers, adjust concurrency)
- 🔄 **Automated daily backups** (3:00 AM, 14-day retention)
- 🧹 **Weekly Docker maintenance** (Sundays 4:00 AM)
- 📊 **Execution auto-cleanup** (7-day retention, max 10,000 executions)
- 📝 **Log rotation** (max 30MB across 3 files per container)
- ⚡ **Optimized timeouts**:
  - Webhooks/SSE/Push: 1 hour
  - Binary data: 1 hour (with buffering off for stable previews)
  - UI/API: 5 minutes
  - Static assets: 7-day cache
- 🛠️ **Fixes**: Binary data preview (text files), CSS/JS loading, worker concurrency, trust proxy

## 📋 Requirements

- **OS**: Ubuntu 20.04, 22.04, or 24.04
- **RAM**: Minimum 2GB (for queue mode and Redis)
- **CPU**: Minimum 1 core (scale workers for more)
- **Storage**: Minimum 10 GB
- **Network**: 
  - Root access
  - Public IP address
  - Domain name with A record pointing to server

## 🚀 Quick Install

```bash
# Download installer
wget https://raw.githubusercontent.com/Igor-Nersisyan/n8n-installer/main/install-n8n.sh

# Make executable
chmod +x install-n8n.sh

# Run as root
sudo ./install-n8n.sh
```

You'll be prompted for:
- Domain name (e.g., `n8n.example.com`)
- Email address (for SSL certificates)

The script performs DNS checks and port availability verification before proceeding.

## 📁 Installation Structure

```
/opt/n8n/
├── docker-compose.yml    # Container configuration
├── .env                  # Environment variables & passwords
├── n8n_storage/          # Workflows, credentials, settings, binary data
├── db_data/              # PostgreSQL data
├── redis_data/           # Redis data
├── init-data.sh          # Database initialization
└── manage-workers.sh     # Worker scaling script

/opt/backups/n8n/
├── backup.sh             # Backup script
├── restore.sh            # Restore script
└── *.gz                  # Backup files
```

## 🛠️ Management Commands

### Service Control

```bash
# View logs (all containers)
cd /opt/n8n && docker compose logs -f

# View specific container logs
cd /opt/n8n && docker compose logs -f n8n-main  # or n8n-worker, postgres, redis

# Restart all services
cd /opt/n8n && docker compose restart

# Stop services
cd /opt/n8n && docker compose down

# Start services (with 1 worker by default)
cd /opt/n8n && docker compose up -d --scale n8n-worker=1

# Check status
cd /opt/n8n && docker compose ps

# Health check (n8n main)
curl http://localhost:5678/healthz
```

### Worker Management

Use the dedicated script to scale workers or adjust concurrency:

```bash
# Run worker manager
bash /opt/n8n/manage-workers.sh
```

Options:
- Add worker (scales up)
- Remove worker (scales down, minimum 1)
- Change concurrency (1-20 jobs per worker, restarts workers)

Default: 1 worker × 5 concurrent jobs = 5 executions

### Backup & Restore

```bash
# Manual backup
/opt/backups/n8n/backup.sh

# List backups
ls -lh /opt/backups/n8n/*.gz

# Restore from backup (replace with your backup date)
/opt/backups/n8n/restore.sh 20240922_030000

# Note: Automatic backups run daily at 3:00 AM with 14-day retention
```

## 🔧 Configuration

### Environment Variables
All settings are in `/opt/n8n/.env` (auto-generated secure values):
- Database credentials (POSTGRES_PASSWORD, POSTGRES_NON_ROOT_PASSWORD)
- n8n encryption key (N8N_ENCRYPTION_KEY)
- Redis password (QUEUE_BULL_REDIS_PASSWORD)
- Webhook URL (https://your-domain.com)
- Execution mode (queue) and concurrency (QUEUE_WORKER_CONCURRENCY=5)
- Data pruning (EXECUTIONS_DATA_MAX_AGE=168, EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000)
- Binary data mode (filesystem)
- Trust proxy (N8N_TRUST_PROXY=true)

Edit and restart services if needed: `cd /opt/n8n && docker compose down && docker compose up -d --scale n8n-worker=1`

### Nginx Config
Located at `/etc/nginx/sites-available/your-domain`:
- Optimized for n8n (separate locations for push, binary-data, static files, API)
- Rate limiting (100r/s with burst)
- Trust proxy and forwarded headers
- HSTS, security headers enabled
- Client max body size: 100MB

### PostgreSQL
- Port: 5433 (localhost only)
- Database: n8n
- User: n8n_user
- Data: `/opt/n8n/db_data`

### Redis
- Port: 6379 (internal)
- Data: `/opt/n8n/redis_data`
- Used for queue mode

## 🐛 Troubleshooting

### Services not starting
- Check logs: `cd /opt/n8n && docker compose logs --tail=50`
- Verify ports: Ensure 5678 (n8n), 5433 (PostgreSQL) are free
- Health checks: Wait 30-60s on first run for DB init

### Binary data preview issues
- Fixed in this version! Ensure `N8N_DEFAULT_BINARY_DATA_MODE=filesystem` in .env
- Clear browser cache if upgrading

### SSL certificate issues
```bash
# Manually renew
certbot renew --deploy-hook "systemctl reload nginx"
```

### Database connection errors
```bash
# Check PostgreSQL logs
docker logs n8n-postgres

# Verify port
ss -tuln | grep 5433
```

### High load / Scaling
- Use `manage-workers.sh` to add workers
- Monitor: `docker stats`

### White screen / CSS/JS not loading
- Fixed in this version! If persists: Clear cache, restart n8n, check Nginx logs (`nginx -t && systemctl reload nginx`)

## 📊 Resource Usage

Typical resource consumption (with 1 worker):
- **RAM**: 1-3GB (idle), 3-6GB (active with queues)
- **CPU**: 5-15% (idle), 30-70% (active workflows)
- **Disk**: ~1GB (base) + workflows/execution/binary data
- **Network**: Varies by workflow complexity

Scale workers for higher loads.

## 🔄 Updates

### Update n8n
```bash
cd /opt/n8n
docker compose pull
docker compose down
docker compose up -d --scale n8n-worker=1  # Or your desired worker count
```

### Update installer
For reinstalls, backup first, remove `/opt/n8n`, then run the latest script.

## 🔒 Security Considerations

- ✅ Firewall configured (ports 22, 80, 443 only)
- ✅ PostgreSQL/Redis bound to localhost/network internal
- ✅ Auto-generated strong passwords and encryption keys
- ✅ SSL/HTTPS enforced with HSTS
- ✅ Rate limiting and security headers
- ✅ Encrypted credentials and secure cookies
- ✅ Payload size limit (100MB)

## 🤝 Contributing

Found a bug or have a suggestion? Please open an issue or submit a PR!

## 📄 License

MIT License - feel free to use in your projects!

## ⭐ Support

If this script saved you time, consider giving it a star on GitHub!

---

**Note**: This is an independent project, not officially affiliated with n8n.
