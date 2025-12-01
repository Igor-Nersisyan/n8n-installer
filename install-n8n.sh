#!/bin/bash

# n8n Installer v3.26 - Production Grade Edition
# For Ubuntu 20.04, 22.04, 24.04
# Features: Complete Docker configuration, latest stable n8n, manual update control
# v3.26: Added certbot retry logic for temporary DNS issues

set -euo pipefail

# --- Configuration ---
N8N_DIR="/opt/n8n"
BACKUP_DIR="/opt/backups/n8n"
POSTGRES_PORT=5433
N8N_PORT=5678
# LATEST STABLE VERSION (uses Docker Hub latest tag)
N8N_VERSION="latest"

# --- Colors and Styles ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Unicode symbols ---
CHECK="✓"
CROSS="✗"
ARROW="➜"
DOT="•"
STAR="★"
GEAR="⚙"
ROCKET="🚀"
SHIELD="🛡"
DATABASE="🗄"
CLOCK="⏰"
WARNING="⚠"
INFO="ℹ"

# --- Functions ---
print_message() { echo -e "${CYAN}${INFO}${NC} ${WHITE}$1${NC}"; }
print_success() { echo -e "${GREEN}${CHECK}${NC} ${GREEN}$1${NC}"; }
print_error() { echo -e "${RED}${CROSS}${NC} ${RED}$1${NC}"; }
print_warning() { echo -e "${YELLOW}${WARNING}${NC} ${YELLOW}$1${NC}"; }
print_step() { echo -e "\n${PURPLE}${ARROW}${NC} ${BOLD}$1${NC}"; }

# --- Fix Repository Mirrors ---
fix_apt_mirrors() {
    # Replace ANY non-official Ubuntu mirrors with archive.ubuntu.com
    # This fixes issues with Beget, Hetzner, OVH, Selectel, Timeweb, etc.
    # Keep only: archive.ubuntu.com, security.ubuntu.com, [country].archive.ubuntu.com
    
    local files=$(find /etc/apt -name "*.list" -o -name "*.sources" 2>/dev/null)
    
    for file in $files /etc/apt/sources.list; do
        [ -f "$file" ] || continue
        
        # Replace any mirror that is NOT official Ubuntu
        sed -i \
            -e 's|http://[^/]*\.clouds\.archive\.ubuntu\.com/ubuntu|http://archive.ubuntu.com/ubuntu|g' \
            -e 's|http://[^/]*beget[^/]*/[^ ]*ubuntu|http://archive.ubuntu.com/ubuntu|g' \
            -e 's|http://public-mirrors[^/]*/[^ ]*ubuntu|http://archive.ubuntu.com/ubuntu|g' \
            -e 's|http://mirror\.[^/]*/ubuntu|http://archive.ubuntu.com/ubuntu|g' \
            -e 's|http://mirrors\.[^/]*/ubuntu|http://archive.ubuntu.com/ubuntu|g' \
            "$file" 2>/dev/null || true
    done
    
    # Clean apt cache completely
    apt-get clean > /dev/null 2>&1
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true
}

# --- ASCII Art Header ---
show_header() {
    clear
    echo -e "${CYAN}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "        ███╗   ██╗ █████╗ ███╗   ██╗"
    echo "        ████╗  ██║██╔══██╗████╗  ██║"
    echo "        ██╔██╗ ██║╚█████╔╝██╔██╗ ██║"
    echo "        ██║╚██╗██║██╔══██╗██║╚██╗██║"
    echo "        ██║ ╚████║╚█████╔╝██║ ╚████║"
    echo "        ╚═╝  ╚═══╝ ╚════╝ ╚═╝  ╚═══╝"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
    echo -e "${BOLD}${WHITE}    Automated Workflow Platform Installer${NC}"
    echo -e "${DIM}    Version 3.26 - Production Edition${NC}"
    echo -e "${YELLOW}    n8n Version: ${N8N_VERSION} (auto-updates to latest stable)${NC}"
    echo ""
}

# --- Port Check Function ---
check_port_availability() {
    local port=$1
    local service=$2
    if ss -tuln | grep -q ":${port}\b"; then
        print_error "Port ${port} is already in use (needed for ${service})"
        print_warning "Please free the port or modify the configuration"
        exit 1
    fi
    print_success "Port ${port} is available for ${service}"
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
    
    print_success "Domain ${domain} resolves to: $(echo $dns_ips | tr '\n' ' ')"
    
    if [ "$server_ip" != "unknown" ] && ! echo "$dns_ips" | grep -q "$server_ip"; then
        print_warning "Domain doesn't resolve to this server's IP ($server_ip)"
        print_warning "Continuing with installation..."
    fi
}

# --- System Requirements Check ---
check_system_requirements() {
    echo -e "\n${BOLD}${WHITE}System Requirements Check${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    # Check CPU cores
    local cpu_cores=$(nproc)
    if [ "$cpu_cores" -ge 1 ]; then
        print_success "CPU Cores: $cpu_cores ${DIM}(minimum: 1)${NC}"
    else
        print_warning "CPU cores: $cpu_cores ${DIM}(minimum: 1)${NC}"
    fi
    
    # Check RAM
    local total_ram=$(free -m | awk 'NR==2{print $2}')
    local ram_gb=$(echo "scale=1; $total_ram/1024" | bc 2>/dev/null || echo "2.0")
    if [ "$total_ram" -ge 2000 ]; then
        print_success "RAM: ${ram_gb}GB ${DIM}(minimum: 2GB)${NC}"
    else
        print_warning "RAM: ${ram_gb}GB ${DIM}(minimum: 2GB)${NC}"
        print_warning "n8n may experience performance issues with less than 2GB RAM"
    fi
    
    # Check available disk space
    local available_space=$(df -BG /opt 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$available_space" -ge 10 ]; then
        print_success "Available disk space: ${available_space}GB ${DIM}(minimum: 10GB)${NC}"
    else
        print_warning "Low disk space: ${available_space}GB ${DIM}(minimum: 10GB)${NC}"
    fi
    
    echo ""
}

# --- Fix Docker Networking ---
fix_docker_networking() {
    print_step "Configuring Docker daemon with complete settings"
    
    # Check if daemon.json exists and backup it
    if [ -f /etc/docker/daemon.json ]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)
        print_message "Backed up existing Docker configuration"
    fi
    
    # Create complete Docker configuration
    cat > /etc/docker/daemon.json <<EOF
{
  "bip": "172.17.0.1/16",
  "iptables": true,
  "ip-masq": true,
  "dns": ["8.8.8.8", "8.8.4.4", "1.1.1.1"],
  "dns-opts": ["ndots:0"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    print_success "Docker daemon configured with:"
    print_success "  • NAT enabled (ip-masq) for internet access"
    print_success "  • Public DNS servers for reliability"
    print_success "  • Log rotation (10MB max, 3 files)"
    print_success "  • Optimized DNS resolution"
    
    # Restart Docker to apply changes
    systemctl restart docker
    print_success "Docker daemon restarted successfully"
}

# --- Initial Checks ---
if [[ $EUID -ne 0 ]]; then 
    show_header
    print_error "This script must be run as root."
    echo -e "${DIM}Please run: sudo bash $0${NC}"
    exit 1
fi

if ! grep -q "Ubuntu" /etc/os-release; then 
    show_header
    print_error "This script is for Ubuntu only."
    exit 1
fi

if [ -d "${N8N_DIR}" ]; then
    show_header
    print_error "Installation directory ${N8N_DIR} already exists."
    print_warning "To reinstall, please first:"
    echo -e "  ${DIM}1. Backup your data: ${BACKUP_DIR}/backup.sh${NC}"
    echo -e "  ${DIM}2. Remove the directory: sudo rm -rf ${N8N_DIR}${NC}"
    exit 1
fi

# --- Welcome Screen ---
show_header

echo -e "${BOLD}${WHITE}${ROCKET} Welcome to n8n Production Installer${NC}"
echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

echo -e "${BOLD}${GREEN}Features:${NC}"
echo -e "  ${GREEN}${CHECK}${NC} Complete Docker networking configuration"
echo -e "  ${GREEN}${CHECK}${NC} Latest stable n8n version (auto-updates via docker pull)"
echo -e "  ${GREEN}${CHECK}${NC} Manual update script for version control"
echo -e "  ${GREEN}${CHECK}${NC} Queue Mode with Redis 7"
echo -e "  ${GREEN}${CHECK}${NC} PostgreSQL database"
echo -e "  ${GREEN}${CHECK}${NC} Automatic daily backups"
echo -e "  ${GREEN}${CHECK}${NC} Worker management script"
echo -e "  ${GREEN}${CHECK}${NC} Automatic SSL renewal"
echo -e "  ${GREEN}${CHECK}${NC} Log rotation (10MB per container)"
echo -e "  ${GREEN}${CHECK}${NC} Supabase integration ready (host.docker.internal)"
echo ""

echo -e "${BOLD}${YELLOW}${WARNING} Minimum Requirements:${NC}"
echo -e "  ${DOT} CPU: 1 core"
echo -e "  ${DOT} RAM: 2GB"
echo -e "  ${DOT} Storage: 10GB"
echo -e "  ${DOT} OS: Ubuntu 20.04/22.04/24.04 LTS"
echo ""

# System requirements check
check_system_requirements

# --- User Input ---
echo -e "${BOLD}${WHITE}Configuration${NC}"
echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

echo -ne "${CYAN}${ARROW}${NC} Enter your domain name (e.g., n8n.example.com): "
read DOMAIN
echo -ne "${CYAN}${ARROW}${NC} Enter your email address (for SSL certificates): "
read EMAIL
echo ""

# --- Port Availability Checks ---
print_step "Checking port availability"
check_port_availability ${N8N_PORT} "n8n"
check_port_availability ${POSTGRES_PORT} "PostgreSQL"

# --- Fix mirrors BEFORE any apt operations ---
print_step "Fixing repository mirrors"
fix_apt_mirrors
print_success "Repository mirrors configured"

# --- System Preparation ---
print_step "Installing prerequisites"
apt-get update > /dev/null 2>&1
apt-get install -y curl wget openssl nginx certbot python3-certbot-nginx ufw dnsutils bc > /dev/null 2>&1
print_success "System packages installed"

print_step "Installing Docker & Docker Compose"
if ! command -v docker &> /dev/null; then 
    print_message "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh > /dev/null 2>&1
    rm /tmp/get-docker.sh
    print_success "Docker installed"
fi

if ! docker compose version &> /dev/null 2>&1; then 
    print_message "Installing Docker Compose..."
    apt-get install -y docker-compose-plugin > /dev/null 2>&1
    print_success "Docker Compose installed"
fi

# FIX DOCKER NETWORKING BEFORE PROCEEDING
fix_docker_networking

systemctl enable --now nginx > /dev/null 2>&1

# Firewall configuration
print_step "Configuring firewall ${SHIELD}"
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 80/tcp > /dev/null 2>&1
ufw allow 443/tcp > /dev/null 2>&1

if ! ufw status | grep -q "Status: active"; then
    print_message "Enabling firewall..."
    ufw --force enable > /dev/null 2>&1
    print_success "Firewall enabled successfully"
fi

# --- System Optimization for Redis ---
print_step "Optimizing system for Redis performance"
echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
print_success "Memory overcommit configured"

# --- n8n Configuration ---
print_step "Setting up n8n directory structure ${GEAR}"
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
# n8n Version
N8N_VERSION=${N8N_VERSION}

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

print_message "Creating Docker Compose file with Supabase integration support..."
cat > docker-compose.yml <<EOF
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
      - "127.0.0.1:\${POSTGRES_PORT}:5432"
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
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
    command: sh -c 'redis-server --requirepass "\$\${QUEUE_BULL_REDIS_PASSWORD}"'
    volumes:
      - ./redis_data:/data
    networks:
      - n8n_net
    healthcheck:
      test: ["CMD", "sh", "-c", "redis-cli --no-auth-warning -a \\"\$\${QUEUE_BULL_REDIS_PASSWORD}\\" ping"]
      interval: 5s
      timeout: 3s
      retries: 10
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  n8n-main:
    image: n8nio/n8n:\${N8N_VERSION}
    container_name: n8n-main
    restart: unless-stopped
    env_file: .env
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
    ports:
      - "127.0.0.1:\${N8N_PORT}:5678"
    volumes:
      - ./n8n_storage:/home/node/.n8n
    extra_hosts:
      - "host.docker.internal:host-gateway"
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
    image: n8nio/n8n:\${N8N_VERSION}
    restart: unless-stopped
    command: worker --concurrency=\${QUEUE_WORKER_CONCURRENCY:-5}
    env_file: .env
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - EXECUTIONS_MODE=queue
    volumes:
      - ./n8n_storage:/home/node/.n8n
    extra_hosts:
      - "host.docker.internal:host-gateway"
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
print_step "Configuring Nginx for SSL challenge"
mkdir -p "/var/www/${DOMAIN}/.well-known/acme-challenge"
chown www-data:www-data "/var/www/${DOMAIN}" -R

cat > "/etc/nginx/sites-available/${DOMAIN}" << NGINX_EOF
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
NGINX_EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/"
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

check_dns_resolution "${DOMAIN}"

print_step "Obtaining SSL certificate from Let's Encrypt ${SHIELD}"

# Retry logic for certbot (DNS/CAA issues are often temporary)
CERTBOT_MAX_ATTEMPTS=5
CERTBOT_ATTEMPT=1
CERTBOT_SUCCESS=false

while [ $CERTBOT_ATTEMPT -le $CERTBOT_MAX_ATTEMPTS ]; do
    print_message "Attempt ${CERTBOT_ATTEMPT}/${CERTBOT_MAX_ATTEMPTS}..."
    
    if certbot certonly --webroot -w "/var/www/${DOMAIN}" -d "${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --deploy-hook "systemctl reload nginx" 2>&1; then
        CERTBOT_SUCCESS=true
        break
    fi
    
    if [ $CERTBOT_ATTEMPT -lt $CERTBOT_MAX_ATTEMPTS ]; then
        print_warning "Certificate request failed, retrying in 30 seconds..."
        print_warning "This is often caused by temporary DNS issues"
        sleep 30
    fi
    
    CERTBOT_ATTEMPT=$((CERTBOT_ATTEMPT + 1))
done

if [ "$CERTBOT_SUCCESS" = "false" ]; then
    print_error "Certbot failed after ${CERTBOT_MAX_ATTEMPTS} attempts."
    print_error "Please check that your DNS A record for '${DOMAIN}' points to this server."
    print_warning "You can retry manually later: certbot certonly --webroot -w /var/www/${DOMAIN} -d ${DOMAIN}"
    exit 1
fi
print_success "SSL certificate obtained successfully!"

print_message "Creating stronger SSL security parameters..."
if [ ! -f "/etc/letsencrypt/options-ssl-nginx.conf" ]; then 
    wget -O /etc/letsencrypt/options-ssl-nginx.conf https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > /dev/null 2>&1
fi
if [ ! -f "/etc/letsencrypt/ssl-dhparams.pem" ]; then 
    print_message "Generating DH parameters (this may take a minute)..."
    openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 > /dev/null 2>&1
    print_success "DH parameters generated"
fi

print_message "Configuring final Nginx production setup..."
cat > "/etc/nginx/sites-available/${DOMAIN}" <<NGINX_FINAL_EOF
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
NGINX_FINAL_EOF
systemctl reload nginx

# --- Start Services ---
print_step "Starting n8n services ${ROCKET}"
docker compose up -d --scale n8n-worker=1

print_message "Waiting for database initialization ${DATABASE}"
echo -n "This may take 30-60 seconds on first run"

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
        echo ""
        print_success "Database initialized successfully with $TABLE_COUNT tables!"
        DB_INITIALIZED=true
        break
    fi
    
    echo -n "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "$DB_INITIALIZED" = "false" ]; then
    echo ""
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
        print_success "All services are healthy and running!"
        break
    fi
    
    echo -n "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo ""
    print_error "Services failed to become healthy after ${MAX_WAIT} seconds"
    print_error "Check logs with: docker compose logs --tail=50"
    exit 1
fi

# --- Auxiliary Scripts ---
print_step "Creating helper scripts"

print_message "Creating backup script..."
cat > ${BACKUP_DIR}/backup.sh <<'BACKUP_EOF'
#!/bin/bash
BACKUP_DIR="/opt/backups/n8n"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR
docker exec n8n-postgres pg_dump -U postgres n8n | gzip > $BACKUP_DIR/db_${DATE}.sql.gz
tar -czf $BACKUP_DIR/files_${DATE}.tar.gz -C /opt/n8n .env docker-compose.yml init-data.sh n8n_storage 2>/dev/null
find $BACKUP_DIR -name "*.gz" -mtime +14 -delete
echo "Backup completed: db_${DATE}.sql.gz and files_${DATE}.tar.gz"
BACKUP_EOF
chmod +x ${BACKUP_DIR}/backup.sh

print_message "Creating restore script..."
cat > ${BACKUP_DIR}/restore.sh <<'RESTORE_EOF'
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
RESTORE_EOF
chmod +x ${BACKUP_DIR}/restore.sh

print_message "Creating UPDATE script..."
cat > ${N8N_DIR}/update-n8n.sh <<'UPDATE_EOF'
#!/bin/bash

# n8n Update Script
# Safe manual update procedure

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      n8n Update Script               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}\n"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   exit 1
fi

cd /opt/n8n

# Get current version
CURRENT_VERSION=$(docker exec n8n-main n8n --version 2>/dev/null || echo "unknown")
echo -e "${YELLOW}Current n8n version: ${BOLD}${CURRENT_VERSION}${NC}\n"

# Ask for target version
echo -e "${CYAN}Enter the target n8n version (e.g., 1.119.1) or 'latest':${NC}"
read -p "Version: " TARGET_VERSION

if [ -z "$TARGET_VERSION" ]; then
    echo -e "${RED}Error: No version specified${NC}"
    exit 1
fi

echo -e "\n${YELLOW}⚠️  IMPORTANT:${NC}"
echo -e "1. Make sure all workflows are deactivated in n8n UI"
echo -e "2. A backup will be created automatically"
echo -e "3. The update process will take 2-5 minutes\n"

read -p "Do you want to proceed? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Update cancelled${NC}"
    exit 1
fi

# Create backup
echo -e "\n${CYAN}Creating backup...${NC}"
bash /opt/backups/n8n/backup.sh

# Stop containers
echo -e "\n${CYAN}Stopping n8n containers...${NC}"
docker compose down

# Update version in .env file
echo -e "\n${CYAN}Updating configuration...${NC}"
if grep -q "^N8N_VERSION=" .env; then
    # Variable exists - update it
    if [ "$TARGET_VERSION" == "latest" ]; then
        sed -i 's/^N8N_VERSION=.*/N8N_VERSION=latest/' .env
    else
        sed -i "s/^N8N_VERSION=.*/N8N_VERSION=${TARGET_VERSION}/" .env
    fi
else
    # Variable doesn't exist - add it
    echo "N8N_VERSION=${TARGET_VERSION}" >> .env
fi

# Update docker-compose.yml to use the new version
sed -i "s|image: n8nio/n8n:.*|image: n8nio/n8n:\${N8N_VERSION}|g" docker-compose.yml

# Pull new images
echo -e "\n${CYAN}Pulling new Docker images...${NC}"
docker compose pull

# Start services
echo -e "\n${CYAN}Starting n8n with new version...${NC}"
docker compose up -d --scale n8n-worker=1

# Wait for services to be healthy
echo -e "\n${CYAN}Waiting for services to become healthy...${NC}"
ELAPSED=0
MAX_WAIT=60

while [ $ELAPSED -lt $MAX_WAIT ]; do
    POSTGRES_HEALTHY=$(docker inspect -f '{{.State.Health.Status}}' n8n-postgres 2>/dev/null || echo "unhealthy")
    REDIS_HEALTHY=$(docker inspect -f '{{.State.Health.Status}}' n8n-redis 2>/dev/null || echo "unhealthy")
    MAIN_HEALTHY=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678/healthz 2>/dev/null || echo "000")

    if [ "$POSTGRES_HEALTHY" = "healthy" ] && [ "$REDIS_HEALTHY" = "healthy" ] && [ "$MAIN_HEALTHY" = "200" ]; then
        echo -e "\n${GREEN}✓ All services are healthy!${NC}"
        break
    fi
    
    echo -n "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo -e "\n${RED}Error: Services failed to become healthy${NC}"
    echo -e "${YELLOW}Check logs with: docker compose logs --tail=50${NC}"
    exit 1
fi

# Verify network connectivity
echo -e "\n${CYAN}Verifying network connectivity...${NC}"
if docker exec n8n-main ping -c 2 8.8.8.8 > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Network connectivity OK${NC}"
else
    echo -e "${RED}⚠️  Warning: Network connectivity issues detected${NC}"
    echo -e "${YELLOW}This might affect external integrations${NC}"
fi

# Get new version
NEW_VERSION=$(docker exec n8n-main n8n --version 2>/dev/null || echo "unknown")

# Clean up old images
echo -e "\n${CYAN}Cleaning up old Docker images...${NC}"
docker image prune -f > /dev/null 2>&1

# Final status
echo -e "\n${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}     Update completed successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "Previous version: ${YELLOW}${CURRENT_VERSION}${NC}"
echo -e "New version: ${GREEN}${NEW_VERSION}${NC}"
echo -e "\nAccess n8n at: ${CYAN}https://$(grep N8N_HOST .env | cut -d '=' -f2)${NC}"
echo -e "\n${YELLOW}Note: Remember to reactivate your workflows in n8n UI${NC}"
UPDATE_EOF
chmod +x ${N8N_DIR}/update-n8n.sh

print_message "Creating worker manager script..."
cat > ${N8N_DIR}/manage-workers.sh <<'WORKER_EOF'
#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

cd /opt/n8n || { echo -e "${RED}Error: Directory /opt/n8n not found.${NC}"; exit 1; }

get_current_workers() {
    docker compose ps n8n-worker 2>/dev/null | tail -n +2 | wc -l
}

echo -e "${CYAN}"
echo "╔══════════════════════════════════════╗"
echo "║      n8n Worker Manager              ║"
echo "╚══════════════════════════════════════╝"
echo -e "${NC}\n"

CURRENT_WORKERS=$(get_current_workers)
echo -e "Current number of running workers: ${GREEN}${CURRENT_WORKERS}${NC}"

# Get current concurrency setting
CONCURRENCY=$(grep QUEUE_WORKER_CONCURRENCY /opt/n8n/.env | cut -d'=' -f2 || echo "5")
echo -e "Each worker handles up to ${GREEN}${CONCURRENCY}${NC} concurrent jobs"
echo -e "Total capacity: ${BOLD}${GREEN}$((CURRENT_WORKERS * CONCURRENCY))${NC} concurrent executions\n"

while true; do
    echo -e "${CYAN}Options:${NC}"
    echo "  [1] Add worker"
    echo "  [2] Remove worker"
    echo "  [3] Change concurrency"
    echo "  [q] Quit"
    echo ""
    read -p "Select option: " choice
    echo ""
    case $choice in
        1)
            NEW_COUNT=$((CURRENT_WORKERS + 1))
            echo -e "Adding worker... Setting total to: ${GREEN}${NEW_COUNT}${NC}"
            docker compose up -d --scale n8n-worker=${NEW_COUNT}
            echo -e "\n${GREEN}✓ Done!${NC}"
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
            echo -e "\n${GREEN}✓ Done!${NC}"
            break
            ;;
        3)
            read -p "Enter new concurrency value (current: $CONCURRENCY): " NEW_CONC
            if [[ "$NEW_CONC" =~ ^[0-9]+$ ]] && [ "$NEW_CONC" -ge 1 ] && [ "$NEW_CONC" -le 20 ]; then
                sed -i "s/QUEUE_WORKER_CONCURRENCY=.*/QUEUE_WORKER_CONCURRENCY=$NEW_CONC/" /opt/n8n/.env
                echo -e "${GREEN}Concurrency updated to $NEW_CONC. Restarting workers...${NC}"
                docker compose restart n8n-worker
                echo -e "\n${GREEN}✓ Done!${NC}"
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
WORKER_EOF
chmod +x ${N8N_DIR}/manage-workers.sh

# --- Cron Jobs ---
print_step "Setting up cron jobs ${CLOCK}"

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
print_success "Automated tasks configured"

# --- Final Message ---
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}${BOLD}     ${ROCKET} Installation Completed Successfully! ${ROCKET}${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${CYAN}${BOLD}NEXT STEPS${NC}"
echo -e "${CYAN}------------------------------------------------------------${NC}"
echo -e "${CHECK} Visit: ${BOLD}${BLUE}https://${DOMAIN}${NC}"
echo -e "${CHECK} Admin setup: Create your first admin account"
echo -e "${CHECK} Credentials: ${DIM}${N8N_DIR}/.env${NC}"
echo -e "${CHECK} Worker management: ${DIM}bash ${N8N_DIR}/manage-workers.sh${NC}"
echo -e "${CHECK} Update n8n: ${DIM}sudo bash ${N8N_DIR}/update-n8n.sh${NC}"
echo ""
echo -e "${PURPLE}${BOLD}${DATABASE} DATABASE STATUS${NC}"
echo -e "${PURPLE}------------------------------------------------------------${NC}"
echo -e "PostgreSQL Tables: ${GREEN}${TABLE_COUNT:-0}${NC}"
echo -e "Expected: ${GREEN}40+ tables${NC} for successful initialization"
echo -e "n8n Version: ${GREEN}${N8N_VERSION}${NC}"
echo ""
echo -e "${YELLOW}${BOLD}${STAR} FEATURES ENABLED${NC}"
echo -e "${YELLOW}------------------------------------------------------------${NC}"
echo -e "${GREEN}${CHECK}${NC} Complete Docker daemon configuration:"
echo -e "    • IP masquerade (NAT) enabled for internet access"
echo -e "    • Public DNS servers (8.8.8.8, 8.8.4.4, 1.1.1.1)"
echo -e "    • Automatic log rotation (10MB/file, max 3 files)"
echo -e "    • DNS optimization for container stability"
echo -e "${GREEN}${CHECK}${NC} n8n version: ${N8N_VERSION} (uses latest stable)"
echo -e "${GREEN}${CHECK}${NC} Manual update script: ${BOLD}/opt/n8n/update-n8n.sh${NC}"
echo -e "${GREEN}${CHECK}${NC} Production Queue Mode with Redis 7"
echo -e "${GREEN}${CHECK}${NC} PostgreSQL database on port ${POSTGRES_PORT}"
echo -e "${GREEN}${CHECK}${NC} Default: 1 worker × 5 jobs = 5 concurrent executions"
echo -e "${GREEN}${CHECK}${NC} Automatic daily backups at 3 AM"
echo -e "${GREEN}${CHECK}${NC} Automatic SSL renewal"
echo -e "${GREEN}${CHECK}${NC} Supabase integration ready (host.docker.internal configured)"
echo ""
echo -e "${BOLD}${CYAN}Supabase Integration:${NC}"
echo -e "  If Supabase is on the same server, use:"
echo -e "    Host: ${GREEN}host.docker.internal${NC}"
echo -e "    Port: ${GREEN}5432${NC}"
echo -e "  Run ${YELLOW}bash /root/harden_supabase_db.sh${NC} on Supabase server first"
echo ""
echo -e "${BOLD}${CYAN}To update n8n in the future:${NC}"
echo -e "  sudo bash /opt/n8n/update-n8n.sh"
echo ""
