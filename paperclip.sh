#!/usr/bin/env bash
# paperclip: run Paperclip 24/7 in Docker on a Claude subscription that does not log out.
#
# Usage (as root):
#   paperclip install [options]   first-time setup, starts everything (see below)
#   paperclip token [--paste]     create/replace the 1-year Claude token and apply it
#   paperclip check               prove the agents' Claude login works right now
#   paperclip invite              print a one-time link to create the first admin account
#   paperclip signups off|on      block (or allow again) new account creation
#   paperclip status              containers, URL, version, token age, last backup
#   paperclip logs                follow the Paperclip logs (Ctrl+C to stop)
#   paperclip backup              database dump + files archive into ./backups (keeps 7)
#   paperclip update [<version>]  show versions, or back up and move to <version>
#   paperclip restart | stop | start
#   paperclip remove-old <dir>    archive and stop another Paperclip compose stack
#   paperclip uninstall           stop and remove containers; keeps your data
#
# Install options:
#   --domain <name>   HTTPS on this domain (its DNS A record must point here)
#   --local           no domain: plain HTTP on port 3100, for a private network
#   --port <n>        host port in --local mode (default 3100)
#   --version <v>     Paperclip version to pin (default: the tested one below)
#   --yes             accept defaults, never prompt (needs --domain or --local)
#   --skip-token      do not ask for the Claude token now
# A token can also be passed non-interactively with CLAUDE_CODE_OAUTH_TOKEN=...
#
# Secrets live only in deploy/.env (mode 600). This script never prints them.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DEPLOY="$ROOT/deploy"
ENV_FILE="$DEPLOY/.env"
BACKUPS="$ROOT/backups"
DEFAULT_VERSION="2026.1005.0"
IMAGE_REPO="ghcr.io/paperclipai/paperclip"
PROJECT_URL="https://github.com/artenl/paperclip-selfhost"
TOKEN_RE='^sk-ant-oat[0-9]+-[A-Za-z0-9_-]{40,}$'
ASSUME_YES=0
DIED=0

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*" >&2; }
die()  { DIED=1; printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# Never stop without saying why: report any exit that die() did not explain.
on_exit() {
  local rc="$1" cmd="$2"
  if [ "$rc" -ne 0 ] && [ "$DIED" -eq 0 ] && [ "$rc" -ne 130 ]; then
    printf '\033[1;31mERR\033[0m Stopped unexpectedly (exit %s) while running: %s\n' "$rc" "$cmd" >&2
    printf '    Running the same command again is safe. If it keeps failing, please report it: %s/issues\n' "$PROJECT_URL" >&2
  fi
}
trap 'on_exit "$?" "$BASH_COMMAND"' EXIT

dc() { (cd "$DEPLOY" && docker compose "$@"); }

need_root() { [ "$(id -u)" -eq 0 ] || die "Run as root (or with sudo)."; }
need_env()  { [ -f "$ENV_FILE" ] || die "Not installed yet. Run: paperclip install"; }

# Prompts read the terminal directly, so they work under `curl ... | bash`.
has_tty() { [ "$ASSUME_YES" -eq 0 ] && ( : < /dev/tty ) 2>/dev/null; }
ask() { # ask "Question" "default" -> answer on stdout
  local answer=""
  if has_tty; then
    read -r -p "$1${2:+ [$2]}: " answer < /dev/tty || true
  fi
  printf '%s' "${answer:-$2}"
}
confirm() { # confirm "Question" (default yes)
  local a; a="$(ask "$1 [Y/n]" "")"
  case "${a:-y}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

env_get() { # KEY -> value ("" if absent)
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

env_set() { # KEY VALUE: replace or append, keep the file private
  local tmp
  tmp="$(mktemp "$DEPLOY/.env.XXXXXX")"
  chmod 600 "$tmp"
  if [ -f "$ENV_FILE" ]; then grep -vE "^$1=" "$ENV_FILE" > "$tmp" || true; fi
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

health_url() { echo "http://127.0.0.1:$(env_get PAPERCLIP_PORT)/api/health"; }

wait_healthy() {
  say "Waiting for Paperclip to start (first start can take a few minutes)..."
  local _
  for _ in $(seq 1 90); do
    if curl -fs -o /dev/null --max-time 5 "$(health_url)"; then
      ok "Paperclip is up."
      return 0
    fi
    sleep 5
  done
  warn "Paperclip did not answer within 7.5 minutes. Recent logs:"
  dc logs --tail=60 paperclip || true
  return 1
}

public_ip() { curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true; }
lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i+1); exit}}' \
    || hostname -I 2>/dev/null | awk '{print $1}' || true
}

normalize_domain() { # trims spaces, a leading http(s):// and any path or port
  local d
  d="$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]')"
  case "$d" in http://*|https://*) d="${d#*://}" ;; esac
  d="${d%%/*}"; d="${d%%:*}"
  printf '%s' "$d"
}
valid_domain() {
  [ "$1" = "localhost" ] || [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}
ask_domain() { # $1 = suggestion -> a valid domain on stdout, or returns 1
  local d
  while :; do
    d="$(normalize_domain "$(ask "Domain" "$1")")"
    if valid_domain "$d"; then printf '%s' "$d"; return 0; fi
    warn "'$d' is not a domain name. Example: paperclip.example.com${1:+ (or press Enter for $1)}"
    has_tty || return 1
  done
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    say "Docker with the compose plugin is not installed."
    if [ "$ASSUME_YES" -eq 1 ] || confirm "Install it now from get.docker.com?"; then
      curl -fsSL https://get.docker.com | sh
    else
      die "Docker is required."
    fi
  fi
  # Start Docker at every boot, so the stack comes back after a reboot.
  if command -v systemctl >/dev/null 2>&1; then systemctl enable --now docker >/dev/null 2>&1 || true; fi
  docker info >/dev/null 2>&1 || die "Docker is installed but not running."
  ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') is running."
}

foreign_port_holders() { # $1 = port regex; containers outside this stack publishing it
  docker ps --format '{{.Names}}|{{.Label "com.docker.compose.project"}}|{{.Ports}}' \
    | awk -F'|' -v re=":($1)->" '$2 != "paperclip" && $3 ~ re {print $1}' | sort -u
}

check_ports() {
  local ports holders host="" filter
  if [ "$(env_get PAPERCLIP_MODE)" = "local" ]; then ports="$(env_get PAPERCLIP_PORT)"; else ports="80|443"; fi
  holders="$(foreign_port_holders "$ports")"
  if command -v ss >/dev/null 2>&1; then
    filter="$(printf '%s' "$ports" | sed -E 's/([0-9]+)/sport = :\1/g; s/\|/ or /g')"
    # Docker's own listeners are covered by the container check above.
    host="$(ss -Hltnp "( $filter )" 2>/dev/null | grep -v docker-proxy || true)"
    # Our own stack's ports are fine.
    [ -n "$(dc ps -q 2>/dev/null)" ] && [ -z "$holders" ] && host=""
  fi
  [ -z "$holders" ] && [ -z "$host" ] && return 0
  warn "Port(s) ${ports//|/ and } already in use on this machine by:"
  [ -n "$holders" ] && printf '    container: %s\n' $holders >&2
  [ -n "$host" ] && printf '    %s\n' "$host" >&2
  die "Free them first (another reverse proxy or an older Paperclip? see 'paperclip remove-old'), or use --local --port <n>."
}

check_dns() {
  local domain="$1" mine theirs
  mine="$(public_ip)"
  theirs="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [ -z "$theirs" ]; then
    warn "$domain does not resolve yet. Create a DNS A record: $domain -> ${mine:-<this server IP>}. HTTPS starts once it resolves."
  elif [ -n "$mine" ] && [ "$mine" != "$theirs" ]; then
    warn "$domain points to $theirs, but this server is $mine. Fix the DNS A record, or HTTPS will not work."
  else
    ok "$domain points to this server ($theirs)."
  fi
}

install_backup_schedule() {
  if [ -d /run/systemd/system ]; then
    cat > /etc/systemd/system/paperclip-backup.service <<EOF
[Unit]
Description=Paperclip backup (database + files)
[Service]
Type=oneshot
ExecStart="$ROOT/paperclip.sh" backup
EOF
    cat > /etc/systemd/system/paperclip-backup.timer <<'EOF'
[Unit]
Description=Daily Paperclip backup
[Timer]
OnCalendar=*-*-* 03:17:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload && systemctl enable --now paperclip-backup.timer >/dev/null 2>&1
    ok "Daily backup scheduled at 03:17 (systemd timer paperclip-backup)."
  elif [ -d /etc/cron.d ]; then
    printf '# Daily Paperclip backup, keeps the newest 7.\n17 3 * * * root "%s/paperclip.sh" backup >> /var/log/paperclip-backup.log 2>&1\n' "$ROOT" > /etc/cron.d/paperclip-backup
    chmod 644 /etc/cron.d/paperclip-backup
    ok "Daily backup scheduled at 03:17 (cron)."
  else
    warn "No systemd or cron found: schedule 'paperclip backup' yourself."
  fi
}

write_config() { # $1 = domain or "local", $2 = version, $3 = local port
  local target="$1" version="$2" port="$3" ip host
  umask 077
  : > "$ENV_FILE"
  env_set PAPERCLIP_VERSION "$version"
  env_set POSTGRES_PASSWORD "$(rand_hex 24)"
  env_set BETTER_AUTH_SECRET "$(rand_hex 32)"
  env_set PAPERCLIP_AGENT_JWT_SECRET "$(rand_hex 32)"
  env_set PAPERCLIP_AUTH_DISABLE_SIGN_UP "false"
  if [ "$target" = "local" ]; then
    ip="$(lan_ip)"; host="$(hostname 2>/dev/null || true)"
    env_set PAPERCLIP_MODE local
    env_set COMPOSE_PROFILES ""
    env_set PAPERCLIP_DOMAIN ""
    # "public" here too: it turns off Paperclip's built-in Claude sign-in, which
    # stores an 8-hour token (the problem this project works around).
    env_set PAPERCLIP_EXPOSURE public
    env_set PAPERCLIP_BIND 0.0.0.0
    env_set PAPERCLIP_PORT "$port"
    env_set PAPERCLIP_PUBLIC_URL "http://${ip:-localhost}:$port"
    env_set PAPERCLIP_ALLOWED_HOSTNAMES "localhost,127.0.0.1${ip:+,$ip}${host:+,$host}"
  else
    env_set PAPERCLIP_MODE https
    env_set COMPOSE_PROFILES https
    env_set PAPERCLIP_DOMAIN "$target"
    env_set PAPERCLIP_EXPOSURE public
    env_set PAPERCLIP_BIND 127.0.0.1
    env_set PAPERCLIP_PORT 3100
    env_set PAPERCLIP_PUBLIC_URL "https://$target"
    env_set PAPERCLIP_ALLOWED_HOSTNAMES ""
  fi
  env_set CLAUDE_CODE_OAUTH_TOKEN ""
  env_set CLAUDE_TOKEN_CREATED ""
}

cmd_install() {
  local domain="" local_mode=0 port=3100 version="$DEFAULT_VERSION" skip_token=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain)     domain="${2:-}"; shift 2 ;;
      --local)      local_mode=1; shift ;;
      --port)       port="${2:-}"; shift 2 ;;
      --version)    version="${2:-}"; shift 2 ;;
      --yes|-y)     ASSUME_YES=1; shift ;;
      --skip-token) skip_token=1; shift ;;
      *) die "Unknown option: $1 (see: paperclip help)" ;;
    esac
  done
  need_root
  if [ -n "$domain" ]; then
    domain="$(normalize_domain "$domain")"
    valid_domain "$domain" || die "--domain '$domain' is not a domain name. Example: paperclip.example.com"
  fi
  ensure_docker
  mkdir -p "$DEPLOY" "$BACKUPS"

  if [ ! -f "$ENV_FILE" ]; then
    if [ -z "$domain" ] && [ "$local_mode" -eq 0 ]; then
      has_tty || die "No terminal to ask questions on. Pass --domain <name> or --local."
      local ip suggestion choice
      ip="$(public_ip)"
      suggestion="${ip:+${ip//./-}.sslip.io}"
      cat > /dev/tty <<EOF

How will you reach Paperclip?
  1) HTTPS on a domain. Best for a server on the internet (VPS).
     No domain? ${suggestion:+$suggestion works with no DNS setup (free sslip.io).}
  2) Local network only: plain HTTP on port $port. For a home server or a test.

EOF
      choice="$(ask "Choose 1 or 2" "1")"
      if [ "$choice" = "2" ]; then
        local_mode=1
      else
        domain="$(ask_domain "$suggestion")" || die "No valid domain given."
      fi
    fi
    if [ "$local_mode" -eq 1 ]; then write_config local "$version" "$port"; else write_config "$domain" "$version" "$port"; fi
    ok "Wrote deploy/.env (private, mode 600)."
  else
    ok "Already configured; keeping deploy/.env and your data."
    # Repair a saved domain that is not a domain (for example a pasted command).
    if [ "$(env_get PAPERCLIP_MODE)" = "https" ] && ! valid_domain "$(env_get PAPERCLIP_DOMAIN)"; then
      warn "The saved domain is not a domain name: '$(env_get PAPERCLIP_DOMAIN)'. Let's fix it."
      if [ -z "$domain" ]; then
        has_tty || die "Run again with --domain <name> to fix it."
        local fix_ip; fix_ip="$(public_ip)"
        domain="$(ask_domain "${fix_ip:+${fix_ip//./-}.sslip.io}")" || die "No valid domain given."
      fi
      env_set PAPERCLIP_DOMAIN "$domain"
      env_set PAPERCLIP_PUBLIC_URL "https://$domain"
      ok "Domain set to $domain."
    fi
  fi

  [ "$(env_get PAPERCLIP_MODE)" = "https" ] && check_dns "$(env_get PAPERCLIP_DOMAIN)"
  check_ports
  mkdir -p "$DEPLOY/data/postgres" "$DEPLOY/data/paperclip" "$DEPLOY/data/caddy/data" "$DEPLOY/data/caddy/config"
  chmod 700 "$DEPLOY/data" "$BACKUPS"
  say "Downloading images (Paperclip is ~2 GB, first time only)..."
  dc pull < /dev/null || warn "Some images could not be downloaded; continuing with any already here."
  dc up -d < /dev/null
  wait_healthy
  install_backup_schedule
  ln -sf "$ROOT/paperclip.sh" /usr/local/bin/paperclip 2>/dev/null && ok "Command installed: paperclip (try: paperclip status)"

  if [ -z "$(env_get CLAUDE_CODE_OAUTH_TOKEN)" ]; then
    if [[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" =~ $TOKEN_RE ]]; then
      save_token "$CLAUDE_CODE_OAUTH_TOKEN"
    elif [ "$skip_token" -eq 0 ] && has_tty; then
      echo
      if confirm "Set up the 1-year Claude subscription token now?"; then cmd_token; else warn "Skipped. Run 'paperclip token' before creating agents."; fi
    else
      warn "No Claude token yet. Run 'paperclip token' before creating agents."
    fi
  fi
  echo
  cmd_invite || true
  echo
  ok "Paperclip is running: $(env_get PAPERCLIP_PUBLIC_URL)"
  echo "    Next: open the invite link above, then read '$PROJECT_URL#after-install'."
}

read_token() { # reads a pasted token from the terminal, tolerating a line break
  local line token="" _ src=/dev/stdin
  has_tty && src=/dev/tty
  IFS= read -r -s line < "$src" || true
  token="$(printf '%s' "$line" | tr -d '[:space:]')"
  for _ in 1 2 3; do
    [[ "$token" =~ $TOKEN_RE ]] && [ "${#token}" -ge 100 ] && break
    IFS= read -r -s -t 2 line < "$src" || break
    token="$token$(printf '%s' "$line" | tr -d '[:space:]')"
  done
  echo >&2
  printf '%s' "$token"
}

save_token() {
  [[ "$1" =~ $TOKEN_RE ]] || die "That does not look like a setup-token (expected sk-ant-oat01-...). Nothing was changed."
  env_set CLAUDE_CODE_OAUTH_TOKEN "$1"
  env_set CLAUDE_TOKEN_CREATED "$(date -u +%Y-%m-%d)"
  ok "Token saved to deploy/.env (not printed)."
  say "Applying it to Paperclip (restarts the Paperclip container, ~1 minute)..."
  dc up -d paperclip < /dev/null
  wait_healthy
  cmd_check
}

cmd_token() {
  need_root; need_env
  local mode="${1:-}" version
  version="$(env_get PAPERCLIP_VERSION)"
  if [ "$mode" != "--paste" ]; then
    has_tty || die "This needs a terminal. Or run 'claude setup-token' elsewhere and: paperclip token --paste"
    cat <<'EOF'

We now run `claude setup-token`. It creates a Claude Code token that lasts ONE YEAR
and never needs refreshing.

  1. A link appears below. Open it in your browser, signed in to the Claude
     account whose subscription the agents should use. Approve.
  2. The page shows a code. Paste it back here and press Enter.
  3. The terminal prints "Your OAuth token (valid for 1 year)" followed by a
     token starting with sk-ant-oat01-. Copy the whole token.

(Already have one from `claude setup-token` on another computer? Press Ctrl+C
and run: paperclip token --paste)

EOF
    ask "Press Enter to start" "" >/dev/null
    docker run --rm -it --user node -e HOME=/tmp -e CLAUDE_CODE_OAUTH_TOKEN= \
      --entrypoint claude "$IMAGE_REPO:$version" setup-token < /dev/tty \
      || warn "setup-token exited with an error; if you got a token anyway, continue."
  fi
  echo
  echo "Paste the token (starts with sk-ant-oat01-; input is hidden), then press Enter:"
  save_token "$(read_token)"
}

cmd_check() {
  need_env
  [ -n "$(env_get CLAUDE_CODE_OAUTH_TOKEN)" ] || die "No token set. Run: paperclip token"
  say "Asking Claude for a one-word reply with the agents' credentials..."
  local out rc=0
  # Same container and environment as the agents; a throwaway Claude home.
  out="$(dc exec -T -u node -e HOME=/tmp/paperclip-check -e CLAUDE_CONFIG_DIR=/tmp/paperclip-check/.claude paperclip \
    sh -c 'mkdir -p "$CLAUDE_CONFIG_DIR" && cd /tmp/paperclip-check && timeout 120 claude -p "Reply with exactly the word OK and nothing else." --output-format text < /dev/null 2>&1' < /dev/null)" || rc=$?
  out="$(printf '%s' "$out" | sed -E 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-***/g' | tail -n 5)"
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | tr -d '[:space:].!' | tr '[:lower:]' '[:upper:]')" = "OK" ]; then
    ok "Claude answered: $out"
    ok "The subscription token works. Agents without an 'AI connection' use it."
  else
    warn "Claude did not answer correctly (exit $rc):"
    printf '    %s\n' "$out" >&2
    die "Token check failed. Create a new one with: paperclip token"
  fi
}

cmd_invite() {
  need_env
  local url out; url="$(env_get PAPERCLIP_PUBLIC_URL)"
  say "Creating a one-time invite link for the first admin account..."
  # The CLI wants a config file; this setup is configured by environment
  # variables, so hand it a throwaway one (the database comes from DATABASE_URL).
  out="$(dc exec -T -u node -w /app paperclip sh -c '
    printf "%s" "{\"\$meta\":{\"version\":1,\"source\":\"onboard\",\"updatedAt\":\"2026-01-01T00:00:00.000Z\"},\"database\":{\"mode\":\"postgres\"},\"logging\":{\"mode\":\"file\"},\"server\":{\"deploymentMode\":\"authenticated\"}}" > /tmp/paperclip-bootstrap.json
    node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts auth bootstrap-ceo -c /tmp/paperclip-bootstrap.json --base-url "$1"
    rm -f /tmp/paperclip-bootstrap.json' sh "$url" < /dev/null 2>&1 || true)"
  if printf '%s' "$out" | grep -qE 'https?://[^ ]*/invite/'; then
    echo
    echo "  Open this link in your browser and create your admin account:"
    echo "  $(printf '%s' "$out" | grep -oE 'https?://[^ ]*/invite/[A-Za-z0-9_]+' | head -n1)"
    echo
    echo "  Once your account exists, close the door to strangers: paperclip signups off"
  elif printf '%s' "$out" | grep -qi 'already'; then
    ok "An admin account already exists; sign in at $url"
  else
    printf '%s\n' "$out" | tail -n 5
    return 1
  fi
}

cmd_status() {
  need_env
  say "Containers"
  dc ps --format 'table {{.Service}}\t{{.Status}}' < /dev/null
  echo
  local url; url="$(env_get PAPERCLIP_PUBLIC_URL)"
  if curl -fs -o /dev/null --max-time 5 "$(health_url)"; then ok "Paperclip answers on this machine."; else warn "Paperclip does not answer locally."; fi
  if [ "$(env_get PAPERCLIP_MODE)" = "https" ]; then
    if curl -fs -o /dev/null --max-time 10 "$url/api/health"; then ok "$url answers (HTTPS OK)."; else warn "$url does not answer yet (DNS, firewall or certificate)."; fi
  else
    echo "URL: $url (plain HTTP, private network only)"
  fi
  echo "Version: $(env_get PAPERCLIP_VERSION) (pinned, no auto-update)"
  if [ "$(env_get PAPERCLIP_AUTH_DISABLE_SIGN_UP)" = "true" ]; then
    echo "Sign-ups: off"
  else
    warn "Sign-ups: OPEN (anyone reaching the site can create an account). Close with: paperclip signups off"
  fi
  local created; created="$(env_get CLAUDE_TOKEN_CREATED)"
  if [ -z "$(env_get CLAUDE_CODE_OAUTH_TOKEN)" ]; then
    warn "Claude token: NOT SET. Run: paperclip token"
  elif [ -n "$created" ]; then
    local age=$(( ( $(date -u +%s) - $(date -u -d "$created" +%s) ) / 86400 ))
    local left=$(( 365 - age ))
    echo "Claude token: set on $created, about $left days left."
    [ "$left" -lt 30 ] && warn "Renew it soon: paperclip token"
  fi
  local last; last="$(ls -1t "$BACKUPS"/paperclip-db-*.dump 2>/dev/null | head -n1 || true)"
  if [ -n "$last" ]; then echo "Last backup: $(basename "$last")"; else echo "Last backup: none yet"; fi
}

cmd_signups() {
  need_root; need_env
  case "${1:-}" in
    off) env_set PAPERCLIP_AUTH_DISABLE_SIGN_UP true ;;
    on)  env_set PAPERCLIP_AUTH_DISABLE_SIGN_UP false ;;
    *)   die "Usage: paperclip signups on|off" ;;
  esac
  dc up -d paperclip < /dev/null
  wait_healthy
  ok "Sign-ups are now $1."
}

cmd_backup() {
  need_root; need_env
  mkdir -p "$BACKUPS"; chmod 700 "$BACKUPS"
  local ts; ts="$(date -u +%Y%m%d-%H%M%S)"
  say "Dumping the database..."
  dc exec -T db pg_dump -U paperclip -d paperclip --format=custom < /dev/null > "$BACKUPS/paperclip-db-$ts.dump"
  say "Archiving Paperclip files (secrets key, uploads, workspaces)..."
  tar -C "$DEPLOY/data" --exclude='*/node_modules' --exclude='paperclip/instances/*/data/backups' -czf "$BACKUPS/paperclip-files-$ts.tar.gz" paperclip
  cp "$ENV_FILE" "$BACKUPS/env-$ts"
  chmod 600 "$BACKUPS"/*
  # Keep the newest 7 of each kind.
  local kind
  for kind in 'paperclip-db-*.dump' 'paperclip-files-*.tar.gz' 'env-*'; do
    ls -1t "$BACKUPS"/$kind 2>/dev/null | tail -n +8 | xargs -r rm -f --
  done
  ok "Backup $ts written to $BACKUPS ($(du -sh "$BACKUPS" | cut -f1) total)."
}

cmd_update() {
  need_root; need_env
  local target="${1:-}" current; current="$(env_get PAPERCLIP_VERSION)"
  if [ -z "$target" ]; then
    echo "Current version: $current"
    echo "Latest stable:   $(curl -fsS --max-time 10 https://registry.npmjs.org/paperclipai/latest | grep -oE '"version":"[^"]+"' | head -n1 | cut -d'"' -f4 || echo '?')"
    echo "Release notes:   https://github.com/paperclipai/paperclip/releases"
    echo "To update:       paperclip update <version>"
    echo "To update these scripts, re-run the install command from $PROJECT_URL"
    return 0
  fi
  say "Checking that $IMAGE_REPO:$target exists..."
  docker pull "$IMAGE_REPO:$target" >/dev/null || die "No image $IMAGE_REPO:$target"
  cmd_backup
  env_set PAPERCLIP_VERSION "$target"
  dc up -d paperclip < /dev/null
  if wait_healthy; then
    ok "Now on $target (was $current). Roll back with: paperclip update $current"
  else
    warn "Rolling back to $current."
    env_set PAPERCLIP_VERSION "$current"
    dc up -d paperclip < /dev/null
    wait_healthy || true
    die "Update to $target failed; back on $current. If the database was migrated, restore the last backup (see README)."
  fi
}

cmd_remove_old() {
  need_root
  local old="${1:-}"
  [ -n "$old" ] || die "Usage: paperclip remove-old <folder of the other stack's docker-compose.yml>"
  old="$(readlink -f "$old")"
  [ "$old" != "$ROOT" ] && [ "$old" != "$DEPLOY" ] || die "That is this installation."
  [ -f "$old/docker-compose.yml" ] || [ -f "$old/compose.yml" ] || [ -f "$old/docker-compose.yaml" ] || die "No compose file in $old."
  say "Stack in $old:"
  (cd "$old" && docker compose ps) || true
  echo
  local archive; archive="/root/paperclip-old-$(date +%Y%m%d-%H%M%S).tar.gz"
  echo "This will stop that stack, archive the whole folder (data included) to"
  echo "$archive, then remove its containers. Nothing is deleted from disk."
  [ "$(ask "Type REMOVE to continue" "")" = "REMOVE" ] || die "Cancelled."
  (cd "$old" && docker compose stop)
  (umask 077 && tar -C "$(dirname "$old")" -czf "$archive" "$(basename "$old")")
  ok "Archived to $archive (private, mode 600)."
  (cd "$old" && docker compose down)
  ok "Old containers removed."
  local holders; holders="$(foreign_port_holders '80|443')"
  if [ -n "$holders" ]; then
    warn "These containers still hold ports 80/443: $holders"
    echo "If they only served the old Paperclip (often a Traefik from a hosting template), stop them:"
    for h in $holders; do echo "    docker update --restart=no $h && docker stop $h"; done
  fi
}

cmd_uninstall() {
  need_root; need_env
  echo "This stops and removes the Paperclip containers, the backup schedule and the"
  echo "'paperclip' command. Your data, settings and backups stay in $ROOT."
  [ "$(ask "Type UNINSTALL to continue" "")" = "UNINSTALL" ] || die "Cancelled."
  dc --profile https down < /dev/null
  if [ -f /etc/systemd/system/paperclip-backup.timer ]; then
    systemctl disable --now paperclip-backup.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/paperclip-backup.timer /etc/systemd/system/paperclip-backup.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f /etc/cron.d/paperclip-backup
  [ "$(readlink -f /usr/local/bin/paperclip 2>/dev/null)" = "$ROOT/paperclip.sh" ] && rm -f /usr/local/bin/paperclip
  ok "Uninstalled. To delete everything, including data: rm -rf $ROOT"
}

case "${1:-help}" in
  install)    shift; cmd_install "$@" ;;
  token)      shift; cmd_token "${1:-}" ;;
  check)      cmd_check ;;
  invite)     cmd_invite ;;
  signups)    shift; cmd_signups "${1:-}" ;;
  status)     cmd_status ;;
  logs)       shift; dc logs -f --tail=200 "${@:-paperclip}" ;;
  backup)     cmd_backup ;;
  update)     shift; cmd_update "${1:-}" ;;
  restart)    need_env; dc restart paperclip < /dev/null; wait_healthy ;;
  stop)       need_env; dc stop < /dev/null ;;
  start)      need_env; dc up -d < /dev/null; wait_healthy ;;
  remove-old) shift; cmd_remove_old "${1:-}" ;;
  uninstall)  cmd_uninstall ;;
  *) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
