#!/usr/bin/env bash
# Fast, non-privileged tests. Does not make system changes or install packages.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/install-code-server.sh"
bash -n "$ROOT/code-server-manager"
bash -n "$ROOT/tools/sync-manager.sh"
bash -n "$ROOT/tests/validate.sh"
bash -n "$ROOT/tests/test-health.sh"
bash -n "$ROOT/tests/test-password.sh"

python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
installer = (root / 'install-code-server.sh').read_text(encoding='utf-8')
manager = (root / 'code-server-manager').read_text(encoding='utf-8')
start = installer.index("<<'EMBEDDED_CODE_SERVER_MANAGER'\n") + len("<<'EMBEDDED_CODE_SERVER_MANAGER'\n")
end = installer.index('\nEMBEDDED_CODE_SERVER_MANAGER\n', start)
assert installer[start:end].rstrip('\n') == manager.rstrip('\n'), 'Embedded manager differs: run ./tools/sync-manager.sh'
for required in ['/srv/code-server', '/srv/workspaces', '/var/lib/code-server', '/etc/code-server', '15001', 'disable-telemetry']:
    assert required in installer, f'Missing expected config item: {required}'
for path in [root / 'install-code-server.sh', root / 'code-server-manager', root / 'README.md']:
    assert not any('\u0400' <= c <= '\u052f' for c in path.read_text(encoding='utf-8')), f'Cyrillic found in {path}'
print('OK: syntax, embedded manager consistency, required paths, and English source files.')
PY

# Validate the options parser without touching system services or installing packages.
help_output=$(bash "$ROOT/install-code-server.sh" --help)
for option in --port --bind-host --workspace-dir --server-ip --version --no-ufw; do
  grep -q -- "$option" <<<"$help_output" || { echo "Missing documented CLI option: $option" >&2; exit 1; }
done
for invalid in '--port 5' '--port NaN' '--workspace-dir ../unsafe' '--server-ip not-an-ip' '--version nope' '--unknown-option'; do
  # word splitting is deliberate for this fixed list of test cases.
  # shellcheck disable=SC2086
  if bash "$ROOT/install-code-server.sh" $invalid >/dev/null 2>&1; then
    echo "Invalid argument unexpectedly accepted: $invalid" >&2
    exit 1
  fi
done
echo 'OK: help screen and invalid-option handling.'

# The upstream health endpoint returns "expired" before any user activity.
bash "$ROOT/tests/test-health.sh"
bash "$ROOT/tests/test-password.sh"
