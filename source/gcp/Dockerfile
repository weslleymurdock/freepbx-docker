FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    ASTERISK_VERSION=21.10.2 \
    ASTERISK_VERSION_TAG=21.10.2 \
    FREEPBX_VERSION=17.0 \
    FREEPBX_VERSION_TAG=17.0.2

WORKDIR /usr/src

RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential pkg-config autoconf-archive cron curl wget gnupg bison flex \
  libedit-dev libnewt-dev libssl-dev libncurses5-dev libsqlite3-dev libjansson-dev libxml2-dev \
  uuid uuid-dev default-libmysqlclient-dev \
  libspeex-dev libspeexdsp-dev libogg-dev libvorbis-dev libasound2-dev portaudio19-dev \
  libcurl4-openssl-dev xmlstarlet libpq-dev unixodbc-dev libneon27-dev \
  libgmime-3.0-dev liblua5.2-dev liburiparser-dev libxslt1-dev \
  libbluetooth-dev libradcli-dev freetds-dev libjack-jackd2-dev libcap-dev \
  libsnmp-dev libiksemel-dev libcpg-dev libcfg-dev libpopt-dev libical-dev libspandsp-dev \
  libresample1-dev libc-client2007e-dev binutils-dev libsrtp2-dev libgsm1-dev \
  doxygen graphviz zlib1g-dev libldap2-dev libcodec2-dev libfftw3-dev libsndfile1-dev libunbound-dev \
  subversion bzip2 patch lame ffmpeg mpg123 expect apache2 mariadb-server mariadb-client \
  php8.2 php8.2-curl php8.2-cli php8.2-common php8.2-mysql php8.2-gd php8.2-mbstring php8.2-intl \
  php8.2-xml php-pear sox sqlite3 automake libtool autoconf unixodbc \
  odbc-mariadb nodejs npm ipset iptables php-soap \
  postfix libsasl2-modules mailutils certbot python3-certbot-apache logrotate fail2ban \
  && echo "postfix postfix/mailname string freepbx.localdomain" | debconf-set-selections \
  && echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections \
  && dpkg-reconfigure -f noninteractive postfix \
  && curl -fsSL https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg \
  && echo 'deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main' > /etc/apt/sources.list.d/mongodb-org-8.0.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends mongodb-org-server mongodb-mongosh \
  && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  curl -fsSL "https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-${ASTERISK_VERSION}.tar.gz" -o asterisk.tar.gz; \
  tar -xzf asterisk.tar.gz; cd "asterisk-${ASTERISK_VERSION}"; \
  contrib/scripts/get_mp3_source.sh; \
  ./configure --libdir=/usr/lib64 --with-pjproject-bundled --with-jansson-bundled; \
  make menuselect.makeopts; menuselect/menuselect --disable BUILD_NATIVE --enable format_mp3 menuselect.makeopts; \
  make -j1; make install; make samples; ldconfig; \
  groupadd asterisk; useradd -r -d /var/lib/asterisk -g asterisk asterisk; usermod -aG audio,dialout asterisk; \
  chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /usr/lib64/asterisk; \
  sed -i 's|;runuser|runuser|' /etc/asterisk/asterisk.conf; sed -i 's|;rungroup|rungroup|' /etc/asterisk/asterisk.conf; \
  echo /usr/lib64 >> /etc/ld.so.conf.d/x86_64-linux-gnu.conf; ldconfig; \
  sed -i 's/^\(upload_max_filesize = \).*/\120M/' /etc/php/8.2/apache2/php.ini; \
  sed -i 's/^\(memory_limit = \).*/\196M/' /etc/php/8.2/apache2/php.ini; \
  sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf; \
  sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf; a2enmod rewrite; \
  echo 'ServerName localhost' >> /etc/apache2/apache2.conf; \
  apache2ctl -t; \
  rm -f /var/www/html/index.html; \
  cd /usr/src; rm -rf "asterisk-${ASTERISK_VERSION}" asterisk.tar.gz; \
  apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /usr/local/src
RUN set -eux; \
  curl -fsSL "https://mirror.freepbx.org/modules/packages/freepbx/freepbx-${FREEPBX_VERSION}-latest.tgz" -o freepbx.tgz; \
  tar -xzf freepbx.tgz; rm freepbx.tgz

COPY odbc/odbcinst.ini /etc/odbcinst.ini
COPY odbc/odbc.ini /etc/odbc.ini
COPY postfix/main.cf /etc/postfix/main.cf
COPY logrotate/asterisk /etc/logrotate.d/asterisk
COPY gcp/jail.local /etc/fail2ban/jail.local
COPY fail2ban/filter.d/asterisk.conf /etc/fail2ban/filter.d/asterisk.conf
COPY gcp/mariadb.cnf /usr/local/src/gcp/mariadb.cnf
COPY gcp/mongod.conf /etc/mongod.conf
COPY gcp/php.ini /usr/local/src/gcp/php.ini
COPY gcp/entrypoint.sh /usr/local/src/gcp/entrypoint.sh

RUN chmod +x /usr/local/src/gcp/entrypoint.sh \
  && mkdir -p /var/log/asterisk /var/lib/mongodb /var/log/mongodb \
  && touch /var/log/asterisk/full \
  && chown -R asterisk:asterisk /var/log/asterisk \
  && chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb

EXPOSE 80 443 5060/udp
VOLUME ["/var/lib/mysql", "/var/lib/mongodb", "/var/lib/asterisk", "/etc/asterisk", "/var/log/asterisk"]

CMD ["/usr/local/src/gcp/entrypoint.sh"]
