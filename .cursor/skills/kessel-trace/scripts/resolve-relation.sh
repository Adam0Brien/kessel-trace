#!/usr/bin/env bash
# resolve-relation.sh -- Resolve a V2 relation name to its V1 permission via KSL schema parsing.
#
# Usage:
#   bash resolve-relation.sh <RELATION> [prod|stage]
#
# Examples:
#   bash resolve-relation.sh notifications_notifications_edit
#   bash resolve-relation.sh rbac_roles_read stage
#
# Resolution strategy:
#   1. If RBAC_CONFIG_DIR is set or ~/rbac-config exists, parse KSL files locally.
#   2. Otherwise, fetch KSL files from GitHub raw content.
#
# Outputs: JSON object with v2_relation, v1_permission, app, resource, verb, ksl_file, type.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <RELATION> [prod|stage]" >&2
    exit 1
fi

RELATION="$1"
ENV="${2:-prod}"

# Infer the app namespace from the relation name.
# For add_v1_based_permission: the v2_perm can be anything, so we scan all KSL files.
# For add_unified_permission: the pattern is app_resource_verb, so the first segment is the app.
INFERRED_APP="${RELATION%%_*}"

RBAC_CONFIG_DIR="${RBAC_CONFIG_DIR:-}"
if [[ -z "$RBAC_CONFIG_DIR" ]]; then
    for candidate in "$HOME/rbac-config" "$HOME/projects/rbac-config" "$HOME/projects/infra/rbac-config"; do
        if [[ -d "$candidate/configs/$ENV/schemas/src" ]]; then
            RBAC_CONFIG_DIR="$candidate"
            break
        fi
    done
fi

resolve_from_local() {
    local ksl_dir="$RBAC_CONFIG_DIR/configs/$ENV/schemas/src"
    
    if [[ ! -d "$ksl_dir" ]]; then
        return 1
    fi

    python3 -c '
import json, re, sys, os

relation = sys.argv[1]
ksl_dir = sys.argv[2]
env = sys.argv[3]

v1_based_re = re.compile(
    r"@(?:rbac\.)?add_v1_based_permission\(\s*"
    r"app:\s*'\''([^'\'']+)'\''\s*,\s*"
    r"resource:\s*'\''([^'\'']+)'\''\s*,\s*"
    r"verb:\s*'\''([^'\'']+)'\''\s*,\s*"
    r"v2_perm:\s*'\''([^'\'']+)'\''"
)

unified_re = re.compile(
    r"@(?:rbac\.)?add_unified_permission\(\s*"
    r"app:\s*'\''([^'\'']+)'\''\s*,\s*"
    r"resource:\s*'\''([^'\'']+)'\''\s*,\s*"
    r"verb:\s*'\''([^'\'']+)'\''"
)

for fname in sorted(os.listdir(ksl_dir)):
    if not fname.endswith(".ksl"):
        continue
    fpath = os.path.join(ksl_dir, fname)
    content = open(fpath).read()
    
    for m in v1_based_re.finditer(content):
        app, resource, verb, v2_perm = m.groups()
        if v2_perm == relation:
            print(json.dumps({
                "v2_relation": relation,
                "v1_permission": f"{app}:{resource}:{verb}",
                "app": app,
                "resource": resource,
                "verb": verb,
                "ksl_file": f"configs/{env}/schemas/src/{fname}",
                "type": "v1_based"
            }, indent=2))
            sys.exit(0)
    
    for m in unified_re.finditer(content):
        app, resource, verb = m.groups()
        unified_v2 = f"{app}_{resource}_{verb}"
        if unified_v2 == relation:
            print(json.dumps({
                "v2_relation": relation,
                "v1_permission": f"{app}:{resource}:{verb}",
                "app": app,
                "resource": resource,
                "verb": verb,
                "ksl_file": f"configs/{env}/schemas/src/{fname}",
                "type": "unified"
            }, indent=2))
            sys.exit(0)

print(json.dumps({"error": "relation not found", "v2_relation": relation}))
sys.exit(1)
' "$RELATION" "$ksl_dir" "$ENV"
}

resolve_from_github() {
    local base_url="https://raw.githubusercontent.com/project-kessel/rbac-config/master"
    local ksl_list_url="$base_url/configs/$ENV/schemas/migrated_apps.lst"
    
    local apps
    apps=$(curl -sf "$ksl_list_url" 2>/dev/null || echo "$INFERRED_APP")
    
    for app in $apps; do
        local ksl_url="$base_url/configs/$ENV/schemas/src/${app}.ksl"
        local content
        content=$(curl -sf "$ksl_url" 2>/dev/null || true)
        
        if [[ -z "$content" ]]; then
            continue
        fi
        
        # Pipe KSL content via stdin to avoid single-quote mangling in bash args.
        local result
        result=$(echo "$content" | python3 -c '
import json, re, sys

relation = sys.argv[1]
fname = sys.argv[2]
env = sys.argv[3]
content = sys.stdin.read()

v1_based_re = re.compile(
    r"@(?:rbac\.)?add_v1_based_permission\(\s*"
    r"app:\x27([^\x27]+)\x27\s*,\s*"
    r"resource:\x27([^\x27]+)\x27\s*,\s*"
    r"verb:\x27([^\x27]+)\x27\s*,\s*"
    r"v2_perm:\x27([^\x27]+)\x27"
)

unified_re = re.compile(
    r"@(?:rbac\.)?add_unified_permission\(\s*"
    r"app:\x27([^\x27]+)\x27\s*,\s*"
    r"resource:\x27([^\x27]+)\x27\s*,\s*"
    r"verb:\x27([^\x27]+)\x27"
)

for m in v1_based_re.finditer(content):
    app, resource, verb, v2_perm = m.groups()
    if v2_perm == relation:
        print(json.dumps({
            "v2_relation": relation,
            "v1_permission": f"{app}:{resource}:{verb}",
            "app": app,
            "resource": resource,
            "verb": verb,
            "ksl_file": f"configs/{env}/schemas/src/{fname}.ksl",
            "type": "v1_based"
        }, indent=2))
        sys.exit(0)

for m in unified_re.finditer(content):
    app, resource, verb = m.groups()
    unified_v2 = f"{app}_{resource}_{verb}"
    if unified_v2 == relation:
        print(json.dumps({
            "v2_relation": relation,
            "v1_permission": f"{app}:{resource}:{verb}",
            "app": app,
            "resource": resource,
            "verb": verb,
            "ksl_file": f"configs/{env}/schemas/src/{fname}.ksl",
            "type": "unified"
        }, indent=2))
        sys.exit(0)

sys.exit(1)
' "$RELATION" "$app" "$ENV" 2>/dev/null) && {
            echo "$result"
            exit 0
        }
    done
    
    echo "{\"error\": \"relation not found\", \"v2_relation\": \"$RELATION\"}"
    exit 1
}

if [[ -n "$RBAC_CONFIG_DIR" ]]; then
    resolve_from_local && exit 0
fi

resolve_from_github
