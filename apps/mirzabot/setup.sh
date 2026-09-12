#!/usr/bin/env bash
# ============================================================================
#  apps/mirzabot/setup.sh — Mirza Bot (PHP + Apache + MySQL + Telegram webhook).
#
#  How it fits on a runner-as-VPS:
#    * upstream's installer wants "a domain that points to this server" + a
#      Let's Encrypt certificate over HTTP-01. A GitHub runner has no inbound
#      port 80 and no stable IP, so we give it the node's Funnel hostname
#      (mrphon3shop-node.<tailnet>.ts.net) and pre-seed /etc/letsencrypt/live/
#      with the REAL certificate Tailscale already issues for that name. The
#      installer then skips issuance and writes its vhost with a valid cert.
#    * Apache stays bound to the node; the public URL is Funnel HTTPS on 443
#      with the TLS terminated by the relay (backend https+insecure).
#    * Telegram posts to https://<fqdn>/... — that is what makes the bot work
#      on a machine with no public IP of its own.
#
#  Required secrets (GitHub -> Settings -> Secrets):
#    TELEGRAM_BOT_TOKEN   from @BotFather
#    TELEGRAM_ADMIN_ID    your numeric chat id
#  optional: MIRZA_BOT_NAME, MIRZA_VERSION
#
#  Everything it creates is persisted:
#    /var/www/html/mirzaprobotconfig (app + config.php), /var/lib/mysql,
#    /etc/letsencrypt, /root/confmirza, /etc/apache2/sites-* (see services.json)
# ============================================================================
export LOG_TAG=mirza
. "$(dirname "$0")/../../scripts/lib/common.sh"
load_config

SRC="${MIRZA_SRC:-/opt/mrphon3shop/software/mirzabot-src}"
FQDN="${NODE_HOSTNAME}.${TAILNET_DNS}"
APP_DIR=/var/www/html/mirzaprobotconfig
CONF_DIR=/root/confmirza
MIRZA_CONF="$CONF_DIR/mrphon3shop.json"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_ADMIN_ID:-}" ]; then
  warn "TELEGRAM_BOT_TOKEN / TELEGRAM_ADMIN_ID are not set — Mirza Bot stays off this boot"
  warn "set them once with:  node-secret TELEGRAM_BOT_TOKEN   then  manage -> reboot-chain"
  exit 0
fi

step "Mirza Bot: dependencies (Apache + PHP 8.2 + MariaDB)"
if ! have apache2 || ! have mariadb || ! have php8.2; then
  retry 2 3 sudo apt-get update -qq || true
  retry 2 3 sudo apt-get install -y -qq software-properties-common lsb-release ca-certificates \
      apache2 mariadb-server unzip curl >/dev/null || die "base stack install failed"
  if ! have php8.2; then
    sudo add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || warn "ondrej PPA not added — trying distro PHP"
    retry 2 3 sudo apt-get update -qq || true
    sudo apt-get install -y -qq php8.2 php8.2-cli php8.2-mysql php8.2-curl php8.2-mbstring \
      php8.2-xml php8.2-zip php8.2-gd php8.2-bcmath libapache2-mod-php8.2 >/dev/null \
      || warn "PHP 8.2 not installed from the PPA — upstream installer will retry"
  fi
  sudo systemctl enable --now apache2 mariadb >/dev/null 2>&1 || true
fi

step "TLS material for $FQDN (real certificate, issued by Tailscale/Let's Encrypt)"
LE_DIR="/etc/letsencrypt/live/$FQDN"
if [ ! -s "$LE_DIR/fullchain.pem" ]; then
  sudo mkdir -p "$LE_DIR"
  if sudo tailscale cert --cert-file="/tmp/$FQDN.crt" --key-file="/tmp/$FQDN.key" "$FQDN" >/dev/null 2>&1; then
    sudo cp -f "/tmp/$FQDN.crt" "$LE_DIR/fullchain.pem"
    sudo cp -f "/tmp/$FQDN.crt" "$LE_DIR/cert.pem"
    sudo cp -f "/tmp/$FQDN.key" "$LE_DIR/privkey.pem"
    sudo cp -f "/tmp/$FQDN.crt" "$LE_DIR/chain.pem"
    sudo chmod 600 "$LE_DIR/privkey.pem"; rm -f "/tmp/$FQDN.crt" "/tmp/$FQDN.key"
    log "certificate for $FQDN in place (upstream installer will skip issuance)"
  else
    warn "tailscale cert failed — the installer will try certbot, which cannot work here"
  fi
else
  log "certificate already present"
fi

step "database credentials (generated once, then carried by the encrypted state)"
sudo mkdir -p "$CONF_DIR"; sudo chmod 700 "$CONF_DIR"
if sudo test -s "$MIRZA_CONF"; then
  DB_NAME="$(sudo jq -r .db_name "$MIRZA_CONF")"; DB_USER="$(sudo jq -r .db_user "$MIRZA_CONF")"; DB_PASS="$(sudo jq -r .db_pass "$MIRZA_CONF")"
else
  DB_NAME="mirza"; DB_USER="mirza"; DB_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  sudo jq -n --arg n "$DB_NAME" --arg u "$DB_USER" --arg p "$DB_PASS" --arg ts "$(iso)" \
       '{db_name:$n, db_user:$u, db_pass:$p, created_at:$ts}' | sudo tee "$MIRZA_CONF" >/dev/null
  sudo chmod 600 "$MIRZA_CONF"
  log "database credentials generated (stored in $MIRZA_CONF, never printed)"
fi

sudo systemctl start mariadb >/dev/null 2>&1 || sudo systemctl start mysql >/dev/null 2>&1 || true

step "run upstream installer (non-interactive, domain = the Funnel name)"
if [ ! -s "$SRC/install.sh" ]; then
  die "Mirza sources missing at $SRC (program 'mirzabot-src' must install first)"
fi
ARGS=(install --name "${MIRZA_BOT_NAME:-mrphonvpnbot}" --token "$TELEGRAM_BOT_TOKEN" \
      --admin "$TELEGRAM_ADMIN_ID" --domain "$FQDN" --db-user "$DB_USER" --db-pass "$DB_PASS")
[ -n "${MIRZA_VERSION:-}" ] && ARGS+=(--version "$MIRZA_VERSION")
[ -n "${MIRZA_CHANNEL:-}" ] && ARGS+=(--channel "$MIRZA_CHANNEL")

if [ -s "$APP_DIR/config.php" ] && sudo grep -q "mirzabot" "$APP_DIR/config.php" 2>/dev/null; then
  log "bot is already installed in $APP_DIR — running the updater instead"
  ARGS=(update)
fi

# the upstream installer is long: bounded, non-interactive, log kept on the node
if timeout "${MIRZA_INSTALL_TIMEOUT:-900}" sudo bash "$SRC/install.sh" "${ARGS[@]}" </dev/null \
     >/opt/mrphon3shop/logs/mirzabot-install.log 2>&1; then
  log "upstream installer finished (log: /opt/mrphon3shop/logs/mirzabot-install.log)"
else
  warn "upstream installer returned non-zero — see the log on the node (it may be waiting for input)"
fi

step "health of the local web stack"
sudo systemctl enable apache2 >/dev/null 2>&1 || true
sudo systemctl restart apache2 >/dev/null 2>&1 || true
for i in 1 2 3 4 5; do
  if curl -sk -o /dev/null --max-time 5 "https://127.0.0.1/" || curl -s -o /dev/null --max-time 5 "http://127.0.0.1/"; then
    log "web stack answers locally"; break
  fi
  sleep 2
done

step "public door for Telegram (Funnel HTTPS on 443, TLS terminated by the relay)"
sudo tailscale funnel --bg --yes --https=443 "https+insecure://127.0.0.1:443" >/dev/null 2>&1 \
  || warn "could not publish the Funnel route for the bot"
log "webhook host: https://${FQDN}/  (telegram will post here)"
