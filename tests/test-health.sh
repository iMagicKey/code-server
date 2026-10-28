#!/usr/bin/env bash
# Regression test for code-server's idle/active /healthz behavior.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
function_body=$(sed -n '/^healthy() {/,/^}/p' "$ROOT/code-server-manager")
[[ -n "$function_body" ]] || { echo 'Missing healthy()' >&2; exit 1; }

BIND_HOST=0.0.0.0
PORT=15001
UNIT=code-server.service
mock_response=''
service_active=true
systemctl() { [[ "$service_active" == true ]]; }
curl() {
  [[ "$*" == *'--noproxy'* ]] || return 17
  printf '%s' "$mock_response"
}
eval "$function_body"

for value in alive expired; do
  mock_response="{\"status\":\"$value\",\"lastHeartbeat\":0}"
  healthy || { echo "Health check rejected valid status: $value" >&2; exit 1; }
done
for value in unknown nope; do
  mock_response="{\"status\":\"$value\"}"
  if healthy; then echo "Health check accepted invalid status: $value" >&2; exit 1; fi
done
mock_response='not-json'
if healthy; then echo 'Health check accepted malformed JSON' >&2; exit 1; fi
mock_response='{"status":"expired"}'
service_active=false
if healthy; then echo 'Health check accepted an inactive systemd service' >&2; exit 1; fi
echo 'OK: alive, expired, invalid JSON, and inactive service.'
