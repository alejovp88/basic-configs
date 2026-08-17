#!/usr/bin/env bash
#
# setup-arch.sh — one-shot local dev environment setup for Arch Linux.
#
# Usage: run as your normal user (NOT root):  ./setup-arch.sh
# All interaction happens at the very beginning (sudo password + a few prompts),
# then the script runs unattended. Safe to re-run: completed steps are skipped.
#
# Set SKIP_DB_PULL=1 to skip pre-downloading the database images.

set -Eeuo pipefail

BOLD=$(tput bold 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$RESET"; }
log()  { printf -- '  -> %s\n' "$1"; }
# on any failure, print exactly which command died and where before exiting
trap 'printf "\n%s*** FAILED at line %s: %s%s\n" "$BOLD" "$LINENO" "$BASH_COMMAND" "$RESET" >&2' ERR

# ---------------------------------------------------------------- sanity checks
if [[ $EUID -eq 0 ]]; then
    echo "Run this script as your normal user (makepkg refuses to run as root)." >&2
    exit 1
fi
if ! command -v pacman >/dev/null 2>&1; then
    echo "pacman not found — this script targets Arch Linux." >&2
    exit 1
fi

DB_DIR="$HOME/Projects/databases"

# ---------------------------------------------------------------- all prompts up front
step "Collecting all required input (nothing else will be asked after this)"

sudo -v
# keep sudo alive for the whole run so it never re-prompts
( while true; do sleep 60; sudo -n true; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

CUR_NAME=""
CUR_EMAIL=""
if command -v git >/dev/null 2>&1; then
    CUR_NAME=$(git config --global user.name 2>/dev/null || true)
    CUR_EMAIL=$(git config --global user.email 2>/dev/null || true)
fi

GIT_NAME=""
GIT_EMAIL=""
if [[ -n $CUR_NAME && -n $CUR_EMAIL ]]; then
    echo "git already configured ($CUR_NAME <$CUR_EMAIL>) — skipping git identity prompts."
    GIT_NAME=$CUR_NAME
    GIT_EMAIL=$CUR_EMAIL
else
    while [[ -z $GIT_NAME ]]; do
        read -rp "Git user.name${CUR_NAME:+ [$CUR_NAME]}: " GIT_NAME
        GIT_NAME=${GIT_NAME:-$CUR_NAME}
    done
    while [[ -z $GIT_EMAIL ]]; do
        read -rp "Git user.email${CUR_EMAIL:+ [$CUR_EMAIL]}: " GIT_EMAIL
        GIT_EMAIL=${GIT_EMAIL:-$CUR_EMAIL}
    done
fi

# git credential to store for HTTPS remotes (GitHub/GitLab require a token, not
# your account password)
GIT_HOST=""
GIT_LOGIN=""
GIT_TOKEN=""
if [[ -f $HOME/.git-credentials ]]; then
    echo "~/.git-credentials already exists — skipping git credential prompt."
else
    echo "Git host: the server your HTTPS token belongs to, e.g. github.com,"
    echo "gitlab.com, bitbucket.org or a self-hosted domain (git.mycompany.com)."
    read -rp "Git host (Enter for github.com): " GIT_HOST
    GIT_HOST=${GIT_HOST:-github.com}
    while [[ -z $GIT_LOGIN ]]; do
        read -rp "Git login (your username on $GIT_HOST): " GIT_LOGIN
    done
    while [[ -z $GIT_TOKEN ]]; do
        read -rsp "Git password / personal access token: " GIT_TOKEN; echo
    done
fi

# database password: must satisfy MSSQL SA policy (8+ chars, upper, lower, digit,
# symbol) or the MSSQL container refuses to start. Characters that would break
# the compose .env file are rejected.
valid_db_password() {
    local p=$1
    [[ ${#p} -ge 8 ]] || { echo "  must be at least 8 characters"; return 1; }
    [[ $p =~ [A-Z] && $p =~ [a-z] && $p =~ [0-9] && $p =~ [^a-zA-Z0-9] ]] \
        || { echo "  must contain upper, lower, digit and symbol (MSSQL policy)"; return 1; }
    case $p in
        *[\'\"\\\$\#\ \`]*) echo "  must not contain spaces or any of: ' \" \\ \$ # \`"; return 1 ;;
    esac
}
DB_PASSWORD=""
if [[ -f $DB_DIR/.env ]]; then
    echo "$DB_DIR/.env already exists — keeping the existing database password."
else
    while true; do
        read -rsp "Database password (MySQL root / Postgres / MSSQL sa): " DB_PASSWORD; echo
        valid_db_password "$DB_PASSWORD" || continue
        read -rsp "Confirm database password: " DB_PASSWORD2; echo
        [[ $DB_PASSWORD == "$DB_PASSWORD2" ]] && break
        echo "  passwords do not match, try again"
    done
fi

echo
echo "All input collected — the rest is unattended. Go grab a coffee."

# ---------------------------------------------------------------- base system
step "Updating system and installing base packages"
log "pacman -Syu (full system upgrade)"
sudo pacman -Syu --noconfirm
log "pacman -S base-devel git curl wget unzip"
sudo pacman -S --needed --noconfirm base-devel git curl wget unzip

# ---------------------------------------------------------------- git config
step "Configuring git"
log "git config --global (name, email, default branch, credential helper)"
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch main
git config --global credential.helper store
if [[ -n $GIT_TOKEN ]]; then
    log "writing ~/.git-credentials"
    printf 'https://%s:%s@%s\n' "$GIT_LOGIN" "$GIT_TOKEN" "$GIT_HOST" > "$HOME/.git-credentials"
    chmod 600 "$HOME/.git-credentials"
fi

# ---------------------------------------------------------------- yay (AUR helper)
step "Installing yay (AUR helper)"
if ! command -v yay >/dev/null 2>&1; then
    TMP=$(mktemp -d)
    log "git clone yay-bin from the AUR"
    git clone https://aur.archlinux.org/yay-bin.git "$TMP/yay-bin"
    log "makepkg -si (build and install yay)"
    ( cd "$TMP/yay-bin" && makepkg -si --noconfirm )
    rm -rf "$TMP"
fi

# ---------------------------------------------------------------- openvpn
step "Installing OpenVPN client"
log "pacman -S openvpn networkmanager-openvpn"
sudo pacman -S --needed --noconfirm openvpn networkmanager-openvpn

# ---------------------------------------------------------------- project dirs
step "Creating project directories under \$HOME/Projects"
log "mkdir -p ~/Projects/{littleTaller,AKI,Personal}"
mkdir -p "$HOME/Projects/littleTaller" "$HOME/Projects/AKI" "$HOME/Projects/Personal"

# ---------------------------------------------------------------- desktop apps (AUR)
# Chrome, Brave, PhpStorm, Slack and Postman only exist in the AUR on Arch.
# The AUR 'phpstorm' package repacks the official tarball — same no-snap install
# JetBrains recommends, but updates arrive through yay like everything else.
step "Installing Chrome, Brave, PhpStorm, Slack and Postman from the AUR"
log "yay -S google-chrome brave-bin phpstorm slack-desktop postman-bin"
yay -S --needed --noconfirm --removemake \
    google-chrome brave-bin phpstorm slack-desktop postman-bin

# ---------------------------------------------------------------- steam
step "Installing Steam (enabling multilib repo)"
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    log "enabling [multilib] in /etc/pacman.conf"
    sudo sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//' /etc/pacman.conf
    log "pacman -Syu (refresh with multilib enabled)"
    sudo pacman -Syu --noconfirm
fi
log "pacman -S steam"
sudo pacman -S --needed --noconfirm steam

# ---------------------------------------------------------------- dbeaver
step "Installing DBeaver Community"
log "pacman -S dbeaver"
sudo pacman -S --needed --noconfirm dbeaver

# ---------------------------------------------------------------- docker engine
step "Installing Docker Engine + compose plugin"
log "pacman -S docker docker-compose docker-buildx"
sudo pacman -S --needed --noconfirm docker docker-compose docker-buildx
# the docker daemon autostarts on boot; the database containers below do NOT
log "systemctl enable --now docker.service"
sudo systemctl enable --now docker.service
log "usermod -aG docker $USER"
sudo usermod -aG docker "$USER"

# ---------------------------------------------------------------- databases
step "Setting up database stack (MySQL, Postgres, MSSQL) in $DB_DIR"
log "writing $DB_DIR/docker-compose.yml"
mkdir -p "$DB_DIR"
# no restart policy on any service: only the docker daemon autostarts on boot,
# databases are started manually with `docker compose up -d <service>`
cat > "$DB_DIR/docker-compose.yml" <<'COMPOSE'
services:
  mysql:
    image: mysql:8.4
    container_name: dev-mysql
    # native password auth so DBeaver/JDBC connect without extra driver settings
    command: --mysql-native-password=ON
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_HOST: "%"
    ports:
      - "3306:3306"
    volumes:
      - mysql-data:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h127.0.0.1 -uroot -p\"$$MYSQL_ROOT_PASSWORD\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 10

  postgres:
    image: postgres:17
    container_name: dev-postgres
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    ports:
      - "5432:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 10

  mssql:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: dev-mssql
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: ${DB_PASSWORD}
      MSSQL_PID: Developer
    ports:
      - "1433:1433"
    volumes:
      - mssql-data:/var/opt/mssql
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P \"$$MSSQL_SA_PASSWORD\" -Q 'SELECT 1' -b -o /dev/null"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

volumes:
  mysql-data:
  postgres-data:
  mssql-data:
COMPOSE

if [[ ! -f $DB_DIR/.env ]]; then
    log "writing $DB_DIR/.env"
    printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD" > "$DB_DIR/.env"
fi
chmod 600 "$DB_DIR/.env"

log "docker compose config -q (validating compose file)"
sudo docker compose -f "$DB_DIR/docker-compose.yml" config -q
if [[ ${SKIP_DB_PULL:-0} != 1 ]]; then
    echo "Pre-downloading database images (set SKIP_DB_PULL=1 to skip)..."
    log "docker compose pull"
    sudo docker compose -f "$DB_DIR/docker-compose.yml" pull
fi

# ---------------------------------------------------------------- claude code
step "Installing Claude Code CLI"
if ! command -v claude >/dev/null 2>&1; then
    log "curl https://claude.ai/install.sh | bash"
    curl -fsSL https://claude.ai/install.sh | bash
fi

# ---------------------------------------------------------------- done
step "Done!"
cat <<SUMMARY

Setup complete. Remaining notes:

  * Log out and back in so your user picks up the 'docker' group.
  * Databases live in $DB_DIR (password in .env, chmod 600). They do NOT
    autostart; run them on demand:
        docker compose -f $DB_DIR/docker-compose.yml up -d mysql
        docker compose -f $DB_DIR/docker-compose.yml up -d postgres mssql
        docker compose -f $DB_DIR/docker-compose.yml stop
  * DBeaver connections (all on localhost):
        MySQL     localhost:3306  user 'root'      + your DB password
        Postgres  localhost:5432  user 'postgres'  + your DB password
        MSSQL     localhost:1433  user 'sa'        + your DB password
  * Git credentials are stored in ~/.git-credentials (plaintext, chmod 600).
  * Claude Code may need a new shell session to appear on PATH.

SUMMARY