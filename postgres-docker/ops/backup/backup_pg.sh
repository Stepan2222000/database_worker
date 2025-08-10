#!/usr/bin/env bash
set -euo pipefail

# Куда складывать бэкапы (по умолчанию: /root/postgres-docker/db_backups)
BACKUP_DIR="${BACKUP_DIR:-$(cd "$(dirname "$0")/../../" && pwd)/db_backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

# Если передали имя сервиса (папки с .env), бэкапим только его.
# Пример: bash backup_pg.sh avito_zamer
SVC_ONLY="${1:-}"

DATE_DIR="$(date +%F)"
STAMP="$(date +%F_%H-%M)"

mkdir -p "$BACKUP_DIR"

# Имена запущенных контейнеров (для быстрого матчинга)
RUNNING_NAMES="$(docker ps --format '{{.Names}}')"

# Обходим все .env в /root/postgres-docker/*/.env
for ENV_FILE in /root/postgres-docker/*/.env; do
  [ -f "$ENV_FILE" ] || continue

  SVC_DIR="$(basename "$(dirname "$ENV_FILE")")"   # например: avito_zamer
  # Фильтр по имени сервиса (если задан)
  if [ -n "$SVC_ONLY" ] && [ "$SVC_DIR" != "$SVC_ONLY" ]; then
    continue
  fi

  # Читаем нужные переменные из .env
  DB="$(grep -E '^POSTGRES_DB=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')" || true
  USER="$(grep -E '^POSTGRES_USER=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')" || true
  PASS="$(grep -E '^POSTGRES_PASSWORD=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')" || true
  CNF_NAME="$(grep -E '^CONTAINER_NAME=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')" || true

  # Значения по умолчанию
  DB="${DB:-$SVC_DIR}"
  USER="${USER:-admin}"

  # Определяем имя контейнера:
  # 1) если задан CONTAINER_NAME в .env и контейнер с таким именем запущен — берём его
  # 2) иначе пробуем "<имя_папки>_db"
  # 3) иначе пробуем "<имя_папки>"
  if [ -n "${CNF_NAME:-}" ] && grep -qw "$CNF_NAME" <<<"$RUNNING_NAMES"; then
    CONTAINER="$CNF_NAME"
  elif grep -qw "${SVC_DIR}_db" <<<"$RUNNING_NAMES"; then
    CONTAINER="${SVC_DIR}_db"
  elif grep -qw "$SVC_DIR" <<<"$RUNNING_NAMES"; then
    CONTAINER="$SVC_DIR"
  else
    echo "[SKIP] Не найден запущенный контейнер для сервиса '$SVC_DIR' (ожидал '${SVC_DIR}_db' или '$SVC_DIR' или CONTAINER_NAME из .env)" >&2
    continue
  fi

  OUT_DIR="$BACKUP_DIR/$SVC_DIR/$DATE_DIR"
  OUT_FILE="$OUT_DIR/${DB}_${STAMP}.sql.gz"
  mkdir -p "$OUT_DIR"

  echo ">> Бэкап: service=$SVC_DIR container=$CONTAINER db=$DB user=$USER -> $OUT_FILE"

  if [ -n "${PASS:-}" ]; then
    docker exec -e PGPASSWORD="$PASS" -t "$CONTAINER" pg_dump -U "$USER" -d "$DB" | gzip > "$OUT_FILE"
  else
    docker exec -t "$CONTAINER" pg_dump -U "$USER" -d "$DB" | gzip > "$OUT_FILE"
  fi

  echo "[OK] $OUT_FILE"
done

# Ротация
find "$BACKUP_DIR" -type f -name '*.sql.gz' -mtime +"$RETENTION_DAYS" -delete
find "$BACKUP_DIR" -type d -empty -delete