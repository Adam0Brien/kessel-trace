# Inventory-API Error Pattern Catalog

Known error patterns for Check/CheckSelf/CheckForUpdate operations. Each entry
includes the log signature, root cause, investigation steps, and common fixes.

Source: inventory-api [error-handling-guidelines](https://github.com/project-kessel/inventory-api/blob/main/docs/error-handling-guidelines.md), [validation middleware](https://github.com/project-kessel/inventory-api/blob/main/internal/middleware/validation.go), and [error mapping middleware](https://github.com/project-kessel/inventory-api/blob/main/internal/middleware/error_mapping.go).

---

## Validation Errors (code=400)

### Missing resource_id

**Signature**: `code=400 reason=VALIDATOR message=validation error: object.resource_id: must be at least 1 characters`

**Root cause**: The calling service sent a Check/CheckSelf request without populating
`object.resource_id`. The `ResourceReference` proto requires `resource_id` to have `min_len = 1`.

**Investigation**:
1. Identify the calling service from the `relation` field (first segment before `_`).
2. Check the caller's code where it constructs the `CheckSelfRequest` or `CheckRequest`.
3. The resource ID (typically a workspace or resource UUID) is missing or empty.

**Common fixes**:
- The caller must include the workspace/resource ID it wants to check permissions against.
- This is always a client-side bug -- the inventory-api validation is correct.

---

### Missing resource_type

**Signature**: `code=400 reason=VALIDATOR message=validation error: object.resource_type: must be at least 1 characters`

**Root cause**: The `resource_type` field in the `ResourceReference` is empty. Valid types
include `workspace`, `rhel_host`, `notifications_integration`, `k8s_cluster`, etc.

**Investigation**:
1. Check caller's request construction code.
2. Verify the caller is using the correct proto field name.

**Common fixes**:
- Populate `resource_type` with the correct type (e.g. `"workspace"`).

---

### Invalid resource_type pattern

**Signature**: `code=400 reason=VALIDATOR message=validation error: object.resource_type: must match pattern "^[A-Za-z0-9_]+$"`

**Root cause**: The resource_type contains invalid characters (spaces, hyphens, dots, etc.).
Only alphanumeric and underscore characters are allowed.

**Investigation**:
1. Check what value the caller is sending for `resource_type`.
2. Common mistake: using `rhel-host` instead of `rhel_host`.

**Common fixes**:
- Use underscores, not hyphens, in resource_type names.

---

### Missing relation

**Signature**: `code=400 reason=VALIDATOR message=validation error: relation: must be at least 1 characters`

**Root cause**: The `relation` field in the CheckRequest is empty. This field specifies which
permission to check (e.g. `notifications_notifications_edit`).

**Investigation**:
1. The caller's permission mapping is broken or the relation constant is not set.

**Common fixes**:
- Ensure the caller passes the correct V2 relation name.
- Look up the relation in the KSL schema: `configs/prod/schemas/src/<app>.ksl`.

---

### Missing subject (Check only, not CheckSelf)

**Signature**: `code=400 reason=VALIDATOR message=validation error: subject: value is required`

**Root cause**: A `Check` request (not `CheckSelf`) was made without a `SubjectReference`.
The `Check` endpoint requires an explicit subject; use `CheckSelf` for implicit caller identity.

**Investigation**:
1. Determine if the caller should be using `CheckSelf` instead of `Check`.
2. If using `Check`, verify the `subject` field is populated.

**Common fixes**:
- Switch to `CheckSelf` if the caller is checking its own permissions.
- Otherwise, populate `subject` with `subject_type` and `subject_id`.

---

## Authentication Errors (code=401)

### Missing authz context

**Signature**: `code=401` with `ErrMetaAuthzContextMissing` in logs

**Root cause**: The request arrived without an authorization context. The authentication
middleware could not extract identity from the request headers or token.

**Investigation**:
1. Check if the caller is sending an `Authorization` header with a valid token.
2. Verify the inventory-api's authn configuration (`authn.impl` in config).
3. If running locally with `allow-unauthenticated`, the user-agent becomes the identity.

**Common fixes**:
- Ensure the caller includes a valid bearer token.
- Check if the token has expired.
- Verify the SSO token endpoint is reachable.

---

### Missing self subject

**Signature**: `code=401` with `ErrSelfSubjectMissing` in logs

**Root cause**: A `CheckSelf` request was made but the middleware could not derive the
caller's identity from the authentication context.

**Investigation**:
1. The authn middleware extracts the subject from the token/headers.
2. If this fails, the `self` subject cannot be populated.
3. Check the identity header chain (`x-rh-identity`, JWT claims, etc.).

**Common fixes**:
- Ensure proper identity headers are forwarded through the gateway.
- Verify the PSK or JWT token contains a valid subject.

---

## Permission Errors (code=403)

### Meta authorization denied

**Signature**: `code=403` with `ErrMetaAuthorizationDenied` or `reason=PermissionDenied`

**Root cause**: The user/subject does not have the requested relation on the target resource.
The SpiceDB/Relations API returned "not permitted".

**Investigation**:
1. Use `resolve-relation.sh` to find the V1 permission and granting roles.
2. Check if the user's org has the correct roles assigned via RBAC groups.
3. For `platform_default` roles, verify the default group is configured.
4. For `admin_default` roles, verify the user is an org admin.
5. Check if the resource's relationships are correctly configured in SpiceDB.

**Common fixes**:
- Assign the user to a group with the appropriate role.
- Verify the resource was reported to inventory (relations exist in SpiceDB).
- Check if the workspace hierarchy is correct (parent workspace chain).
- For new permissions, ensure the rbac-config role version was bumped and deployed.

---

### Meta authorizer unavailable

**Signature**: `code=500` with `ErrMetaAuthorizerUnavailable`

**Root cause**: Inventory-api could not reach the Relations API (SpiceDB) to perform the
authorization check. This is an infrastructure issue, not a permissions issue.

**Investigation**:
1. Check Relations API pod health in the same namespace.
2. Check network connectivity between inventory-api and relations-api.
3. Look for connection timeout or DNS resolution errors in logs.

**Common fixes**:
- Restart the Relations API pods if they're unhealthy.
- Check if a deployment is in progress that might have caused a brief outage.
- Verify the `authz.kessel.url` configuration points to the correct service.

---

## Internal Errors (code=500)

### Database error

**Signature**: `code=500` with `ErrDatabaseError` in mapped error

**Root cause**: A database operation failed during the check flow. Typically a PostgreSQL
connection or query issue.

**Investigation**:
1. Check PostgreSQL pod health and connection pool metrics.
2. Look for serialization failures (error code 40001) which are auto-retried.
3. Check for connection exhaustion under high load.

**Common fixes**:
- Scale up DB connection pool if under contention.
- Check for long-running transactions blocking the pool.

---

## Consumer Errors (background processing)

### Kafka offset out of range

**Signature**: `Broker: Offset out of range` in consumer logs

**Root cause**: The consumer's stored offset points to a message that was deleted by
Kafka's retention policy.

**Investigation and fix**: See the inventory-api [consumer errors runbook](https://github.com/project-kessel/inventory-api/blob/main/docs/runbooks/general-consumer-errors.md).

Reset with:
```bash
./bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVERS \
  --command-config $KAFKA_AUTH_CONFIG --group inventory-consumer \
  --reset-offsets --to-latest --execute --topic outbox.event.kessel.tuples
```
