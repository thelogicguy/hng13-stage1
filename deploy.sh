#!/bin/sh
###############################################################################
# deploy.sh
# Production-Grade Dockerized Application Deployment Script (POSIX-Compliant)
# Author: Macdonald Daniel
# Description: Automates setup, deployment, and configuration of a Dockerized Application
# Version: 1.0.0
###############################################################################

# -------------------------
# Safety / strict mode
# -------------------------
set -eu        # -e exit on error, -u treat unset vars as error
IFS=$(printf '\n\t')

# -------------------------
# Logging (POSIX-safe)
# -------------------------
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# Save original stdout to FD 3 so we can print user-facing messages to console
exec 3>&1

# Redirect stdout/stderr to logfile (note: command outputs go to log; key messages printed to console via >&3)
exec 1>>"$LOG_FILE" 2>&1

# Print a short banner to console (still logged too)
echo "📘 Deployment Log — $(date)" >&3
echo "Log file: $LOG_FILE" >&3
echo "-------------------------------------------------------------" >&3

# -------------------------
# Helper: basic safe echo to console+log
# Usage: info "message"
# -------------------------
info() {
    # message to log (stdout -> LOG_FILE) and to console (FD 3)
    printf "%s\n" "$1" >&3
    printf "%s\n" "$1"
}

# -------------------------
# Error handler & cleanup (functions must be declared before trap)
# -------------------------
error_handler() {
    EXIT_CODE=$1
    LINE_NO=$2
    if [ "$EXIT_CODE" -ne 0 ]; then
        printf "❌ Error occurred at line %s. Exit code: %s\n" "$LINE_NO" "$EXIT_CODE" >&3
        printf "💡 Check %s for details.\n" "$LOG_FILE" >&3
    fi
    # Ensure we leave without further actions (cleanup invoked separately if desired)
    exit "$EXIT_CODE"
}

cleanup() {
    # This cleanup is idempotent and safe; prompts for SSH info if not set
    printf "\n🧹 Running cleanup routine...\n" >&3
    # Ensure required SSH variables exist; prompt if missing
    if [ -z "${SSH_USER-}" ]; then
        printf "Enter remote SSH username for cleanup: " >&3
        read SSH_USER
    fi
    if [ -z "${SERVER_IP-}" ]; then
        printf "Enter remote server IP/host for cleanup: " >&3
        read SERVER_IP
    fi
    if [ -z "${SSH_KEY_PATH-}" ]; then
        printf "Enter SSH private key path for cleanup (e.g., ~/.ssh/id_rsa): " >&3
        read SSH_KEY_PATH
    fi

    if [ ! -f "$SSH_KEY_PATH" ]; then
        printf "❌ SSH key not found at %s\n" "$SSH_KEY_PATH" >&3
        exit 1
    fi

    # Remote cleanup commands (idempotent)
    ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$SERVER_IP" "
        set -e || true
        echo 'Stopping and removing known containers (if any)...' || true
        if [ -f /home/$SSH_USER/app_deploy/docker-compose.yml ]; then
            sudo docker-compose -f /home/$SSH_USER/app_deploy/docker-compose.yml down || true
        fi
        # Try to remove a container named after deployment dir if present
        if sudo docker ps -a --format '{{.Names}}' | grep -q '^app_deploy\$'; then
            sudo docker rm -f app_deploy || true
        fi
        echo 'Pruning unused containers and networks...' || true
        sudo docker container prune -f >/dev/null 2>&1 || true
        sudo docker network prune -f >/dev/null 2>&1 || true
        echo 'Removing deployment directory...' || true
        sudo rm -rf /home/$SSH_USER/app_deploy || true
        echo 'Removing nginx site config if present...' || true
        if [ -f /etc/nginx/sites-available/app.conf ]; then
            sudo rm -f /etc/nginx/sites-available/app.conf || true
        fi
        if [ -f /etc/nginx/sites-enabled/app.conf ]; then
            sudo rm -f /etc/nginx/sites-enabled/app.conf || true
        fi
        sudo systemctl reload nginx >/dev/null 2>&1 || true
        echo 'CLEANUP_DONE'
    " || {
        printf "⚠️ Remote cleanup encountered issues (check log for details).\n" >&3
    }

    printf "✅ Cleanup finished.\n" >&3
    exit 0
}

# -------------------------
# Setup trap for errors and interrupts
# Use EXIT so we reliably capture exit code; pass $? and current line number
# -------------------------
trap 'error_handler $? $LINENO' INT TERM EXIT

# -------------------------
# Quick arg parse: support --cleanup
# -------------------------
CLEANUP_MODE="false"
# Note: POSIX-safe arg parsing (only checks for single flag)
if [ "${1-}" = "--cleanup" ]; then
    CLEANUP_MODE="true"
fi

if [ "$CLEANUP_MODE" = "true" ]; then
    # If cleanup requested, run cleanup and exit (cleanup will prompt for missing SSH info)
    cleanup
    # cleanup exits, so we won't reach below
fi

# -------------------------
# Input validation helper
# -------------------------
validate_input() {
    input_name="$1"
    input_value="$2"
    if [ -z "$input_value" ]; then
        printf "❌ Error: %s cannot be empty. Exiting.\n" "$input_name" >&3
        exit 1
    fi
}

# -------------------------
# STEP 1: Collect parameters (interactive)
# -------------------------
printf "Enter your Git Repository URL (e.g., https://github.com/user/app.git): " >&3
read GIT_REPO

printf "Enter your Personal Access Token (PAT) (press Enter if public repo): " >&3
# Hide token entry using stty
stty -echo
read GIT_PAT
stty echo
printf "\n" >&3

# Branch (default: main)
printf "Enter branch name [default: main]: " >&3
read GIT_BRANCH
if [ -z "$GIT_BRANCH" ]; then
    GIT_BRANCH="main"
fi

# SSH details
printf "Enter remote server username: " >&3
read SSH_USER

printf "Enter remote server IP address: " >&3
read SERVER_IP

printf "Enter SSH private key path (e.g., ~/.ssh/id_rsa): " >&3
read SSH_KEY_PATH

# Application internal port
printf "Enter the container's internal application port (e.g., 3000): " >&3
read APP_PORT

# Validate required inputs
validate_input "Git Repository URL" "$GIT_REPO"
# PAT can be empty for public repo; so not strictly required
validate_input "Branch" "$GIT_BRANCH"
validate_input "SSH Username" "$SSH_USER"
validate_input "Server IP" "$SERVER_IP"
validate_input "SSH Key Path" "$SSH_KEY_PATH"
validate_input "App Port" "$APP_PORT"

# Print configuration summary to console (FD 3) and also log
cat <<EOF >&3
-------------------------------------------------------------
🔧 Configuration Summary
-------------------------------------------------------------
Git Repository:      $GIT_REPO
Branch:              $GIT_BRANCH
Server IP:           $SERVER_IP
SSH User:            $SSH_USER
SSH Key:             $SSH_KEY_PATH
App Internal Port:   $APP_PORT
-------------------------------------------------------------
EOF

printf "Proceed with deployment? (y/n): " >&3
read CONFIRM
if [ "$CONFIRM" != "y" ]; then
    printf "❌ Deployment cancelled by user.\n" >&3
    exit 0
fi

printf "✅ User input validated successfully. Proceeding...\n" >&3

# -------------------------
# STEP 2: Clone or update git repo (idempotent)
# -------------------------
REPO_NAME=$(basename "$GIT_REPO" .git)

printf "\n📦 Preparing repository: %s\n" "$REPO_NAME" >&3

if [ -d "$REPO_NAME" ]; then
    printf "📁 Repository exists locally; pulling latest changes...\n" >&3
    cd "$REPO_NAME" || {
        printf "❌ Failed to enter repo directory: %s\n" "$REPO_NAME" >&3
        exit 1
    }
    # ensure branch
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf "")
    if [ "$CURRENT_BRANCH" != "$GIT_BRANCH" ]; then
        git fetch origin "$GIT_BRANCH" >/dev/null 2>&1 || true
        git checkout "$GIT_BRANCH" >/dev/null 2>&1 || true
    fi
    git pull origin "$GIT_BRANCH" || {
        printf "❌ git pull failed\n" >&3
        exit 1
    }
else
    # clone using PAT if provided and URL is https
    printf "⬇️  Cloning repository...\n" >&3
    if printf "%s" "$GIT_REPO" | grep -q "^https://"; then
        if [ -n "$GIT_PAT" ]; then
            # inject PAT for clone only (we'll unset after)
            GIT_CLONE_URL=$(printf "%s" "$GIT_REPO" | sed "s#https://#https://${GIT_PAT}@#")
        else
            GIT_CLONE_URL="$GIT_REPO"
        fi
    else
        GIT_CLONE_URL="$GIT_REPO"
    fi

    git clone --branch "$GIT_BRANCH" "$GIT_CLONE_URL" || {
        printf "❌ git clone failed\n" >&3
        # ensure we don't leave PAT in env
        unset GIT_PAT 2>/dev/null || true
        exit 1
    }
    # unset PAT to avoid accidental leaks
    unset GIT_PAT 2>/dev/null || true

    cd "$REPO_NAME" || {
        printf "❌ Failed to enter repo directory after clone\n" >&3
        exit 1
    }
fi

# Verify docker config presence
if [ -f "Dockerfile" ]; then
    printf "✅ Dockerfile found in project root.\n" >&3
elif [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    printf "✅ docker-compose.yml found in project root.\n" >&3
else
    printf "❌ No Dockerfile or docker-compose.yml found. Cannot proceed.\n" >&3
    exit 1
fi

printf "✅ Repository ready for deployment.\n" >&3

# -------------------------
# STEP 3: Confirm working directory and project structure
# -------------------------
if [ ! -d "." ]; then
    printf "❌ Current directory missing (unexpected).\n" >&3
    exit 1
fi

CURRENT_DIR=$(pwd)
printf "📂 Currently in project directory: %s\n" "$CURRENT_DIR" >&3

# Detect app type heuristically (optional)
APP_TYPE="Generic Docker App"
if [ -f "Dockerfile" ]; then
    if grep -qi "node" Dockerfile 2>/dev/null; then
        APP_TYPE="Node.js"
    elif grep -qi "python" Dockerfile 2>/dev/null; then
        APP_TYPE="Python"
    fi
fi
printf "🔍 Detected Application Type: %s\n" "$APP_TYPE" >&3

printf "\n📁 Project contents preview:\n" >&3
ls -1 | sed -n '1,10p' >&3
printf '%s\n' '-------------------------------------------------------------' >&3

# -------------------------
# STEP 4: SSH connectivity checks
# -------------------------
printf "\n🌐 Validating SSH connectivity to remote server...\n" >&3

if [ ! -f "$SSH_KEY_PATH" ]; then
    printf "❌ SSH key not found at: %s\n" "$SSH_KEY_PATH" >&3
    exit 1
fi

# ping check (best-effort; some hosts block ICMP)
if ping -c 2 -W 5 "$SERVER_IP" >/dev/null 2>&1; then
    printf "✅ Network connectivity confirmed (ping OK).\n" >&3
else
    printf "⚠️ Ping failed or blocked; continuing to SSH test (ping not reliable on some hosts).\n" >&3
fi

# SSH dry-run
ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$SERVER_IP" "echo SSH_OK" >/dev/null 2>&1 || {
    printf "❌ SSH authentication failed. Ensure your key is authorized on the server.\n" >&3
    exit 1
}
printf "✅ SSH authentication successful. Remote server reachable.\n" >&3

# Print basic remote info
ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" "
    echo '---------------------------------------------'
    echo 'Remote Hostname: ' \$(hostname)
    echo 'OS: ' \$(cat /etc/os-release 2>/dev/null | sed -n '1p' || uname -a)
    echo 'Docker installed?: ' \$(command -v docker >/dev/null 2>&1 && echo Yes || echo No)
    echo '---------------------------------------------'
"

# -------------------------
# STEP 5: Prepare remote environment (install Docker, docker-compose, nginx)
# -------------------------
printf "\n🧰 Preparing remote environment (installing Docker/Docker Compose/NGINX if missing)...\n" >&3

ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" "
    set -e
    # Detect package manager (Debian/Ubuntu vs RHEL)
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release >/dev/null 2>&1 || true

        if ! command -v docker >/dev/null 2>&1; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
            echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null 2>&1
            sudo apt-get update -y
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || true
            sudo systemctl enable --now docker >/dev/null 2>&1 || true
            echo 'Docker installed'
        else
            echo 'Docker already installed'
        fi

        if ! command -v docker-compose >/dev/null 2>&1; then
            sudo curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
            echo 'Docker Compose installed'
        else
            echo 'Docker Compose already installed'
        fi

        if ! command -v nginx >/dev/null 2>&1; then
            sudo apt-get install -y nginx >/dev/null 2>&1 || true
            sudo systemctl enable --now nginx >/dev/null 2>&1 || true
            echo 'NGINX installed'
        else
            echo 'NGINX already installed'
        fi

    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        # RHEL/CentOS path (simplified)
        if ! command -v docker >/dev/null 2>&1; then
            curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sudo sh /tmp/get-docker.sh || true
            sudo systemctl enable --now docker >/dev/null 2>&1 || true
            echo 'Docker installed (RHEL path)'
        else
            echo 'Docker already installed'
        fi

        if ! command -v docker-compose >/dev/null 2>&1; then
            sudo curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
            echo 'Docker Compose installed'
        else
            echo 'Docker Compose already installed'
        fi

        if ! command -v nginx >/dev/null 2>&1; then
            sudo yum install -y nginx || true
            sudo systemctl enable --now nginx >/dev/null 2>&1 || true
            echo 'NGINX installed'
        else
            echo 'NGINX already installed'
        fi
    else
        echo 'Unsupported OS/package manager; manual install may be required'
        exit 1
    fi

    # Add user to docker group if necessary
    if ! getent group docker >/dev/null 2>&1; then
        sudo groupadd docker || true
    fi
    sudo usermod -aG docker \"$USER\" >/dev/null 2>&1 || true

    echo 'REMOTE_PREP_DONE'
"

printf "✅ Remote environment preparation complete (see remote output above).\n" >&3

# -------------------------
# STEP 6: Transfer project files and deploy containers
# -------------------------
printf "\n🚀 Deploying Dockerized application to remote server...\n" >&3

REMOTE_APP_DIR="/home/$SSH_USER/app_deploy"

# Ensure remote dir exists
ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" "mkdir -p \"$REMOTE_APP_DIR\""

# Use rsync to transfer current repo (exclude .git)
# From current repo directory (we are inside repo)
rsync -az --exclude='.git' -e "ssh -i $SSH_KEY_PATH -o BatchMode=yes" ./ "$SSH_USER@$SERVER_IP:$REMOTE_APP_DIR/"

printf "✅ Files transferred to remote: %s\n" "$REMOTE_APP_DIR" >&3

# Build and run remotely
ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" "
    set -e
    cd \"$REMOTE_APP_DIR\"
    echo 'Stopping previous containers (if any)...'
    if [ -f docker-compose.yml ]; then
        sudo docker-compose down || true
    else
        # stop any container exposing APP_PORT (best-effort)
        sudo docker ps -q --filter 'publish=$APP_PORT' | xargs -r sudo docker stop || true
    fi

    echo 'Starting containers...'
    if [ -f docker-compose.yml ]; then
        sudo docker-compose up -d --build --remove-orphans
    elif [ -f Dockerfile ]; then
        APP_NAME=\$(basename \"\$PWD\")
        sudo docker build -t \$APP_NAME .
        # remove old container if exists
        if sudo docker ps -a --format '{{.Names}}' | grep -q \"^\$APP_NAME\$\"; then
            sudo docker rm -f \$APP_NAME || true
        fi
        sudo docker run -d --name \$APP_NAME --restart unless-stopped -p 127.0.0.1:$APP_PORT:$APP_PORT \$APP_NAME
    else
        echo 'No Dockerfile or docker-compose.yml found' >&2
        exit 1
    fi

    echo 'DEPLOY_DONE'
"

printf "✅ Remote containers deployed (or updated).\n" >&3

# -------------------------
# STEP 7: Configure NGINX reverse proxy
# -------------------------

printf "\n🌐 Configuring NGINX as reverse proxy (port 80 -> %s)...\n" "$APP_PORT" >&3

ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" bash <<EOF
    set -e
    
    # Create nginx config with cat (more reliable than printf over ssh)
    sudo tee /etc/nginx/sites-available/app.conf > /dev/null <<'NGINX_EOF'
server {
    listen 80;
    server_name _;

    access_log /var/log/nginx/app_access.log;
    error_log /var/log/nginx/app_error.log;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
NGINX_EOF

    # Enable the config
    sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
    
    # Remove default if it exists
    sudo rm -f /etc/nginx/sites-enabled/default
    
    # Test configuration
    sudo nginx -t
    
    # Start or reload nginx
    if sudo systemctl is-active --quiet nginx; then
        sudo systemctl reload nginx
    else
        sudo systemctl start nginx
    fi
    
    echo 'NGINX_CONFIG_DONE'
EOF

printf "✅ NGINX configured and reloaded on remote host.\n" >&3

# -------------------------
# STEP 8: Validate deployment and health checks
# -------------------------
printf "\n🩺 Validating deployment and application health...\n" >&3

ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" "
    set -e
    echo 'Checking Docker service...'
    if sudo systemctl is-active --quiet docker; then
        echo 'Docker: active'
    else
        echo 'Docker: inactive' >&2
        exit 1
    fi

    echo 'Checking NGINX service...'
    if sudo systemctl is-active --quiet nginx; then
        echo 'NGINX: active'
    else
        echo 'NGINX: inactive' >&2
        exit 1
    fi

    echo 'Listing running containers:'
    sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

    echo 'Testing local app endpoint (nginx -> container)...'
    if curl -sSf http://127.0.0.1/ >/dev/null 2>&1; then
        echo 'App reachable via NGINX (localhost).'
    else
        echo 'App not reachable via NGINX (localhost).' >&2
    fi

    echo 'Showing last 5 lines of nginx access log (if any):'
    sudo tail -n 5 /var/log/nginx/app_access.log 2>/dev/null || echo '(no access logs yet)'
"

printf "\n🎉 Deployment completed. Access your app at: http://%s/\n" "$SERVER_IP" >&3
printf "Full log saved to: %s\n" "$LOG_FILE" >&3

# Explicit successful exit
exit 0
