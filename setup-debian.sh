#!/usr/bin/env bash
#
# setup-debian.sh — one-shot local dev environment setup for Debian/Ubuntu.
#
# Usage: run as your normal user (NOT root):  ./setup-debian.sh
# All interaction happens at the very beginning (sudo password + a few prompts),
# then the script runs unattended. Safe to re-run: completed steps are skipped.
#
# Set SKIP_DB_PULL=1 to skip pre-downloading the database images.

set -euo pipefail

BOLD=$(tput bold 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$RESET"; }

# ---------------------------------------------------------------- sanity checks
if [[ $EUID -eq 0 ]]; then
    echo "Run this script as your normal user (it uses sudo internally), not as root." >&2
    exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get not found — this script targets Debian/Ubuntu." >&2
    exit 1
fi
. /etc/os-release
if [[ ${ID:-} != debian && ${ID:-} != ubuntu ]]; then
    echo "Unsupported distro '${ID:-unknown}' — this script targets Debian/Ubuntu." >&2
    exit 1
fi
CODENAME=${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}
export DEBIAN_FRONTEND=noninteractive

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
while [[ -z $GIT_NAME ]]; do
    read -rp "Git user.name${CUR_NAME:+ [$CUR_NAME]}: " GIT_NAME
    GIT_NAME=${GIT_NAME:-$CUR_NAME}
done
GIT_EMAIL=""
while [[ -z $GIT_EMAIL ]]; do
    read -rp "Git user.email${CUR_EMAIL:+ [$CUR_EMAIL]}: " GIT_EMAIL
    GIT_EMAIL=${GIT_EMAIL:-$CUR_EMAIL}
done

# git credential to store for HTTPS remotes (GitHub/GitLab require a token, not
# your account password)
GIT_HOST=""
GIT_LOGIN=""
GIT_TOKEN=""
if [[ -f $HOME/.git-credentials ]]; then
    echo "~/.git-credentials already exists — skipping git credential prompt."
else
    read -rp "Git host [github.com]: " GIT_HOST
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
step "Updating package index and installing prerequisites"
sudo apt-get update
sudo apt-get -y upgrade
sudo apt-get -y install ca-certificates curl wget gnupg jq apt-transport-https \
    software-properties-common unzip

step "Enabling extra repository components (needed for Steam)"
if [[ $ID == ubuntu ]]; then
    sudo add-apt-repository -y multiverse
else
    if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
        sudo sed -i 's/^Components: .*/Components: main contrib non-free non-free-firmware/' \
            /etc/apt/sources.list.d/debian.sources
    else
        sudo sed -i -E 's/^(deb .*main)$/\1 contrib non-free/' /etc/apt/sources.list
    fi
fi
sudo dpkg --add-architecture i386
sudo apt-get update

# ---------------------------------------------------------------- git
step "Installing and configuring git"
sudo apt-get -y install git
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch main
git config --global credential.helper store
if [[ -n $GIT_TOKEN ]]; then
    printf 'https://%s:%s@%s\n' "$GIT_LOGIN" "$GIT_TOKEN" "$GIT_HOST" > "$HOME/.git-credentials"
    chmod 600 "$HOME/.git-credentials"
fi

# ---------------------------------------------------------------- openvpn
step "Installing OpenVPN client"
sudo apt-get -y install openvpn network-manager-openvpn network-manager-openvpn-gnome

# ---------------------------------------------------------------- project dirs
step "Creating project directories under \$HOME/Projects"
mkdir -p "$HOME/Projects/littleTaller" "$HOME/Projects/AKI" "$HOME/Projects/Personal"

# ---------------------------------------------------------------- google chrome
step "Installing Google Chrome"
if ! command -v google-chrome >/dev/null 2>&1; then
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | sudo gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    sudo apt-get update
    sudo apt-get -y install google-chrome-stable
fi

# ---------------------------------------------------------------- brave
step "Installing Brave browser"
if ! command -v brave-browser >/dev/null 2>&1; then
    sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
        | sudo tee /etc/apt/sources.list.d/brave-browser-release.list >/dev/null
    sudo apt-get update
    sudo apt-get -y install brave-browser
fi

# ---------------------------------------------------------------- phpstorm
# Standalone tarball install (not snap: JetBrains warns the snap degrades
# performance and breaks Chromium JS debugging). /opt/phpstorm stays owned by
# the user so the IDE's built-in updater works.
step "Installing PhpStorm (official tarball)"
if [[ ! -x /opt/phpstorm/bin/phpstorm.sh ]]; then
    PS_URL=$(curl -fsSL 'https://data.services.jetbrains.com/products/releases?code=PS&latest=true&type=release' \
        | jq -r '.PS[0].downloads.linux.link')
    TMP=$(mktemp -d)
    curl -fL "$PS_URL" -o "$TMP/phpstorm.tar.gz"
    tar -xzf "$TMP/phpstorm.tar.gz" -C "$TMP"
    PS_DIR=$(find "$TMP" -maxdepth 1 -type d -name 'PhpStorm-*' | head -n1)
    sudo mv "$PS_DIR" /opt/phpstorm
    sudo chown -R "$USER": /opt/phpstorm
    sudo ln -sf /opt/phpstorm/bin/phpstorm.sh /usr/local/bin/phpstorm
    rm -rf "$TMP"
    mkdir -p "$HOME/.local/share/applications"
    cat > "$HOME/.local/share/applications/phpstorm.desktop" <<'DESKTOP'
[Desktop Entry]
Name=PhpStorm
Exec=/opt/phpstorm/bin/phpstorm.sh %f
Icon=/opt/phpstorm/bin/phpstorm.svg
Type=Application
Categories=Development;IDE;
Terminal=false
StartupWMClass=jetbrains-phpstorm
DESKTOP
fi

# ---------------------------------------------------------------- slack
step "Installing Slack"
if ! command -v slack >/dev/null 2>&1; then
    curl -fsSL https://packagecloud.io/slacktechnologies/slack/gpgkey \
        | sudo gpg --dearmor --yes -o /usr/share/keyrings/slack.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/slack.gpg] https://packagecloud.io/slacktechnologies/slack/debian/ jessie main" \
        | sudo tee /etc/apt/sources.list.d/slack.list >/dev/null
    sudo apt-get update
    sudo apt-get -y install slack-desktop
fi

# ---------------------------------------------------------------- postman
step "Installing Postman (official tarball)"
if [[ ! -d /opt/Postman ]]; then
    TMP=$(mktemp -d)
    curl -fL https://dl.pstmn.io/download/latest/linux_64 -o "$TMP/postman.tar.gz"
    sudo tar -xzf "$TMP/postman.tar.gz" -C /opt
    sudo chown -R "$USER": /opt/Postman
    sudo ln -sf /opt/Postman/Postman /usr/local/bin/postman
    rm -rf "$TMP"
    mkdir -p "$HOME/.local/share/applications"
    cat > "$HOME/.local/share/applications/postman.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Postman
Exec=/opt/Postman/Postman
Icon=/opt/Postman/app/resources/app/assets/icon.png
Type=Application
Categories=Development;
Terminal=false
DESKTOP
fi

# ---------------------------------------------------------------- claude code
step "Installing Claude Code CLI"
if ! command -v claude >/dev/null 2>&1; then
    curl -fsSL https://claude.ai/install.sh | bash
fi

# ---------------------------------------------------------------- steam
step "Installing Steam"
# pre-accept the Steam license so the install stays non-interactive
echo "steam steam/question select I AGREE" | sudo debconf-set-selections
echo "steam steam/license note ''" | sudo debconf-set-selections
sudo apt-get -y install steam-installer || sudo apt-get -y install steam

# ---------------------------------------------------------------- dbeaver
step "Installing DBeaver Community"
if ! command -v dbeaver >/dev/null 2>&1; then
    curl -fsSL https://dbeaver.io/debs/dbeaver.gpg.key \
        | sudo gpg --dearmor --yes -o /usr/share/keyrings/dbeaver.gpg
    echo "deb [signed-by=/usr/share/keyrings/dbeaver.gpg] https://dbeaver.io/debs/dbeaver-ce /" \
        | sudo tee /etc/apt/sources.list.d/dbeaver.list >/dev/null
    sudo apt-get update
    sudo apt-get -y install dbeaver-ce
fi

# ---------------------------------------------------------------- docker engine
step "Installing Docker Engine + compose plugin"
if ! command -v docker >/dev/null 2>&1; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${CODENAME} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get -y install docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi
# the docker daemon autostarts on boot; the database containers below do NOT
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

# ---------------------------------------------------------------- databases
step "Setting up database stack (MySQL, Postgres, MSSQL) in $DB_DIR"
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
    printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD" > "$DB_DIR/.env"
fi
chmod 600 "$DB_DIR/.env"

sudo docker compose -f "$DB_DIR/docker-compose.yml" config -q
if [[ ${SKIP_DB_PULL:-0} != 1 ]]; then
    echo "Pre-downloading database images (set SKIP_DB_PULL=1 to skip)..."
    sudo docker compose -f "$DB_DIR/docker-compose.yml" pull
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