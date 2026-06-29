#!/usr/bin/env bash
# parse-log.sh -- Parse a Kratos-style structured log line into JSON.
#
# Usage:
#   echo '<LOG_LINE>' | bash parse-log.sh
#   bash parse-log.sh '<LOG_LINE>'
#
# Handles the tricky proto-text args format by tracking brace depth.
# Outputs a single JSON object to stdout.

set -euo pipefail

if [[ $# -ge 1 ]]; then
    LINE="$1"
else
    IFS= read -r LINE
fi

if [[ -z "${LINE:-}" ]]; then
    echo '{}' 
    exit 0
fi

# Use Python for reliable parsing of the complex key=value format with nested
# proto-text braces and quoted strings. Bash alone can't handle the brace-depth
# tracking reliably across all edge cases.
python3 -c '
import json, sys, re

line = sys.argv[1]

# Extract leading level
level = ""
for lvl in ("ERROR", "WARN", "INFO", "DEBUG"):
    if line.startswith(lvl + " ") or line.startswith(lvl + "\t"):
        level = lvl
        line = line[len(lvl):].lstrip()
        break

def tokenize_kv(s):
    """Tokenize key=value pairs, handling nested braces and quoted strings."""
    pairs = []
    i = 0
    n = len(s)
    while i < n:
        # Skip whitespace
        while i < n and s[i] in (" ", "\t"):
            i += 1
        if i >= n:
            break

        # Find = separator
        eq_idx = -1
        j = i
        while j < n and s[j] not in ("=", " ", "\t"):
            j += 1
        if j >= n or s[j] != "=":
            # No = found, skip token
            while i < n and s[i] not in (" ", "\t"):
                i += 1
            continue

        eq_idx = j
        key = s[i:eq_idx]
        i = eq_idx + 1

        # Extract value
        val, i = extract_value(s, i)
        pairs.append((key, val))
    return pairs


def is_proto_field(s, j):
    """Check if position j starts a proto-text field (word: not word=)."""
    n = len(s)
    k = j
    while k < n and s[k] not in (":", "=", " ", "\t"):
        k += 1
    if k >= n or k == j:
        return False
    if s[k] == "=":
        return False
    if s[k] != ":":
        return False
    # Not a URL scheme
    if k + 2 < n and s[k+1] == "/" and s[k+2] == "/":
        return False
    return True


def extract_value(s, i):
    """Extract a value starting at position i, handling nested braces."""
    n = len(s)
    if i >= n:
        return "", i
    start = i
    brace_depth = 0

    while i < n:
        ch = s[i]
        if ch == "{":
            brace_depth += 1
            i += 1
        elif ch == "}":
            brace_depth -= 1
            i += 1
            if brace_depth <= 0:
                j = i
                while j < n and s[j] in (" ", "\t"):
                    j += 1
                if j < n and is_proto_field(s, j):
                    i = j
                    continue
                return s[start:i], i
        elif ch == "\"":
            i += 1
            while i < n and s[i] != "\"":
                if s[i] == "\\":
                    i += 1
                i += 1
            if i < n:
                i += 1
        elif ch in (" ", "\t") and brace_depth == 0:
            j = i
            while j < n and s[j] in (" ", "\t"):
                j += 1
            if j < n and is_proto_field(s, j):
                i = j
                continue
            return s[start:i], i
        else:
            i += 1

    return s[start:i], i


pairs = tokenize_kv(line)
kv = {}
for k, v in pairs:
    kv[k] = v

# The "stack" field in Kratos logs contains embedded "key = value" patterns
# (with spaces around =) that the tokenizer truncates. Re-extract it from
# the raw line by finding stack= and reading until the next top-level key=
# (a key without spaces before its =, like "latency=").
raw_line = sys.argv[1]
stack_match = re.search(r"\bstack=", raw_line)
if stack_match:
    stack_start = stack_match.end()
    # Find the last top-level key= after stack (latency= is typically last)
    tail_match = re.search(r"\s+(latency=\S+)\s*$", raw_line[stack_match.start():])
    if tail_match:
        stack_val = raw_line[stack_start:stack_match.start() + tail_match.start()].strip()
        kv["stack"] = stack_val
        kv["latency"] = tail_match.group(1).split("=", 1)[1]
    else:
        kv["stack"] = raw_line[stack_start:].strip()

# Extract operation short name
operation_full = kv.get("operation", "")
operation = operation_full.rsplit("/", 1)[-1] if "/" in operation_full else operation_full

# Parse args for proto-text fields
args = kv.get("args", "")
resource_type = ""
resource_id = ""
reporter_type = ""
relation = ""
subject_type = ""
subject_id = ""

m = re.search(r"resource_type:\"([^\"]*)\"", args)
if m:
    resource_type = m.group(1)
m = re.search(r"resource_id:\"([^\"]*)\"", args)
if m:
    resource_id = m.group(1)
m = re.search(r"reporter:\{[^}]*type:\"([^\"]*)\"", args)
if m:
    reporter_type = m.group(1)
m = re.search(r"(?:^|\s|})relation:\"([^\"]*)\"", args)
if m:
    relation = m.group(1)
m = re.search(r"subject_type:\"([^\"]*)\"", args)
if m:
    subject_type = m.group(1)
m = re.search(r"subject_id:\"([^\"]*)\"", args)
if m:
    subject_id = m.group(1)

# Infer calling service from relation
calling_service = relation.split("_")[0] if relation else ""

# Parse code as int
code = 0
try:
    code = int(kv.get("code", "0"))
except ValueError:
    pass

# Parse latency as float
latency = 0.0
try:
    latency = float(kv.get("latency", "0"))
except ValueError:
    pass

# Extract message from stack if not directly available
message = kv.get("message", "")
stack = kv.get("stack", "")
if not message and stack:
    m_msg = re.search(r"message\s*=\s*(.+?)(?:\s+metadata\s*=|$)", stack)
    if m_msg:
        message = m_msg.group(1).strip()

result = {
    "level": level,
    "timestamp": kv.get("ts", ""),
    "operation": operation,
    "operation_full": operation_full,
    "resource_type": resource_type,
    "resource_id": resource_id,
    "reporter_type": reporter_type,
    "relation": relation,
    "subject_type": subject_type,
    "subject_id": subject_id,
    "code": code,
    "reason": kv.get("reason", ""),
    "message": message,
    "stack": stack,
    "trace_id": kv.get("trace.id", ""),
    "span_id": kv.get("span.id", ""),
    "latency": latency,
    "calling_service": calling_service,
    "service_name": kv.get("service.name", ""),
    "component": kv.get("component", ""),
}

print(json.dumps(result, indent=2))
' "$LINE"
