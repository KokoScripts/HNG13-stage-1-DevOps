#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Logging
LOG_DIR="$PWD/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

info()  { printf "[INFO] %s\n" "$*"; }
warn()  { printf "[WARN] %s\n" "$*"; }
error() { printf "[ERROR] %s\n" "$*" >&2; }

trap 'error "Script failed at line $LINENO. Check $LOG_FILE"; exit 2' ERR

# Defaults
DEFAULT_BRANCH="main"
REMOTE_APP_DIR="/opt/deploy_app"
NGINX_SITE_NAME="deployed_app"
CLEANUP_MODE=0

# Helpers
prompt() {
  local v="$1"; local prompttext="$2"; local default="$3"
  read -r -p "$prompttext ${default:+[$default]}: " vtemp
  if [ -z "$vtemp" ]; then vtemp="${default:-}"; fi
  eval "$v"='"$vtemp"'
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# Flags 
if [ "${1:-}" = "--cleanup" ]; then
  CLEANUP_MODE=1
fi

# Input collection
if [ "$CLEANUP_MODE" -eq 0 ]; then
  info "Collecting inputs..."
  prompt GIT_URL "Git repository URL (https:// or git@...)" ""
  prompt GIT_PAT "Personal Access Token (if private repo) (leave blank for public)" ""
  prompt BRANCH "Branch name" "$DEFAULT_BRANCH"
  prompt SSH_USER "Remote SSH username" ""
  prompt REMOTE_IP "Remote server IP" ""
  prompt SSH_KEY "Path to SSH private key" "$HOME/.ssh/id_rsa"
  prompt APP_PORT "Internal container port (e.g., 8080)" "8080"

  # Basic validations
  if [ -z "$GIT_URL" ]; then error "Git URL is required"; exit 1; fi
  if [ -z "$SSH_USER" ] || [ -z "$REMOTE_IP" ]; then error "SSH details required"; exit 1; fi
  if [ ! -f "$SSH_KEY" ]; then error "SSH key file not found: $SSH_KEY"; exit 1; fi
fi

# Remote command runner
SSH_BASE="ssh -i \"$SSH_KEY\" -o BatchMode=yes -o StrictHostKeyChecking=no $SSH_USER@$REMOTE_IP"
SCP_BASE="scp -i \"$SSH_KEY\" -o StrictHostKeyChecking=no -r"

run_remote() {
  local cmd="$1"
  info "REMOTE> $cmd"
  eval $SSH_BASE "'$cmd'"
}

# Cleanup mode
if [ "$CLEANUP_MODE" -eq 1 ]; then
  read -r -p "Cleanup confirmed? This will stop/remove containers and remove $REMOTE_APP_DIR on remote. Type YES to proceed: " confirm
  if [ "$confirm" != "YES" ]; then info "Cleanup aborted"; exit 0; fi

  info "Stopping and removing containers, removing files and nginx config on remote..."
  run_remote "sudo docker compose -f $REMOTE_APP_DIR/docker-compose.yml down || true; sudo docker ps -a --filter 'name=deployed_app' -q | xargs -r sudo docker rm -f || true; sudo rm -rf $REMOTE_APP_DIR; sudo rm -f /etc/nginx/sites-enabled/$NGINX_SITE_NAME /etc/nginx/sites-available/$NGINX_SITE_NAME; sudo nginx -t && sudo systemctl reload nginx || true"
  info "Cleanup complete."
  exit 0
fi

# Clone or update repo locally
info "Preparing local repo..."
REPO_NAME="$(basename -s .git "$GIT_URL")"
CLONE_DIR="$PWD/$REPO_NAME"
if [ -d "$CLONE_DIR/.git" ]; then
  info "Repo exists locally, pulling latest..."
  (cd "$CLONE_DIR" && git fetch --all && git checkout "$BRANCH" && git pull origin "$BRANCH")
else
  info "Cloning repository..."
  if [ -n "$GIT_PAT" ]; then
    # For HTTPS PAT auth: embed token in URL (warning: exposes token in process list - consider using git credential helper)
    # Normalize https URL
    if echo "$GIT_URL" | grep -q "https://"; then
      AUTH_URL="$(echo "$GIT_URL" | sed -E "s#https://#https://$GIT_PAT@#")"
      git clone --branch "$BRANCH" "$AUTH_URL" "$CLONE_DIR"
    else
      git clone --branch "$BRANCH" "$GIT_URL" "$CLONE_DIR"
    fi
  else
    git clone --branch "$BRANCH" "$GIT_URL" "$CLONE_DIR"
  fi
fi

cd "$CLONE_DIR"
info "Now in $(pwd)"

if [ ! -f Dockerfile ] && [ ! -f docker-compose.yml ] && [ ! -f docker-compose.yaml ]; then
  error "No Dockerfile or docker-compose.yml found in repo root. Aborting."
  exit 1
fi
info "Found Dockerfile or docker-compose.yml."

# ---------- Verify remote SSH connectivity ----------
info "Checking SSH connectivity..."
if ! eval $SSH_BASE "echo connected" >/dev/null 2>&1; then
  error "SSH connection to $SSH_USER@$REMOTE_IP failed. Fix SSH access and try again."
  exit 1
fi
info "SSH connectivity OK."

# ---------- Prepare remote environment ----------
info "Preparing remote environment (installing Docker, docker-compose, nginx if missing)..."
# Install script to run remotely
REMOTE_SETUP_SCRIPT=$(cat <<'EOF'
set -e
# Detect apt-based system
if command -v apt >/dev/null 2>&1; then
  sudo apt update -y
  # Install docker, docker-compose plugin, nginx
  if ! command -v docker >/dev/null 2>&1; then
    sudo apt install -y ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update -y
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
  if ! command -v docker-compose >/dev/null 2>&1; then
    # Try docker-compose plugin first; if not present, install python-based docker-compose
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      true
    else
      sudo apt install -y python3-pip
      sudo pip3 install docker-compose
    fi
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    sudo apt install -y nginx
  fi
  sudo systemctl enable docker --now || true
  sudo systemctl enable nginx --now || true
  sudo usermod -aG docker $USER || true
  echo "versions: docker $(docker --version || echo n/a) docker-compose $(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || echo n/a) nginx $(nginx -v 2>&1 || echo n/a)"
else
  echo "Non-apt system: please manually install docker, docker-compose, nginx"
  exit 1
fi
EOF
)

# run remote setup
run_remote "$REMOTE_SETUP_SCRIPT"

# ---------- Transfer project files ----------
info "Transferring project files to remote $REMOTE_IP:$REMOTE_APP_DIR ..."
# Use rsync if available on local; otherwise scp
if cmd_exists rsync; then
  RSYNC_CMD="rsync -avz -e \"ssh -i $SSH_KEY -o StrictHostKeyChecking=no\" --delete ./ $SSH_USER@$REMOTE_IP:$REMOTE_APP_DIR/"
  info "Running: $RSYNC_CMD"
  eval $RSYNC_CMD
else
  info "rsync not found, using scp (slower)..."
  eval $SCP_BASE " ./ $SSH_USER@$REMOTE_IP:$REMOTE_APP_DIR"
fi

# ---------- Deploy app on remote ----------
info "Deploying app on remote..."
REMOTE_DEPLOY_CMD=$(cat <<EOF
set -e
cd "$REMOTE_APP_DIR"
# If docker-compose file exists, use it
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  sudo docker compose down || true
  sudo docker compose build --pull
  sudo docker compose up -d
else
  # Build and run with docker
  if [ -f Dockerfile ]; then
    sudo docker build -t deployed_app .
    sudo docker ps -q --filter "name=deployed_app" | xargs -r sudo docker rm -f || true
    sudo docker run -d --name deployed_app -p $APP_PORT:$APP_PORT deployed_app
  else
    echo "No Dockerfile or compose file found"
    exit 1
  fi
fi

# Wait a few seconds for container to start
sleep 5

# Check container status
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
EOF
)

run_remote "$REMOTE_DEPLOY_CMD"

# ---------- Configure Nginx on remote ----------
info "Configuring nginx reverse proxy..."
NGINX_CONF=$(cat <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
)

# Copy nginx conf via ssh heredoc
run_remote "cat > /tmp/$NGINX_SITE_NAME.conf <<'NGCONF'
$NGINX_CONF
NGCONF
sudo mv /tmp/$NGINX_SITE_NAME.conf /etc/nginx/sites-available/$NGINX_SITE_NAME
sudo ln -sf /etc/nginx/sites-available/$NGINX_SITE_NAME /etc/nginx/sites-enabled/$NGINX_SITE_NAME
run_remote "sudo nginx -t && sudo systemctl reload nginx || (sudo tail -n 200 /var/log/nginx/error.log || true)"

info "Nginx configured to forward port 80 -> $APP_PORT"

# ---------- Validation ----------
info "Validating deployment from remote..."
run_remote "curl -sS -I http://127.0.0.1:$APP_PORT | head -n 10" || warn "Local container curl failed"
info "Validating nginx externally..."
if curl -sS -I "http://$REMOTE_IP" >/dev/null 2>&1; then
  info "External HTTP check OK: http://$REMOTE_IP"
else
  warn "External HTTP check failed. Check security group / firewall or Nginx config."
fi

info "Deployment finished. Log file: $LOG_FILE"
