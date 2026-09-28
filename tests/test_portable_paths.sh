#!/usr/bin/env bash
# Proves relation resolution uses third_party/rbac-config and does not read $HOME.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/.cursor/skills/kessel-trace/scripts/resolve-relation.sh"
PARSE="$ROOT/.cursor/skills/kessel-trace/scripts/parse-log.sh"
FIXTURE="$ROOT/tests/fixtures/check-error.log"

EMPTY_HOME="$(mktemp -d)"
OVERRIDE=""
cleanup() { rm -rf "$EMPTY_HOME" "${OVERRIDE:-}"; }
trap cleanup EXIT

if [[ ! -d "$ROOT/third_party/rbac-config/configs/prod/schemas/src" ]]; then
    echo "missing third_party/rbac-config; run: git submodule update --init" >&2
    exit 1
fi

resolved="$(env -u RBAC_CONFIG_DIR HOME="$EMPTY_HOME" bash "$SCRIPT" notifications_notifications_edit prod)"
printf '%s\n' "$resolved" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["v2_relation"] == "notifications_notifications_edit", data
assert data["v1_permission"] == "notifications:notifications:write", data
assert data["ksl_file"] == "configs/prod/schemas/src/notifications.ksl", data
assert data["type"] == "v1_based", data
'

parsed="$(env -u RBAC_CONFIG_DIR HOME="$EMPTY_HOME" bash "$PARSE" "$(cat "$FIXTURE")")"
printf '%s\n' "$parsed" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["relation"] == "notifications_notifications_edit", data
assert data["code"] == 403, data
assert data["reason"] == "PermissionDenied", data
'

# A valid RBAC_CONFIG_DIR wins over third_party/rbac-config and does not fall through to GitHub.
OVERRIDE="$(mktemp -d)"
mkdir -p "$OVERRIDE/configs/prod/schemas/src"
cat > "$OVERRIDE/configs/prod/schemas/src/custom.ksl" << 'EOF'
@rbac.add_v1_based_permission(app:'custom', resource:'thing', verb:'read', v2_perm:'custom_thing_view');
EOF

overridden="$(env RBAC_CONFIG_DIR="$OVERRIDE" HOME="$EMPTY_HOME" bash "$SCRIPT" custom_thing_view prod)"
printf '%s\n' "$overridden" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["v1_permission"] == "custom:thing:read", data
assert data["ksl_file"] == "configs/prod/schemas/src/custom.ksl", data
'

FAKE_BIN="$(mktemp -d)"
cat > "$FAKE_BIN/curl" << 'EOF'
#!/bin/sh
echo "curl should not run when RBAC_CONFIG_DIR is set" >&2
exit 99
EOF
chmod +x "$FAKE_BIN/curl"

set +e
miss="$(PATH="$FAKE_BIN:$PATH" env RBAC_CONFIG_DIR="$OVERRIDE" HOME="$EMPTY_HOME" bash "$SCRIPT" notifications_notifications_edit prod 2>"$FAKE_BIN/err")"
miss_status=$?
set -e
if [[ "$miss_status" -eq 0 ]]; then
    echo "expected local miss to fail when RBAC_CONFIG_DIR is set" >&2
    exit 1
fi
if [[ -s "$FAKE_BIN/err" ]]; then
    cat "$FAKE_BIN/err" >&2
    exit 1
fi
printf '%s\n' "$miss" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data.get("error") == "relation not found", data
'
rm -rf "$FAKE_BIN"

echo "ok"
