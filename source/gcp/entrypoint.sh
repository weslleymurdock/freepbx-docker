#!/usr/bin/env bash
set -Eeuo pipefail
log() { printf '[gcp-entrypoint] %s\n' "$*"; }
ensure_user() { getent group asterisk >/dev/null || groupadd --system asterisk; id -u asterisk >/dev/null 2>&1 || useradd --system --home-dir /var/lib/asterisk --gid asterisk asterisk; usermod -aG audio,dialout asterisk 2>/dev/null || true; }
prepare_runtime() { mkdir -p /run/mysqld /run/sshd /var/log/asterisk /var/run/fail2ban /var/log/mongodb /var/lib/mongodb; chown mysql:mysql /run/mysqld 2>/dev/null || true; chown -R asterisk:asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk 2>/dev/null || true; chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb 2>/dev/null || true; }
configure_low_memory() { install -m 0644 /usr/local/src/gcp/mariadb.cnf /etc/mysql/conf.d/zz-gcp-low-memory.cnf; install -m 0644 /usr/local/src/gcp/php.ini /etc/php/8.2/apache2/conf.d/99-gcp-low-memory.ini; install -m 0644 /usr/local/src/gcp/php.ini /etc/php/8.2/cli/conf.d/99-gcp-low-memory.ini; }
start_mariadb() {
  if [[ ! -d /var/lib/mysql/mysql ]]; then mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null; fi
  log 'starting mariadb'; mysqld --user=mysql --skip-name-resolve >/var/log/mariadb.log 2>&1 &
  for _ in $(seq 1 30); do mysqladmin ping --silent >/dev/null 2>&1 && break; sleep 1; done
  mysqladmin ping --silent >/dev/null 2>&1 || { log 'MariaDB failed to become ready'; exit 1; }
  if [[ -n "${MYSQL_ROOT_PASSWORD:-}" && -n "${FREEPBX_DB_PASSWORD:-}" ]]; then
    local root_pw="${MYSQL_ROOT_PASSWORD//\'/\'\'}" db_pw="${FREEPBX_DB_PASSWORD//\'/\'\'}"
    mysql --protocol=socket -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_pw}';
CREATE USER IF NOT EXISTS 'freepbxuser'@'localhost' IDENTIFIED BY '${db_pw}';
CREATE USER IF NOT EXISTS 'freepbxuser'@'%' IDENTIFIED BY '${db_pw}';
ALTER USER 'freepbxuser'@'localhost' IDENTIFIED BY '${db_pw}';
ALTER USER 'freepbxuser'@'%' IDENTIFIED BY '${db_pw}';
CREATE DATABASE IF NOT EXISTS asterisk;
CREATE DATABASE IF NOT EXISTS asteriskcdrdb;
GRANT ALL PRIVILEGES ON asterisk.* TO 'freepbxuser'@'localhost';
GRANT ALL PRIVILEGES ON asterisk.* TO 'freepbxuser'@'%';
GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'freepbxuser'@'localhost';
GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'freepbxuser'@'%';
FLUSH PRIVILEGES;
SQL
  else log 'MYSQL_ROOT_PASSWORD and FREEPBX_DB_PASSWORD are not set; skipping database credential initialization'; fi
}
start_mongodb() { log 'starting mongodb'; mongod --config /etc/mongod.conf >/var/log/mongodb/mongod-stdout.log 2>&1 & }
start_service() { local name="$1"; shift; log "starting $name"; "$@" >/var/log/${name}.log 2>&1 & }
ensure_user; prepare_runtime; configure_low_memory; start_mariadb; start_mongodb
command -v postfix >/dev/null 2>&1 && (service postfix start || log 'postfix did not start; continuing')
command -v cron >/dev/null 2>&1 && start_service cron /usr/sbin/cron -f
command -v fail2ban-server >/dev/null 2>&1 && start_service fail2ban /usr/bin/fail2ban-server -xf start
if [[ -x /usr/local/src/freepbx/start_asterisk ]]; then log 'starting asterisk/freepbx'; /usr/local/src/freepbx/start_asterisk start & fi
log 'starting apache in foreground'; exec apache2ctl -D FOREGROUND
