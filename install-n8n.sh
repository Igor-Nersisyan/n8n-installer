#!/bin/bash

# n8n Installer v3.22 - Production Grade Edition (Fixed Binary Preview & Trust Proxy)
# For Ubuntu 20.04, 22.04, 24.04

set -euo pipefail

# --- Configuration ---
N8N_DIR="/opt/n8n"
BACKUP_DIR="/opt/backups/n8n"
POSTGRES_PORT=5433
N8N_PORT=5678

# --- Colors and Functions ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_message() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# --- Port Check Function ---
check_port_availability() {
    local port=$1
    local service=$2
    if ss -tuln | grep -q ":${port}\b"; then
        print_error "Port ${port} is already in use (needed for ${service})"
        print_warning "Please free the port or modify the configuration"
        exit 1
    fi
    print_message "Port ${port} is available for ${service}"
}

# --- DNS Check Function ---
check_dns_resolution() {
    local domain=$1
    print_message "Checking DNS resolution for ${domain}..."
    
    if ! command -v dig &> /dev/null; then
        apt-get install -y dnsutils > /dev/null 2>&1
    fi
    
    local dns_ips=$(dig +short ${domain} A)
    if [ -z "$dns_ips" ]; then
        print_error "DNS resolution failed for ${domain}"
        print_warning "Please ensure your DNS A record is configured correctly"
        exit 1
    fi
    
    local server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
                      curl -s --max-time 5 icanhazip.com 2>/dev/null || \
                      hostname -I | awk '{print $1}' || \
                      echo "unknown")
    
    print_message "Domain ${domain} resolves to: $(echo $dns_ips | tr '\n' ' ')"
    
    if [ "$server_ip" != "unknown" ] && ! echo "$dns_ips" | grep -q "$server_ip"; then
        print_warning "Domain doesn't resolve to this server's IP ($server_ip)"
        read -p "Do you want to continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# --- Initial Checks ---
if [[ $EUID -ne 0 ]]; then print_error "This script must be run as root."; exit 1; fi
if ! grep -q "Ubuntu" /etc/os-release; then print_error "This script is for Ubuntu only."; exit 1; fi

if [ -d "${N8N_DIR}" ]; then
    print_error "Installation directory ${N8N_DIR} already exists."
    print_warning "To reinstall, please first:"
    print_warning "1. Backup your data: ${BACKUP_DIR}/backup.sh"
    print_warning "2. Remove the directory: sudo rm -rf ${N8N_DIR}"
    exit 1
fi

clear
echo "=========================================="
echo "   n8n Installer v3.22 (Production Grade)"
echo "=========================================="
echo ""
echo "Features:"
echo "  ✓ Queue Mode with Redis 7 for high performance"
echo "  ✓ PostgreSQL database (properly initialized)"
echo "  ✓ Automatic daily backups"
echo "  ✓ Worker management script for easy scaling"
echo "  ✓ Fixed CSS/JS loading issues"
echo "  ✓ Fixed worker concurrency configuration"
echo "  ✓ Proper trust proxy configuration"
echo "  ✓ Automatic SSL renewal"
echo "  ✓ Fixed binary data preview (text files)"
echo ""

# --- User Input ---
read -p "Enter your domain name (e.g., n8n.example.com): " DOMAIN
read -p "Enter your email address (for SSL certificates): " EMAIL
echo ""

# --- Port Availability Checks ---
print_message "Checking port availability..."
check_port_availability ${N8N_PORT} "n8n"
check_port_availability ${POSTGRES_PORT} "PostgreSQL"

# --- System Preparation ---
print_message "Installing prerequisites..."
apt-get update > /dev-null 2>&1
apt-get install -y curl wget openssl nginx certbot python3-certbot-nginx ufw dnsutils > /dev/null 2>&1

print_message "Installing Docker & Docker Compose..."
if ! command -v docker &> /dev/null; then 
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh > /dev/null 2>&1
    rm /tmp/get-docker.sh
fi
if ! docker compose version &> /dev/null 2>&1; then 
    apt-get install -y docker-compose-plugin > /dev/null 2>&1
fi

systemctl enable --now nginx > /dev/null 2>&1

# Firewall configuration
print_message "Configuring firewall..."
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 80/tcp > /dev/null 2>&1
ufw allow 443/tcp > /dev/null 2>&1

if ! ufw status | grep -q "Status: active"; then
    print_message "UFW is not active. Enabling firewall automatically..."
    ufw --force enable > /dev/null 2>&1
    print_message "Firewall enabled successfully."
fi

# --- System Optimization for Redis ---
print_message "Optimizing system for Redis performance (memory overcommit)..."
echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1

# --- n8n Configuration ---
print_message "Setting up n8n directory structure..."
mkdir -p $N8N_DIR/{db_data,n8n_storage,redis_data}
mkdir -p $BACKUP_DIR
chown -R 1000:1000 $N8N_DIR/n8n_storage
cd $N8N_DIR

print_message "Generating secure credentials..."
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
POSTGRES_USER_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
QUEUE_BULL_REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

# Define these as shell variables for use in init-data.sh
POSTGRES_DB="n8n"
POSTGRES_NON_ROOT_USER="n8n_user"

print_message "Creating configuration file (.env)..."
cat > .env <<EOF
# Database
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_NON_ROOT_USER=${POSTGRES_NON_ROOT_USER}
POSTGRES_NON_ROOT_PASSWORD=${POSTGRES_USER_PASSWORD}
POSTGRES_PORT=${POSTGRES_PORT}

# n8n Core
N8N_HOST=${DOMAIN}
N8N_PROTOCOL=https
N8N_PORT=${N8N_PORT}
WEBHOOK_URL=https://${DOMAIN}/
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
GENERIC_TIMEZONE=UTC
NODE_ENV=production

# Database Connection for n8n
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
DB_POSTGRESDB_USER=${POSTGRES_NON_ROOT_USER}
DB_POSTGRESDB_PASSWORD=${POSTGRES_USER_PASSWORD}

# Trust Proxy for Nginx
N8N_TRUST_PROXY=true
N8N_PROXY_HOPS=1

# Execution mode - queue for scalability
EXECUTIONS_MODE=queue
QUEUE_WORKER_CONCURRENCY=5
QUEUE_HEALTH_CHECK_ACTIVE=true

# Prevent deprecation warnings
N8N_RUNNERS_ENABLED=true
OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
N8N_BLOCK_ENV_ACCESS_IN_NODE=false

# Redis Connection
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_DB=0
QUEUE_BULL_REDIS_PASSWORD=${QUEUE_BULL_REDIS_PASSWORD}

# Security Hardening
N8N_SECURE_COOKIE=true
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

# Performance & Data Management
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=168
EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_PAYLOAD_SIZE_MAX=100
EOF

# Create init script with variables substituted
cat > init-data.sh <<EOF
#!/bin/bash
set -e
if [ -n "\${POSTGRES_NON_ROOT_USER:-}" ] && [ -n "\${POSTGRES_NON_ROOT_PASSWORD:-}" ]; then 
    psql -v ON_ERROR_STOP=1 --username "\$POSTGRES_USER" --dbname "\$POSTGRES_DB" <<-EOSQL
        CREATE USER ${POSTGRES_NON_ROOT_USER} WITH PASSWORD '${POSTGRES_USER_PASSWORD}';
        GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_NON_ROOT_USER};
        GRANT CREATE ON SCHEMA public TO ${POSTGRES_NON_ROOT_USER};
        ALTER DATABASE ${POSTGRES_DB} OWNER TO ${POSTGRES_NON_ROOT_USER};
EOSQL
fi
EOF
chmod +x init-data.sh

print_message "Creating Docker Compose file..."
cat > docker-compose.yml <<'EOF'
networks:
  n8n_net:
    driver: bridge

services:
  postgres:
    image: postgres:15
    container_name: n8n-postgres
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./db_data:/var/lib/postgresql/data
      - ./init-data.sh:/docker-entrypoint-initdb.d/init-data.sh:ro
    ports:
      - "127.0.0.1:${POSTGRES_PORT}:5432"
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}']
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

  redis:
    image: redis:7-alpine
    container_name: n8n-redis
    restart: unless-stopped
    env_file: .env
    command: sh -c 'redis-server --requirepass "$${QUEUE_BULL_REDIS_PASSWORD}"'
    volumes:
      - ./redis_data:/data
    networks:
      - n8n_net
    healthcheck:
      test: ["CMD", "sh", "-c", "redis-cli --no-auth-warning -a \"$${QUEUE_BULL_REDIS_PASSWORD}\" ping"]
      interval: 5s
      timeout: 3s
      retries: 10
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  n8n-main:
    image: n8nio/n8n:latest
    container_name: n8n-main
    restart: unless-stopped
    env_file: .env
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
    ports:
      - "127.0.0.1:${N8N_PORT}:5678"
    volumes:
      - ./n8n_storage:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - n8n_net
    healthcheck:
      test: ['CMD', 'wget', '--spider', '-q', 'http://localhost:5678/healthz']
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  n8n-worker:
    image: n8nio/n8n:latest
    restart: unless-stopped
    # FIXED: Properly pass concurrency from .env variable
    command: worker --concurrency=${QUEUE_WORKER_CONCURRENCY:-5}
    env_file: .env
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - EXECUTIONS_MODE=queue
    volumes:
      - ./n8n_storage:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - n8n_net
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

# --- Nginx and SSL ---
print_message "Configuring Nginx for SSL challenge..."
mkdir -p "/var/www/${DOMAIN}/.well-known/acme-challenge"
chown www-data:www-data "/var/www/${DOMAIN}" -R

cat > "/etc/nginx/sites-available/${DOMAIN}" << EOF
server { 
    listen 80; 
    server_name ${DOMAIN}; 
    location /.well-known/acme-challenge/ { 
        root /var/www/${DOMAIN}; 
    } 
    location / { 
        return 404; 
    } 
}
EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/"
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

check_dns_resolution "${DOMAIN}"

print_message "Obtaining SSL certificate from Let's Encrypt..."
if ! certbot certonly --webroot -w "/var/www/${DOMAIN}" -d "${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --deploy-hook "systemctl reload nginx"; then
    print_error "Certbot failed. Please check that your DNS A record for '${DOMAIN}' points to this server."
    exit 1
fi

print_message "Creating stronger SSL security parameters..."
if [ ! -f "/etc/letsencrypt/options-ssl-nginx.conf" ]; then 
    wget -O /etc/letsencrypt/options-ssl-nginx.conf https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > /dev/null 2>&1
fi
if [ ! -f "/etc/letsencrypt/ssl-dhparams.pem" ]; then 
    openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 > /dev/null 2>&1
fi

print_message "Configuring final Nginx production setup..."
cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
# Rate limiting with reasonable limits
limit_req_zone \$binary_remote_addr zone=n8n_limit:10m rate=100r/s;

map \$http_upgrade \$connection_upgrade { 
    default upgrade; 
    '' close; 
}

server { 
    listen 80; 
    server_name ${DOMAIN}; 
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
    
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy strict-origin-when-cross-origin;
    
    # Dedicated block for WebSocket push (real-time UI updates) - no rate limiting, long timeouts
    location ^~ /rest/push {
        proxy_pass http://127.0.0.1:${N8N_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600;
        proxy_connect_timeout 3600;
        proxy_send_timeout 3600;
        proxy_buffering off;
        proxy_ignore_client_abort on;
    }

    # Binary data (enhanced for stable viewing/download)
    location ^~ /rest/binary-data {
        limit_req zone=n8n_limit burst=200 nodelay;
        proxy_pass http://127.0.0.1:${N8N_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_ignore_client_abort on;
    }
    
    # Static files without rate limiting
    location ~ \.(css|js|jpg|jpeg|gif|png|ico|svg|woff|woff2|ttf|eot|map)$ {
        proxy_pass http://127.0.0.1:${N8N_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        expires 7d;
        add_header Cache-Control "public, immutable";
    }
    
    # API endpoints with higher rate limit
    location ~ ^/(webhook|rest|api) {
        limit_req zone=n8n_limit burst=200 nodelay;
        proxy_pass http://127.0.0.1:${N8N_PORT}; 
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade; 
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host; 
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; 
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600; 
        proxy_send_timeout 3600;
        proxy_buffering off;
    }
    
    # Main location with moderate rate limit
    location / {
        limit_req zone=n8n_limit burst=100 nodelay;
        proxy_pass http://127.0.0.1:${N8N_PORT}; 
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade; 
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host; 
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; 
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 300; 
        proxy_send_timeout 300;
        proxy_buffering off;
    }
}
EOF
systemctl reload nginx

# --- Start Services ---
print_message "Starting n8n services..."
docker compose up -d --scale n8n-worker=1

print_message "Waiting for database initialization (this may take 30-60 seconds on first run)..."
sleep 20

# Check for specific table
MAX_WAIT=120
ELAPSED=0
TABLE_COUNT=0
DB_INITIALIZED=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    TABLE_EXISTS=$(docker exec n8n-postgres psql -U ${POSTGRES_NON_ROOT_USER} -d ${POSTGRES_DB} -t -c \
        "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='workflow_entity';" 2>/dev/null | xargs || echo "0")
    
    if [ "$TABLE_EXISTS" = "1" ]; then
        TABLE_COUNT=$(docker exec n8n-postgres psql -U ${POSTGRES_NON_ROOT_USER} -d ${POSTGRES_DB} -t -c \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | xargs || echo "0")
        print_message "Database initialized successfully with $TABLE_COUNT tables!"
        DB_INITIALIZED=true
        break
    fi
    
    echo -n "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "$DB_INITIALIZED" = "false" ]; then
    print_error "Database initialization failed after ${MAX_WAIT} seconds"
    print_error "Check logs with: docker compose logs"
    exit 1
fi

# Wait for all services to be healthy
print_message "Waiting for all services to become healthy..."
ELAPSED=0
MAX_WAIT=60

while [ $ELAPSED -lt $MAX_WAIT ]; do
    POSTGRES_HEALTHY=$(docker inspect -f '{{.State.Health.Status}}' n8n-postgres 2>/dev/null || echo "unhealthy")
    REDIS_HEALTHY=$(docker inspect -f '{{.State.Health.Status}}' n8n-redis 2>/dev/null || echo "unhealthy")
    MAIN_HEALTHY=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${N8N_PORT}/healthz 2>/dev/null || echo "000")

    if [ "$POSTGRES_HEALTHY" = "healthy" ] && [ "$REDIS_HEALTHY" = "healthy" ] && [ "$MAIN_HEALTHY" = "200" ]; then
        print_message "All services are healthy and running!"
        break
    fi
    
    echo -n "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    print_error "Services failed to become healthy after ${MAX_WAIT} seconds"
    print_error "Check logs with: docker compose logs --tail=50"
    exit 1
fi

# --- Auxiliary Scripts ---
print_message "Creating helper scripts (backup, restore, worker manager)..."

cat > ${BACKUP_DIR}/backup.sh <<'EOF'
#!/bin/bash
BACKUP_DIR="/opt/backups/n8n"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR
docker exec n8n-postgres pg_dump -U postgres n8n | gzip > $BACKUP_DIR/db_${DATE}.sql.gz
tar -czf $BACKUP_DIR/files_${DATE}.tar.gz -C /opt/n8n .env docker-compose.yml init-data.sh n8n_storage 2>/dev/null
find $BACKUP_DIR -name "*.gz" -mtime +14 -delete
echo "Backup completed: db_${DATE}.sql.gz and files_${DATE}.tar.gz"
EOF
chmod +x ${BACKUP_DIR}/backup.sh

cat > ${BACKUP_DIR}/restore.sh <<'EOF'
#!/bin/bash
DATE=$1
if [ -z "$DATE" ]; then 
    echo "Usage: $0 <backup_date>"
    echo "Available backups:"
    ls -la /opt/backups/n8n/ | grep -E "(db_|files_)" | awk '{print $9}'
    exit 1
fi

cd /opt/n8n && docker compose down
tar -xzf /opt/backups/n8n/files_${DATE}.tar.gz -C /opt/n8n
chown -R 1000:1000 /opt/n8n/n8n_storage
source /opt/n8n/.env

echo "Starting PostgreSQL..."
docker compose up -d postgres

echo "Waiting for PostgreSQL to become healthy..."
until [ "$(docker inspect -f '{{.State.Health.Status}}' n8n-postgres 2>/dev/null)" = "healthy" ]; do
    echo -n "."
    sleep 2
done
echo " PostgreSQL is healthy!"

echo "Restoring database from dump..."
gunzip < /opt/backups/n8n/db_${DATE}.sql.gz | docker exec -i n8n-postgres psql -U postgres n8n

echo "Starting all services..."
docker compose up -d --scale n8n-worker=1

echo "Restore completed."
EOF
chmod +x ${BACKUP_DIR}/restore.sh

cat > ${N8N_DIR}/manage-workers.sh <<'EOF'
#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

cd /opt/n8n || { echo -e "${RED}Error: Directory /opt/n8n not found.${NC}"; exit 1; }

get_current_workers() {
    docker compose ps n8n-worker 2>/dev/null | tail -n +2 | wc -l
}

echo -e "${GREEN}========================================${NC}"
echo -e "${YELLOW}      n8n Worker Manager${NC}"
echo -e "${GREEN}========================================${NC}\n"

CURRENT_WORKERS=$(get_current_workers)
echo -e "Current number of running workers: ${GREEN}${CURRENT_WORKERS}${NC}"

# Get current concurrency setting
CONCURRENCY=$(grep QUEUE_WORKER_CONCURRENCY /opt/n8n/.env | cut -d'=' -f2 || echo "5")
echo -e "Each worker handles up to ${GREEN}${CONCURRENCY}${NC} concurrent jobs\n"

while true; do
    read -p "Select: [1] Add worker, [2] Remove worker, [3] Change concurrency, [q] Quit: " choice
    echo ""
    case $choice in
        1)
            NEW_COUNT=$((CURRENT_WORKERS + 1))
            echo -e "Adding worker... Setting total to: ${GREEN}${NEW_COUNT}${NC}"
            docker compose up -d --scale n8n-worker=${NEW_COUNT}
            echo -e "\n${GREEN}✔ Done!${NC}"
            break
            ;;
        2)
            if [ "$CURRENT_WORKERS" -le 1 ]; then 
                echo -e "${RED}Error: Cannot remove the last worker.${NC}"
                exit 1
            fi
            NEW_COUNT=$((CURRENT_WORKERS - 1))
            echo -e "Removing worker... Setting total to: ${GREEN}${NEW_COUNT}${NC}"
            docker compose up -d --scale n8n-worker=${NEW_COUNT}
            echo -e "\n${GREEN}✔ Done!${NC}"
            break
            ;;
        3)
            read -p "Enter new concurrency value (current: $CONCURRENCY): " NEW_CONC
            if [[ "$NEW_CONC" =~ ^[0-9]+$ ]] && [ "$NEW_CONC" -ge 1 ] && [ "$NEW_CONC" -le 20 ]; then
                sed -i "s/QUEUE_WORKER_CONCURRENCY=.*/QUEUE_WORKER_CONCURRENCY=$NEW_CONC/" /opt/n8n/.env
                echo -e "${GREEN}Concurrency updated to $NEW_CONC. Restarting workers...${NC}"
                docker compose restart n8n-worker
                echo -e "\n${GREEN}✔ Done!${NC}"
            else
                echo -e "${RED}Invalid value. Must be between 1-20.${NC}"
            fi
            break
            ;;
        [qQ])
            echo "Exiting without changes."
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice.${NC}"
            ;;
    esac
done

echo -e "\nChecking status..."
sleep 2
docker compose ps
EOF
chmod +x ${N8N_DIR}/manage-workers.sh

# --- Cron Jobs ---
print_message "Setting up cron jobs for backup and maintenance..."

CRON_BACKUP_JOB="0 3 * * * ${BACKUP_DIR}/backup.sh > /var/log/n8n_backup.log 2>&1"
CRON_PRUNE_JOB="0 4 * * 0 docker system prune -af > /var/log/docker_prune.log 2>&1"
CRON_CERT_RENEW_JOB="0 2 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'"

CRON_TEMP=$(mktemp /tmp/cron.XXXXXX)
(crontab -l 2>/dev/null | grep -vE "n8n_backup|docker_prune|certbot") > "$CRON_TEMP" || true
echo "$CRON_BACKUP_JOB" >> "$CRON_TEMP"
echo "$CRON_PRUNE_JOB" >> "$CRON_TEMP"
echo "$CRON_CERT_RENEW_JOB" >> "$CRON_TEMP"
crontab "$CRON_TEMP"
rm -f "$CRON_TEMP"

# --- Final Message ---
echo ""
echo "=========================================="
echo -e "${GREEN}   Installation Completed!${NC}"
echo "=========================================="
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}           NEXT STEPS${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  1. Visit https://${DOMAIN} to create your admin account"
echo "  2. Review your credentials in ${N8N_DIR}/.env"
echo "  3. Use the worker manager to adjust performance:"
echo -e "     ${GREEN}bash ${N8N_DIR}/manage-workers.sh${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DATABASE STATUS:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PostgreSQL Tables: ${TABLE_COUNT:-0}"
echo "  Expected: 40+ tables for successful initialization"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FEATURES ENABLED:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ Production Queue Mode with Redis 7"
echo "  ✓ PostgreSQL database (not SQLite)"
echo "  ✓ Default: 1 worker × 5 jobs = 5 concurrent executions"
echo "  ✓ Automatic daily backups at 3 AM"
echo "  ✓ Automatic SSL renewal"
echo "  ✓ PostgreSQL on port ${POSTGRES_PORT}"
echo "  ✓ Worker concurrency properly configured"
echo "  ✓ Trust proxy properly configured"
echo "  ✓ Binary data preview fixed"
echo ""
