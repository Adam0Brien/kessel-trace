# Inventory-API Architecture Reference

Concise reference for diagnosing Check/CheckSelf/CheckForUpdate errors.

Source checkout: `third_party/inventory-api` (override with `INVENTORY_API_DIR`).
Upstream: [project-kessel/inventory-api](https://github.com/project-kessel/inventory-api).

`project-kessel/relations-api` is deprecated and is not a submodule. Check evaluation
in this pin goes through inventory-api's relations repository. Prefer `authz.impl: spicedb`.
The check-request `relation` field is still the permission name and is unrelated to that
deprecated service.

---

## gRPC Service API

Service: `kessel.inventory.v1beta2.KesselInventoryService`

### Check operations (authorization)

| RPC | Purpose | Subject |
|-----|---------|---------|
| `Check` | Does subject X have relation Y on object Z? | Explicit (in request) |
| `CheckSelf` | Does the caller have relation Y on object Z? | Implicit (from auth context) |
| `CheckForUpdate` | Same as Check but strongly consistent | Explicit |
| `CheckBulk` | Batch Check for multiple items | Explicit |
| `CheckSelfBulk` | Batch CheckSelf for multiple items | Implicit |
| `CheckForUpdateBulk` | Batch CheckForUpdate for multiple items | Explicit |

### Resource operations (inventory)

| RPC | Purpose |
|-----|---------|
| `ReportResource` | Create or update a resource representation |
| `DeleteResource` | Delete a reporter's representation of a resource |
| `StreamedListObjects` | Stream objects where subject has a relation |
| `StreamedListSubjects` | Stream subjects that have a relation to a resource |

---

## Proto Message Structure

### ResourceReference

```protobuf
message ResourceReference {
  string resource_type = 1;  // e.g. "workspace" -- pattern: ^[A-Za-z0-9_]+$
  string resource_id = 2;    // e.g. UUID -- min_len: 1
  optional ReporterReference reporter = 3;  // e.g. {type: "rbac"}
}
```

### CheckSelfRequest

```protobuf
message CheckSelfRequest {
  ResourceReference object = 1;   // required
  string relation = 2;            // e.g. "notifications_notifications_edit" -- min_len: 1
  optional Consistency consistency = 3;
}
```

### CheckRequest (adds explicit subject)

```protobuf
message CheckRequest {
  ResourceReference object = 1;   // required
  string relation = 2;            // min_len: 1
  SubjectReference subject = 3;   // required (unlike CheckSelf)
  optional Consistency consistency = 4;
}
```

---

## Middleware Chain

Requests flow through this middleware chain before hitting business logic:

```
Request
  -> Authentication (extract identity from token/headers)
  -> Validation (protovalidate: check required fields, patterns, min_len)
  -> Sanitization (remove nulls from struct fields)
  -> Error Mapping (domain errors -> gRPC status codes)
  -> Business Logic (usecase layer)
  -> Relations API / SpiceDB (actual permission check)
```

Key middleware files:
- `internal/middleware/authn.go` -- authentication
- `internal/middleware/validation.go` -- proto validation (returns `VALIDATOR` reason)
- `internal/middleware/sanitize.go` -- null removal (returns `SANITIZER` reason)
- `internal/middleware/error_mapping.go` -- error-to-gRPC-status mapping

---

## Error Mapping (domain -> gRPC)

From `internal/middleware/error_mapping.go`:

| Domain Error | gRPC Code | Status Message |
|-------------|-----------|----------------|
| `ErrMetaAuthzContextMissing` | Unauthenticated | authz context missing |
| `ErrSelfSubjectMissing` | Unauthenticated | self subject missing |
| `ErrMetaAuthorizerUnavailable` | Internal | meta authorizer unavailable |
| `ErrMetaAuthorizationDenied` | PermissionDenied | meta authorization denied |
| `ErrResourceNotFound` | NotFound | resource not found |
| `ErrResourceAlreadyExists` | AlreadyExists | resource already exists |
| `ErrDatabaseError` | Internal | internal error |
| Validation errors (`ErrEmpty`, etc.) | InvalidArgument | specific message |
| `context.Canceled` | Canceled | request canceled |
| `context.DeadlineExceeded` | DeadlineExceeded | request deadline exceeded |

Errors from the `Validation` middleware (protovalidate) are returned as `BadRequest`
with reason `VALIDATOR` *before* reaching the error mapping middleware.

---

## KSL Permission Model

Permissions are defined in KSL files at
`third_party/rbac-config/configs/<env>/schemas/src/<app>.ksl`
(override the checkout with `RBAC_CONFIG_DIR`).

### Two mapping types

**`@rbac.add_v1_based_permission`** -- V2 name differs from V1:
```ksl
@rbac.add_v1_based_permission(
  app:'notifications', resource:'notifications', verb:'write',
  v2_perm:'notifications_notifications_edit'
);
```
- V1: `notifications:notifications:write`
- V2: `notifications_notifications_edit`

**`@rbac.add_unified_permission`** -- V2 name = `app_resource_verb`:
```ksl
@rbac.add_unified_permission(app:'rbac', resource:'roles', verb:'read')
```
- V1: `rbac:roles:read`
- V2: `rbac_roles_read`

### Permission resolution chain

```
relation field on the Check request (permission name)
  -> KSL schema directive in third_party/rbac-config
  -> V1 permission (app:resource:verb)
  -> Role JSON access[].permission (exact or wildcard match)
  -> User's group membership and role bindings
  -> inventory-api RelationsRepository
       authz.impl=spicedb -> SpiceDB CheckPermission (authz.spicedb.endpoint)
       authz.impl=kessel  -> legacy relations-api client (deprecated; do not vendor)
       authz.impl=allow-all -> allow
```

### Wildcard matching in role definitions

Role `access[].permission` values can use wildcards:
- `notifications:*:*` -- all permissions for the notifications app
- `notifications:notifications:*` -- all verbs for notifications:notifications
- `*:*:*` -- all permissions (superadmin)

---

## Supported Resource Types

- `workspace` -- RBAC workspace (hierarchy root for permission checks)
- `rhel_host` -- RHEL host inventory
- `notifications_integration` -- notifications/integrations service
- `k8s_cluster` -- Kubernetes cluster
- `k8s_policy` -- Kubernetes policy

---

## Key Source Paths

Paths are relative to `third_party/inventory-api` (or `INVENTORY_API_DIR`).

| Path | Purpose |
|------|---------|
| `api/kessel/inventory/v1beta2/` | Proto definitions and generated Go code |
| `internal/middleware/error_mapping.go` | Maps domain errors to gRPC status codes |
| `internal/biz/model/errors.go` | Sentinel domain errors |
| `internal/biz/usecase/resources/` | Business logic including auth errors |
| `internal/biz/usecase/metaauthorizer/enforcement.go` | `ErrMetaAuthorizerUnavailable` when the authorizer is nil |
| `internal/config/relations/options.go` | `authz.impl`: `allow-all`, `kessel`, or `spicedb` |
| `internal/data/relations_repository_factory.go` | Selects the relations repository from `authz.impl` |
| `internal/data/spicedb_relations_repository.go` | SpiceDB `CheckPermission` client |
| `docs/runbooks/` | Operational runbooks |
| `.inventory-api.yaml` | Default local config (`authz.impl: allow-all`) |
