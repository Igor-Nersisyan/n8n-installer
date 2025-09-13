#!/bin/bash

# n8n Automated Installer
# Version: 1.0.0
# For Ubuntu 20.04, 22.04, 24.04

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
N8N_DIR="/opt/n8n"
POSTGRES_PORT=5433
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
    print_error "This script must be run as root"
    echo "Please run: sudo $0"
    exit 1
fi

# Check Ubuntu
if ! grep -q "Ubuntu" /etc/os-release; then
    print_error "This script is for Ubuntu only"
    exit 1
fi

clear
echo "=========================================="
echo "     n8n Automated Installer v1.0.0"
echo "=========================================="
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
SERVER_IP=$(curl -s ifconfig.me)
DNS_IP=$(dig +short $DOMAIN | tail -n1)

if [ -z "$DNS_IP" ]; then
    print_error "Domain $DOMAIN does not resolve"
    echo "Please create DNS A record pointing to: $SERVER_IP"
    exit 1
fi

print_message "Server IP: $SERVER_IP"
print_message "Domain resolves to: $DNS_IP"

# Install prerequisites
print_message "Installing prerequisites..."
apt-get update > /dev/null 2>&1
apt-get install -y curl wget openssl > /dev/null 2>&1

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

# Install nginx
if ! command -v nginx &> /dev/null; then
    print_message "Installing nginx..."
    apt-get install -y nginx > /dev/null 2>&1
fi
systemctl enable nginx > /dev/null 2>&1
systemctl start nginx > /dev/null 2>&1

# Install certbot
if ! command -v certbot &> /dev/null; then
    print_message "Installing Certbot..."
    apt-get install -y certbot python3-certbot-nginx > /dev/null 2>&1
fi

# Configure firewall
print_message "Configuring firewall..."
if ! command -v ufw &> /dev/null; then
    apt-get install -y ufw > /dev/null 2>&1
fi

# Just add our rules, don't touch defaults
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 80/tcp > /dev/null 2>&1
ufw allow 443/tcp > /dev/null 2>&1

if ! ufw status | grep -q "Status: active"; then
    print_message "Firewall is not active. Enabling with default settings..."
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
fi

print_message "Firewall rules added"

# Create n8n directory
print_message "Setting up n8n..."
mkdir -p $N8N_DIR
cd $N8N_DIR

# Generate passwords
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
POSTGRES_USER_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

# Create .env
cat > .env <<EOF
# Database
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=n8n
POSTGRES_NON_ROOT_USER=n8n_user
POSTGRES_NON_ROOT_PASSWORD=${POSTGRES_USER_PASSWORD}

# n8n
N8N_HOST=${DOMAIN}
N8N_PROTOCOL=https
N8N_PORT=${N8N_PORT}
WEBHOOK_URL=https://${DOMAIN}/
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
GENERIC_TIMEZONE=UTC
NODE_ENV=production
EXECUTIONS_MODE=regular
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
  db_storage:
  n8n_storage:

networks:
  n8n_net:
    driver: bridge

services:
  postgres:
    image: postgres:16
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - POSTGRES_NON_ROOT_USER=\${POSTGRES_NON_ROOT_USER}
      - POSTGRES_NON_ROOT_PASSWORD=\${POSTGRES_NON_ROOT_PASSWORD}
    volumes:
      - db_storage:/var/lib/postgresql/data
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

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_NON_ROOT_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_NON_ROOT_PASSWORD}
      - N8N_HOST=\${N8N_HOST}
      - N8N_PROTOCOL=\${N8N_PROTOCOL}
      - N8N_PORT=\${N8N_PORT}
      - WEBHOOK_URL=\${WEBHOOK_URL}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - NODE_ENV=\${NODE_ENV}
      - EXECUTIONS_MODE=\${EXECUTIONS_MODE}
    ports:
      - "127.0.0.1:${N8N_PORT}:5678"
    volumes:
      - n8n_storage:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - n8n_net
EOF

# Configure nginx
print_message "Configuring nginx..."
cat > /etc/nginx/sites-available/n8n <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    
    client_max_body_size 100M;
    
    location / {
        proxy_pass http://127.0.0.1:${N8N_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_read_timeout 300;
    }
}
EOF

ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
nginx -t > /dev/null 2>&1
systemctl reload nginx

# Start n8n
print_message "Starting n8n..."
docker compose down > /dev/null 2>&1 || true
docker compose up -d

# Wait for n8n to start
print_message "Waiting for n8n to start..."
sleep 20

# Get SSL certificate
print_message "Getting SSL certificate..."
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${EMAIL} --redirect || true

# Final message
echo ""
echo "=========================================="
echo -e "${GREEN}   Installation Completed!${NC}"
echo "=========================================="
echo ""
echo -e "${GREEN}Your n8n is ready at: https://${DOMAIN}${NC}"
echo ""
echo "Commands:"
echo "  View logs:    cd ${N8N_DIR} && docker compose logs -f"
echo "  Restart:      cd ${N8N_DIR} && docker compose restart"
echo "  Stop:         cd ${N8N_DIR} && docker compose down"
echo ""
