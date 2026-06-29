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
logs, resolving V2 relations to V1 permissions via rbac-config, and producing actionable
root-cause analysis.

## Diagnosis Workflow

Follow these steps in order. Skip steps that don't apply.

### Step 1: Obtain the error

**If the user pasted a log line**, proceed to Step 2.

**If the user asks to check live logs**, fetch them with the Kubernetes MCP:

```
CallMcpTool: user-kubernetes / kubectl_logs
  resourceType: "deployment"
  name: "inventory-api"          # adjust if user specifies different name
  namespace: <ask user or use "kessel">
  tail: 200
  since: "15m"
```

Then filter the output for lines containing `Check` operations (Check, CheckSelf,
CheckForUpdate, CheckBulk, CheckSelfBulk, CheckForUpdateBulk) that have `ERROR` level
or non-zero error codes.

### Step 2: Parse the log line

Run the parser script on the log line to extract structured fields:

```bash
echo '<LOG_LINE>' | bash .cursor/skills/kessel-trace/scripts/parse-log.sh
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

If the log contains a `relation` field, resolve it to the V1 permission and granting roles:

```bash
bash .cursor/skills/kessel-trace/scripts/resolve-relation.sh <RELATION> [prod|stage]
```

This outputs JSON with: `v2_relation`, `v1_permission`, `app`, `resource`, `verb`,
`ksl_file`, `type`.

If the script can't resolve it (no local rbac-config clone), fall back to the GitHub MCP:

1. Fetch the KSL file for the app (first segment of the relation before `_`):
   ```
   CallMcpTool: user-github / get_file_contents
     owner: "project-kessel"
     repo: "rbac-config"
     path: "configs/prod/schemas/src/<APP>.ksl"
   ```
2. Search for `v2_perm:'<RELATION>'` in the output to find the `add_v1_based_permission`
   directive and extract `app`, `resource`, `verb`.
3. Fetch the roles file to find which roles grant that permission:
   ```
   CallMcpTool: user-github / get_file_contents
     owner: "project-kessel"
     repo: "rbac-config"
     path: "configs/prod/roles/<APP>.json"
   ```
4. Scan `access[].permission` for matches (exact or wildcard `app:*:*`, `app:resource:*`).

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
- "Look up the calling service's source code for how it constructs this request?"
- "Fetch more recent logs to see if this error is recurring?"
- "Check which roles/groups the affected user has?"

## Key Knowledge

### Relation naming conventions

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
