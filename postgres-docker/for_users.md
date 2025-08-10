Руководство пользователя: бэкапы и восстановление PostgreSQL (Docker)

Этот файл можно просто скопировать или распечатать. Все команды рассчитаны на структуру проекта ниже и работу в Linux на сервере (root).

⸻

Структура проекта

/root/postgres-docker
├─ avito_zamer/              # папка сервиса (есть .env и docker-compose.yml)
├─ ebay/
├─ test_db/
├─ db_backups/               # сюда складываются бэкапы
└─ ops/
   └─ backup/
      ├─ backup_pg.sh        # скрипт бэкапа
      └─ restore.sh          # скрипт восстановления

Скрипты ничего редактировать не требуют: они сами находят все /root/postgres-docker/*/.env, читают POSTGRES_DB, POSTGRES_USER, а имя контейнера берут из CONTAINER_NAME (если нет — из имени папки с суффиксом _db).

⸻

Быстрый старт (TL;DR)

Бэкап всех БД

cd /root/postgres-docker
BACKUP_DIR=/root/postgres-docker/db_backups RETENTION_DAYS=14 \
bash ops/backup/backup_pg.sh

Бэкап одной БД (пример: avito_zamer)

cd /root/postgres-docker
PROJECT=avito_zamer bash ops/backup/backup_pg.sh

Восстановить последний бэкап (пример: avito_zamer)

cd /root/postgres-docker
ops/backup/restore.sh avito_zamer -y

Восстановить конкретный файл

ops/backup/restore.sh avito_zamer \
  /root/postgres-docker/db_backups/avito_zamer/2025-08-10/avito_zamer_2025-08-10_14-29.sql.gz -y


⸻

Как это работает

Скрипт backup_pg.sh
	•	Находит все проекты по маске /root/postgres-docker/*/.env.
	•	Для каждого проекта:
	•	определяет контейнер, пользователя и имя БД;
	•	делает pg_dump из запущенного контейнера;
	•	складывает архив в:

/root/postgres-docker/db_backups/<project>/<YYYY-MM-DD>/<db>_<YYYY-MM-DD_HH-MM>.sql.gz


	•	удаляет архивы старше RETENTION_DAYS (по умолчанию 14) и чистит пустые папки.

Скрипт restore.sh
	•	Принимает имя проекта и необязательный путь до .sql.gz.
	•	Если путь не указан, берёт отмеченный (SELECTED) или самый свежий файл.
	•	Безопасно завершает активные сессии, делает DROP DATABASE → CREATE DATABASE, накатывает дамп.
	•	Запрашивает подтверждение (можно отключить флагом -y или AUTO_YES=1).

⸻

Где лежат бэкапы

/root/postgres-docker/db_backups/
├─ avito_zamer/
│  └─ 2025-08-10/
│     ├─ avito_zamer_2025-08-10_12-18.sql.gz
│     └─ avito_zamer_2025-08-10_14-29.sql.gz
├─ ebay/
└─ test_db/

Показать последние файлы по проекту:

ls -1t /root/postgres-docker/db_backups/avito_zamer/*/*.sql.gz | head


⸻

Восстановление: «отмеченный» файл

Можно «пометить» конкретный архив как выбранный, чтобы потом восстанавливать одной командой без указания пути.

Пометить файл:

echo "/root/postgres-docker/db_backups/avito_zamer/2025-08-10/avito_zamer_2025-08-10_14-29.sql.gz" \
> /root/postgres-docker/db_backups/avito_zamer/SELECTED

Восстановить отмеченный/последний:

AUTO_YES=1 ops/backup/restore.sh avito_zamer

Снять пометку:

rm -f /root/postgres-docker/db_backups/avito_zamer/SELECTED


⸻

Автоматизация (cron)

Открыть crontab:

crontab -e

Добавить (ежедневно в 02:00, хранить 14 дней):

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BACKUP_DIR=/root/postgres-docker/db_backups
RETENTION_DAYS=14
0 2 * * * /bin/bash /root/postgres-docker/ops/backup/backup_pg.sh >> /root/postgres-docker/ops/backup/backup.log 2>&1

Проверить статус:

systemctl status cron --no-pager

Логи:

tail -n 200 /root/postgres-docker/ops/backup/backup.log


⸻

Проверка после восстановления
	1.	Контейнер «живой»:

docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

	2.	Postgres принимает соединения:

docker exec -it avito_zamer_db pg_isready -U admin -d avito_zamer

	3.	Есть таблицы/данные:

docker exec -it avito_zamer_db psql -U admin -d avito_zamer -c '\dt'


⸻

Ручной бэкап (на всякий случай)

DATE_DIR=$(date +%F); STAMP=$(date +%F_%H-%M)
mkdir -p /root/postgres-docker/db_backups/avito_zamer/$DATE_DIR
docker exec -t avito_zamer_db pg_dump -U admin -d avito_zamer \
| gzip > /root/postgres-docker/db_backups/avito_zamer/$DATE_DIR/avito_zamer_${STAMP}.sql.gz


⸻

Скачивание/загрузка бэкапов (SFTP)

Через SFTP‑клиент (например, встроенный в Termius) переходите в:

/root/postgres-docker/db_backups/<project>/<YYYY-MM-DD>/*.sql.gz

Файлы можно скачивать на ПК или загружать обратно, чтобы затем восстановить командой restore.sh.

⸻

Частые проблемы

1) psql: connection to server on socket ... failed
Контейнер ещё стартует. Подождите 5–10 секунд и проверьте:

docker ps
docker logs <имя_контейнера> --tail 100
docker exec -it <имя_контейнера> pg_isready -U admin -d <db>

2) Не создаётся бэкап конкретного проекта
Проверьте:
	•	контейнер запущен: docker ps (имя обычно <папка>_db или из CONTAINER_NAME);
	•	в папке проекта есть .env с POSTGRES_DB, POSTGRES_USER;
	•	права на /root/postgres-docker/db_backups (запуск от root обычно решает).

3) Нужно «чистое начало» (стереть данные БД)
Осторожно: удалит данные!

cd /root/postgres-docker/<проект>
docker compose down -v   # удалит контейнер и named volume
docker compose up -d     # поднимет «пустую» БД

4) Мало места
Посмотреть размер:

du -h /root/postgres-docker/db_backups | tail -n 1

Уменьшите RETENTION_DAYS или удалите старые даты.

⸻

Шпаргалка
	•	Список контейнеров Postgres:

docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | awk '/5432\\/tcp|postgres/ { print }'

	•	Последний бэкап проекта:

ls -1t /root/postgres-docker/db_backups/avito_zamer/*/*.sql.gz | head -1

	•	Восстановить последний без вопросов:

AUTO_YES=1 ops/backup/restore.sh avito_zamer

	•	Бэкап всех БД сейчас:

BACKUP_DIR=/root/postgres-docker/db_backups RETENTION_DAYS=14 \
bash ops/backup/backup_pg.sh


⸻

Требования для работы «из коробки»
	•	В каждой папке проекта: .env и docker-compose.yml.
	•	Контейнеры запущены: docker compose up -d в каждой папке.
	•	Скрипты существуют и исполняемые:

chmod +x /root/postgres-docker/ops/backup/backup_pg.sh
chmod +x /root/postgres-docker/ops/backup/restore.sh

	•	Каталог для бэкапов создан:

mkdir -p /root/postgres-docker/db_backups


⸻

Важно знать
	•	Бэкап — логический (pg_dump), переносит схему и данные, не переносит серверные конфиги/расширения вне дампа.
	•	Восстановление пересоздаёт БД (DROP/CREATE) — текущие данные будут удалены.
	•	Ротация удаляет файлы старше RETENTION_DAYS и пустые папки.

Готово ✅ Теперь вы можете запускать бэкапы и восстановление одной-двумя командами.