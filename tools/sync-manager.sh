#!/usr/bin/env bash
# Keep the manager embedded in the standalone installer in sync with the source file.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
installer = root / 'install-code-server.sh'
manager = root / 'code-server-manager'
text = installer.read_text(encoding='utf-8')
start_marker = "<<'EMBEDDED_CODE_SERVER_MANAGER'\n"
end_marker = "\nEMBEDDED_CODE_SERVER_MANAGER\n"
assert text.count(start_marker) == 1 and text.count(end_marker) == 1, 'Manager markers not unique'
start = text.index(start_marker) + len(start_marker)
end = text.index(end_marker, start)
source = manager.read_text(encoding='utf-8').rstrip('\n')
installer.write_text(text[:start] + source + text[end:], encoding='utf-8')
print('Embedded manager synchronized.')
PY
