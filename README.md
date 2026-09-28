# kessel-trace

Diagnose inventory-api Check errors from stage and prod logs. KSL schemas and inventory-api source are git submodules, so the tool does not depend on a home-directory layout.

`project-kessel/relations-api` is deprecated and is not included. The `relation` field on a Check log line is still the permission name on the request.

## Clone

```bash
git clone --recurse-submodules git@github.com:Adam0Brien/kessel-trace.git
```

If the repo is already cloned without submodules:

```bash
git submodule update --init
```

Move the pinned commits onto each upstream default branch only when you mean to:

```bash
git submodule update --remote
```

## Layout

- `third_party/rbac-config` — KSL schemas and role JSON
- `third_party/inventory-api` — inventory-api source
- `.cursor/skills/kessel-trace` — diagnosis skill and scripts

Overrides, when you already have a checkout elsewhere:

- `RBAC_CONFIG_DIR` — used instead of `third_party/rbac-config`
- `INVENTORY_API_DIR` — used instead of `third_party/inventory-api`

Scripts find the submodule by walking up from their own directory to `.gitmodules`. They do not search `$HOME`.

## Try it

Requires `bash` and `python3`. `kubectl` is only needed for live log fetch.

```bash
bash .cursor/skills/kessel-trace/scripts/resolve-relation.sh notifications_notifications_edit prod
```

```bash
bash .cursor/skills/kessel-trace/scripts/parse-log.sh "$(cat tests/fixtures/check-error.log)"
```

```bash
bash tests/test_portable_paths.sh
```

## Live logs

```bash
bash .cursor/skills/kessel-trace/scripts/fetch-check-errors.sh -n kessel -d inventory-api
```

`-n`, `-d`, and `-c` select the cluster. The defaults are the inventory-api deployment name and namespace, not a path on your machine.
