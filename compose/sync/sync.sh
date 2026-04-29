#!/bin/sh
set -e

# install curl and jq if not present (postgres:17-alpine)
command -v curl >/dev/null 2>&1 || apk add --no-cache curl jq >/dev/null 2>&1

GITHUB_RAW="https://raw.githubusercontent.com/EVERSE-ResearchSoftware/indicators/main"
GITHUB_API="https://api.github.com/repos/EVERSE-ResearchSoftware/indicators/contents"
WORKDIR="/tmp/sync"

mkdir -p "$WORKDIR/dimensions" "$WORKDIR/indicators"

echo "Fetching dimensions..."
for dim in $(curl -sf "$GITHUB_API/dimensions" | jq -r '.[].name | select(endswith(".json"))'); do
  curl -sfL "$GITHUB_RAW/dimensions/$dim" -o "$WORKDIR/dimensions/$dim"
done

echo "Fetching indicators..."
for ind in $(curl -sf "$GITHUB_API/indicators" | jq -r '.[].name | select(endswith(".json"))'); do
  curl -sfL "$GITHUB_RAW/indicators/$ind" -o "$WORKDIR/indicators/$ind"
done

echo "Generating SQL..."
cat > "$WORKDIR/import.sql" <<'EOSQL'
SET search_path TO api, public;
EOSQL

for f in "$WORKDIR"/dimensions/*.json; do
  abbrev=$(jq -r '.abbreviation // empty' "$f")
  name=$(jq -r '.name // empty' "$f")
  desc=$(jq -r '.description // empty' "$f" | sed "s/'/''/g")
  source=$(jq -c '.source // {}' "$f")

  if [ -n "$abbrev" ] && [ -n "$name" ]; then
    cat >> "$WORKDIR/import.sql" <<EOSQL
INSERT INTO dimensions (identifier, name, description, status, source)
VALUES ('$abbrev', '$name', '$desc', 'Active', '$source'::jsonb)
ON CONFLICT (identifier) DO UPDATE SET
  name = EXCLUDED.name, description = EXCLUDED.description,
  source = EXCLUDED.source, updated_at = CURRENT_TIMESTAMP;
EOSQL
  fi
done

for f in "$WORKDIR"/indicators/*.json; do
  abbrev=$(jq -r '.abbreviation // empty' "$f")
  name=$(jq -r '.name // empty' "$f")
  desc=$(jq -r '.description // empty' "$f" | sed "s/'/''/g")
  status=$(jq -r '.status // "Active"' "$f")
  dim=$(jq -r '.qualityDimension // empty' "$f")
  contact=$(jq -c '.contact // .contactPoint // {}' "$f")
  source=$(jq -c '.source // {}' "$f")

  if [ -n "$abbrev" ] && [ -n "$name" ]; then
    cat >> "$WORKDIR/import.sql" <<EOSQL
INSERT INTO indicators (identifier, name, description, status, quality_dimension, contact, source)
VALUES ('$abbrev', '$name', '$desc', '$status', '$dim', '$contact'::jsonb, '$source'::jsonb)
ON CONFLICT (identifier) DO UPDATE SET
  name = EXCLUDED.name, description = EXCLUDED.description, status = EXCLUDED.status,
  quality_dimension = EXCLUDED.quality_dimension, contact = EXCLUDED.contact,
  source = EXCLUDED.source, updated_at = CURRENT_TIMESTAMP;
EOSQL
  fi
done

echo "Importing to database..."
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -f "$WORKDIR/import.sql"

echo "Sync complete"
