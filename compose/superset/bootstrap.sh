#!/bin/bash
set -e

echo "Installing dependencies..."
pip install --quiet psycopg2-binary flask-cors

echo "Waiting for PostgreSQL..."
until python -c "
import socket, sys
s = socket.socket()
s.settimeout(5)
sys.exit(0 if s.connect_ex(('${DATABASE_HOST}', int('${DATABASE_PORT}'))) == 0 else 1)
" 2>/dev/null; do
  sleep 2
done

echo "Waiting for Redis..."
until python -c "
import socket, sys
s = socket.socket()
s.settimeout(5)
sys.exit(0 if s.connect_ex(('${REDIS_HOST}', int('${REDIS_PORT}'))) == 0 else 1)
" 2>/dev/null; do
  sleep 2
done

echo "Running database migrations..."
superset db upgrade

echo "Creating admin user (idempotent)..."
superset fab create-admin \
  --username "${ADMIN_USERNAME}" \
  --firstname Admin \
  --lastname User \
  --email "${ADMIN_EMAIL}" \
  --password "${ADMIN_PASSWORD}" || true

echo "Initializing Superset roles and permissions..."
superset init

echo "Bootstrap complete"
