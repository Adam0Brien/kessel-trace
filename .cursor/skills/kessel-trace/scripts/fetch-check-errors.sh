#!/usr/bin/env bash
# fetch-check-errors.sh -- Fetch inventory-api K8s logs and filter for check operation errors.
#
# Usage:
#   bash fetch-check-errors.sh [OPTIONS]
#
# Options:
#   -n, --namespace   NAMESPACE   K8s namespace (default: kessel)
#   -d, --deployment  NAME        Deployment name (default: inventory-api)
#   -l, --label       SELECTOR    Label selector (overrides --deployment)
#   -s, --since       DURATION    Show logs since duration (default: 15m)
#   -t, --tail        LINES       Number of lines from end (default: 500)
#   -c, --context     CONTEXT     Kubeconfig context to use
#   -r, --raw                     Output raw log lines instead of parsed JSON
#   -h, --help                    Show this help message
#
# Requires: kubectl, python3
# Outputs: JSON array of parsed check errors (or raw lines with --raw)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="kessel"
DEPLOYMENT="inventory-api"
LABEL_SELECTOR=""
SINCE="15m"
TAIL=500
CONTEXT=""
RAW=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
        -d|--deployment) DEPLOYMENT="$2"; shift 2 ;;
        -l|--label)      LABEL_SELECTOR="$2"; shift 2 ;;
        -s|--since)      SINCE="$2"; shift 2 ;;
        -t|--tail)       TAIL="$2"; shift 2 ;;
        -c|--context)    CONTEXT="$2"; shift 2 ;;
        -r|--raw)        RAW=true; shift ;;
        -h|--help)
            head -n 15 "$0" | tail -n +2 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

KUBECTL_ARGS=(logs "deployment/${DEPLOYMENT}" -n "$NAMESPACE" --tail="$TAIL" --since="$SINCE")

if [[ -n "$LABEL_SELECTOR" ]]; then
    KUBECTL_ARGS=(logs -l "$LABEL_SELECTOR" -n "$NAMESPACE" --tail="$TAIL" --since="$SINCE")
fi

if [[ -n "$CONTEXT" ]]; then
    KUBECTL_ARGS+=(--context "$CONTEXT")
fi

CHECK_PATTERN='KesselInventoryService/(Check|CheckSelf|CheckForUpdate|CheckBulk|CheckSelfBulk|CheckForUpdateBulk)'

if $RAW; then
    kubectl "${KUBECTL_ARGS[@]}" 2>/dev/null | grep -E "$CHECK_PATTERN" | grep -E '(ERROR|code=[1-9])' || true
    exit 0
fi

LINES=$(kubectl "${KUBECTL_ARGS[@]}" 2>/dev/null | grep -E "$CHECK_PATTERN" | grep -E '(ERROR|code=[1-9])' || true)

if [[ -z "$LINES" ]]; then
    echo '[]'
    exit 0
fi

echo '['
FIRST=true
while IFS= read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    if $FIRST; then
        FIRST=false
    else
        echo ','
    fi
    bash "$SCRIPT_DIR/parse-log.sh" "$line"
done <<< "$LINES"
echo ']'
