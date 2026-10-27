#!/usr/bin/env bash
# Standalone installer for code-server, Ubuntu 26.04 LTS (amd64/arm64)
# Usage: sudo bash install-code-server.sh
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP=/srv/code-server
ETC=/etc/code-server
STATE=/var/lib/code-server
WORKSPACES=/srv/workspaces
SERVICE=/etc/systemd/system/code-server.service
TIMER=/etc/systemd/system/code-server-cert-renew.timer
TIMER_SERVICE=/etc/systemd/system/code-server-cert-renew.service
CREDS=/root/code-server-credentials.txt
MANAGER=/usr/local/sbin/code-server-manager
MARKER="$ETC/.installed-by-standalone-installer"
SETTINGS="$ETC/manager.env"
PORT=15001
BIND_HOST=0.0.0.0
IP_OVERRIDE=
RELEASE_VERSION=latest
MANAGE_UFW=true
CUSTOM_OPTIONS=false

say() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: sudo bash install-code-server.sh [OPTIONS]

Installs code-server as root with HTTPS and password authentication.
Defaults: TCP 15001, bind 0.0.0.0, workspace /srv/workspaces.

Options for a fresh installation:
  --port NUMBER          HTTPS listening port (1024-65535)
  --bind-host IPV4       Listening address, e.g. 0.0.0.0 or 127.0.0.1
  --workspace-dir PATH   Absolute path for projects (default /srv/workspaces)
  --server-ip IPV4       Override detected IP used for TLS SAN and access URL
  --version X.Y.Z        Install a specific stable release (default: latest)
  --no-ufw               Do not modify UFW firewall rules
  --help                 Show this help

Options only apply on the first installation. Subsequent runs preserve
existing settings. Use code-server-manager for updates and rollback.
EOF
}

ipv4_valid() {
  python3 - "$1" <<'PYCODE' >/dev/null 2>&1
import ipaddress, sys
try:
    addr = ipaddress.IPv4Address(sys.argv[1])
    assert not (addr.is_multicast or addr.is_unspecified or addr.is_link_local)
except (ValueError, AssertionError):
    sys.exit(1)
PYCODE
}

while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --no-ufw) MANAGE_UFW=false; CUSTOM_OPTIONS=true; shift ;;
    --port|--bind-host|--workspace-dir|--server-ip|--version)
      key=$1
      (($# >= 2)) || die "Missing value for $key"
      value=$2
      case "$key" in
        --port) PORT=$value ;;
        --bind-host) BIND_HOST=$value ;;
        --workspace-dir) WORKSPACES=$value ;;
        --server-ip) IP_OVERRIDE=$value ;;
        --version) RELEASE_VERSION=$value ;;
      esac
      CUSTOM_OPTIONS=true
      shift 2 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$PORT >= 1024 && 10#$PORT <= 65535 )) || die 'Port must be between 1024 and 65535.'
PORT=$((10#$PORT))
ipv4_valid "$BIND_HOST" || [[ "$BIND_HOST" == 0.0.0.0 ]] || die 'Invalid --bind-host IPv4 address.'
[[ -z "$IP_OVERRIDE" ]] || ipv4_valid "$IP_OVERRIDE" || die 'Invalid --server-ip IPv4 address.'
[[ "$RELEASE_VERSION" == latest || "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Version must be X.Y.Z.'
# Deliberately restrict paths to avoid unexpected systemd/YAML special characters.
[[ "$WORKSPACES" =~ ^/[a-zA-Z0-9._/-]+$ && "$WORKSPACES" != / && "$WORKSPACES" != *'//'* && "$WORKSPACES" != *'/../'* && "$WORKSPACES" != *'/./'* && "$WORKSPACES" != *'/..' && "$WORKSPACES" != *'/.' ]] || die 'Invalid workspace path: use an absolute path with letters, digits, . _ - / (no .. segments).'
WORKSPACES=${WORKSPACES%/}
case "$WORKSPACES" in
  "$APP"|"$APP"/*|"$ETC"|"$ETC"/*|"$STATE"|"$STATE"/*)
    die 'Workspace must be outside the application, state, and configuration directories.' ;;
esac
if [[ "$BIND_HOST" == 127.0.0.1 && -z "$IP_OVERRIDE" ]]; then
  IP_OVERRIDE=127.0.0.1
fi

(( EUID == 0 )) || die 'Use sudo bash install-code-server.sh'
[[ -r /etc/os-release ]] || die 'Cannot identify the OS.'
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 26.04 ]] || die "Expected Ubuntu 26.04 LTS; detected ${PRETTY_NAME:-unknown}."
case "$(dpkg --print-architecture)" in amd64|arm64) ;; *) die 'Only amd64 and arm64 are supported.' ;; esac
[[ -d /run/systemd/system ]] || die 'This installation requires systemd (not a container without systemd).'

if [[ -f "$MARKER" ]]; then
  [[ "$CUSTOM_OPTIONS" == false ]] || die 'Install options are first-install only; existing configuration is preserved. See README for changing settings.'
else
  for path in "$SERVICE" "$ETC/config.yaml" "$APP/current" "$MANAGER" "$SETTINGS"; do
    [[ ! -e "$path" && ! -L "$path" ]] || die "Existing unmanaged installation at $path. Refusing to overwrite."
  done
fi

say 'Installing only required packages (no apt upgrade)...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl openssl python3 python3-argon2 iproute2
python3 -c 'from argon2 import PasswordHasher; from argon2.low_level import Type' \
  || die 'Python argon2-cffi is unavailable after package installation.'

install -d -m 0755 "$APP" "$APP/versions" "$STATE" \
  "$STATE/user-data" "$STATE/user-data/User" "$STATE/extensions"
# Existing workspaces, permissions and files must never be modified by this installer.
if [[ ! -d "$WORKSPACES" ]]; then
  [[ ! -e "$WORKSPACES" && ! -L "$WORKSPACES" ]] || die "Workspace path is not a directory: $WORKSPACES"
  install -d -m 0755 "$WORKSPACES"
fi
install -d -m 0700 "$APP/ssl" "$ETC"
if [[ ! -e "$SETTINGS" ]]; then
  {
    printf 'PORT=%q\n' "$PORT"
    printf 'BIND_HOST=%q\n' "$BIND_HOST"
    printf 'WORKSPACES=%q\n' "$WORKSPACES"
    printf 'IP_OVERRIDE=%q\n' "$IP_OVERRIDE"
    printf 'MANAGE_UFW=%q\n' "$MANAGE_UFW"
  } > "$SETTINGS"
  chmod 0600 "$SETTINGS"
fi
# Preserve existing installation settings without replacing the YAML or unit.
# On repeat installation, read the path and port from the root-owned settings.
if [[ -f "$MARKER" ]]; then
  [[ ! -L "$SETTINGS" && "$(stat -c %u "$SETTINGS")" == 0 ]] || die 'Untrusted manager settings.'
  settings_mode=$(stat -c %a "$SETTINGS")
  (( (8#$settings_mode & 8#022) == 0 )) || die 'Manager settings must not be group/other writable.'
  unset settings_mode
  # shellcheck disable=SC1090
  source "$SETTINGS"
fi

# The manager is embedded below, so this installer needs no companion files.
cat >"${MANAGER}.tmp.$$" <<'EMBEDDED_CODE_SERVER_MANAGER'
#!/usr/bin/env bash
# code-server manager for Ubuntu 26.04; installed at /usr/local/sbin/code-server-manager
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP=/srv/code-server
VERSIONS="$APP/versions"
CURRENT="$APP/current"
PREVIOUS="$APP/previous"
SSL="$APP/ssl"
ETC=/etc/code-server
STATE=/var/lib/code-server
UNIT=code-server.service
PORT=15001
BIND_HOST=0.0.0.0
IP_OVERRIDE=
WORKSPACES=/srv/workspaces
GITHUB_API=https://api.github.com/repos/coder/code-server/releases/latest
SETTINGS=/etc/code-server/manager.env
CREDENTIALS=/root/code-server-credentials.txt
TMP_WORK=

# Settings are root-owned and generated by the installer.
# Never source a config file writable by an unprivileged user.
if [[ -f "$SETTINGS" ]]; then
  [[ ! -L "$SETTINGS" ]] || { echo 'Refusing symlinked manager settings.' >&2; exit 1; }
  [[ "$(stat -c %u "$SETTINGS")" == 0 ]] || { echo 'Manager settings must be root-owned.' >&2; exit 1; }
  mode=$(stat -c %a "$SETTINGS")
  (( (8#$mode & 8#022) == 0 )) || { echo 'Manager settings must not be group/other writable.' >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$SETTINGS"
  unset mode
fi

say() { printf '[code-server] %s\n' "$*"; }
die() { printf '[code-server] ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n "$TMP_WORK" && -d "$TMP_WORK" ]]; then rm -rf -- "$TMP_WORK"; fi; }
trap cleanup EXIT

need_root() { (( EUID == 0 )) || die 'Run with sudo or as root.'; }
need_tools() {
  local name
  for name in curl python3 sha256sum tar mktemp openssl systemctl flock; do
    command -v "$name" >/dev/null || die "Missing dependency: $name (run installer first)."
  done
}
lock() {
  mkdir -p /run/lock
  exec 9>/run/lock/code-server-manager.lock
  flock -n 9 || die 'Another code-server-manager operation is in progress.'
}
architecture() {
  case "$(dpkg --print-architecture)" in
    amd64|arm64) dpkg --print-architecture ;;
    *) die 'Supported architectures: amd64 and arm64 only.' ;;
  esac
}
installed_version() {
  local path
  [[ -L "$CURRENT" ]] || return 0
  path=$(readlink -f "$CURRENT") || return 0
  [[ "$path" == "$VERSIONS/"* ]] || die 'Unsafe current symlink: outside versions directory.'
  [[ -x "$path/bin/code-server" ]] || die "Broken current symlink: $path"
  basename "$path"
}
previous_version() {
  local path
  [[ -L "$PREVIOUS" ]] || return 0
  path=$(readlink -f "$PREVIOUS") || return 0
  [[ "$path" == "$VERSIONS/"* && -x "$path/bin/code-server" ]] || return 0
  basename "$path"
}
# Atomically replace a symlink in the same filesystem; never delete versions.
point_link() {
  local name=$1 target=$2 tmp
  tmp="${name}.new.$$"
  ln -s "$target" "$tmp"
  mv -Tf "$tmp" "$name"
}
release_metadata() {
  local arch=$1 output=$2 requested=${3:-latest} url
  if [[ "$requested" == latest ]]; then
    url=$GITHUB_API
  else
    [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid version: $requested"
    url="https://api.github.com/repos/coder/code-server/releases/tags/v${requested}"
  fi
  curl -fLsS --retry 3 --connect-timeout 10 --max-time 45 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: code-server-manager/1.0' \
    "$url" -o "$output"
  python3 - "$arch" "$output" <<'PY'
import json, re, sys
arch, filename = sys.argv[1:]
try:
    with open(filename, encoding='utf-8') as fh:
        doc = json.load(fh)
    tag = doc['tag_name']
    assert not doc.get('draft') and not doc.get('prerelease')
    assert re.fullmatch(r'v\d+\.\d+\.\d+', tag), 'Unexpected release tag'
    version = tag[1:]
    name = f'code-server-{version}-linux-{arch}.tar.gz'
    assets = [asset for asset in doc['assets'] if asset.get('name') == name]
    assert len(assets) == 1, 'Release archive not found'
    asset = assets[0]
    url = asset['browser_download_url']
    assert url == f'https://github.com/coder/code-server/releases/download/{tag}/{name}', 'Unexpected asset URL'
    digest = asset['digest']
    assert re.fullmatch(r'sha256:[a-f0-9]{64}', digest), 'Missing SHA-256 digest'
    print(version)
    print(url)
    print(digest.partition(':')[2])
except (KeyError, ValueError, AssertionError, TypeError) as exc:
    sys.exit(f'Invalid GitHub release metadata: {exc}')
PY
}
read_release() {
  local arch=$1 file=$2 requested=${3:-latest}
  local -a fields
  # Capture the subprocess exit status as well as the parsed output.
  local metadata
  metadata=$(release_metadata "$arch" "$file" "$requested") || die 'Unable to retrieve release metadata.'
  mapfile -t fields <<< "$metadata"
  [[ ${#fields[@]} -eq 3 && -n ${fields[2]:-} ]] || die 'Could not parse release metadata.'
  RELEASE_VERSION=${fields[0]}
  RELEASE_URL=${fields[1]}
  RELEASE_SHA=${fields[2]}
}

download_release() {
  local v=$1 url=$2 sha=$3 arch=$4 dest="$VERSIONS/$1"
  local base="code-server-${v}-linux-${arch}" actual
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid version in release metadata.'
  if [[ -x "$dest/bin/code-server" ]]; then
    say "Version $v already available locally."
    return 0
  fi
  [[ ! -e "$dest" && ! -L "$dest" ]] || die "Unexpected existing version directory: $dest"
  mkdir -p "$VERSIONS"
  TMP_WORK=$(mktemp -d "$VERSIONS/.install.XXXXXXXX")
  say "Downloading code-server $v ($arch), approximately 230 MB..."
  curl -fL --retry 3 --connect-timeout 15 --speed-time 45 --speed-limit 1000 \
    --progress-bar "$url" -o "$TMP_WORK/release.tar.gz"
  actual=$(sha256sum "$TMP_WORK/release.tar.gz" | cut -d' ' -f1)
  [[ "$actual" == "$sha" ]] || die "SHA-256 mismatch: expected $sha, received $actual"
  say 'SHA-256 verified.'
  # Prevent unexpected paths before extracting an archive as root.
  tar -tzf "$TMP_WORK/release.tar.gz" | python3 -c '
import sys
base = sys.argv[1]
for raw in sys.stdin:
    path = raw.rstrip("\n")
    parts = path.split("/")
    if not path.startswith(base + "/") and path != base:
        sys.exit("Refusing archive with unexpected top-level path: " + path)
    if any(part == ".." for part in parts):
        sys.exit("Refusing archive with parent traversal: " + path)
' "$base" || die 'Unsafe archive paths.'
  tar -xzf "$TMP_WORK/release.tar.gz" -C "$TMP_WORK" --no-same-owner
  [[ -x "$TMP_WORK/$base/bin/code-server" ]] || die 'Downloaded archive lacks code-server executable.'
  "$TMP_WORK/$base/bin/code-server" --version >/dev/null || die 'Downloaded code-server binary failed its version check.'
  mv -T "$TMP_WORK/$base" "$dest"
  say "Installed $dest"
  rm -rf -- "$TMP_WORK"
  TMP_WORK=
}

healthy() {
  systemctl is-active --quiet "$UNIT" || return 1
  local response health_host=127.0.0.1
  [[ "$BIND_HOST" == 0.0.0.0 ]] || health_host=$BIND_HOST
  response=$(curl -fkLsS --connect-timeout 2 --max-time 3 "https://${health_host}:${PORT}/healthz" 2>/dev/null) || return 1
  python3 -c 'import json,sys; assert json.load(sys.stdin).get("status") == "alive"' <<<"$response" 2>/dev/null
}
wait_for_health() {
  local i
  for i in $(seq 1 30); do
    if healthy; then return 0; fi
    sleep 1
  done
  return 1
}

check() {
  local current arch
  current=$(installed_version)
  arch=$(architecture)
  TMP_WORK=$(mktemp -d)
  read_release "$arch" "$TMP_WORK/release.json"
  printf 'Installed: %s\nLatest:    %s\n' "${current:-none}" "$RELEASE_VERSION"
  if [[ "$current" == "$RELEASE_VERSION" ]]; then
    say 'Up to date.'
  else
    say 'To install the latest release: sudo code-server-manager update'
  fi
}

update() {
  local old v arch requested=latest
  if [[ ${1:-} == --version ]]; then
    [[ $# -eq 2 ]] || die 'Usage: code-server-manager update [--version X.Y.Z]'
    requested=$2
  else
    [[ $# -eq 0 ]] || die 'Usage: code-server-manager update [--version X.Y.Z]'
  fi
  lock
  [[ -f "$ETC/config.yaml" && -f /etc/systemd/system/code-server.service ]] || die 'Run the installer first.'
  arch=$(architecture)
  TMP_WORK=$(mktemp -d)
  read_release "$arch" "$TMP_WORK/release.json" "$requested"
  rm -rf -- "$TMP_WORK"
  TMP_WORK=
  v=$RELEASE_VERSION
  old=$(installed_version)
  if [[ "$old" == "$v" ]]; then
    say "code-server $v is already installed."
    return 0
  fi
  download_release "$v" "$RELEASE_URL" "$RELEASE_SHA" "$arch"
  say "Activating $v (previous: ${old:-none})."
  point_link "$CURRENT" "versions/$v"
  systemctl daemon-reload
  if systemctl restart "$UNIT" && wait_for_health; then
    if [[ -n "$old" ]]; then
      point_link "$PREVIOUS" "versions/$old"
    fi
    say "Updated successfully to $v."
    return 0
  fi
  say 'Health check failed: restoring previous version.' >&2
  if [[ -n "$old" ]]; then
    point_link "$CURRENT" "versions/$old"
    systemctl restart "$UNIT" || true
    if wait_for_health; then say "Restored $old."; else say 'Previous version also failed the health check; check journalctl.' >&2; fi
  else
    rm -f "$CURRENT"
    systemctl stop "$UNIT" || true
    say 'Initial installation did not pass health check. Inspect journalctl -u code-server.' >&2
  fi
  return 1
}

rollback() {
  local old target
  lock
  old=$(installed_version)
  target=$(previous_version)
  [[ -n "$old" && -n "$target" ]] || die 'No previous version available.'
  [[ "$old" != "$target" ]] || die 'Previous and current versions match.'
  say "Switching $old -> $target"
  point_link "$CURRENT" "versions/$target"
  if systemctl restart "$UNIT" && wait_for_health; then
    point_link "$PREVIOUS" "versions/$old"
    say "Rolled back to $target."
    return 0
  fi
  say 'Rollback target failed health check; restoring original.' >&2
  point_link "$CURRENT" "versions/$old"
  systemctl restart "$UNIT" || true
  wait_for_health || say 'Service still unhealthy, check logs.' >&2
  return 1
}

valid_ip() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress,sys
try:
    ip=ipaddress.IPv4Address(sys.argv[1])
    assert not (ip.is_unspecified or ip.is_multicast or ip.is_link_local)
except (ValueError, AssertionError):
    sys.exit(1)
PY
}
public_ip() {
  local url ip
  if [[ -n "$IP_OVERRIDE" ]]; then
    valid_ip "$IP_OVERRIDE" || die "Invalid --server-ip address: $IP_OVERRIDE"
    printf '%s\n' "$IP_OVERRIDE"
    return 0
  fi
  for url in https://api.ipify.org https://checkip.amazonaws.com https://ifconfig.me/ip; do
    ip=$(curl -4fLsS --connect-timeout 3 --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    if valid_ip "$ip"; then printf '%s\n' "$ip"; return 0; fi
  done
  # Keep the previously detected address if discovery services fail temporarily.
  # In particular, do not rotate an existing public TLS certificate to an
  # unrelated private address during transient network failures.
  if [[ -s "$ETC/public-ip" ]]; then
    ip=$(cat "$ETC/public-ip" 2>/dev/null || true)
    if valid_ip "$ip"; then
      say "WARNING: external IP services unavailable; reusing recorded IP $ip." >&2
      printf '%s\n' "$ip"
      return 0
    fi
  fi
  # Last resort for new installations on isolated/private networks.
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}') || true
  if [[ -n "$ip" ]] && valid_ip "$ip"; then
    say "WARNING: external IP services unavailable; using local IPv4 $ip." >&2
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

certificate_matches() {
  local ip=$1
  [[ -s "$SSL/cert.pem" && -s "$SSL/key.pem" ]] || return 1
  openssl x509 -in "$SSL/cert.pem" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
  openssl x509 -in "$SSL/cert.pem" -noout -checkip "$ip" >/dev/null 2>&1 || return 1
  # Verify private key matches certificate public key.
  local a b
  a=$(openssl x509 -in "$SSL/cert.pem" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) || return 1
  b=$(openssl pkey -in "$SSL/key.pem" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) || return 1
  [[ "$a" == "$b" ]]
}
renew_cert() {
  local ip temp had_old=0 old_ip=
  lock
  mkdir -p "$SSL" "$ETC"
  chmod 700 "$SSL"
  ip=$(public_ip) || die 'Cannot determine IPv4 address; certificate not modified.'
  if certificate_matches "$ip"; then
    say "Certificate for $ip is valid for at least 30 more days."
    printf '%s\n' "$ip" >"$ETC/public-ip"
    return 0
  fi
  say "Generating a new self-signed certificate for IP $ip."
  temp=$(mktemp -d "$SSL/.cert.XXXXXXXX")
  TMP_WORK=$temp
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -keyout "$temp/key.pem" -out "$temp/cert.pem" \
    -subj "/CN=$ip" \
    -addext "subjectAltName=IP:$ip" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
    -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1 || { rm -rf -- "$temp"; die 'OpenSSL certificate creation failed.'; }
  chmod 600 "$temp/key.pem"
  chmod 644 "$temp/cert.pem"
  old_ip=$(cat "$ETC/public-ip" 2>/dev/null || true)
  if [[ -f "$SSL/key.pem" && -f "$SSL/cert.pem" ]]; then
    had_old=1
    cp -p "$SSL/key.pem" "$temp/old.key.pem"
    cp -p "$SSL/cert.pem" "$temp/old.cert.pem"
  fi
  # Place key first so no new certificate is briefly paired with a stale key on restart.
  mv -f "$temp/key.pem" "$SSL/key.pem"
  mv -f "$temp/cert.pem" "$SSL/cert.pem"
  printf '%s\n' "$ip" >"$ETC/public-ip"
  if systemctl is-active --quiet "$UNIT"; then
    if ! systemctl restart "$UNIT" || ! wait_for_health; then
      say 'New TLS certificate caused a service failure; restoring old certificate.' >&2
      if (( had_old )); then
        mv -f "$temp/old.key.pem" "$SSL/key.pem"
        mv -f "$temp/old.cert.pem" "$SSL/cert.pem"
      fi
      if [[ -n "$old_ip" ]]; then printf "%s\n" "$old_ip" >"$ETC/public-ip"; else rm -f "$ETC/public-ip"; fi
      systemctl restart "$UNIT" || true
      rm -rf -- "$temp"
      die 'TLS certificate replacement failed.'
    fi
  fi
  rm -rf -- "$temp"
  TMP_WORK=
  say "Certificate ready: https://$ip:$PORT"
  say "SHA-256 fingerprint: $(openssl x509 -in "$SSL/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2-)"
}

status() {
  local ver prev ip
  ver=$(installed_version)
  prev=$(previous_version)
  ip=$(cat "$ETC/public-ip" 2>/dev/null || true)
  printf 'code-server version:   %s\n' "${ver:-not installed}"
  printf 'Previous version:      %s\n' "${prev:-none}"
  printf 'Service state:         %s\n' "$(systemctl is-active "$UNIT" 2>/dev/null || true)"
  printf 'Health endpoint:       %s\n' "$(if healthy; then echo alive; else echo unreachable; fi)"
  printf 'URL (recorded IP):     https://%s:%s\n' "${ip:-unknown}" "$PORT"
  printf 'Bind address:          %s:%s\n' "$BIND_HOST" "$PORT"
  printf 'Workspace:             %s\n' "$WORKSPACES"
  printf 'Credentials file:      %s\n' "$CREDENTIALS"
  if [[ -f "$SSL/cert.pem" ]]; then
    printf 'TLS certificate until: %s\n' "$(openssl x509 -in "$SSL/cert.pem" -noout -enddate | cut -d= -f2-)"
  fi
}

usage() {
  cat <<'EOF'
Usage: sudo code-server-manager COMMAND
  check         Check latest stable GitHub release
  update [--version X.Y.Z]
                Download, SHA-256 verify, activate; roll back on failed health check
  rollback      Swap to the previous installed version
  status        Show version, service, health, TLS certificate
  renew-cert    Reissue self-signed TLS certificate if expired soon / IP changed
  help          Show this help
EOF
}

main() {
  need_root
  need_tools
  case "${1:-help}" in
    help|-h|--help) usage ;;
    check) [[ $# -eq 1 ]] || die 'Usage: code-server-manager check'; check ;;
    update) shift; update "$@" ;;
    rollback) rollback ;;
    status) status ;;
    renew-cert) renew_cert ;;
    *) usage >&2; die "Unknown command: $1" ;;
  esac
}
main "$@"
EMBEDDED_CODE_SERVER_MANAGER
chmod 0755 "${MANAGER}.tmp.$$"
mv -f "${MANAGER}.tmp.$$" "$MANAGER"

if [[ ! -f "$ETC/config.yaml" ]]; then
  if [[ -f "$CREDS" ]]; then
    password=$(sed -n 's/^CODE_SERVER_PASSWORD=//p' "$CREDS" | head -n 1)
    [[ -n "$password" ]] || die "Credential file malformed: $CREDS"
    say 'Reusing the existing generated password.'
  else
    password=$(openssl rand -base64 36 | tr -d '\n')
    printf 'CODE_SERVER_PASSWORD=%s\n' "$password" > "$CREDS"
    chmod 0600 "$CREDS"
  fi
  hash=$(printf %s "$password" | python3 -c '
import sys
from argon2 import PasswordHasher
from argon2.low_level import Type
p = sys.stdin.buffer.read().decode("ascii")
print(PasswordHasher(type=Type.ID, time_cost=3, memory_cost=65536, parallelism=2).hash(p))
')
  [[ "$hash" == '$argon2id$'* ]] || die 'Argon2id generation failed.'
  cat > "$ETC/config.yaml" <<EOF
bind-addr: $BIND_HOST:$PORT
auth: password
hashed-password: "$hash"
cert: $APP/ssl/cert.pem
cert-key: $APP/ssl/key.pem
disable-telemetry: true
disable-update-check: true
disable-getting-started-override: true
user-data-dir: $STATE/user-data
extensions-dir: $STATE/extensions
EOF
  chmod 0600 "$ETC/config.yaml"
  unset password hash
else
  say 'Existing config.yaml preserved.'
fi

if [[ ! -e "$STATE/user-data/User/settings.json" ]]; then
  printf '{\n  "telemetry.telemetryLevel": "off"\n}\n' > "$STATE/user-data/User/settings.json"
  chmod 0600 "$STATE/user-data/User/settings.json"
fi

if [[ ! -f "$SERVICE" ]]; then
  cat > "$SERVICE" <<EOF
[Unit]
Description=code-server (browser-based VS Code; runs as root)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$WORKSPACES
Environment=HOME=/root
ExecStart=/srv/code-server/current/bin/code-server --config /etc/code-server/config.yaml --disable-telemetry --disable-update-check $WORKSPACES
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
fi

if [[ ! -f "$TIMER_SERVICE" ]]; then
  cat > "$TIMER_SERVICE" <<'EOF'
[Unit]
Description=Renew code-server self-signed TLS certificate if needed
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/code-server-manager renew-cert
EOF
fi

if [[ ! -f "$TIMER" ]]; then
  cat > "$TIMER" <<'EOF'
[Unit]
Description=Daily code-server TLS certificate check

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=45m
Unit=code-server-cert-renew.service

[Install]
WantedBy=timers.target
EOF
fi

chmod 0644 "$SERVICE" "$TIMER" "$TIMER_SERVICE"
touch "$MARKER"
chmod 0600 "$MARKER"
systemctl daemon-reload
systemctl enable code-server.service

say 'Generating or checking TLS certificate (IP and SAN automatically detected)...'
"$MANAGER" renew-cert

if [[ -L "$APP/current" ]]; then
  say 'Existing installation found; not modifying the installed version.'
  systemctl start code-server.service
  "$MANAGER" status
else
  say 'Fetching and installing the newest stable GitHub release...'
  if [[ "$RELEASE_VERSION" == latest ]]; then
    "$MANAGER" update
  else
    "$MANAGER" update --version "$RELEASE_VERSION"
  fi
fi

systemctl enable --now code-server-cert-renew.timer

# Open only code-server's port when UFW is already enabled; never enable UFW automatically.
if [[ "$MANAGE_UFW" == true && "$BIND_HOST" != 127.0.0.1 ]] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if ! ufw status | grep -qE "^${PORT}/tcp[[:space:]]+ALLOW"; then
    ufw allow "${PORT}/tcp" comment 'code-server HTTPS'
  fi
fi

ip=$(cat "$ETC/public-ip" 2>/dev/null || echo '<IPv4 not detected>')
say ''
say '================= INSTALLATION COMPLETE ================='
say "URL:        https://$ip:$PORT"
say 'User:       root (system service; web login only uses password)'
if [[ -f "$CREDS" ]]; then
  password=$(sed -n 's/^CODE_SERVER_PASSWORD=//p' "$CREDS" | head -n 1)
  if [[ -n "$password" ]]; then say "Password:   $password"; fi
  unset password
fi
say "Credentials: $CREDS (chmod 600)"
say "Workspace:   $WORKSPACES"
say "Listening:   $BIND_HOST:$PORT"
say 'Updates:     sudo code-server-manager update'
say 'Rollback:    sudo code-server-manager rollback'
say 'Status:      sudo code-server-manager status'
say "TLS SHA-256: $(openssl x509 -in "$APP/ssl/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2-)"
say 'IMPORTANT: root code-server exposed on the Internet grants full server access after login.'
say 'A self-signed certificate must be explicitly trusted; otherwise some VS Code webviews may fail.'
