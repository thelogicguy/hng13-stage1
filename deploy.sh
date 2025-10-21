#!/bin/sh

################################################################################
# deploy.sh - Production-Grade Dockerized Application Deployment Script
################################################################################
# Author: Macdonald Daniel
# Version: 1.0.0
# Description: Automates setup, deployment, and configuration of Dockerized
#              applications on remote Linux servers with full POSIX compliance
#
# Usage:
#   ./deploy.sh           # Normal deployment
#   ./deploy.sh --cleanup # Remove all deployed resources
#   ./deploy.sh --help    # Show usage information
#
# Requirements:
#   - POSIX-compliant shell (sh, dash, bash, etc.)
#   - git, ssh, scp/rsync, curl
#   - SSH key-based authentication to remote server
#
# Exit Codes:
#   0  - Success
#   1  - General error
#   2  - Input validation failed
#   3  - SSH connection failed
#   4  - Deployment failed
#   5  - Configuration error
#   130 - Interrupted by user (Ctrl+C)
################################################################################

# ============================================================================
# STRICT MODE AND SAFETY SETTINGS
# ============================================================================
# Exit on error, treat unset variables as errors
set -e
set -u

# Set Internal Field Separator to newline and tab only
# This prevents word splitting issues with filenames containing spaces
IFS='
	'

# ============================================================================
# GLOBAL CONSTANTS AND CONFIGURATION
# ============================================================================

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

# Exit codes (semantic error codes for better debugging)
readonly EXIT_SUCCESS=0
readonly EXIT_GENERAL_ERROR=1
readonly EXIT_VALIDATION_ERROR=2
readonly EXIT_SSH_ERROR=3
readonly EXIT_DEPLOYMENT_ERROR=4
readonly EXIT_CONFIG_ERROR=5
readonly EXIT_INTERRUPTED=130

# Logging configuration
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="${SCRIPT_DIR}/deploy_${TIMESTAMP}.log"

# Color codes for terminal output (POSIX-compliant using printf)
readonly COLOR_RED="$(printf '\033[0;31m')"
readonly COLOR_GREEN="$(printf '\033[0;32m')"
readonly COLOR_YELLOW="$(printf '\033[1;33m')"
readonly COLOR_BLUE="$(printf '\033[0;34m')"
readonly COLOR_CYAN="$(printf '\033[0;36m')"
readonly COLOR_RESET="$(printf '\033[0m')"

# Emoji/symbols for output (use ASCII fallbacks if terminal doesn't support)
readonly SYMBOL_SUCCESS="✅"
readonly SYMBOL_ERROR="❌"
readonly SYMBOL_WARNING="⚠️"
readonly SYMBOL_INFO="ℹ️"
readonly SYMBOL_ROCKET="🚀"
readonly SYMBOL_PACKAGE="📦"
readonly SYMBOL_NETWORK="🌐"
readonly SYMBOL_FOLDER="📁"
readonly SYMBOL_WRENCH="🔧"
readonly SYMBOL_CHECK="🩺"
readonly SYMBOL_CELEBRATE="🎉"

# Deployment configuration (populated from user input)
GIT_REPO=""
GIT_PAT=""
GIT_BRANCH="main"
SSH_USER=""
SERVER_IP=""
SSH_KEY_PATH=""
APP_PORT=""
CLEANUP_MODE=0

# Derived paths
LOCAL_CLONE_DIR=""
REMOTE_APP_DIR="/opt/app_deploy"
NGINX_CONFIG_PATH="/etc/nginx/sites-available/app.conf"
NGINX_ENABLED_PATH="/etc/nginx/sites-enabled/app.conf"

# ============================================================================
# LOGGING AND OUTPUT FUNCTIONS
# ============================================================================

# Initialize logging system
# Creates log file and writes header information
initialize_logging() {
    # Create log file with header
    {
        printf "================================================================================\n"
        printf "Deployment Script Log\n"
        printf "================================================================================\n"
        printf "Script Version: %s\n" "$SCRIPT_VERSION"
        printf "Execution Date: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf "Log File: %s\n" "$LOG_FILE"
        printf "================================================================================\n\n"
    } > "$LOG_FILE"
    
    # Display log location to user
    printf "%s Log file: %s%s%s\n" "$SYMBOL_INFO" "$COLOR_CYAN" "$LOG_FILE" "$COLOR_RESET"
    printf "================================================================================\n\n"
}

# Logging function that writes to both console and log file
# Arguments:
#   $1 - Log level (INFO|SUCCESS|WARN|ERROR)
#   $2+ - Message to log
# Usage:
#   log "INFO" "Starting deployment"
#   log "ERROR" "Failed to connect"
log() {
    level="$1"
    shift
    message="$*"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Write to log file with timestamp
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
    
    # Display to console with colors and symbols
    case "$level" in
        INFO)
            printf "%s%s[INFO]%s %s\n" "$COLOR_BLUE" "$SYMBOL_INFO" "$COLOR_RESET" "$message"
            ;;
        SUCCESS)
            printf "%s%s[SUCCESS]%s %s\n" "$COLOR_GREEN" "$SYMBOL_SUCCESS" "$COLOR_RESET" "$message"
            ;;
        WARN)
            printf "%s%s[WARN]%s %s\n" "$COLOR_YELLOW" "$SYMBOL_WARNING" "$COLOR_RESET" "$message"
            ;;
        ERROR)
            printf "%s%s[ERROR]%s %s\n" "$COLOR_RED" "$SYMBOL_ERROR" "$COLOR_RESET" "$message"
            ;;
        *)
            printf "[%s] %s\n" "$level" "$message"
            ;;
    esac
}

# Print section header for better visual organization
# Arguments:
#   $1 - Section title
print_section_header() {
    title="$1"
    printf "\n"
    printf "================================================================================\n"
    printf "%s %s\n" "$SYMBOL_ROCKET" "$title"
    printf "================================================================================\n"
    log "INFO" "=== $title ==="
}

# ============================================================================
# ERROR HANDLING AND CLEANUP
# ============================================================================

# Error handler called when script exits with error
# Arguments:
#   $1 - Exit code
error_handler() {
    exit_code="$1"
    
    if [ "$exit_code" -ne 0 ]; then
        log "ERROR" "Script failed with exit code: $exit_code"
        printf "\n%s Deployment failed. Check log file for details: %s\n" "$SYMBOL_ERROR" "$LOG_FILE"
        printf "================================================================================\n"
    fi
}

# Handle interrupt signals (Ctrl+C)
interrupt_handler() {
    log "WARN" "Deployment interrupted by user"
    printf "\n%s Deployment cancelled by user\n" "$SYMBOL_WARNING"
    exit $EXIT_INTERRUPTED
}

# Cleanup function for --cleanup flag
# Removes all deployed resources from remote server
cleanup_deployment() {
    print_section_header "Cleanup Mode - Removing Deployed Resources"
    
    # Collect SSH information if not already set
    if [ -z "${SSH_USER:-}" ]; then
        printf "Enter SSH username: "
        read -r SSH_USER
    fi
    
    if [ -z "${SERVER_IP:-}" ]; then
        printf "Enter server IP address: "
        read -r SERVER_IP
    fi
    
    if [ -z "${SSH_KEY_PATH:-}" ]; then
        printf "Enter SSH key path: "
        read -r SSH_KEY_PATH
    fi
    
    # Validate SSH key exists
    if [ ! -f "$SSH_KEY_PATH" ]; then
        log "ERROR" "SSH key not found: $SSH_KEY_PATH"
        exit $EXIT_VALIDATION_ERROR
    fi
    
    log "INFO" "Connecting to remote server: $SERVER_IP"
    
    # Execute cleanup commands on remote server
    ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "$SSH_USER@$SERVER_IP" sh <<'CLEANUP_EOF'
        
        echo "Stopping and removing containers..."
        
        # Stop docker-compose managed containers
        if [ -f "$HOME/app_deploy/docker-compose.yml" ]; then
            cd "$HOME/app_deploy"
            sudo docker-compose down -v 2>/dev/null || true
        fi
        
        # Stop standalone containers
        container_ids=$(sudo docker ps -aq 2>/dev/null || true)
        if [ -n "$container_ids" ]; then
            printf "%s" "$container_ids" | xargs sudo docker stop 2>/dev/null || true
            printf "%s" "$container_ids" | xargs sudo docker rm 2>/dev/null || true
        fi
        
        # Prune unused resources
        sudo docker container prune -f 2>/dev/null || true
        sudo docker network prune -f 2>/dev/null || true
        sudo docker volume prune -f 2>/dev/null || true
        
        # Remove deployment directory
        sudo rm -rf "$HOME/app_deploy" /opt/app_deploy 2>/dev/null || true
        
        # Remove Nginx configuration
        sudo rm -f /etc/nginx/sites-available/app.conf 2>/dev/null || true
        sudo rm -f /etc/nginx/sites-enabled/app.conf 2>/dev/null || true
        
        # Reload Nginx
        if sudo systemctl is-active --quiet nginx 2>/dev/null; then
            sudo systemctl reload nginx 2>/dev/null || true
        fi
        
        echo "Cleanup completed successfully"
CLEANUP_EOF
    
    log "SUCCESS" "Cleanup completed successfully"
    exit $EXIT_SUCCESS
}

# Set up signal traps
# These ensure proper cleanup and error reporting
trap 'saved_exit=$?; error_handler $saved_exit' EXIT
trap 'interrupt_handler' INT TERM

# ============================================================================
# INPUT VALIDATION FUNCTIONS
# ============================================================================

# Validate that input is not empty
# Arguments:
#   $1 - Field name (for error messages)
#   $2 - Value to validate
# Returns:
#   0 if valid, exits script if invalid
validate_not_empty() {
    field_name="$1"
    value="$2"
    
    if [ -z "$value" ]; then
        log "ERROR" "$field_name cannot be empty"
        exit $EXIT_VALIDATION_ERROR
    fi
}

# Validate URL format (basic check for http(s):// or git@)
# Arguments:
#   $1 - URL to validate
# Returns:
#   0 if valid, 1 if invalid
validate_url() {
    url="$1"
    
    case "$url" in
        https://*|http://*|git@*|ssh://*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Validate IP address format
# Arguments:
#   $1 - IP address to validate
# Returns:
#   0 if valid, 1 if invalid
validate_ip() {
    ip="$1"
    
    # Check for invalid characters
    case "$ip" in
        *[!0-9.]*)
            return 1
            ;;
    esac
    
    # Split IP into octets and validate each
    octet_count=0
    old_ifs="$IFS"
    IFS='.'
    
    for octet in $ip; do
        octet_count=$((octet_count + 1))
        
        # Check if octet is a valid number
        case "$octet" in
            ''|*[!0-9]*)
                IFS="$old_ifs"
                return 1
                ;;
        esac
        
        # Check octet range (0-255)
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ] 2>/dev/null; then
            IFS="$old_ifs"
            return 1
        fi
    done
    
    IFS="$old_ifs"
    
    # IP must have exactly 4 octets
    if [ "$octet_count" -ne 4 ]; then
        return 1
    fi
    
    return 0
}

# Validate port number (1-65535)
# Arguments:
#   $1 - Port number to validate
# Returns:
#   0 if valid, 1 if invalid
validate_port() {
    port="$1"
    
    # Check if it's a number
    case "$port" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    
    # Check port range
    if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# Validate file exists and is readable
# Arguments:
#   $1 - File path to validate
# Returns:
#   0 if valid, 1 if invalid
validate_file() {
    file="$1"
    
    if [ -f "$file" ] && [ -r "$file" ]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# USER INPUT COLLECTION
# ============================================================================

# Collect all deployment parameters from user with validation
collect_deployment_parameters() {
    print_section_header "Collecting Deployment Parameters"
    
    # Git Repository URL
    while true; do
        printf "Enter Git Repository URL: "
        read -r GIT_REPO
        
        if validate_url "$GIT_REPO"; then
            log "SUCCESS" "Repository URL validated: $GIT_REPO"
            break
        else
            log "ERROR" "Invalid URL format. Use https://, http://, git@, or ssh://"
        fi
    done
    
    # Personal Access Token (optional for public repos)
    printf "Enter Personal Access Token (press Enter if public repo): "
    stty -echo 2>/dev/null  # Hide input
    read -r GIT_PAT
    stty echo 2>/dev/null   # Restore echo
    printf "\n"
    
    if [ -n "$GIT_PAT" ]; then
        log "INFO" "PAT configured (hidden for security)"
    else
        log "INFO" "No PAT provided (assuming public repository)"
    fi
    
    # Branch name with default
    printf "Enter branch name [default: main]: "
    read -r input_branch
    GIT_BRANCH="${input_branch:-main}"
    log "SUCCESS" "Branch set to: $GIT_BRANCH"
    
    # SSH Username
    while true; do
        printf "Enter SSH username: "
        read -r SSH_USER
        
        if [ -n "$SSH_USER" ]; then
            log "SUCCESS" "SSH username: $SSH_USER"
            break
        else
            log "ERROR" "Username cannot be empty"
        fi
    done
    
    # Server IP Address
    while true; do
        printf "Enter server IP address: "
        read -r SERVER_IP
        
        if validate_ip "$SERVER_IP"; then
            log "SUCCESS" "Server IP validated: $SERVER_IP"
            break
        else
            log "ERROR" "Invalid IP address format (expected: xxx.xxx.xxx.xxx)"
        fi
    done
    
    # SSH Key Path
    while true; do
        printf "Enter SSH private key path [default: ~/.ssh/id_rsa]: "
        read -r input_key
        SSH_KEY_PATH="${input_key:-$HOME/.ssh/id_rsa}"
        
        # Expand tilde
        case "$SSH_KEY_PATH" in
            \~/*) SSH_KEY_PATH="$HOME/${SSH_KEY_PATH#\~/}" ;;
        esac
        
        if validate_file "$SSH_KEY_PATH"; then
            log "SUCCESS" "SSH key found: $SSH_KEY_PATH"
            break
        else
            log "ERROR" "SSH key not found or not readable: $SSH_KEY_PATH"
        fi
    done
    
    # Application Port
    while true; do
        printf "Enter application internal port: "
        read -r APP_PORT
        
        if validate_port "$APP_PORT"; then
            log "SUCCESS" "Application port: $APP_PORT"
            break
        else
            log "ERROR" "Invalid port (must be 1-65535)"
        fi
    done
    
    # Set local clone directory based on repo name
    repo_name="${GIT_REPO##*/}"
    repo_name="${repo_name%.git}"
    LOCAL_CLONE_DIR="${SCRIPT_DIR}/${repo_name}"
    
    # Display configuration summary
    printf "\n"
    printf "================================================================================\n"
    printf "%s Configuration Summary\n" "$SYMBOL_WRENCH"
    printf "================================================================================\n"
    printf "Repository:     %s\n" "$GIT_REPO"
    printf "Branch:         %s\n" "$GIT_BRANCH"
    printf "Server IP:      %s\n" "$SERVER_IP"
    printf "SSH User:       %s\n" "$SSH_USER"
    printf "SSH Key:        %s\n" "$SSH_KEY_PATH"
    printf "App Port:       %s\n" "$APP_PORT"
    printf "Local Clone:    %s\n" "$LOCAL_CLONE_DIR"
    printf "================================================================================\n"
    
    # Confirmation prompt
    printf "\nProceed with deployment? (y/n): "
    read -r confirm
    
    case "$confirm" in
        y|Y|yes|YES)
            log "SUCCESS" "User confirmed deployment"
            ;;
        *)
            log "WARN" "Deployment cancelled by user"
            exit $EXIT_SUCCESS
            ;;
    esac
}

# ============================================================================
# GIT OPERATIONS
# ============================================================================

# Clone repository or update if it already exists (idempotent)
clone_or_update_repository() {
    print_section_header "Preparing Git Repository"
    
    # Construct authenticated URL for HTTPS repos
    auth_url=""
    case "$GIT_REPO" in
        https://*)
            if [ -n "$GIT_PAT" ]; then
                # Inject PAT into URL for authentication
                auth_url="$(printf "%s" "$GIT_REPO" | sed "s|https://|https://${GIT_PAT}@|")"
                log "INFO" "Using authenticated HTTPS URL"
            else
                auth_url="$GIT_REPO"
                log "INFO" "Using public HTTPS URL"
            fi
            ;;
        git@*|ssh://*)
            auth_url="$GIT_REPO"
            log "INFO" "Using SSH URL"
            ;;
        *)
            log "ERROR" "Unsupported repository URL format"
            exit $EXIT_VALIDATION_ERROR
            ;;
    esac
    
    # Check if repository already exists locally
    if [ -d "$LOCAL_CLONE_DIR" ]; then
        log "INFO" "Repository directory exists, updating..."
        
        cd "$LOCAL_CLONE_DIR" || {
            log "ERROR" "Failed to enter repository directory"
            exit $EXIT_GENERAL_ERROR
        }
        
        # Check current branch
        current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || current_branch=""
        
        if [ "$current_branch" != "$GIT_BRANCH" ]; then
            log "INFO" "Switching to branch: $GIT_BRANCH"
            git fetch origin "$GIT_BRANCH" >> "$LOG_FILE" 2>&1 || true
            git checkout "$GIT_BRANCH" >> "$LOG_FILE" 2>&1 || {
                log "ERROR" "Failed to checkout branch: $GIT_BRANCH"
                exit $EXIT_GENERAL_ERROR
            }
        fi
        
        # Pull latest changes
        log "INFO" "Pulling latest changes from origin/$GIT_BRANCH"
        if git pull origin "$GIT_BRANCH" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Repository updated successfully"
        else
            log "ERROR" "Failed to pull changes from origin"
            exit $EXIT_GENERAL_ERROR
        fi
    else
        # Clone repository for the first time
        log "INFO" "Cloning repository..."
        
        if git clone --branch "$GIT_BRANCH" "$auth_url" "$LOCAL_CLONE_DIR" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Repository cloned successfully"
        else
            log "ERROR" "Failed to clone repository"
            exit $EXIT_GENERAL_ERROR
        fi
        
        cd "$LOCAL_CLONE_DIR" || {
            log "ERROR" "Failed to enter cloned repository"
            exit $EXIT_GENERAL_ERROR
        }
    fi
    
    # Clear PAT from memory for security
    GIT_PAT=""
    
    # Display current commit
    current_commit="$(git rev-parse --short HEAD 2>/dev/null)" || current_commit="unknown"
    log "INFO" "Current commit: $current_commit"
}

# Verify Docker configuration files exist
verify_docker_configuration() {
    print_section_header "Verifying Docker Configuration"
    
    log "INFO" "Current directory: $(pwd)"
    
    # Check for Docker configuration files
    if [ -f "Dockerfile" ]; then
        log "SUCCESS" "Found Dockerfile"
        
        # Try to detect application type
        if grep -qi "node" Dockerfile 2>/dev/null; then
            log "INFO" "Detected: Node.js application"
        elif grep -qi "python" Dockerfile 2>/dev/null; then
            log "INFO" "Detected: Python application"
        elif grep -qi "java" Dockerfile 2>/dev/null; then
            log "INFO" "Detected: Java application"
        else
            log "INFO" "Detected: Generic Docker application"
        fi
    elif [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
        log "SUCCESS" "Found docker-compose.yml"
    else
        log "ERROR" "No Dockerfile or docker-compose.yml found"
        log "ERROR" "Cannot proceed without Docker configuration"
        exit $EXIT_VALIDATION_ERROR
    fi
    
    # Display project structure
    log "INFO" "Project structure (top 10 items):"
    ls -1 | head -n 10 >> "$LOG_FILE"
}

# ============================================================================
# SSH AND NETWORK OPERATIONS
# ============================================================================

# Test SSH connectivity to remote server
test_ssh_connectivity() {
    print_section_header "Testing SSH Connectivity"
    
    # Optional: Test network connectivity with ping (not reliable, some hosts block ICMP)
    log "INFO" "Testing network connectivity to $SERVER_IP"
    if ping -c 2 -W 5 "$SERVER_IP" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Network connectivity confirmed (ping successful)"
    else
        log "WARN" "Ping failed or blocked (this is often normal)"
    fi
    
    # Test SSH authentication
    log "INFO" "Testing SSH authentication"
    if ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=10 \
           -o StrictHostKeyChecking=accept-new "$SSH_USER@$SERVER_IP" \
           "echo 'SSH_CONNECTION_OK'" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "SSH authentication successful"
    else
        log "ERROR" "SSH authentication failed"
        log "ERROR" "Ensure your SSH key is authorized on the server"
        exit $EXIT_SSH_ERROR
    fi
    
    # Gather remote system information
    log "INFO" "Gathering remote system information"
    ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" sh <<'REMOTE_INFO_EOF'
        printf "Hostname: %s\n" "$(hostname)"
        printf "OS: %s\n" "$(cat /etc/os-release 2>/dev/null | head -n1 || uname -a)"
        printf "Kernel: %s\n" "$(uname -r)"
        printf "Architecture: %s\n" "$(uname -m)"
        
        if command -v docker >/dev/null 2>&1; then
            printf "Docker: %s\n" "$(docker --version 2>/dev/null || echo 'installed')"
        else
            printf "Docker: not installed\n"
        fi
REMOTE_INFO_EOF
}

# Execute command on remote server with error handling
# Arguments:
#   $1 - Command to execute
# Returns:
#   0 on success, 1 on failure
remote_exec() {
    command="$1"
    
    log "INFO" "Executing remotely: $command"
    
    if ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" "$command" >> "$LOG_FILE" 2>&1; then
        return 0
    else
        log "ERROR" "Remote command failed: $command"
        return 1
    fi
}

# ============================================================================
# REMOTE ENVIRONMENT PREPARATION
# ============================================================================

# Install Docker, Docker Compose, and Nginx on remote server
prepare_remote_environment() {
    print_section_header "Preparing Remote Environment"
    
    log "INFO" "Installing required software on remote server"
    log "INFO" "This may take several minutes..."
    
    # Execute installation script on remote server
    ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" sh <<'REMOTE_SETUP_EOF'
        set -e
        
        echo "Detecting package manager..."
        
        # Function to install Docker
        install_docker() {
            if command -v docker >/dev/null 2>&1; then
                echo "Docker already installed"
                docker --version
                return 0
            fi
            
            echo "Installing Docker..."
            
            if command -v apt-get >/dev/null 2>&1; then
                # Debian/Ubuntu
                sudo apt-get update -qq
                sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
                
                # Add Docker GPG key and repository
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
                    sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg 2>/dev/null || true
                
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
                    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
                
                sudo apt-get update -qq
                sudo apt-get install -y docker-ce docker-ce-cli containerd.io
                
            elif command -v yum >/dev/null 2>&1; then
                # RHEL/CentOS
                sudo yum install -y yum-utils
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                sudo yum install -y docker-ce docker-ce-cli containerd.io
                
            elif command -v dnf >/dev/null 2>&1; then
                # Fedora
                sudo dnf -y install dnf-plugins-core
                sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
                sudo dnf install -y docker-ce docker-ce-cli containerd.io
            else
                echo "Unsupported package manager"
                return 1
            fi
            
            # Enable and start Docker
            sudo systemctl enable docker 2>/dev/null || true
            sudo systemctl start docker
            
            echo "Docker installed successfully"
            docker --version
        }
        
        # Function to install Docker Compose
        install_docker_compose() {
            if command -v docker-compose >/dev/null 2>&1; then
                echo "Docker Compose already installed"
                docker-compose --version
                return 0
            fi
            
            echo "Installing Docker Compose..."
            
            # Download latest version
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
                -o /usr/local/bin/docker-compose
            
            sudo chmod +x /usr/local/bin/docker-compose
            
            echo "Docker Compose installed successfully"
            docker-compose --version
        }
        
        # Function to install Nginx
        install_nginx() {
            if command -v nginx >/dev/null 2>&1; then
                echo "Nginx already installed"
                nginx -v
                return 0
            fi
            
            echo "Installing Nginx..."
            
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update -qq
                sudo apt-get install -y nginx
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y nginx
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y nginx
            else
                echo "Unsupported package manager"
                return 1
            fi
            
            # Enable and start Nginx
            sudo systemctl enable nginx 2>/dev/null || true
            sudo systemctl start nginx
            
            echo "Nginx installed successfully"
            nginx -v
        }
        
        # Install all components
        install_docker
        install_docker_compose
        install_nginx
        
        # Add user to docker group (requires re-login to take effect)
        if ! getent group docker >/dev/null 2>&1; then
            sudo groupadd docker || true
        fi
        sudo usermod -aG docker "$USER" || true
        
        echo "Remote environment preparation completed"
REMOTE_SETUP_EOF
    
    log "SUCCESS" "Remote environment prepared successfully"
    
    # Verify installations
    log "INFO" "Verifying installations..."
    remote_exec "docker --version && docker-compose --version && nginx -v"
}

# ============================================================================
# APPLICATION DEPLOYMENT
# ============================================================================

# Transfer application files to remote server
transfer_application_files() {
    print_section_header "Transferring Application Files"
    
    log "INFO" "Creating remote directory: $REMOTE_APP_DIR"
    remote_exec "sudo mkdir -p $REMOTE_APP_DIR && sudo chown $SSH_USER:$SSH_USER $REMOTE_APP_DIR"
    
    log "INFO" "Transferring files from $LOCAL_CLONE_DIR to $SERVER_IP:$REMOTE_APP_DIR"
    
    # Try rsync first (more efficient), fall back to scp if not available
    if command -v rsync >/dev/null 2>&1; then
        log "INFO" "Using rsync for efficient transfer"
        
        if rsync -avz --delete --exclude='.git' \
           -e "ssh -i $SSH_KEY_PATH -o BatchMode=yes" \
           "$LOCAL_CLONE_DIR/" "$SSH_USER@$SERVER_IP:$REMOTE_APP_DIR/" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Files transferred successfully using rsync"
        else
            log "ERROR" "File transfer failed"
            exit $EXIT_GENERAL_ERROR
        fi
    else
        log "INFO" "rsync not available, using scp"
        
        if scp -i "$SSH_KEY_PATH" -o BatchMode=yes -r \
           "$LOCAL_CLONE_DIR/"* "$SSH_USER@$SERVER_IP:$REMOTE_APP_DIR/" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Files transferred successfully using scp"
        else
            log "ERROR" "File transfer failed"
            exit $EXIT_GENERAL_ERROR
        fi
    fi
}

# Build and deploy Docker containers
deploy_docker_containers() {
    print_section_header "Deploying Docker Containers"
    
    log "INFO" "Building and starting containers on remote server"
    
    # Pass necessary variables to remote execution
    ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" \
        "REMOTE_DIR='$REMOTE_APP_DIR' APP_PORT='$APP_PORT'" sh <<'DEPLOY_EOF'
        set -e
        
        cd "$REMOTE_DIR" || exit 1
        
        echo "Current directory: $(pwd)"
        echo "Stopping existing containers (idempotent)..."
        
        # Stop docker-compose managed containers
        if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
            sudo docker-compose down 2>/dev/null || true
        fi
        
        # Stop any containers using the target port
        port_containers=$(sudo docker ps -q --filter "publish=$APP_PORT" 2>/dev/null || true)
        if [ -n "$port_containers" ]; then
            printf "%s" "$port_containers" | xargs sudo docker stop 2>/dev/null || true
        fi
        
        echo "Building and starting new containers..."
        
        # Deploy based on available configuration
        if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
            echo "Using docker-compose for deployment"
            sudo docker-compose build --no-cache
            sudo docker-compose up -d --remove-orphans
            
        elif [ -f Dockerfile ]; then
            echo "Using standalone Dockerfile for deployment"
            
            # Generate app name from directory
            APP_NAME=$(basename "$PWD")
            
            # Build image
            sudo docker build -t "$APP_NAME:latest" .
            
            # Remove old container if exists
            if sudo docker ps -a --format '{{.Names}}' | grep -x "$APP_NAME" >/dev/null 2>&1; then
                sudo docker rm -f "$APP_NAME" || true
            fi
            
            # Run new container
            sudo docker run -d \
                --name "$APP_NAME" \
                --restart unless-stopped \
                -p "127.0.0.1:$APP_PORT:$APP_PORT" \
                "$APP_NAME:latest"
        else
            echo "Error: No Dockerfile or docker-compose.yml found"
            exit 1
        fi
        
        echo "Waiting for containers to stabilize..."
        sleep 10
        
        echo "Container deployment completed"
DEPLOY_EOF
    
    log "SUCCESS" "Containers deployed successfully"
}

# Verify container health and status
verify_container_health() {
    print_section_header "Verifying Container Health"
    
    log "INFO" "Checking container status..."
    
    # Check running containers
    ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" sh <<'VERIFY_EOF'
        echo "Running containers:"
        sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
        
        echo ""
        echo "Checking container logs (last 20 lines):"
        container_ids=$(sudo docker ps -q)
        if [ -n "$container_ids" ]; then
            for container_id in $container_ids; do
                echo "--- Container: $container_id ---"
                sudo docker logs --tail 20 "$container_id" 2>&1 || true
            done
        fi
VERIFY_EOF
    
    log "SUCCESS" "Container health check completed"
}

# ============================================================================
# NGINX CONFIGURATION
# ============================================================================

# Configure Nginx as reverse proxy
configure_nginx_proxy() {
    print_section_header "Configuring Nginx Reverse Proxy"
    
    log "INFO" "Creating Nginx configuration (port 80 -> $APP_PORT)"
    
    # Create Nginx configuration on remote server
    # Note: EOF is NOT quoted so variables expand
    ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" \
        "APP_PORT='$APP_PORT'" sh <<EOF
        set -e
        
        echo "Writing Nginx configuration..."
        
        # Create configuration file
        sudo tee /etc/nginx/sites-available/app.conf > /dev/null <<NGINX_CONFIG
server {
    listen 80;
    listen [::]:80;
    server_name _;

    # Logging
    access_log /var/log/nginx/app_access.log;
    error_log /var/log/nginx/app_error.log;

    # Main application proxy
    location / {
        proxy_pass http://127.0.0.1:\$APP_PORT;
        proxy_http_version 1.1;
        
        # WebSocket support
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection 'upgrade';
        
        # Standard proxy headers
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Buffering
        proxy_buffering off;
        proxy_cache_bypass \\\$http_upgrade;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
}
NGINX_CONFIG

        echo "Enabling site configuration..."
        
        # Create symbolic link to enable site
        sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
        
        # Remove default site if it exists
        sudo rm -f /etc/nginx/sites-enabled/default
        
        echo "Testing Nginx configuration..."
        sudo nginx -t
        
        echo "Reloading Nginx..."
        if sudo systemctl is-active --quiet nginx; then
            sudo systemctl reload nginx
        else
            sudo systemctl start nginx
        fi
        
        echo "Nginx configuration completed"
EOF
    
    log "SUCCESS" "Nginx configured and reloaded successfully"
}

# ============================================================================
# DEPLOYMENT VALIDATION
# ============================================================================

# Perform comprehensive deployment validation
validate_deployment() {
    print_section_header "Validating Deployment"
    
    # Check Docker service
    log "INFO" "Checking Docker service status..."
    if remote_exec "sudo systemctl is-active docker"; then
        log "SUCCESS" "Docker service is running"
    else
        log "ERROR" "Docker service is not running"
        exit $EXIT_DEPLOYMENT_ERROR
    fi
    
    # Check Nginx service
    log "INFO" "Checking Nginx service status..."
    if remote_exec "sudo systemctl is-active nginx"; then
        log "SUCCESS" "Nginx service is running"
    else
        log "ERROR" "Nginx service is not running"
        exit $EXIT_CONFIG_ERROR
    fi
    
    # Check container status
    log "INFO" "Verifying containers are running..."
    if ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "$SSH_USER@$SERVER_IP" \
           "sudo docker ps | grep -q 'Up' 2>/dev/null"; then
        log "SUCCESS" "Application containers are running"
    else
        log "WARN" "No running containers detected"
    fi
    
    # Test local endpoint on remote server
    log "INFO" "Testing application endpoint (remote localhost)..."
    if remote_exec "curl -sf -m 10 http://127.0.0.1:$APP_PORT >/dev/null 2>&1 || nc -z 127.0.0.1 $APP_PORT"; then
        log "SUCCESS" "Application is responding on port $APP_PORT"
    else
        log "WARN" "Application may not be fully ready on port $APP_PORT"
    fi
    
    # Test Nginx proxy
    log "INFO" "Testing Nginx reverse proxy..."
    if remote_exec "curl -sf -m 10 http://127.0.0.1 >/dev/null 2>&1"; then
        log "SUCCESS" "Nginx proxy is working correctly"
    else
        log "WARN" "Nginx proxy may not be fully operational"
    fi
    
    # Test external access
    log "INFO" "Testing external access to http://$SERVER_IP"
    if curl -sf -m 10 "http://$SERVER_IP" >/dev/null 2>&1; then
        log "SUCCESS" "Application is accessible from external network"
    else
        log "WARN" "Application may not be accessible externally (check firewall rules)"
    fi
    
    # Display service status summary
    log "INFO" "Deployment validation completed"
    
    # Fetch and display recent Nginx logs
    log "INFO" "Recent Nginx access logs:"
    remote_exec "sudo tail -n 5 /var/log/nginx/app_access.log 2>/dev/null || echo 'No logs yet'"
}

# ============================================================================
# MAIN EXECUTION FLOW
# ============================================================================

# Display usage information
show_usage() {
    cat <<USAGE
================================================================================
$SCRIPT_NAME - Production-Grade Docker Deployment Script
================================================================================

USAGE:
    ./$SCRIPT_NAME [OPTIONS]

OPTIONS:
    (no options)    Run normal deployment workflow
    --cleanup       Remove all deployed resources from remote server
    --help          Display this help message
    --version       Display script version

DESCRIPTION:
    Automates the complete deployment lifecycle of Dockerized applications
    to remote Linux servers. Handles:
    
    - Git repository cloning/updating
    - SSH connectivity testing
    - Remote environment preparation (Docker, Docker Compose, Nginx)
    - Container building and deployment
    - Nginx reverse proxy configuration
    - Comprehensive deployment validation

REQUIREMENTS:
    Local:  git, ssh, scp/rsync, curl
    Remote: Linux server with SSH access (key-based authentication)

EXAMPLES:
    # Normal deployment
    ./$SCRIPT_NAME
    
    # Cleanup existing deployment
    ./$SCRIPT_NAME --cleanup
    
    # Show help
    ./$SCRIPT_NAME --help

EXIT CODES:
    0   - Success
    1   - General error
    2   - Input validation failed
    3   - SSH connection failed
    4   - Deployment failed
    5   - Configuration error
    130 - Interrupted by user

For more information, check the generated log file after execution.

================================================================================
USAGE
}

# Main function - orchestrates entire deployment process
main() {
    # Parse command line arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --cleanup)
                CLEANUP_MODE=1
                shift
                ;;
            --help|-h)
                show_usage
                exit $EXIT_SUCCESS
                ;;
            --version|-v)
                printf "%s version %s\n" "$SCRIPT_NAME" "$SCRIPT_VERSION"
                exit $EXIT_SUCCESS
                ;;
            *)
                printf "%s Error: Unknown option: %s\n" "$SYMBOL_ERROR" "$1"
                printf "Run './%s --help' for usage information\n" "$SCRIPT_NAME"
                exit $EXIT_VALIDATION_ERROR
                ;;
        esac
    done
    
    # Initialize logging
    initialize_logging
    
    # Handle cleanup mode
    if [ "$CLEANUP_MODE" -eq 1 ]; then
        cleanup_deployment
        # cleanup_deployment exits, so we won't reach here
    fi
    
    # Display welcome banner
    printf "\n"
    printf "================================================================================\n"
    printf "%s DOCKER DEPLOYMENT AUTOMATION SCRIPT\n" "$SYMBOL_ROCKET"
    printf "================================================================================\n"
    printf "Version: %s\n" "$SCRIPT_VERSION"
    printf "Started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "================================================================================\n\n"
    
    log "INFO" "Starting deployment workflow"
    
    # Execute deployment steps in sequence
    collect_deployment_parameters
    clone_or_update_repository
    verify_docker_configuration
    test_ssh_connectivity
    prepare_remote_environment
    transfer_application_files
    deploy_docker_containers
    verify_container_health
    configure_nginx_proxy
    validate_deployment
    
    # Display success summary
    printf "\n"
    printf "================================================================================\n"
    printf "%s DEPLOYMENT COMPLETED SUCCESSFULLY\n" "$SYMBOL_CELEBRATE"
    printf "================================================================================\n"
    printf "\n"
    printf "%s Access your application at: %shttp://%s%s\n" \
           "$SYMBOL_NETWORK" "$COLOR_GREEN" "$SERVER_IP" "$COLOR_RESET"
    printf "%s Nginx reverse proxy: Port 80 -> Port %s\n" \
           "$SYMBOL_INFO" "$APP_PORT"
    printf "%s Log file: %s%s%s\n" \
           "$SYMBOL_INFO" "$COLOR_CYAN" "$LOG_FILE" "$COLOR_RESET"
    printf "\n"
    printf "To remove this deployment, run:\n"
    printf "  ./%s --cleanup\n" "$SCRIPT_NAME"
    printf "\n"
    printf "================================================================================\n"
    
    log "SUCCESS" "Deployment workflow completed successfully"
}

# ============================================================================
# SCRIPT ENTRY POINT
# ============================================================================

# Execute main function with all command line arguments
main "$@"

# Explicit success exit (trap will handle logging)
exit $EXIT_SUCCESS