#!/usr/bin/env bash
# One-command installer for paperclip-selfhost.
#
#   curl -fsSL https://raw.githubusercontent.com/artenl/paperclip-selfhost/main/install.sh | sudo bash
#
# Options go after `bash -s --`, for example:
#   ... | sudo bash -s -- --domain paperclip.example.com
#   ... | sudo bash -s -- --local
#
# It downloads the scripts to /opt/paperclip (override with PAPERCLIP_DIR) and runs
# `paperclip install`. Running it again updates the scripts and keeps your
# settings and data.
set -euo pipefail

# Everything lives in main(), called on the last line: under `curl | bash`, bash
# then has the whole file before it runs any of it.
main() {
  local repo="${PAPERCLIP_SELFHOST_REPO:-artenl/paperclip-selfhost}"
  local ref="${PAPERCLIP_SELFHOST_REF:-main}"
  local dir="${PAPERCLIP_DIR:-/opt/paperclip}"
  local tmp f

  fail() { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }
  [ "$(uname -s)" = "Linux" ] || fail "This installer supports Linux servers only."
  [ "$(id -u)" -eq 0 ] || fail "Run it as root: curl -fsSL https://raw.githubusercontent.com/$repo/$ref/install.sh | sudo bash"
  for f in curl tar; do command -v "$f" >/dev/null 2>&1 || fail "'$f' is required. Install it first (apt-get install -y $f)."; done

  printf '\033[1;34m==>\033[0m Downloading paperclip-selfhost (%s@%s) to %s\n' "$repo" "$ref" "$dir"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://github.com/$repo/archive/$ref.tar.gz" | tar -xz -C "$tmp" --strip-components=1 \
    || fail "Download failed."
  [ -f "$tmp/paperclip.sh" ] || fail "Downloaded archive is missing paperclip.sh."

  # Only these files are replaced. deploy/.env, deploy/data/ and backups/ are never touched.
  mkdir -p "$dir/deploy"
  install -m 755 "$tmp/paperclip.sh" "$dir/paperclip.sh"
  install -m 644 "$tmp/deploy/docker-compose.yml" "$dir/deploy/docker-compose.yml"
  install -m 644 "$tmp/deploy/Caddyfile" "$dir/deploy/Caddyfile"
  for f in README.md LICENSE; do [ -f "$tmp/$f" ] && install -m 644 "$tmp/$f" "$dir/$f"; done

  # Questions are read from the terminal (/dev/tty), not from this pipe.
  exec "$dir/paperclip.sh" install "$@" < /dev/null
}

main "$@"
