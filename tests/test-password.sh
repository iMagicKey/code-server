#!/usr/bin/env bash
# Test password rotation in an isolated directory (never touches real configs).
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! python3 -c 'import argon2' >/dev/null 2>&1; then
  echo 'SKIP: python3-argon2 not installed (password rotation test).'
  exit 0
fi
function_body=$(sed -n '/^reset_password() {/,/^}/p' "$ROOT/code-server-manager")
[[ -n "$function_body" ]] || { echo 'Missing reset_password()' >&2; exit 1; }
SANDBOX=$(mktemp -d)
trap 'rm -rf -- "$SANDBOX"' EXIT
ETC="$SANDBOX/config"
UNIT=code-server.service
TMP_WORK=
LEGACY_CREDENTIALS="$SANDBOX/legacy-password"
mkdir -p "$ETC"
printf 'auth: password\nhashed-password: "oldhash"\n' > "$ETC/config.yaml"
chmod 0600 "$ETC/config.yaml"
printf 'legacy secret\n' > "$LEGACY_CREDENTIALS"

service_active=false
healthy_after_restart=true
systemctl() {
  if [[ "$1" == is-active ]]; then [[ "$service_active" == true ]]; else return 0; fi
}
wait_for_health() { [[ "$healthy_after_restart" == true ]]; }
lock() { :; }
say() { printf '[test] %s\n' "$*"; }
die() { echo "Failed: $*" >&2; return 1; }
eval "$function_body"

output=$(reset_password)
password=$(grep -E '^[a-f0-9]{48}$' <<<"$output")
[[ -n "$password" ]] || { echo 'New password not displayed' >&2; exit 1; }
[[ ! -e "$LEGACY_CREDENTIALS" ]] || { echo 'Legacy credentials not removed' >&2; exit 1; }
[[ $(stat -c %a "$ETC/config.yaml") == 600 ]] || { echo 'Config permissions changed' >&2; exit 1; }
! grep -Fq "$password" "$ETC/config.yaml" || { echo 'Plaintext stored in config' >&2; exit 1; }
hash=$(sed -n 's/^hashed-password: "\(.*\)"$/\1/p' "$ETC/config.yaml")
TEST_RESET_PASSWORD="$password" TEST_RESET_HASH="$hash" python3 - <<'PY'
import os
from argon2 import PasswordHasher
assert PasswordHasher().verify(os.environ['TEST_RESET_HASH'], os.environ['TEST_RESET_PASSWORD'])
PY

# When restart/health fails, restore previous hash, keep legacy credentials,
# and do not expose a non-working new password.
service_active=true
healthy_after_restart=false
printf 'legacy secret\n' > "$LEGACY_CREDENTIALS"
config_before=$(cat "$ETC/config.yaml")
if failed_output=$(reset_password 2>/dev/null); then
  echo 'Broken server accepted new password' >&2; exit 1
fi
[[ "$(cat "$ETC/config.yaml")" == "$config_before" ]] || { echo 'Config rollback failed' >&2; exit 1; }
[[ -f "$LEGACY_CREDENTIALS" ]] || { echo 'Legacy secret removed on failed reset' >&2; exit 1; }
! grep -Eq '^[a-f0-9]{48}$' <<<"$failed_output" || { echo 'Printed password after failed reset' >&2; exit 1; }
echo 'OK: new Argon2id hash, no plaintext file, rotation rollback.'
