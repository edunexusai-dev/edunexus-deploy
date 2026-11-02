#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Keycloak Realm Export — run on the developer's Mac (not on the server).
#
# Exports the edunexusai-feddrick realm (clients, roles, users, credentials)
# from the local Keycloak container into files ready for production import.
#
# Prerequisites:
#   - The local Keycloak container is running (or keycloak-local-snapshot image exists)
#   - docker CLI is available
#
# What this does (read-only — does NOT modify the running Keycloak):
#   1. Runs a SECOND container from the keycloak-local-snapshot image
#   2. Exports the realm to JSON files
#   3. Copies export files to deploy/keycloak-import/
#   4. Scrubs the bootstrap admin password from the export
#
# After export, review the files and commit them (secrets are scrubbed; client
# secrets are re-generated in production anyway).
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
IMPORT_DIR="$DEPLOY_DIR/keycloak-import"
EXPORT_CONTAINER="kc-export-temp"
REALM="edunexusai-feddrick"

echo "=== Keycloak Realm Export ==="
echo "Target directory: $IMPORT_DIR"
echo ""

# Check for the snapshot image
if ! docker image inspect keycloak-local-snapshot >/dev/null 2>&1; then
  echo "ERROR: keycloak-local-snapshot image not found."
  echo "Create it first:  docker commit <running-keycloak-container-id> keycloak-local-snapshot"
  exit 1
fi

# Clean up any previous export container
docker rm -f "$EXPORT_CONTAINER" 2>/dev/null || true

echo "Starting temporary export container..."
docker run -d \
  --name "$EXPORT_CONTAINER" \
  --entrypoint /bin/bash \
  keycloak-local-snapshot \
  -c "sleep 300"

echo "Running realm export (this may take 30-60 seconds)..."
docker exec "$EXPORT_CONTAINER" \
  /opt/keycloak/bin/kc.sh export \
  --dir /tmp/kc-export \
  --realm "$REALM" \
  --users realm_file

echo "Copying export files..."
mkdir -p "$IMPORT_DIR"
docker cp "$EXPORT_CONTAINER":/tmp/kc-export/. "$IMPORT_DIR/"

echo "Cleaning up temporary container..."
docker rm -f "$EXPORT_CONTAINER" >/dev/null

# Scrub bootstrap admin credentials from the master realm export (if present)
if [ -f "$IMPORT_DIR/master-realm.json" ]; then
  echo "Removing master realm export (not needed for import)..."
  rm -f "$IMPORT_DIR/master-realm.json"
  rm -f "$IMPORT_DIR/master-users-0.json"
fi

# Scrub client secrets from the realm export — they will be regenerated in production
REALM_FILE="$IMPORT_DIR/${REALM}-realm.json"
if [ -f "$REALM_FILE" ]; then
  echo "Scrubbing client secrets from realm export..."
  python3 -c "
import json, sys
with open('$REALM_FILE') as f:
    data = json.load(f)
for client in data.get('clients', []):
    if client.get('secret'):
        client['secret'] = '**REGENERATE_IN_PRODUCTION**'
with open('$REALM_FILE', 'w') as f:
    json.dump(data, f, indent=2)
print('  Scrubbed secrets from', len([c for c in data.get('clients',[]) if c.get('secret')=='**REGENERATE_IN_PRODUCTION**']), 'clients')
"
fi

echo ""
echo "=== Export complete ==="
echo "Files in $IMPORT_DIR:"
ls -la "$IMPORT_DIR/"
echo ""
echo "Next steps:"
echo "  1. Review the exported JSON files"
echo "  2. The realm file contains users with hashed passwords (bcrypt) — safe to commit"
echo "  3. Client secrets are scrubbed — regenerate them in Keycloak admin after import"
echo "  4. Copy keycloak-import/ to the EC2 instance alongside docker-compose.yml"
