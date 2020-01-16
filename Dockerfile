# Multi-stage build - See https://docs.docker.com/engine/userguide/eng-image/multistage-build
FROM ubnt/unms:1.1.3 as unms
FROM ubnt/unms-nginx:1.1.3 as unms-nginx
FROM ubnt/unms-netflow:1.1.3 as unms-netflow
FROM ubnt/unms-crm:3.1.3 as unms-crm
FROM oznu/s6-node:10.15.3-debian-amd64

ENV DEBIAN_FRONTEND=noninteractive 

# base deps redis, rabbitmq, postgres 9.6
RUN set -x \
  && echo "deb http://ftp.debian.org/debian stretch-backports main" >> /etc/apt/sources.list \
  && apt-get update \
  && apt-get -y install apt-transport-https lsb-release ca-certificates wget \
  && wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg \
  && sh -c 'echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list' \
  && apt-get update \
  && mkdir -p /usr/share/man/man1 /usr/share/man/man7 \
  && mkdir -p /usr/share/man/man7 \
  && apt-get install -y build-essential rabbitmq-server redis-server \
    postgresql-9.6 postgresql-contrib-9.6 postgresql-client-9.6 libpq-dev \
    gzip bash vim openssl libcap-dev dumb-init sudo gettext zlibc zlib1g zlib1g-dev \
    iproute2 netcat wget libpcre3 libpcre3-dev libssl-dev git pkg-config \
    libcurl4-openssl-dev libxml2-dev libedit-dev libsodium-dev libargon2-dev \
    jq autoconf libgmp-dev libpng-dev libbz2-dev libc-client-dev libkrb5-dev \
    libjpeg-dev libfreetype6-dev libzip-dev unzip supervisor \
  && apt-get install -y certbot -t stretch-backports

# start ubnt/unms dockerfile #
RUN mkdir -p /home/app/unms

WORKDIR /home/app/unms

# Copy UNMS app from offical image since the source code is not published at this time
COPY --from=unms /home/app/unms /home/app/unms

RUN rm -rf node_modules \
    && JOBS=$(nproc) npm install sharp@latest \
    && JOBS=$(nproc) npm install --production \
    && JOBS=$(nproc) npm install npm

COPY --from=unms /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && cp -r /home/app/unms/node_modules/npm /home/app/unms/
# end ubnt/unms dockerfile #

# start unms-netflow dockerfile #
RUN mkdir -p /home/app/netflow

COPY --from=unms-netflow /home/app /home/app/netflow

RUN cd /home/app/netflow \
    && rm -rf node_modules \
    && JOBS=$(nproc) npm install --production
# end unms-netflow dockerfile #

# start unms-crm dockerfile #
RUN mkdir -p /usr/src/ucrm \
    && mkdir -p /tmp/crontabs \
    && mkdir -p /usr/local/etc/php/conf.d \
    && mkdir -p /usr/local/etc/php-fpm.d \
    && mkdir -p /tmp/supervisor.d \
    && mkdir -p /tmp/supervisord

COPY --from=unms-crm /usr/src/ucrm /usr/src/ucrm
COPY --from=unms-crm /data /data
COPY --from=unms-crm /usr/local/bin/crm* /usr/local/bin/
COPY --from=unms-crm /usr/local/bin/docker* /usr/local/bin/
COPY --from=unms-crm /tmp/crontabs/server /tmp/crontabs/server
COPY --from=unms-crm /tmp/supervisor.d /tmp/supervisor.d
COPY --from=unms-crm /tmp/supervisord /tmp/supervisord

RUN grep -lR "nginx:nginx" /usr/src/ucrm/ | xargs sed -i 's/nginx:nginx/unms:unms/g' \
    && grep -lR "su-exec nginx" /usr/src/ucrm/ | xargs sed -i 's/su-exec nginx//g' \
    && grep -lR "su-exec nginx" /tmp/crontabs/ | xargs sed -i 's/su-exec nginx//g' \
    && grep -lR "su-exec nginx" /tmp/supervisor.d/ | xargs sed -i 's/su-exec nginx//g' \
    && sed -i 's#chmod -R 775 /data/log/var/log#chmod -R 777 /data/log/var/log#g' /usr/src/ucrm/scripts/dirs.sh \
    && sed -i 's#chown -R unms:unms /data/log/var/log#chown root:root /data/log/var/log#g' /usr/src/ucrm/scripts/dirs.sh \
    && sed -i 's#rm -rf /var/log#mv /var/log /data/log/var#g' /usr/src/ucrm/scripts/dirs.sh \
    && sed -i 's#LC_CTYPE=C tr -dc "a-zA-Z0-9" < /dev/urandom | fold -w 48 | head -n 1 || true#head /dev/urandom | tr -dc A-Za-z0-9 | head -c 48#g' \
       /usr/src/ucrm/scripts/parameters.sh \
    && sed -i 's#-regex \x27.*Version\[0-9]\\{14\\}#-regextype posix-extended -regex \x27.*Version\[0-9]\{14}#g' \
       /usr/src/ucrm/scripts/database_migrations_ready.sh \
    && sed -i '/\[program:nginx]/,+10d' /tmp/supervisor.d/server.ini \
    && sed -i '/\[program:cron]/,+10d' /tmp/supervisor.d/server.ini \
    && sed -i "s#php-fpm --nodaemonize --force-stderr#bash -c 'exec php-fpm --nodaemonize --force-stderr'#g" /tmp/supervisor.d/server.ini \
    && sed -i "1s#^#POSTGRES_SCHEMA=ucrm\n#" /tmp/crontabs/server \
    && sed -i "1s#^#POSTGRES_DB=unms\n#" /tmp/crontabs/server \
    && sed -i "1s#^#POSTGRES_PASSWORD=ucrm\n#" /tmp/crontabs/server \
    && sed -i "1s#^#POSTGRES_USER=ucrm\n#" /tmp/crontabs/server \
    && sed -i "1s#^#POSTGRES_PORT=5432\n#" /tmp/crontabs/server \
    && sed -i "1s#^#POSTGRES_HOST=127.0.0.1\n#" /tmp/crontabs/server \
    && sed -i "1s#^#PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n#" /tmp/crontabs/server \
    && sed -i "s#\.0#\.crt#g" /usr/src/ucrm/scripts/update-certificates.sh \
    && sed -i "s#http://localhost/%s#http://localhost:9081/%s#g" /usr/src/ucrm/src/AppBundle/Service/LocalUrlGenerator.php \
    && sed -i "s#'localhost', '127.0.0.1'#'localhost:9081', '127.0.0.1:9081'#g" /usr/src/ucrm/src/AppBundle/Util/Helpers.php
# end unms-crm dockerfile #

# ubnt/nginx docker file #
ENV NGINX_UID=1000 \
    NGINX_VERSION=nginx-1.14.2 \
    LUAJIT_VERSION=2.1.0-beta3 \
    LUA_NGINX_VERSION=0.10.13 \
    PHP_VERSION=php-7.3.12

RUN set -x \
    && mkdir -p /tmp/src && cd /tmp/src \
    && wget -q http://nginx.org/download/${NGINX_VERSION}.tar.gz -O nginx.tar.gz \
    && wget -q https://github.com/openresty/lua-nginx-module/archive/v${LUA_NGINX_VERSION}.tar.gz -O lua-nginx-module.tar.gz \
    && wget -q https://github.com/simpl/ngx_devel_kit/archive/v0.3.0.tar.gz -O ndk.tar.gz \
    && wget -q http://luajit.org/download/LuaJIT-${LUAJIT_VERSION}.tar.gz -O luajit.tar.gz \
	&& wget -q https://www.php.net/get/${PHP_VERSION}.tar.xz/from/this/mirror -O php.tar.xz \
    && tar -zxvf lua-nginx-module.tar.gz \
    && tar -zxvf ndk.tar.gz \
    && tar -zxvf luajit.tar.gz \
    && tar -zxvf nginx.tar.gz \
	&& tar -xvf php.tar.xz \
	&& cp php.tar.xz /usr/src \
    && cd /tmp/src/LuaJIT-${LUAJIT_VERSION} && make amalg PREFIX='/usr' && make install PREFIX='/usr' \
    && export LUAJIT_LIB=/usr/lib/libluajit-5.1.so && export LUAJIT_INC=/usr/include/luajit-2.1 \
    && cd /tmp/src/${NGINX_VERSION} && ./configure \
        --with-cc-opt='-g -O2 -fPIE -fstack-protector-strong -Wformat -Werror=format-security -fPIC -Wdate-time -D_FORTIFY_SOURCE=2' \
        --with-ld-opt='-Wl,-Bsymbolic-functions -fPIE -pie -Wl,-z,relro -Wl,-z,now -fPIC' \
        --with-pcre-jit \
        --with-threads \
        --add-module=/tmp/src/lua-nginx-module-${LUA_NGINX_VERSION} \
        --add-module=/tmp/src/ngx_devel_kit-0.3.0 \
        --with-http_ssl_module \
        --with-http_realip_module \
        --with-http_gzip_static_module \
        --with-http_secure_link_module \
        --without-mail_pop3_module \
        --without-mail_imap_module \
        --without-http_upstream_ip_hash_module \
        --without-http_memcached_module \
        --without-http_auth_basic_module \
        --without-http_userid_module \
        --without-http_uwsgi_module \
        --without-http_scgi_module \
        --prefix=/var/lib/nginx \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --http-log-path=/dev/stdout \
        --error-log-path=/dev/stderr \
        --lock-path=/tmp/nginx.lock \
        --pid-path=/tmp/nginx.pid \
        --http-client-body-temp-path=/tmp/body \
        --http-proxy-temp-path=/tmp/proxy \
    && make -j $(nproc) \
    && make install \
    && cd /tmp/src/${PHP_VERSION} && ./configure \
        --with-config-file-path="/usr/local/etc/php" \
        --with-config-file-scan-dir="/usr/local/etc/php/conf.d" \
        --enable-option-checking=fatal \
        --with-mhash \
        --enable-ftp \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-password-argon2 \
        --with-sodium=shared \
        --with-curl \
        --with-libedit \
        --with-openssl \
        --with-zlib \
        --enable-fpm \
        --with-fpm-user=www-data \
        --with-fpm-group=www-data \
        --disable-cgi \
    && make -j $(nproc) \
    && make install \
    && rm /usr/bin/luajit-${LUAJIT_VERSION} \
    && rm -rf /tmp/src \
    && rm -rf /var/cache/apk/* \
    && echo "unms ALL=(ALL) NOPASSWD: /usr/sbin/nginx -s *" >> /etc/sudoers \
    && echo "unms ALL=(ALL) NOPASSWD:SETENV: /refresh-certificate.sh *" >> /etc/sudoers \
    && echo "unms ALL=(ALL) NOPASSWD:SETENV: /refresh-configuration.sh *" >> /etc/sudoers
	
COPY --from=unms-crm /etc/nginx/available-servers /etc/nginx/ucrm

COPY --from=unms-nginx /entrypoint.sh /refresh-certificate.sh /refresh-configuration.sh /openssl.cnf /ip-whitelist.sh /
COPY --from=unms-nginx /templates /templates
COPY --from=unms-nginx /www/public /www/public

RUN chmod +x /entrypoint.sh /refresh-certificate.sh /refresh-configuration.sh /ip-whitelist.sh \
    && sed -i "s#80#9081#g" /etc/nginx/ucrm/ucrm.conf \
    && sed -i "s#81#9082#g" /etc/nginx/ucrm/suspended_service.conf \
    && sed -i '/conf;/a \ \ include /etc/nginx/ucrm/*.conf;' /templates/nginx.conf.template \
    && grep -lR "location /nms/ " /templates | xargs sed -i "s#location /nms/ #location /nms #g" \
    && grep -lR "location /crm/ " /templates | xargs sed -i "s#location /crm/ #location /crm #g" \
    && sed -i "s#\\\.\[0-9]{1,3}#[0-9]#g" /refresh-certificate.sh

# make compatible with debian
RUN sed -i "s#/bin/sh#/bin/bash#g" /entrypoint.sh \
    && sed -i "s#adduser -D#adduser --disabled-password --gecos \"\"#g" /entrypoint.sh
# end ubnt/nginx docker file #

# php & composer
ENV PHP_INI_DIR=/usr/local/etc/php \
    SYMFONY_ENV=prod
	
COPY --from=unms-crm /usr/local/etc/php/php.ini /usr/local/etc/php/
COPY --from=unms-crm /usr/local/etc/php-fpm.conf /usr/local/etc/
COPY --from=unms-crm /usr/local/etc/php-fpm.d /usr/local/etc/php-fpm.d

RUN echo '' | pecl install apcu ds \
    && docker-php-ext-enable apcu ds \
    && docker-php-ext-configure gd \
        --with-gd \
        --with-freetype-dir=/usr/include/ \
        --with-png-dir=/usr/include/ \
        --with-jpeg-dir=/usr/include/ \
    && docker-php-ext-configure curl \
    && docker-php-ext-configure imap \
        --with-imap-ssl \
        --with-kerberos \
    && docker-php-ext-install -j2 pdo_pgsql gmp zip bcmath gd bz2 curl \
      exif intl dom xml opcache imap soap sockets sysvmsg sysvshm sysvsem \
    && curl -sS https://getcomposer.org/installer | php -- \
        --install-dir=/usr/bin --filename=composer \
	&& cd /usr/src/ucrm \
    && composer global require hirak/prestissimo \
    && composer install \
        --classmap-authoritative \
        --no-dev --no-interaction \
    && composer clear-cache \
    && sed -i 's#nginx#unms#g' /usr/local/etc/php-fpm.d/zz-docker.conf
# end php & composer

ENV PATH=/home/app/unms/node_modules/.bin:$PATH:/usr/lib/postgresql/9.6/bin \
  PGDATA=/config/postgres \
  POSTGRES_DB=unms \
  QUIET_MODE=0 \
  WS_PORT=443 \
  PUBLIC_HTTPS_PORT=443 \
  PUBLIC_WS_PORT=443 \
  UNMS_NETFLOW_PORT=2055 \
  SECURE_LINK_SECRET=enigma \
  SSL_CERT=""

EXPOSE 80 443 2055/udp

VOLUME ["/config"]

COPY root /
