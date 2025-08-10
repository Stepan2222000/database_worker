ручные бекапы делаются введением команды из корня

бекап всех бд
BACKUP_DIR=/root/postgres-docker/db_backups \
bash /root/postgres-docker/ops/backup/backup_pg.sh

бекап одной бд
BACKUP_DIR=/root/postgres-docker/db_backups \
bash /root/postgres-docker/ops/backup/backup_pg.sh avito_zamer





удаление прошлой бд и установка последнего бекапа
/root/postgres-docker/ops/backup/restore.sh avito_zamer -y

просмотр всех доступных бекапов
ls -1t /root/postgres-docker/db_backups/avito_zamer/*/*.sql.gz

применение определенного бекапа (надо заменять паки названия файлов)

/root/postgres-docker/ops/backup/restore.sh avito_zamer \
  /root/postgres-docker/db_backups/avito_zamer/2025-08-10/avito_zamer_2025-08-10_14-29.sql.gz -y