#!/usr/bin/env bash
set -euo pipefail

CLOUD_FORGE_CADDY_IMAGE="${CLOUD_FORGE_CADDY_IMAGE:-caddy:2.11.4}"
PLATFORM_COMPOSE="/opt/cloud-forge/docker-compose.platform.yml"

sudo tee /opt/cloud-forge/bin/cloud-forge-caddy-config >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOCK_FILE="/run/cloud-forge-caddy-config.lock"
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock 9
fi

DEFAULT_ENV="/etc/cloud-forge/default.env"
APP_ENV="/etc/cloud-forge/app.env"
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_IMAGE="${CLOUD_FORGE_CADDY_IMAGE:-caddy:2.11.4}"

if [[ -f "$DEFAULT_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$DEFAULT_ENV"
  set +a
fi

if [[ -f "$APP_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$APP_ENV"
  set +a
fi

CLOUD_FORGE_CADDY_SITE="${CLOUD_FORGE_CADDY_SITE:-}"
CLOUD_FORGE_DOMAIN_NAME="${CLOUD_FORGE_DOMAIN_NAME:-}"
CLOUD_FORGE_CADDY_UPSTREAM="${CLOUD_FORGE_CADDY_UPSTREAM:-}"
CLOUD_FORGE_CADDY_TLS_MODE="${CLOUD_FORGE_CADDY_TLS_MODE:-auto}"
CLOUD_FORGE_CADDY_AUTO_IP_CERT="${CLOUD_FORGE_CADDY_AUTO_IP_CERT:-false}"
CLOUD_FORGE_CADDY_PUBLIC_IP="${CLOUD_FORGE_CADDY_PUBLIC_IP:-}"
CLOUD_FORGE_CADDY_IP_CERT_CA="${CLOUD_FORGE_CADDY_IP_CERT_CA:-https://acme-v02.api.letsencrypt.org/directory}"
CLOUD_FORGE_CADDY_IP_CERT_PROFILE="${CLOUD_FORGE_CADDY_IP_CERT_PROFILE:-shortlived}"
CLOUD_FORGE_CADDY_IP_CERT_FALLBACK="${CLOUD_FORGE_CADDY_IP_CERT_FALLBACK:-http}"
CLOUD_FORGE_CADDY_INTERNAL_TLS="${CLOUD_FORGE_CADDY_INTERNAL_TLS:-false}"
CLOUD_FORGE_CADDY_EMAIL="${CLOUD_FORGE_CADDY_EMAIL:-}"

CLOUD_FORGE_CADDY_TLS_MODE="${CLOUD_FORGE_CADDY_TLS_MODE,,}"
CLOUD_FORGE_CADDY_IP_CERT_FALLBACK="${CLOUD_FORGE_CADDY_IP_CERT_FALLBACK,,}"

truthy() {
  case "${1,,}" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
}

if truthy "$CLOUD_FORGE_CADDY_INTERNAL_TLS" && [[ "$CLOUD_FORGE_CADDY_TLS_MODE" == "auto" ]]; then
  CLOUD_FORGE_CADDY_TLS_MODE="internal"
fi

fetch_imds() {
  local path="$1"
  local token

  token="$(curl -fsS --noproxy '*' \
    --connect-timeout 1 \
    --max-time 2 \
    -X PUT \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
    http://169.254.169.254/latest/api/token 2>/dev/null || true)"

  if [[ -z "$token" ]]; then
    return 1
  fi

  curl -fsS --noproxy '*' \
    --connect-timeout 1 \
    --max-time 2 \
    -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/$path" 2>/dev/null
}

is_public_ipv4() {
  local ip="$1"
  local a b c d

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    ((octet >= 0 && octet <= 255)) || return 1
  done

  ((a == 0 || a == 10 || a == 127 || a >= 224)) && return 1
  ((a == 100 && b >= 64 && b <= 127)) && return 1
  ((a == 169 && b == 254)) && return 1
  ((a == 172 && b >= 16 && b <= 31)) && return 1
  ((a == 192 && b == 168)) && return 1
  ((a == 198 && (b == 18 || b == 19))) && return 1
  return 0
}

detect_public_ipv4() {
  local ip

  if [[ -n "$CLOUD_FORGE_CADDY_PUBLIC_IP" ]]; then
    printf '%s\n' "$CLOUD_FORGE_CADDY_PUBLIC_IP"
    return 0
  fi

  if ! truthy "$CLOUD_FORGE_CADDY_AUTO_IP_CERT"; then
    return 1
  fi

  ip="$(fetch_imds public-ipv4 || true)"
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

select_site() {
  local public_ip=""

  if [[ -n "$CLOUD_FORGE_CADDY_SITE" ]]; then
    printf '%s\t%s\n' "$CLOUD_FORGE_CADDY_SITE" "$CLOUD_FORGE_CADDY_TLS_MODE"
    return 0
  fi

  if [[ -n "$CLOUD_FORGE_DOMAIN_NAME" ]]; then
    if [[ "$CLOUD_FORGE_CADDY_TLS_MODE" == "http" ]]; then
      printf 'http://%s\t%s\n' "$CLOUD_FORGE_DOMAIN_NAME" "http"
    else
      printf '%s\t%s\n' "$CLOUD_FORGE_DOMAIN_NAME" "$CLOUD_FORGE_CADDY_TLS_MODE"
    fi
    return 0
  fi

  case "$CLOUD_FORGE_CADDY_TLS_MODE" in
    internal)
      printf ':443\tinternal\n'
      return 0
      ;;
    ip-letsencrypt)
      public_ip="$(detect_public_ipv4 || true)"
      if ! is_public_ipv4 "$public_ip"; then
        echo "CLOUD_FORGE_CADDY_TLS_MODE=ip-letsencrypt requires a public IPv4 address" >&2
        exit 1
      fi
      printf '%s\tip-letsencrypt\n' "$public_ip"
      return 0
      ;;
    auto)
      public_ip="$(detect_public_ipv4 || true)"
      if is_public_ipv4 "$public_ip"; then
        printf '%s\tip-letsencrypt\n' "$public_ip"
      else
        printf ':80\thttp\n'
      fi
      return 0
      ;;
    http | "")
      printf ':80\thttp\n'
      return 0
      ;;
    *)
      echo "unsupported CLOUD_FORGE_CADDY_TLS_MODE: $CLOUD_FORGE_CADDY_TLS_MODE" >&2
      exit 1
      ;;
  esac
}

write_caddyfile() {
  local site="$1"
  local tls_mode="$2"

  {
    echo "{"
    echo "  admin localhost:2019"
    if [[ -n "$CLOUD_FORGE_CADDY_EMAIL" ]]; then
      echo "  email $CLOUD_FORGE_CADDY_EMAIL"
    fi
    if [[ "$tls_mode" == "ip-letsencrypt" ]]; then
      echo "  default_sni $site"
    fi
    echo "}"
    echo
    echo "$site {"
    case "$tls_mode" in
      internal)
        echo "  tls internal"
        ;;
      ip-letsencrypt)
        echo "  tls {"
        echo "    issuer acme $CLOUD_FORGE_CADDY_IP_CERT_CA {"
        echo "      profile $CLOUD_FORGE_CADDY_IP_CERT_PROFILE"
        echo "    }"
        echo "  }"
        ;;
    esac
    echo "  encode zstd gzip"
    echo "  header {"
    if [[ -n "$CLOUD_FORGE_DOMAIN_NAME" && "$tls_mode" != "internal" && "$tls_mode" != "http" ]]; then
      echo "    Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\""
    fi
    echo "    X-Content-Type-Options \"nosniff\""
    echo "    X-Frame-Options \"DENY\""
    echo "    Referrer-Policy \"strict-origin-when-cross-origin\""
    echo "  }"
    echo "  respond /health \"ok\" 200"
    if [[ -n "$CLOUD_FORGE_CADDY_UPSTREAM" ]]; then
      echo "  reverse_proxy $CLOUD_FORGE_CADDY_UPSTREAM"
    else
      echo "  root * /var/www/cloud-forge"
      echo "  file_server"
    fi
    echo "}"
  } | sudo tee "$CADDYFILE" >/dev/null
}

validate_caddyfile() {
  if command -v caddy >/dev/null 2>&1; then
    sudo caddy fmt --overwrite "$CADDYFILE"
    sudo caddy validate --config "$CADDYFILE"
    return
  fi

  docker run --rm \
    -v /etc/caddy:/etc/caddy \
    "$CADDY_IMAGE" caddy fmt --overwrite "$CADDYFILE"
  docker run --rm \
    -v /etc/caddy:/etc/caddy:ro \
    "$CADDY_IMAGE" caddy validate --config "$CADDYFILE"
}

sudo install -d -m 0755 /etc/caddy /var/www/cloud-forge

IFS=$'\t' read -r selected_site selected_tls_mode < <(select_site)
write_caddyfile "$selected_site" "$selected_tls_mode"

if ! validate_caddyfile; then
  if [[ "$CLOUD_FORGE_CADDY_TLS_MODE" == "auto" && "$selected_tls_mode" == "ip-letsencrypt" && "$CLOUD_FORGE_CADDY_IP_CERT_FALLBACK" == "http" ]]; then
    echo "IP certificate Caddy config is not supported by this Caddy build; falling back to HTTP"
    write_caddyfile ":80" "http"
    validate_caddyfile
  else
    exit 1
  fi
fi
EOF

sudo tee /opt/cloud-forge/bin/cloud-forge-apply-app >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PLATFORM="/opt/cloud-forge/docker-compose.platform.yml"
APP="/opt/cloud-forge/docker-compose.app.yml"
COMPOSE_PROJECT="cloud-forge-platform"
COMPOSE=(docker compose --project-name "$COMPOSE_PROJECT" -f "$PLATFORM")
LOCK_FILE="/run/cloud-forge-apply-app.lock"

exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock 9
fi

if [[ ! -f "$PLATFORM" ]]; then
  echo "missing platform compose file: $PLATFORM" >&2
  exit 1
fi

if [[ -f "$APP" ]]; then
  COMPOSE+=(-f "$APP")
fi

/opt/cloud-forge/bin/cloud-forge-caddy-config
"${COMPOSE[@]}" up -d --remove-orphans
"${COMPOSE[@]}" restart caddy
EOF

sudo chmod 0755 /opt/cloud-forge/bin/cloud-forge-caddy-config /opt/cloud-forge/bin/cloud-forge-apply-app

if [[ -f /etc/cloud-forge/app.env ]]; then
  echo "==> Rendering Caddy configuration..."
  sudo /opt/cloud-forge/bin/cloud-forge-caddy-config
else
  echo "==> Skipping Caddy render until app.env is written by bootstrap-app.sh"
fi

sudo tee /etc/systemd/system/cloud-forge-platform.service >/dev/null <<EOF
[Unit]
Description=Cloud Forge platform stack (Caddy via Docker Compose)
Documentation=https://github.com/CoreNovaLabs/cloud-forge-ami-factory
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/opt/cloud-forge/bin/cloud-forge-caddy-config
ExecStart=/opt/cloud-forge/bin/cloud-forge-apply-app
ExecReload=/opt/cloud-forge/bin/cloud-forge-caddy-config
ExecReload=/opt/cloud-forge/bin/cloud-forge-apply-app
ExecStop=/usr/bin/docker compose --project-name cloud-forge-platform -f ${PLATFORM_COMPOSE} down --remove-orphans

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/cloud-forge-caddy-config.service >/dev/null <<'EOF'
[Unit]
Description=Render Cloud Forge Caddy configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/cloud-forge/bin/cloud-forge-caddy-config

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cloud-forge-caddy-config.service
sudo systemctl enable cloud-forge-platform.service

if command -v docker >/dev/null 2>&1 && [[ -f /etc/cloud-forge/app.env ]]; then
  sudo systemctl start docker
  echo "==> Starting Cloud Forge platform stack (${CLOUD_FORGE_CADDY_IMAGE})..."
  sudo systemctl start cloud-forge-platform.service
  echo "==> Platform stack status:"
  sudo docker compose --project-name cloud-forge-platform -f "$PLATFORM_COMPOSE" ps || true
fi
