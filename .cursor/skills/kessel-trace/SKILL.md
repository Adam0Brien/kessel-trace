---
name: kessel-trace
description: >-
  Diagnose inventory-api Check/CheckSelf/CheckForUpdate errors from production logs.
  Cross-references rbac-config KSL schemas, permissions, and roles to produce enriched
  root-cause analysis. Use when the user pastes an inventory-api error log, asks to check
  inventory-api logs, mentions kessel-trace, or asks about permission check failures.
disable-model-invocation: true
---

# kessel-trace: Inventory-API Error Diagnosis

Diagnose `project-kessel/inventory-api` authorization check errors by parsing structured
logs, resolving the check-request `relation` field to a V1 permission via rbac-config, and
producing actionable root-cause analysis.

Scripts live in `scripts/` next to this file. Call them by that directory, not by a
workspace-root path and not by anything under `$HOME`. Upstream source is vendored in
this repo:

- `third_party/rbac-config` — KSL schemas and role JSON. Override with `RBAC_CONFIG_DIR`.
- `third_party/inventory-api` — inventory-api source. Override with `INVENTORY_API_DIR`.

`relations-api` is deprecated and is not vendored. The `relation` field on a Check log
line is the permission name on the request. Keep parsing it.

## Diagnosis Workflow

Follow these steps in order. Skip steps that don't apply.

### Step 1: Obtain the error

**If the user pasted a log line**, proceed to Step 2.

**If the user asks to check live logs**, run the fetch script next to this skill:

```bash
SKILL_DIR="<directory containing this SKILL.md>"
bash "$SKILL_DIR/scripts/fetch-check-errors.sh"
```

Flags: `-n` namespace (default `kessel`), `-d` deployment (default `inventory-api`),
`-c` kube context, `-s` since, `-t` tail. Those defaults are service names, not a
machine path.

A Kubernetes logs MCP tool is optional when one is connected. Do not require a
particular MCP server id.

Then filter for Check operations (Check, CheckSelf, CheckForUpdate, CheckBulk,
CheckSelfBulk, CheckForUpdateBulk) at `ERROR` level or with a non-zero error code.
`fetch-check-errors.sh` already applies that filter.

### Step 2: Parse the log line

```bash
SKILL_DIR="<directory containing this SKILL.md>"
echo '<LOG_LINE>' | bash "$SKILL_DIR/scripts/parse-log.sh"
```

This outputs JSON with: `level`, `timestamp`, `operation`, `resource_type`, `resource_id`,
`reporter_type`, `relation`, `code`, `reason`, `message`, `trace_id`, `span_id`,
`latency`, `calling_service`.

### Step 3: Classify the error

Use the `code` and `reason` fields:

| code | reason | Category |
|------|--------|----------|
| 400 | VALIDATOR | Validation error -- caller sent malformed request |
| 400 | SANITIZER | Sanitization error -- null values in representations |
| 401 | Unauthenticated | Auth context missing or invalid token |
| 403 | PermissionDenied | User lacks the required relation/permission |
| 500 | Internal | Server-side failure (DB, authorizer unavailable) |

Read [reference/error-patterns.md](reference/error-patterns.md) for the full pattern catalog
with root causes and fixes for each.

### Step 4: Resolve the permission context

If the log contains a `relation` field, resolve it to the V1 permission and granting roles.
The script reads `third_party/rbac-config` (or `RBAC_CONFIG_DIR`) and does not search `$HOME`.

```bash
SKILL_DIR="<directory containing this SKILL.md>"
bash "$SKILL_DIR/scripts/resolve-relation.sh" <RELATION> [prod|stage]
```

This outputs JSON with: `v2_relation`, `v1_permission`, `app`, `resource`, `verb`,
`ksl_file`, `type`.

Role JSON for that app is `third_party/rbac-config/configs/<env>/roles/<APP>.json`.
Scan `access[].permission` for matches (exact or wildcard `app:*:*`, `app:resource:*`).

If the submodule was not checked out, the script falls back to GitHub raw content.
A GitHub file-contents MCP tool is an optional extra in that case. Do not require a
particular MCP server id. Prefer initializing submodules (`git submodule update --init`)
so resolution stays local.

### Step 5: Produce the diagnosis

Present a structured diagnosis using this template:

```
--- <Operation> Error ------------------------------------------
  Timestamp:    <timestamp>
  Operation:    <operation short name>
  Status:       <code> (<reason>)
  Latency:      <human-readable latency>
  Trace ID:     <trace_id or "(none)">

  Request:
    resource_type:  <resource_type>
    resource_id:    <resource_id or "(empty) <-- MISSING">
    reporter:       <reporter_type>
    relation:       <relation>

  Root Cause:
    <1-2 sentence explanation of what went wrong>
    <Why the calling service triggered this error>

  Permission Context:            (only for check operations with a relation)
    V2 Relation:    <relation>
    V1 Permission:  <app:resource:verb>
    KSL Source:     <ksl_file>
    Granted by:
      - <role name> (<flags like admin_default, platform_default>)

  Suggestions:
    1. <Most likely fix>
    2. <Investigation step>
    3. <Contextual advice>
---------------------------------------------------------------
```

### Step 6: Offer follow-up actions

After presenting the diagnosis, offer:
- "Look up how inventory-api handles this in `third_party/inventory-api` (or `$INVENTORY_API_DIR`)?"
- "Fetch more recent logs to see if this error is recurring?"
- "Check which roles/groups the affected user has?"

## Key Knowledge

### Relation naming conventions

The check-request `relation` string is still the permission name. It is not the
deprecated relations-api service.

- `add_v1_based_permission`: V2 name differs from V1. Pattern: `v2_perm:'<custom_name>'`.
  Example: `notifications_notifications_edit` maps to `notifications:notifications:write`.
- `add_unified_permission`: V2 name = `app_resource_verb` (same as V1 but with underscores).
  Example: `rbac_roles_read` maps to `rbac:roles:read`.

### Wildcard matching in roles

Role `access[].permission` can use wildcards:
- `app:*:*` grants all permissions for that app
- `app:resource:*` grants all verbs for that resource
- `*:*:*` grants everything (superadmin)

### Common calling services

The first segment of a relation name (before the first `_`) usually identifies the app:
- `notifications_*` -> notifications service
- `integrations_*` -> integrations service
- `rbac_*` -> RBAC service itself
- `inventory_*` -> inventory/HBI service

## Additional Resources

- For the full error pattern catalog: [reference/error-patterns.md](reference/error-patterns.md)
- For inventory-api architecture details: [reference/inventory-api-architecture.md](reference/inventory-api-architecture.md)
- Vendored source: `third_party/inventory-api` and `third_party/rbac-config` at the repo root
