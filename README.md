# n8n Production Installer

🚀 **Automated production-ready n8n installation script for Ubuntu servers**

[![Version](https://img.shields.io/badge/version-2.2-blue.svg)](https://github.com/Igor-Nersisyan/n8n-installer)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20|%2022.04%20|%2024.04-orange.svg)](https://ubuntu.com/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

## 🎯 What is this?

A battle-tested installation script that sets up n8n workflow automation platform with enterprise-grade configuration in minutes. No Docker knowledge required.

## ✨ Features

### Core Setup
- ✅ **PostgreSQL 15** database (port 5433 - no conflicts with Supabase)
- ✅ **SSL/HTTPS** with Let's Encrypt auto-renewal
- ✅ **Nginx reverse proxy** with optimized configs
- ✅ **Docker & Docker Compose** latest versions
- ✅ **UFW firewall** auto-configuration

### Production Optimizations
- 🔄 **Automated daily backups** (3:00 AM, 14-day retention)
- 🧹 **Weekly maintenance** (Sundays 4:00 AM)
- 📊 **Execution auto-cleanup** (7-day retention)
- 📝 **Log rotation** (max 30MB)
- ⚡ **Optimized timeouts**:
  - Webhooks/SSE: 1 hour
  - UI/API: 2 minutes
  - Static assets: 30-day cache

## 📋 Requirements

- **OS**: Ubuntu 20.04, 22.04, or 24.04
- **RAM**: Minimum 1GB 
- **CPU**: Minimum 1 core
- **Storage**: 10GB+ 
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

## 📁 Installation Structure
```
/opt/n8n/
├── docker-compose.yml    # Container configuration
├── .env                  # Environment variables & passwords
├── n8n_storage/         # Workflows, credentials, settings
├── db_data/             # PostgreSQL data
├── init-data.sh         # Database initialization
└── maintenance.sh       # Weekly cleanup script

/opt/backups/n8n/
├── backup.sh            # Backup script
├── restore.sh           # Restore script
└── *.gz                 # Backup files
```


## 🛠️ Management Commands

### Service Control
```bash
# View logs
cd /opt/n8n && docker compose logs -f

# Restart n8n
cd /opt/n8n && docker compose restart

# Stop services
cd /opt/n8n && docker compose down

# Start services
cd /opt/n8n && docker compose up -d

# Check status
cd /opt/n8n && docker compose ps

# Health check
curl http://localhost:5678/healthz
Backup & Restore
bash# Manual backup
/opt/backups/n8n/backup.sh

# List backups
ls -lh /opt/backups/n8n/*.gz

# Restore from backup
/opt/backups/n8n/restore.sh 20240314_030000

# Note: Automatic backups run daily at 3:00 AM
🔧 Configuration
Environment Variables
All settings are in /opt/n8n/.env:

Database passwords (auto-generated)
n8n encryption key
Webhook URL
Execution retention settings

Nginx Config
Located at /etc/nginx/sites-available/n8n:

Optimized for n8n's specific needs
Separate handling for webhooks, UI, and static files
Rate limiting enabled

PostgreSQL

Port: 5433 (avoids conflicts)
Database: n8n
User: n8n_user
Data: /opt/n8n/db_data

🐛 Troubleshooting
White screen on first load
Fixed in v2.2! If you still experience issues:
bash# Clear browser cache
# Restart n8n
cd /opt/n8n && docker compose restart
SSL certificate issues
bash# Manually obtain certificate
certbot --nginx -d your-domain.com
Database connection errors
bash# Check PostgreSQL status
docker logs n8n-postgres

# Verify port 5433 is not in use
netstat -tulpn | grep 5433
High memory usage
bash# Check container stats
docker stats

# Restart to clear memory
cd /opt/n8n && docker compose restart
📊 Resource Usage
Typical resource consumption:

RAM: 1-2GB (idle), 2-4GB (active)
CPU: 5-10% (idle), 20-50% (active)
Disk: ~500MB (base) + workflows/execution data
Network: Varies by workflow complexity

🔄 Updates
Update n8n
bashcd /opt/n8n
docker compose pull
docker compose down
docker compose up -d
Update installer
bashwget https://raw.githubusercontent.com/Igor-Nersisyan/n8n-installer/main/install-n8n.sh -O install-n8n-new.sh
# Review changes, then use if needed
🔒 Security Considerations

✅ Firewall configured (ports 22, 80, 443 only)
✅ PostgreSQL bound to localhost only
✅ Auto-generated strong passwords
✅ SSL/HTTPS enforced
✅ Rate limiting enabled
✅ Encrypted credentials storage

🤝 Contributing
Found a bug or have a suggestion? Please open an issue or submit a PR!
📄 License
MIT License - feel free to use in your projects!
⭐ Support
If this script saved you time, consider giving it a star on GitHub!

Note: This is an independent project, not officially affiliated with n8n.
