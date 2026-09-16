#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[gcp-entrypoint] %s\n' "$*"; }

ensure_user() {
  getent group asterisk >/dev/null || groupadd --system asterisk
  id -u asterisk >/dev/null 2>&1 || useradd --system --home-dir /var/lib/asterisk --gid asterisk asterisk
  usermod -aG audio,dialout asterisk 2>/dev/null || true
}

prepare_runtime() {
  mkdir -p /run/mysqld /run/sshd /var/log/asterisk /var/run/fail2ban
  chown mysql:mysql /run/mysqld 2>/dev/null || true
  chown -R asterisk:asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk 2>/dev/null || true
}

configure_low_memory() {
  if [[ -f /usr/local/src/gcp/mariadb.cnf ]]; then
    install -m 0644 /usr/local/src/gcp/mariadb.cnf /etc/mysql/conf.d/zz-gcp-low-memory.cnf
  fi
  if [[ -f /usr/local/src/gcp/php.ini ]]; then
    install -m 0644 /usr/local/src/gcp/php.ini /etc/php/8.2/apache2/conf.d/99-gcp-low-memory.ini
    install -m 0644 /usr/local/src/gcp/php.ini /etc/php/8.2/cli/conf.d/99-gcp-low-memory.ini
  fi
}

start_service() {
  local name="$1"; shift
  log "starting $name"
  "$@" >/var/log/${name}.log 2>&1 &
}

ensure_user
prepare_runtime
configure_low_memory

start_service mariadb mysqld --user=mysql
for _ in $(seq 1 30); do
  if mysqladmin ping --silent >/dev/null 2>&1; then break; fi
  sleep 1
done

if command -v postfix >/dev/null 2>&1; then
  service postfix start || log 'postfix did not start; continuing'
fi

if command -v cron >/dev/null 2>&1; then
  start_service cron /usr/sbin/cron -f
fi

if command -v fail2ban-server >/dev/null 2>&1; then
  start_service fail2ban /usr/bin/fail2ban-server -xf start
fi

if [[ -x /usr/local/src/freepbx/start_asterisk ]]; then
  log 'starting asterisk/freepbx'
  /usr/local/src/freepbx/start_asterisk start &
fi

log 'starting apache in foreground'
exec apache2ctl -D FOREGROUND
