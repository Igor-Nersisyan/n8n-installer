#!/bin/bash

# n8n Simple Installer v3.2 - Production Ready with Robust SSL, CSS Fix & Best Practices
# Fixed service check, added modern n8n variables
# For Ubuntu 20.04, 22.04, 24.04

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
N8N_DIR="/opt/n8n"
BACKUP_DIR="/opt/backups/n8n"
POSTGRES_PORT=5433  # Always 5433
N8N_PORT=5678

# Functions
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root. Please run: sudo $0"
    exit 1
fi

# Check Ubuntu
if ! grep -q "Ubuntu" /etc/os-release; then
    print_error "This script is for Ubuntu only"
    exit 1
fi

clear
echo "=========================================="
echo "     n8n Simple Installer v3.2"
echo "  Production Ready & Robust SSL Setup"
echo "=========================================="
echo ""
echo "Features:"
echo "  ✓ PostgreSQL on port ${POSTGRES_PORT}"
echo "  ✓ Reliable two-stage SSL setup"
echo "  ✓ DNS validation"
echo "  ✓ Automatic local backups"
echo "  ✓ Log rotation & Auto-cleanup (7 days)"
echo "  ✓ Optimized nginx configuration"
echo "  ✓ Fixed CSS/JS loading on first access"
echo "  ✓ Modern security settings (Task Runners)"
echo ""

# Get domain and email
read -p "Enter your domain name (e.g., n8n.example.com): " DOMAIN
read -p "Enter your email address (for SSL certificates): " EMAIL

echo ""
print_message "Domain: $DOMAIN"
print_message "Email: $EMAIL"
echo ""

# Check DNS
print_message "Checking DNS..."
SERVER_IP=$(curl -s ifconfig.me || echo "unknown")

# Install dig if needed
if ! command -v dig &> /dev/null; then
    apt-get update > /dev/null 2>&1
    apt-get install -y dnsutils > /dev/null 2>&1 || true
fi

DNS_IP=$(dig +short $DOMAIN 2>/dev/null | tail -n1 || echo "")

if [ -z "$DNS_IP" ]; then
    print_warning "Domain $DOMAIN does not resolve yet"
    echo "Server IP: $SERVER_IP"
    echo "Please ensure DNS A record points to this IP"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
else
    print_message "Server IP: $SERVER_IP"
    print_message "Domain resolves to: $DNS_IP"
fi

# Install prerequisites
print_message "Installing prerequisites..."
apt-get update > /dev/null 2>&1
apt-get install -y curl wget openssl nginx certbot python3-certbot-nginx ufw dnsutils > /dev/null 2>&1

# Install Docker
if ! command -v docker &> /dev/null; then
    print_message "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh > /dev/null 2>&1
    rm /tmp/get-docker.sh
fi

# Install Docker Compose
if ! docker compose version &> /dev/null 2>&1; then
    print_message "Installing Docker Compose..."
    apt-get install -y docker-compose-plugin > /dev/null 2>&1
fi

systemctl enable nginx > /dev/null 2>&1
systemctl start nginx > /dev/null 2>&1

# Configure firewall
print_message "Configuring firewall..."
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 80/tcp > /dev/null 2>&1
ufw allow 443/tcp > /dev/null 2>&1

if ! ufw status | grep -q "Status: active"; then
    print_message "Enabling firewall..."
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
fi

print_message "Firewall configured"

# Create directories
print_message "Setting up n8n directory structure..."
mkdir -p $N8N_DIR/{db_data,n8n_storage}
mkdir -p $BACKUP_DIR

# Fix permissions for n8n storage (n8n runs as user 1000)
chown -R 1000:1000 $N8N_DIR/n8n_storage

cd $N8N_DIR

# Generate passwords
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
POSTGRES_USER_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

# Create .env with modern variables
cat > .env <<EOF
# Database
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=n8n
POSTGRES_NON_ROOT_USER=n8n_user
POSTGRES_NON_ROOT_PASSWORD=${POSTGRES_USER_PASSWORD}

# n8n Core
N8N_HOST=${DOMAIN}
N8N_PROTOCOL=https
N8N_PORT=${N8N_PORT}
WEBHOOK_URL=https://${DOMAIN}/
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
GENERIC_TIMEZONE=UTC
NODE_ENV=production

# Security & Modern Features (n8n v1.70+)
N8N_RUNNERS_ENABLED=true
N8N_BLOCK_ENV_ACCESS_IN_NODE=true
N8N_SECURE_COOKIE=true

# Execution mode - regular (simple mode without Redis)
EXECUTIONS_MODE=regular

# Data management - auto cleanup after 7 days
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=168
EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000

# Performance optimizations
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_PAYLOAD_SIZE_MAX=32
N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

# Proxy settings
N8N_PROXY_HOPS=1
EOF

# Create PostgreSQL init script
cat > init-data.sh <<'EOF'
#!/bin/bash
set -e
if [ -n "${POSTGRES_NON_ROOT_USER:-}" ] && [ -n "${POSTGRES_NON_ROOT_PASSWORD:-}" ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
        CREATE USER ${POSTGRES_NON_ROOT_USER} WITH PASSWORD '${POSTGRES_NON_ROOT_PASSWORD}';
        GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_NON_ROOT_USER};
        GRANT CREATE ON SCHEMA public TO ${POSTGRES_NON_ROOT_USER};
        ALTER DATABASE ${POSTGRES_DB} OWNER TO ${POSTGRES_NON_ROOT_USER};
EOSQL
fi
EOF
chmod +x init-data.sh

# Create docker-compose.yml
cat > docker-compose.yml <<EOF
volumes:
  db_data:
  n8n_storage:

networks:
  n8n_net:
    driver: bridge

services:
  postgres:
    image: postgres:15
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - POSTGRES_NON_ROOT_USER=\${POSTGRES_NON_ROOT_USER}
      - POSTGRES_NON_ROOT_PASSWORD=\${POSTGRES_NON_ROOT_PASSWORD}
    volumes:
      - ./db_data:/var/lib/postgresql/data
      - ./init-data.sh:/docker-entrypoint-initdb.d/init-data.sh:ro
    ports:
      - "127.0.0.1:${POSTGRES_PORT}:5432"
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -h localhost -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - n8n_net
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_NON_ROOT_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_NON_ROOT_PASSWORD}
      - EXECUTIONS_MODE=\${EXECUTIONS_MODE}
      - WEBHOOK_URL=\${WEBHOOK_URL}
      - N8N_HOST=\${N8N_HOST}
      - N8N_PROTOCOL=\${N8N_PROTOCOL}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - NODE_ENV=\${NODE_ENV}
      - EXECUTIONS_DATA_PRUNE=\${EXECUTIONS_DATA_PRUNE}
      - EXECUTIONS_DATA_MAX_AGE=\${EXECUTIONS_DATA_MAX_AGE}
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=\${EXECUTIONS_DATA_PRUNE_MAX_COUNT}
      - N8N_DEFAULT_BINARY_DATA_MODE=\${N8N_DEFAULT_BINARY_DATA_MODE}
      - N8N_PAYLOAD_SIZE_MAX=\${N8N_PAYLOAD_SIZE_MAX}
      - N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=\${N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=\${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
      - N8N_PROXY_HOPS=\${N8N_PROXY_HOPS}
      - N8N_RUNNERS_ENABLED=\${N8N_RUNNERS_ENABLED}
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=\${N8N_BLOCK_ENV_ACCESS_IN_NODE}
      - N8N_SECURE_COOKIE=\${N8N_SECURE_COOKIE}
    ports:
      - "127.0.0.1:${N8N_PORT}:5678"
    volumes:
      - ./n8n_storage:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ['CMD', 'wget', '--spider', '-q', 'http://localhost:5678/healthz']
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    networks:
      - n8n_net
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

# === ROBUST SSL ACQUISITION (Phase 1) ===
print_message "Creating webroot for SSL certificate validation..."
mkdir -p "/var/www/${DOMAIN}/.well-known/acme-challenge"
chown www-data:www-data "/var/www/${DOMAIN}" -R

print_message "Configuring temporary Nginx for SSL challenge..."
cat > "/etc/nginx/sites-available/${DOMAIN}" << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/${DOMAIN};
    }
    
    location / {
        return 404; # Temporarily block other requests
    }
}
EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/"
rm -f /etc/nginx/sites-enabled/default
nginx -t > /dev/null 2>&1
systemctl restart nginx

print_message "Obtaining SSL certificate via webroot..."
if ! certbot certonly --webroot -w "/var/www/${DOMAIN}" -d "${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}"; then
    print_error "Certbot failed. Please check your DNS A record points to this server's IP."
    print_error "Server IP: $SERVER_IP"
    exit 1
fi
print_message "SSL certificate obtained successfully."

# Create stronger SSL security files
if [ ! -f "/etc/letsencrypt/options-ssl-nginx.conf" ]; then
    wget -O /etc/letsencrypt/options-ssl-nginx.conf https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > /dev/null 2>&1
fi
if [ ! -f "/etc/letsencrypt/ssl-dhparams.pem" ]; then
    openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 > /dev/null 2>&1
fi

# === FINAL NGINX CONFIGURATION (Phase 2) ===
print_message "Configuring final Nginx production setup..."
cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
# Rate limiting
limit_req_zone \$binary_remote_addr zone=n8n_limit:10m rate=10r/s;

# WebSocket upgrade map
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name ${DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/${DOMAIN};
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 100M;
    
    # Location for static assets - FIX for CSS/JS loading issues
    location ~* \.(css|js|jpg|jpeg|gif|png|ico|svg|woff|woff2|ttf|eot)\$ {
        proxy_pass http://127.0.0.1:${N8N_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Accept-Encoding gzip;
        
        # Caching for static files
        expires 30d;
        add_header Cache-Control "public, immutable";
        proxy_buffering on;
    }
    
    # Location for webhooks and SSE (long timeouts)
    location ~ ^/(webhook|rest/sse) {
        # Rate limiting
        limit_req zone=n8n_limit burst=20 nodelay;
        
        # Proxy settings
        proxy_pass http://127.0.0.1:${N8N_PORT};
        proxy_http_version 1.1;
        
        # Headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        
        # Long timeouts for webhooks and SSE
        proxy_connect_timeout 3600;
        proxy_send_timeout 3600;
        proxy_read_timeout 3600;
        keepalive_timeout 3600;
        
        # Disable buffering for SSE
        proxy_buffering off;
        proxy_cache off;
    }
    
    # Location for UI and regular API (optimized for first load)
    location / {
        # Rate limiting
        limit_req zone=n8n_limit burst=20 nodelay;
        
        # Proxy settings
        proxy_pass http://127.0.0.1:${N8N_PORT};
        proxy_http_version 1.1;
        
        # Headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        
        # Increased timeouts to prevent CSS loading errors
        proxy_connect_timeout 120;
        proxy_send_timeout 120;
        proxy_read_timeout 120;
        keepalive_timeout 120;
        
        # Disable buffering for better first-load experience
        proxy_buffering off;
        proxy_request_buffering off;
    }
    
    # Health check endpoint
    location /healthz {
        access_log off;
        proxy_pass http://127.0.0.1:${N8N_PORT}/healthz;
    }
}
EOF

nginx -t > /dev/null 2>&1
systemctl reload nginx

# Start n8n
print_message "Starting n8n..."
docker compose down > /dev/null 2>&1 || true
docker compose up -d

print_message "Waiting for services to start..."
MAX_WAIT=180  # 3 minutes
WAIT_INTERVAL=5
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if curl -s -f -o /dev/null "http://127.0.0.1:${N8N_PORT}/healthz"; then
        print_message "n8n is healthy and ready!"
        break
    fi
    
    echo -n "."
    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

echo ""

if [ $ELAPSED -ge $MAX_WAIT ]; then
    print_error "n8n failed to start within 3 minutes"
    echo "Showing recent logs:"
    docker compose logs --tail=50
    exit 1
fi

# FIXED: Improved service check with compatibility fallback
print_message "Verifying service status..."
sleep 1  # Give Docker API a moment to stabilize

# Try modern method first
if docker compose ps --status=running 2>/dev/null | head -n1 > /dev/null; then
    # New Docker Compose with --status support
    HEALTHY_SERVICES=$(docker compose ps --status=running -q 2>/dev/null | wc -l)
    if [ "$HEALTHY_SERVICES" -eq 2 ]; then
        print_message "All services started successfully (${HEALTHY_SERVICES}/2 running)"
    else
        print_error "Service check failed. Expected 2 healthy services, found ${HEALTHY_SERVICES}"
        docker compose ps
        docker compose logs --tail=50
        exit 1
    fi
else
    # Fallback for older Docker Compose versions
    print_message "Using legacy service check method..."
    N8N_RUNNING=$(docker inspect -f '{{.State.Running}}' n8n 2>/dev/null || echo "false")
    PG_RUNNING=$(docker inspect -f '{{.State.Running}}' n8n-postgres 2>/dev/null || echo "false")
    
    if [ "$N8N_RUNNING" = "true" ] && [ "$PG_RUNNING" = "true" ]; then
        print_message "All services started successfully"
    else
        print_error "Service check failed"
        print_error "n8n status: $N8N_RUNNING"
        print_error "PostgreSQL status: $PG_RUNNING"
        docker compose ps
        docker compose logs --tail=50
        exit 1
    fi
fi

# Create backup script
cat > ${BACKUP_DIR}/backup.sh <<'EOF'
#!/bin/bash
# n8n Local Backup Script

BACKUP_DIR="/opt/backups/n8n"
DATE=$(date +%Y%m%d_%H%M%S)

echo "[$(date)] Starting backup..."

# Create backup directory if not exists
mkdir -p $BACKUP_DIR

# Backup database
docker exec n8n-postgres pg_dump -U postgres n8n | gzip > $BACKUP_DIR/db_${DATE}.sql.gz
echo "[$(date)] Database backed up"

# Backup n8n files (workflows, credentials, settings)
tar -czf $BACKUP_DIR/files_${DATE}.tar.gz \
    /opt/n8n/docker-compose.yml \
    /opt/n8n/.env \
    /opt/n8n/n8n_storage \
    2>/dev/null
echo "[$(date)] Files backed up"

# Remove backups older than 14 days
find $BACKUP_DIR -name "*.gz" -mtime +14 -delete
echo "[$(date)] Old backups cleaned"

# Show backup sizes
echo "[$(date)] Current backups:"
ls -lh $BACKUP_DIR | tail -n 5

echo "[$(date)] Backup completed successfully"
EOF
chmod +x ${BACKUP_DIR}/backup.sh

# Create maintenance script
cat > ${N8N_DIR}/maintenance.sh <<'EOF'
#!/bin/bash
# Weekly maintenance script

echo "[$(date)] Starting maintenance..."

# Clean docker images
docker image prune -a -f

# Clean docker volumes
docker volume prune -f

# Vacuum journal logs
journalctl --vacuum-time=10d --vacuum-size=500M

echo "[$(date)] Maintenance completed"
EOF
chmod +x ${N8N_DIR}/maintenance.sh

# Setup cron jobs
print_message "Setting up automated tasks..."

# Remove existing n8n related cron jobs and add new ones
(crontab -l 2>/dev/null || echo "") | grep -v "${BACKUP_DIR}/backup.sh" | grep -v "${N8N_DIR}/maintenance.sh" > /tmp/crontab.tmp || true

# Add new cron jobs - using single quotes to prevent glob expansion
echo '0 3 * * * '"${BACKUP_DIR}/backup.sh"' >> '"${BACKUP_DIR}/backup.log"' 2>&1' >> /tmp/crontab.tmp
echo '0 4 * * 0 '"${N8N_DIR}/maintenance.sh"' >> '"${N8N_DIR}/maintenance.log"' 2>&1' >> /tmp/crontab.tmp

# Install new crontab
crontab /tmp/crontab.tmp
rm -f /tmp/crontab.tmp

# Create safe restore script
cat > ${BACKUP_DIR}/restore.sh <<'EOF'
#!/bin/bash
# n8n Safe Restore Script

if [ $# -eq 0 ]; then
    echo "Usage: $0 <backup_date>"
    echo "Example: $0 20240314_030000"
    echo ""
    echo "Available backups:"
    ls -lh /opt/backups/n8n/*.gz
    exit 1
fi

DATE=$1
BACKUP_DIR="/opt/backups/n8n"
TEMP_DIR="/tmp/n8n-restore-$$"

echo "Restoring from backup: ${DATE}"
read -p "This will overwrite current data. Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# Verify backup files exist
if [ ! -f "${BACKUP_DIR}/db_${DATE}.sql.gz" ] || [ ! -f "${BACKUP_DIR}/files_${DATE}.tar.gz" ]; then
    echo "Error: Backup files not found for date ${DATE}"
    exit 1
fi

# Stop services
cd /opt/n8n
docker compose down

# Create temporary directory
mkdir -p ${TEMP_DIR}

# Extract files to temporary directory
echo "Extracting backup to temporary directory..."
tar -xzf ${BACKUP_DIR}/files_${DATE}.tar.gz -C ${TEMP_DIR}

# Restore specific files
echo "Restoring configuration and data..."
if [ -f "${TEMP_DIR}/opt/n8n/.env" ]; then
    cp -a "${TEMP_DIR}/opt/n8n/.env" /opt/n8n/.env
fi

if [ -d "${TEMP_DIR}/opt/n8n/n8n_storage" ]; then
    rm -rf /opt/n8n/n8n_storage
    cp -a "${TEMP_DIR}/opt/n8n/n8n_storage" /opt/n8n/
    # Fix permissions for n8n container (runs as UID 1000)
    chown -R 1000:1000 /opt/n8n/n8n_storage
fi

# Clean up temporary directory
rm -rf ${TEMP_DIR}

# Start PostgreSQL only
docker compose up -d postgres
sleep 10

# Restore database
echo "Restoring database..."
gunzip < ${BACKUP_DIR}/db_${DATE}.sql.gz | docker exec -i n8n-postgres psql -U postgres n8n

# Start all services
docker compose up -d

echo "Restore completed"
echo "Services are starting up. Check status with: docker compose ps"
EOF
chmod +x ${BACKUP_DIR}/restore.sh

# Final message
echo ""
echo "=========================================="
echo -e "${GREEN}   Installation Completed!${NC}"
echo "=========================================="
echo ""
echo -e "${GREEN}✓ n8n is ready at: https://${DOMAIN}${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FEATURES ENABLED:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ PostgreSQL database on port ${POSTGRES_PORT}"
echo "  ✓ Daily automated backups at 3:00 AM"
echo "  ✓ Weekly maintenance at 4:00 AM Sunday"
echo "  ✓ Log rotation (max 30MB)"
echo "  ✓ Auto-cleanup executions > 7 days"
echo "  ✓ Task Runners enabled (modern security)"
echo "  ✓ Environment variables blocked in Code nodes"
echo "  ✓ Secure cookies for HTTPS"
echo "  ✓ Optimized nginx configuration:"
echo "    • Webhooks/SSE: 1-hour timeout"
echo "    • UI/API: 120-second timeout"
echo "    • Static files: Cached properly"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "IMPORTANT PATHS:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  n8n Directory: ${N8N_DIR}"
echo "  Config File: ${N8N_DIR}/.env"
echo "  Workflows/Data: ${N8N_DIR}/n8n_storage"
echo "  Backup Directory: ${BACKUP_DIR}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "MANAGEMENT COMMANDS:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  View logs:       cd ${N8N_DIR} && docker compose logs -f"
echo "  Restart:         cd ${N8N_DIR} && docker compose restart"
echo "  Stop:            cd ${N8N_DIR} && docker compose down"
echo "  Status:          cd ${N8N_DIR} && docker compose ps"
echo "  Check health:    curl http://localhost:${N8N_PORT}/healthz"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "BACKUP & RESTORE:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Manual backup:   ${BACKUP_DIR}/backup.sh"
echo "  Restore:         ${BACKUP_DIR}/restore.sh <date>"
echo "  View backups:    ls -lh ${BACKUP_DIR}/*.gz"
echo "  Backup retention: 14 days"
echo "  Execution retention: 7 days"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "NEXT STEPS:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  1. Visit https://${DOMAIN}"
echo "  2. Create your admin account"
echo "  3. Test a simple workflow"
echo "  4. Configure email settings (optional)"
echo ""
echo -e "${GREEN}✓ Database credentials are stored in: ${N8N_DIR}/.env${NC}"
echo ""
