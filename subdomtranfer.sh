#!/usr/bin/env bash
set -euo pipefail

APP_NAME="token-proxy"
APP_DIR="/opt/${APP_NAME}"
ENV_FILE="${APP_DIR}/.env"
SERVER_FILE="${APP_DIR}/server.js"
PACKAGE_FILE="${APP_DIR}/package.json"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}"
NGINX_LINK="/etc/nginx/sites-enabled/${APP_NAME}"
INSTALL_LOG="/var/log/${APP_NAME}-installer.log"
APP_LOG_DIR="/var/log/${APP_NAME}"
UNINSTALL_SCRIPT="${APP_DIR}/uninstall.sh"
NODE_USER="www-data"
LOCAL_APP_PORT="19091"

log() {
  mkdir -p "$(dirname "$INSTALL_LOG")"
  echo "[$(date '+%F %T')] $*" | tee -a "$INSTALL_LOG"
}

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Bu script root olarak calismali. Ornek: sudo bash 1.sh"
    exit 1
  fi
}

pause_screen() {
  echo
  read -r -p "Devam etmek icin Enter tusuna basin..." _
}

ask_required() {
  local label="$1"
  local example="$2"
  local value=""

  while true; do
    echo >&2
    echo "$label" >&2
    echo "Ornek: $example" >&2
    read -r -p "> " value

    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi

    echo "Bos gecilemez. Tekrar deneyin." >&2
  done
}

normalize_url() {
  local url="$1"
  url="${url%/}"
  echo "$url"
}

parse_url_parts() {
  local input="$1"

  PARSED_SCHEME=""
  PARSED_HOST=""
  PARSED_PORT=""
  PARSED_PATH=""

  if [[ "$input" =~ ^(https?)://([^/:]+)(:([0-9]+))?(/.*)?$ ]]; then
    PARSED_SCHEME="${BASH_REMATCH[1]}"
    PARSED_HOST="${BASH_REMATCH[2]}"
    PARSED_PORT="${BASH_REMATCH[4]:-}"
    PARSED_PATH="${BASH_REMATCH[5]:-/}"
  else
    echo "URL formati hatali: $input"
    return 1
  fi

  if [[ -z "$PARSED_PORT" ]]; then
    if [[ "$PARSED_SCHEME" == "https" ]]; then
      PARSED_PORT="443"
    else
      PARSED_PORT="80"
    fi
  fi

  [[ "$PARSED_PATH" == */ ]] || PARSED_PATH="${PARSED_PATH}/"
  return 0
}

show_config_summary() {
  echo
  echo "Kurulum ozeti"
  echo "----------------------------------------"
  echo "Ana URL       : $PRIMARY_BASE_URL"
  echo "Yedek URL     : $BACKUP_BASE_URL"
  echo "Ana host      : $PRIMARY_HOST"
  echo "Ana port      : $PRIMARY_PORT"
  echo "Ana path      : $PRIMARY_PATH"
  echo "Yedek host    : $BACKUP_HOST"
  echo "Yedek port    : $BACKUP_PORT"
  echo "Yedek path    : $BACKUP_PATH"
  echo "SSL cert      : $SSL_CERT_PATH"
  echo "SSL key       : $SSL_KEY_PATH"
  echo "Node port     : $LOCAL_APP_PORT"
  echo "UA filtre     : happ / Happ"
  echo "UA red cevabi : tg @Mr_Silco"
  echo "----------------------------------------"
}

check_ssl_files() {
  if [[ ! -f "$SSL_CERT_PATH" ]]; then
    echo "SSL certificate dosyasi bulunamadi: $SSL_CERT_PATH"
    exit 1
  fi

  if [[ ! -f "$SSL_KEY_PATH" ]]; then
    echo "SSL key dosyasi bulunamadi: $SSL_KEY_PATH"
    exit 1
  fi
}

ensure_packages() {
  log "Paket kontrolu basladi"
  apt-get update
  apt-get install -y nginx curl ca-certificates gnupg

  if ! command -v node >/dev/null 2>&1; then
    log "Node.js kurulu degil, NodeSource deposu ekleniyor"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    chmod a+r /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get install -y nodejs
  fi

  log "Node surumu: $(node -v)"
  log "Npm surumu: $(npm -v)"
}

create_user_and_dirs() {
  log "Dizinler hazirlaniyor"
  mkdir -p "$APP_DIR"
  mkdir -p "$APP_LOG_DIR"
  chown -R "$NODE_USER:$NODE_USER" "$APP_DIR" "$APP_LOG_DIR"
  chmod -R 755 "$APP_DIR"
}

write_package_json() {
  cat > "$PACKAGE_FILE" <<'JSON'
{
  "name": "token-proxy",
  "version": "1.0.0",
  "description": "Token capture and backup URL response service with UA filter",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  }
}
JSON
}

write_env() {
  cat > "$ENV_FILE" <<EOF2
APP_NAME=${APP_NAME}
APP_PORT=${LOCAL_APP_PORT}
PRIMARY_BASE_URL=${PRIMARY_BASE_URL}
PRIMARY_SCHEME=${PRIMARY_SCHEME}
PRIMARY_HOST=${PRIMARY_HOST}
PRIMARY_PORT=${PRIMARY_PORT}
PRIMARY_PATH=${PRIMARY_PATH}
BACKUP_BASE_URL=${BACKUP_BASE_URL}
BACKUP_SCHEME=${BACKUP_SCHEME}
BACKUP_HOST=${BACKUP_HOST}
BACKUP_PORT=${BACKUP_PORT}
BACKUP_PATH=${BACKUP_PATH}
TRUST_PROXY=true
LOG_DIR=${APP_LOG_DIR}
UA_ALLOW_PATTERN=happ
UA_REJECT_TEXT=tg @Mr_Silco
EOF2
}

write_server_js() {
  cat > "$SERVER_FILE" <<'JS'
const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

function readEnvFile(filePath) {
  const env = {};
  if (!fs.existsSync(filePath)) {
    throw new Error(`Env file missing: ${filePath}`);
  }

  const lines = fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eqIndex = line.indexOf('=');
    if (eqIndex === -1) continue;
    const key = line.slice(0, eqIndex).trim();
    const value = line.slice(eqIndex + 1).trim();
    env[key] = value;
  }
  return env;
}

const env = readEnvFile(path.join(__dirname, '.env'));
const appPort = Number(env.APP_PORT || 19091);
const trustProxy = String(env.TRUST_PROXY || 'true') === 'true';
const logDir = env.LOG_DIR || '/var/log/token-proxy';
const accessLogFile = path.join(logDir, 'access.log');
const errorLogFile = path.join(logDir, 'error.log');
const allowPattern = String(env.UA_ALLOW_PATTERN || 'happ').toLowerCase();
const rejectText = String(env.UA_REJECT_TEXT || 'tg @Mr_Silco');

if (!fs.existsSync(logDir)) {
  fs.mkdirSync(logDir, { recursive: true });
}

function appendLog(file, data) {
  fs.appendFile(file, data + '\n', (err) => {
    if (err) {
      console.error('Log write failed:', err.message);
    }
  });
}

function nowIso() {
  return new Date().toISOString();
}

function getClientIp(req) {
  if (trustProxy) {
    const forwarded = req.headers['x-forwarded-for'];
    if (forwarded) {
      return String(forwarded).split(',')[0].trim();
    }
  }
  return req.socket.remoteAddress || '-';
}

function escapeText(str) {
  return String(str).replace(/[\r\n\t]/g, ' ');
}

function buildUrl(baseUrl, token) {
  const cleanBase = String(baseUrl || '').replace(/\/$/, '');
  return `${cleanBase}/${encodeURIComponent(token)}`;
}

function getPathSegments(urlPath) {
  return String(urlPath || '')
    .split('/')
    .map(s => s.trim())
    .filter(Boolean);
}

function requestLogger(req, res, extra = {}) {
  const payload = {
    time: nowIso(),
    ip: getClientIp(req),
    method: req.method,
    host: req.headers.host || '-',
    userAgent: req.headers['user-agent'] || '-',
    referer: req.headers['referer'] || '-',
    url: req.url,
    status: res.statusCode,
    ...extra
  };
  appendLog(accessLogFile, JSON.stringify(payload));
}

function errorLogger(req, err, extra = {}) {
  const payload = {
    time: nowIso(),
    ip: getClientIp(req),
    method: req.method,
    host: req.headers.host || '-',
    userAgent: req.headers['user-agent'] || '-',
    url: req.url,
    error: err.message,
    stack: err.stack,
    ...extra
  };
  appendLog(errorLogFile, JSON.stringify(payload));
}

function isAllowedUserAgent(ua) {
  return String(ua || '').toLowerCase().includes(allowPattern);
}

const server = http.createServer((req, res) => {
  try {
    const userAgent = String(req.headers['user-agent'] || '');
    const fullUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const pathname = fullUrl.pathname || '/';
    const segments = getPathSegments(pathname);

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.statusCode = 405;
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      const text = 'Method Not Allowed';
      if (req.method !== 'HEAD') res.end(text);
      else res.end();
      requestLogger(req, res, { reason: 'invalid_method' });
      return;
    }

    if (!isAllowedUserAgent(userAgent)) {
      res.statusCode = 200;
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
      res.setHeader('Pragma', 'no-cache');
      res.setHeader('Expires', '0');

      if (req.method !== 'HEAD') res.end(rejectText);
      else res.end();

      requestLogger(req, res, {
        uaAllowed: false,
        rejectText,
        reason: 'ua_rejected'
      });
      return;
    }

    if (segments.length < 2) {
      res.statusCode = 400;
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      const text = 'Invalid path. Expected /something/TOKEN';
      if (req.method !== 'HEAD') res.end(text);
      else res.end();
      requestLogger(req, res, { reason: 'invalid_path', segments, uaAllowed: true });
      return;
    }

    const token = segments[segments.length - 1];
    const requestBasePath = '/' + segments.slice(0, -1).join('/') + '/';
    const outputUrl = buildUrl(env.BACKUP_BASE_URL, token);

    res.statusCode = 200;
    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');

    if (req.method !== 'HEAD') res.end(outputUrl);
    else res.end();

    requestLogger(req, res, {
      uaAllowed: true,
      token: escapeText(token),
      requestBasePath: escapeText(requestBasePath),
      configuredPrimaryBase: env.PRIMARY_BASE_URL,
      configuredBackupBase: env.BACKUP_BASE_URL,
      outputUrl
    });
  } catch (err) {
    res.statusCode = 500;
    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    res.end('Internal Server Error');
    errorLogger(req, err);
  }
});

server.listen(appPort, '127.0.0.1', () => {
  appendLog(accessLogFile, JSON.stringify({
    time: nowIso(),
    system: 'startup',
    message: `Server listening on 127.0.0.1:${appPort}`,
    primaryBase: env.PRIMARY_BASE_URL,
    backupBase: env.BACKUP_BASE_URL,
    uaAllowPattern: allowPattern,
    uaRejectText: rejectText
  }));
});

process.on('uncaughtException', (err) => {
  appendLog(errorLogFile, JSON.stringify({
    time: nowIso(),
    system: 'uncaughtException',
    error: err.message,
    stack: err.stack
  }));
});

process.on('unhandledRejection', (reason) => {
  appendLog(errorLogFile, JSON.stringify({
    time: nowIso(),
    system: 'unhandledRejection',
    error: String(reason)
  }));
});
JS
}

write_systemd_service() {
  cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=Token Proxy Node Service
After=network.target

[Service]
Type=simple
User=${NODE_USER}
Group=${NODE_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/node ${SERVER_FILE}
Restart=always
RestartSec=3
StandardOutput=append:${APP_LOG_DIR}/service.log
StandardError=append:${APP_LOG_DIR}/service-error.log

[Install]
WantedBy=multi-user.target
EOF2
}

write_nginx_conf() {
  cat > "$NGINX_CONF" <<EOF2
server {
    listen ${PRIMARY_PORT} ssl;
    listen [::]:${PRIMARY_PORT} ssl;
    server_name ${PRIMARY_HOST};

    ssl_certificate ${SSL_CERT_PATH};
    ssl_certificate_key ${SSL_KEY_PATH};
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    access_log /var/log/nginx/${APP_NAME}-access.log;
    error_log  /var/log/nginx/${APP_NAME}-error.log warn;

    client_max_body_size 1m;

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port ${PRIMARY_PORT};
        proxy_pass http://127.0.0.1:${LOCAL_APP_PORT};
        proxy_read_timeout 30s;
    }
}
EOF2

  ln -sf "$NGINX_CONF" "$NGINX_LINK"
}

write_uninstall_script() {
  cat > "$UNINSTALL_SCRIPT" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="token-proxy"
APP_DIR="/opt/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}"
NGINX_LINK="/etc/nginx/sites-enabled/${APP_NAME}"

systemctl stop ${APP_NAME} 2>/dev/null || true
systemctl disable ${APP_NAME} 2>/dev/null || true
rm -f "$SERVICE_FILE"
systemctl daemon-reload
systemctl reset-failed || true
rm -f "$NGINX_LINK"
rm -f "$NGINX_CONF"
rm -rf "$APP_DIR"
nginx -t && systemctl reload nginx || systemctl restart nginx || true
echo "Token proxy tamamen kaldirildi. Loglar /var/log/token-proxy altinda birakildi."
BASH

  chmod +x "$UNINSTALL_SCRIPT"
}

install_proxy() {
  echo
  echo "Ana URL tum detaylariyla girilmeli. Script host, port ve path bilgisini otomatik ayiklar."

  PRIMARY_BASE_URL="$(ask_required "Ana adresi girin" "https://tmskechers.yelkenlogistik.ru:448/sub")"
  BACKUP_BASE_URL="$(ask_required "Yedek adresi girin" "https://test27s.yelkenlogistik.ru/sub")"
  SSL_CERT_PATH="$(ask_required "SSL certificate dosya yolunu girin" "/root/fullchain.pem")"
  SSL_KEY_PATH="$(ask_required "SSL key dosya yolunu girin" "/root/key.pem")"

  PRIMARY_BASE_URL="$(normalize_url "$PRIMARY_BASE_URL")"
  BACKUP_BASE_URL="$(normalize_url "$BACKUP_BASE_URL")"

  parse_url_parts "$PRIMARY_BASE_URL"
  PRIMARY_SCHEME="$PARSED_SCHEME"
  PRIMARY_HOST="$PARSED_HOST"
  PRIMARY_PORT="$PARSED_PORT"
  PRIMARY_PATH="$PARSED_PATH"

  parse_url_parts "$BACKUP_BASE_URL"
  BACKUP_SCHEME="$PARSED_SCHEME"
  BACKUP_HOST="$PARSED_HOST"
  BACKUP_PORT="$PARSED_PORT"
  BACKUP_PATH="$PARSED_PATH"

  check_ssl_files
  show_config_summary

  echo
  read -r -p "Bu ayarlarla kuruluma devam edilsin mi? (e/h): " confirm
  confirm="$(printf '%s' "$confirm" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ "$confirm" != "e" && "$confirm" != "E" ]]; then
    echo "Kurulum iptal edildi."
    return 0
  fi

  ensure_packages
  create_user_and_dirs
  write_package_json
  write_env
  write_server_js
  write_systemd_service
  write_nginx_conf
  write_uninstall_script

  chown -R "$NODE_USER:$NODE_USER" "$APP_DIR" "$APP_LOG_DIR"
  chmod 600 "$ENV_FILE"
  chmod 755 "$SERVER_FILE" "$UNINSTALL_SCRIPT"

  systemctl daemon-reload
  systemctl enable "$APP_NAME"
  systemctl restart "$APP_NAME"

  nginx -t
  systemctl enable nginx
  systemctl reload nginx

  log "Kurulum tamamlandi"

  echo
  echo "Kurulum basarili."
  echo "Test girisi   : ${PRIMARY_BASE_URL}/SHR2diwxNzc2MjQ5MzY50Z0K4T78JM"
  echo "Beklenen cikis: ${BACKUP_BASE_URL}/SHR2diwxNzc2MjQ5MzY50Z0K4T78JM"
  echo "UA kosulu     : User-Agent icinde happ veya Happ olmali"
  echo "UA red cevabi : tg @Mr_Silco"
  echo
  echo "Node log klasoru : ${APP_LOG_DIR}"
  echo "Nginx access log : /var/log/nginx/${APP_NAME}-access.log"
  echo "Nginx error log  : /var/log/nginx/${APP_NAME}-error.log"
  echo "Service log      : ${APP_LOG_DIR}/service.log"
  echo "App access log   : ${APP_LOG_DIR}/access.log"
  echo "App error log    : ${APP_LOG_DIR}/error.log"
}

show_live_logs() {
  echo
  echo "1. App access log"
  echo "2. App error log"
  echo "3. Service log"
  echo "4. Nginx access log"
  echo "5. Nginx error log"
  echo "6. Hepsinin son 50 satiri"
  echo

  read -r -p "Secim: " choice

  case "$choice" in
    1) tail -f "${APP_LOG_DIR}/access.log" ;;
    2) tail -f "${APP_LOG_DIR}/error.log" ;;
    3) tail -f "${APP_LOG_DIR}/service.log" ;;
    4) tail -f "/var/log/nginx/${APP_NAME}-access.log" ;;
    5) tail -f "/var/log/nginx/${APP_NAME}-error.log" ;;
    6)
      echo "--- APP ACCESS ---"
      tail -n 50 "${APP_LOG_DIR}/access.log" 2>/dev/null || true
      echo
      echo "--- APP ERROR ---"
      tail -n 50 "${APP_LOG_DIR}/error.log" 2>/dev/null || true
      echo
      echo "--- SERVICE LOG ---"
      tail -n 50 "${APP_LOG_DIR}/service.log" 2>/dev/null || true
      echo
      echo "--- NGINX ACCESS ---"
      tail -n 50 "/var/log/nginx/${APP_NAME}-access.log" 2>/dev/null || true
      echo
      echo "--- NGINX ERROR ---"
      tail -n 50 "/var/log/nginx/${APP_NAME}-error.log" 2>/dev/null || true
      pause_screen
      ;;
    *)
      echo "Gecersiz secim"
      ;;
  esac
}

remove_proxy() {
  echo
  echo "Bu islem Node servis, Nginx ayari ve uygulama dosyalarini siler."
  echo "Loglar varsayilan olarak korunur."
  read -r -p "Emin misiniz? (SIL yazin): " confirm

  confirm="$(printf '%s' "$confirm" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ "$confirm" != "SIL" ]]; then
    echo "Kaldirma iptal edildi. Girilen deger: [$confirm]"
    return 0
  fi

  systemctl stop "$APP_NAME" 2>/dev/null || true
  systemctl disable "$APP_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl reset-failed || true

  rm -f "$NGINX_LINK"
  rm -f "$NGINX_CONF"
  rm -rf "$APP_DIR"

  nginx -t && systemctl reload nginx || systemctl restart nginx || true

  echo "Kaldirma tamamlandi."
  echo
  read -r -p "Loglari da silmek istiyor musunuz? (e/h): " purge_logs
  purge_logs="$(printf '%s' "$purge_logs" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ "$purge_logs" == "e" || "$purge_logs" == "E" ]]; then
    rm -rf "$APP_LOG_DIR"
    rm -f "$INSTALL_LOG"
    rm -f "/var/log/nginx/${APP_NAME}-access.log"
    rm -f "/var/log/nginx/${APP_NAME}-error.log"
    echo "Loglar da silindi."
  else
    echo "Loglar korundu."
  fi
}

main_menu() {
  while true; do
    clear || true
    echo "========================================"
    echo "        TOKEN PROXY KURULUM MENUSU      "
    echo "========================================"
    echo "1. Proxy yap"
    echo "2. Log izle"
    echo "3. Kaldir"
    echo "4. Cikis"
    echo "========================================"
    echo
    read -r -p "Seciminiz: " choice

    case "$choice" in
      1) install_proxy; pause_screen ;;
      2) show_live_logs ;;
      3) remove_proxy; pause_screen ;;
      4) exit 0 ;;
      *) echo "Gecersiz secim"; pause_screen ;;
    esac
  done
}

need_root
main_menu
