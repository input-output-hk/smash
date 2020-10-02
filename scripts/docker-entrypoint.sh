#!/usr/bin/env bash
set -euo pipefail

SECRET_DIR=${1:-/run/secrets}
OUT_DIR=${2:-/configuration}
SCHEMA_DIR=${3:-/schema}
SMASHPGPASSFILE=${OUT_DIR}/pgpass

POSTGRES_DB=''${POSTGRES_DB:-$(< ''${SECRET_DIR}/postgres_db)}
POSTGRES_USER=''${POSTGRES_USER:-$(< ''${SECRET_DIR}/postgres_user)}
POSTGRES_PASSWORD=''${POSTGRES_PASSWORD:-$(< ''${SECRET_DIR}/postgres_password)}
echo ${POSTGRES_HOST}:${POSTGRES_PORT}:${POSTGRES_DB}:${POSTGRES_USER}:${POSTGRES_PASSWORD} > $SMASHPGPASSFILE
chmod 0600 $SMASHPGPASSFILE
export SMASHPGPASSFILE

exec smash-exe --schema-dir ${SCHEMA_DIR} $@
