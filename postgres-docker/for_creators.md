Руководство разработчика: как развернуть систему бэкапов PostgreSQL (Docker) с нуля

Этот документ — для разработчиков/DevOps. После выполнения шагов вы получите:
	•	единый шаблон папок для нескольких сервисов Postgres;
	•	автоматический бэкап всех БД (и выборочно по проекту);
	•	скрипт восстановления из последнего или указанного файла;
	•	ротацию старых бэкапов и cron-задачу.

⸻

1) Предусловия
	•	Сервер Linux (Ubuntu 22.04/24.04 рекомендуемо).
	•	Установлены: docker, docker compose (plugin), bash.
	•	Пользователь с правами root (или используйте sudo).

Проверка:

docker --version
docker compose version


⸻

2) Базовая структура проекта

Создадим корневую директорию и стандартные подпапки:

mkdir -p /root/postgres-docker/{ops/backup,db_backups}
mkdir -p /root/postgres-docker/{avito_zamer,ebay,test_db}

Итоговая структура:

/root/postgres-docker
├─ avito_zamer/           # сервис №1
├─ ebay/                  # сервис №2
├─ test_db/               # сервис-песочница
├─ db_backups/            # сюда падают бэкапы
└─ ops/
   └─ backup/
      ├─ backup_pg.sh     # скрипт бэкапа (авто-обнаружение сервисов)
      └─ restore.sh       # восстановление из дампа


⸻

3) Шаблоны .env и docker-compose.yml

Для каждого сервиса создайте .env и docker-compose.yml.

3.1 Пример .env (положить в /root/postgres-docker/<project>/.env)

POSTGRES_USER=admin
POSTGRES_PASSWORD=Password123
POSTGRES_DB=<project_db_name>
POSTGRES_PORT=<host_port>   # например: 5401, 5402, 5403 ...
# Необязательно, но удобно — точное имя контейнера:
CONTAINER_NAME=<project>_db

Примеры:

# /root/postgres-docker/avito_zamer/.env
POSTGRES_USER=admin
POSTGRES_PASSWORD=Password123
POSTGRES_DB=avito_zamer
POSTGRES_PORT=5402
CONTAINER_NAME=avito_zamer_db

# /root/postgres-docker/ebay/.env
POSTGRES_USER=admin
POSTGRES_PASSWORD=Password123
POSTGRES_DB=ebay
POSTGRES_PORT=5401
CONTAINER_NAME=ebay_db

# /root/postgres-docker/test_db/.env
POSTGRES_USER=admin
POSTGRES_PASSWORD=Password123
POSTGRES_DB=test_db
POSTGRES_PORT=5403
CONTAINER_NAME=test_db

3.2 Пример docker-compose.yml (положить в /root/postgres-docker/<project>/docker-compose.yml)

services:
  db:
    image: postgres:16
    container_name: ${CONTAINER_NAME:-${COMPOSE_PROJECT_NAME:-db}}
    restart: always
    env_file: .env
    ports:
      - "${POSTGRES_PORT}:5432"
    volumes:
      - ${COMPOSE_PROJECT_NAME:-${CONTAINER_NAME:-db}}_data:/var/lib/postgresql/data
volumes:
  ${COMPOSE_PROJECT_NAME:-${CONTAINER_NAME:-db}}_data:

Примечание: имя named volume в примере зависит от названия проекта/контейнера — это удобно для изоляции данных.

3.3 Запуск контейнеров

cd /root/postgres-docker/avito_zamer && docker compose up -d
cd /root/postgres-docker/ebay        && docker compose up -d
cd /root/postgres-docker/test_db     && docker compose up -d

Проверка:

docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'


⸻

4) Скрипты: бэкап и восстановление

4.1 backup_pg.sh

Сохраните файл как /root/postgres-docker/ops/backup/backup_pg.sh и сделайте исполняемым.

cat >/root/postgres-docker/ops/backup/backup_pg.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

# Где хранить бэкапы (по умолчанию — рядом с проектом)
BACKUP_DIR="${BACKUP_DIR:-$(cd "$(dirname "$0")/../../" && pwd)/db_backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
PROJECT="${PROJECT:-}"        # если указать — бэкапнется только этот проект (имя папки)

DATE_DIR="$(date +%F)"
STAMP="$(date +%F_%H-%M)"
mkdir -p "$BACKUP_DIR"

# Список запущенных контейнеров (для быстрой проверки существования)
RUNNING_NAMES="$(docker ps --format '{{.Names}}')"

shopt -s nullglob
for ENV_FILE in /root/postgres-docker/*/.env; do
  SVC_DIR="$(basename "$(dirname "$ENV_FILE")")"    # имя папки (проект)
  [[ -n "$PROJECT" && "$PROJECT" != "$SVC_DIR" ]] && continue

  # читаем ключевые переменные из .env
  DB="$(grep -E '^POSTGRES_DB='    "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)"
  USER="$(grep -E '^POSTGRES_USER=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)"
  CNF_NAME="$(grep -E '^CONTAINER_NAME=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)"

  DB="${DB:-$SVC_DIR}"
  USER="${USER:-admin}"

  # выбираем корректное имя контейнера
  if [[ -n "${CNF_NAME:-}" ]] && grep -qw "$CNF_NAME" <<<"$RUNNING_NAMES"; then
    CONTAINER="$CNF_NAME"
  elif grep -qw "${SVC_DIR}_db" <<<"$RUNNING_NAMES"; then
    CONTAINER="${SVC_DIR}_db"
  elif grep -qw "$SVC_DIR" <<<"$RUNNING_NAMES"; then
    CONTAINER="$SVC_DIR"
  else
    echo "[SKIP] Не найден запущенный контейнер для '$SVC_DIR'" >&2
    continue
  fi

  OUT_DIR="$BACKUP_DIR/$SVC_DIR/$DATE_DIR"
  OUT_FILE="$OUT_DIR/${DB}_${STAMP}.sql.gz"
  mkdir -p "$OUT_DIR"

  echo "==> Dump $DB (container=$CONTAINER, user=$USER) -> $OUT_FILE"
  docker exec -t "$CONTAINER" pg_dump -U "$USER" -d "$DB" | gzip > "$OUT_FILE"
  echo "[OK]  $OUT_FILE"

done

# Ротация
find "$BACKUP_DIR" -type f -name '*.sql.gz' -mtime "+$RETENTION_DAYS" -delete || true
find "$BACKUP_DIR" -type d -empty -delete || true
BASH

chmod +x /root/postgres-docker/ops/backup/backup_pg.sh

4.2 restore.sh

Сохраните файл как /root/postgres-docker/ops/backup/restore.sh и сделайте исполняемым.

cat >/root/postgres-docker/ops/backup/restore.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/root/postgres-docker/db_backups}"
LOG="${LOG:-/root/postgres-docker/ops/backup/restore.log}"
AUTO_YES="${AUTO_YES:-}"   # можно передать -y первым/вторым аргументом

DB="${1:-}"
FILE="${2:-}"
[[ "${DB:-}" == "-y" ]] && { AUTO_YES=1; DB="${2:-}"; FILE="${3:-}"; }
[[ "${2:-}" == "-y" ]] && { AUTO_YES=1; FILE=""; }

if [[ -z "${DB:-}" ]]; then
  echo "Usage: $0 <project|db> [backup.sql.gz] [-y]"; exit 1;
fi

# Находим .env по имени папки или по совпадению POSTGRES_DB
ENV_FILE=""
for f in /root/postgres-docker/*/.env; do
  svc="$(basename "$(dirname "$f")")"
  pdb="$(grep -E '^POSTGRES_DB=' "$f" | cut -d= -f2- | tr -d '"' || true)"
  if [[ "$svc" == "$DB" || "${pdb:-}" == "$DB" ]]; then ENV_FILE="$f"; break; fi
done

[[ -z "$ENV_FILE" ]] && { echo "Unknown project/db '$DB'"; exit 1; }

SVC_DIR="$(basename "$(dirname "$ENV_FILE")")"
DB_NAME="$(grep -E '^POSTGRES_DB=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)"
USER="$(grep -E '^POSTGRES_USER=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)"
CNF_NAME="$(grep -E '^CONTAINER_NAME=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)"

DB_NAME="${DB_NAME:-$SVC_DIR}"
USER="${USER:-admin}"

# Определяем контейнер
RUNNING_NAMES="$(docker ps --format '{{.Names}}')"
if [[ -n "${CNF_NAME:-}" ]] && grep -qw "$CNF_NAME" <<<"$RUNNING_NAMES"; then
  CONTAINER="$CNF_NAME"
elif grep -qw "${SVC_DIR}_db" <<<"$RUNNING_NAMES"; then
  CONTAINER="${SVC_DIR}_db"
elif grep -qw "$SVC_DIR" <<<"$RUNNING_NAMES"; then
  CONTAINER="$SVC_DIR"
else
  echo "Container for '$SVC_DIR' is not running"; exit 1
fi

# Если файл не задан — берём SELECTED или последний по времени
if [[ -z "${FILE:-}" ]]; then
  if [[ -f "$BACKUP_DIR/$SVC_DIR/SELECTED" ]]; then
    FILE="$(cat "$BACKUP_DIR/$SVC_DIR/SELECTED")"
  else
    FILE="$(ls -1t "$BACKUP_DIR/$SVC_DIR"/*/*.sql.gz 2>/dev/null | head -1 || true)"
  fi
fi

[[ -z "${FILE:-}" || ! -f "$FILE" ]] && { echo "Backup file not found for '$SVC_DIR'"; exit 1; }

confirm() {
  local ans
  if [[ -n "${AUTO_YES:-}" ]]; then return 0; fi
  read -r -p "This will DROP DATABASE $DB_NAME and replace all data. Continue? [y/N] " ans || true
  ans="$(printf '%s' "$ans" | tr -d '\r\n\t ' | tr '[:upper:]' '[:lower:]')"
  [[ "$ans" == "y" ]]
}

# Отчёт об операции
{
  echo "About to RESTORE"
  echo "  Project   : $SVC_DIR"
  echo "  Container : $CONTAINER"
  echo "  DB/User   : $DB_NAME / $USER"
  echo "  Backup    : $FILE"
} | tee -a "$LOG"

confirm || { echo "Cancelled." | tee -a "$LOG"; exit 0; }

# Гасим подключения, дропаем/создаём БД и накатываем дамп
zcat "$FILE" > /dev/null 2>&1 || { echo "Bad archive: $FILE"; exit 1; }

docker exec -i "$CONTAINER" psql -U "$USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME';
DROP DATABASE IF EXISTS "$DB_NAME";
CREATE DATABASE "$DB_NAME" OWNER "$USER";
SQL

zcat "$FILE" | docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB_NAME" -v ON_ERROR_STOP=1

echo "[OK] Restored $SVC_DIR from $FILE" | tee -a "$LOG"
BASH

chmod +x /root/postgres-docker/ops/backup/restore.sh


⸻

5) Первое включение и smoke-тест
	1.	Поднимите все контейнеры (docker compose up -d в папках сервисов).
	2.	Сделайте пробный бэкап всех БД:

cd /root/postgres-docker
BACKUP_DIR=/root/postgres-docker/db_backups RETENTION_DAYS=14 \
bash ops/backup/backup_pg.sh


	3.	Проверьте наличие файлов:

ls -R db_backups | sed -n '1,80p'


	4.	Проверьте восстановление в тестовый проект (осторожно — дропнет БД):

/root/postgres-docker/ops/backup/restore.sh test_db -y



⸻

6) Автоматизация через cron

Откройте crontab и добавьте ежедневный запуск:

crontab -e

Вставьте строки:

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BACKUP_DIR=/root/postgres-docker/db_backups
RETENTION_DAYS=14
0 2 * * * /bin/bash /root/postgres-docker/ops/backup/backup_pg.sh >> /root/postgres-docker/ops/backup/backup.log 2>&1

Проверка статуса демона cron:

systemctl status cron --no-pager

Смотреть лог бэкапов:

tail -n 200 /root/postgres-docker/ops/backup/backup.log


⸻

7) Эксплуатация (ежедневные задачи)
	•	Бэкап всех БД вручную:

cd /root/postgres-docker
bash ops/backup/backup_pg.sh


	•	Бэкап только одного проекта (например, avito_zamer):

cd /root/postgres-docker
PROJECT=avito_zamer bash ops/backup/backup_pg.sh


	•	Восстановление последнего бэкапа:

/root/postgres-docker/ops/backup/restore.sh avito_zamer -y


	•	Восстановление из конкретного файла:

/root/postgres-docker/ops/backup/restore.sh avito_zamer /root/postgres-docker/db_backups/avito_zamer/2025-08-10/avito_zamer_2025-08-10_14-29.sql.gz -y


	•	Закрепить файл как «выбранный» для последующих восстановлений:

echo /root/postgres-docker/db_backups/avito_zamer/2025-08-10/avito_zamer_2025-08-10_14-29.sql.gz > /root/postgres-docker/db_backups/avito_zamer/SELECTED
AUTO_YES=1 /root/postgres-docker/ops/backup/restore.sh avito_zamer



⸻

8) Добавление нового сервиса Postgres
	1.	Создайте папку: /root/postgres-docker/<new_project>.
	2.	Скопируйте шаблон .env и docker-compose.yml, проставьте уникальные POSTGRES_DB, POSTGRES_PORT, CONTAINER_NAME.
	3.	Запустите: docker compose up -d из папки проекта.
	4.	Проверьте docker ps и выполните пробный бэкап:

PROJECT=<new_project> bash /root/postgres-docker/ops/backup/backup_pg.sh



Никаких изменений в скриптах делать не нужно — авто-обнаружение работает по .env.

⸻

9) Миграция на новый сервер
	1.	На старом сервере скачайте бэкапы (SFTP или scp) из /root/postgres-docker/db_backups.
	2.	На новом сервере разверните структуру (разделы 2–4), запустите контейнеры.
	3.	Загрузите нужные файлы .sql.gz в соответствующие папки внутри /root/postgres-docker/db_backups/<project>/<YYYY-MM-DD>/.
	4.	Восстановите: restore.sh <project> -y (или укажите конкретный файл).

⸻

10) Тонкости, безопасность, обновления
	•	Права доступа. Храните /root/postgres-docker под root, чтобы избежать проблем записи/чтения.
	•	Пароли. .env содержат секреты — ограничьте доступ (chmod 600).
	•	Версии Postgres. Обновляйте образ планово (16.x → 17.x) по инструкции Postgres (иногда нужен pg_upgrade). Для бэкапов/восстановлений внутри минорных версий pg_dump/psql совместимы.
	•	Объём диска. Следите за /root/postgres-docker/db_backups:

du -h /root/postgres-docker/db_backups | tail -n 1


	•	Сжатие. Здесь используем gzip; при больших БД можно заменить на zstd (потребуется правка скриптов: zstd -T0/unzstd).

⸻

11) Диагностика и FAQ
	•	Контейнер не принимает соединения:

docker logs <container> --tail 200
docker exec -it <container> pg_isready -U <user> -d <db>


	•	Бэкап для проекта не создаётся:
	1.	контейнер запущен (docker ps),
	2.	корректный .env (есть POSTGRES_DB, POSTGRES_USER, желательно CONTAINER_NAME),
	3.	хватает прав записи в db_backups.
	•	Нужно «обнулить» данные проекта:

cd /root/postgres-docker/<project>
docker compose down -v   # удалит контейнер и named volume с данными
docker compose up -d


	•	Восстановление требует подтверждение — отключите вопрос флагом:

/root/postgres-docker/ops/backup/restore.sh <project> -y
# или
AUTO_YES=1 /root/postgres-docker/ops/backup/restore.sh <project>



⸻

Готово!

После выполнения документа у вас есть полностью автоматизированная система бэкапов/восстановления для нескольких контейнеров PostgreSQL без ручных правок скриптов при добавлении новых сервисов.