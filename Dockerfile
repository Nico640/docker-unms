FROM --platform=linux/amd64 ubnt/unms:3.0.159 as unms
FROM --platform=linux/amd64 ubnt/unms-nginx:3.0.159 as unms-nginx
FROM --platform=linux/amd64 ubnt/unms-netflow:3.0.159 as unms-netflow
FROM --platform=linux/amd64 ubnt/unms-crm:4.5.33 as unms-crm
FROM --platform=linux/amd64 ubnt/unms-siridb:3.0.159 as unms-siridb
FROM --platform=linux/amd64 ubnt/unms-postgres:3.0.159 as unms-postgres
FROM rabbitmq:3.7.28-alpine as rabbitmq
FROM timescale/timescaledb:2.18.2-pg17 as timescaledb

FROM nico640/s6-alpine-node:20.18.3-3.21
ARG TARGETARCH

# base deps postgres 17, certbot
RUN set -x \
    && apk upgrade --no-cache \
    && apk add --no-cache certbot gzip bash vim dumb-init openssl libcap sudo \
       pcre pcre2 yajl gettext coreutils make argon2-libs jq tar xz \
       libzip gmp icu c-client supervisor libuv su-exec gnu-libiconv git libsodium \
       postgresql17 postgresql17-client postgresql17-contrib libpng libwebp libjpeg-turbo freetype glib

COPY --from=timescaledb /usr/local/lib/postgresql/timescaledb* /usr/lib/postgresql17/
COPY --from=timescaledb /usr/local/share/postgresql/extension/timescaledb* /usr/share/postgresql17/extension/
RUN echo "shared_preload_libraries = 'timescaledb'" >> /usr/share/postgresql17/postgresql.conf.sample

# temporarily include postgres 13 because it is needed for migration from older versions
WORKDIR /postgres/13
RUN cp /etc/apk/repositories /etc/apk/repositories_temp \
    && echo "https://dl-cdn.alpinelinux.org/alpine/v3.19/community" > /etc/apk/repositories \
    && apk fetch --root / --arch ${APK_ARCH} --no-cache -U postgresql13 postgresql13-contrib -o /postgres \
    && mv /etc/apk/repositories_temp /etc/apk/repositories

# start unms #
WORKDIR /home/app/unms

# copy unms app from offical image since the source code is not published at this time
COPY --from=unms /home/app/unms /home/app/unms

ENV LIBVIPS_VERSION=8.14.4

RUN apk add --no-cache --virtual .build-deps python3 g++ glib-dev meson expat-dev gobject-introspection-dev \
    && mkdir -p /tmp/src /home/app/unms/tmp && cd /tmp/src \
    && wget -q https://github.com/libvips/libvips/releases/download/v${LIBVIPS_VERSION}/vips-${LIBVIPS_VERSION}.tar.xz -O libvips.tar.xz \
    && tar -Jxvf libvips.tar.xz \
    && cd /tmp/src/vips-${LIBVIPS_VERSION} && meson setup build \
    && cd build && meson compile && meson install \
    && cd /home/app/unms \
    && mv node_modules/@ubnt/* tmp/ \
    && sed -i 's#"@ubnt/link-core-common": ".*"#"@ubnt/link-core-common": "file:../link-core-common"#g' tmp/link-core/package.json \
    && sed -i 's#"@ubnt/link-core": ".*"#"@ubnt/link-core": "file:./tmp/link-core"#g' package.json \
    && sed -i 's# "sharp": "0.32.4"# "sharp": "0.32.5"#g' package.json \
    && sed -i '$i,"resolutions": { "cheerio": "1.0.0-rc.5" }' package.json \
    && rm -rf node_modules \
    && CHILD_CONCURRENCY=1 yarn install --production --no-cache --ignore-engines --network-timeout 100000 \
    && yarn cache clean \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* tmp /tmp/src \
    && setcap cap_net_raw=pe /usr/local/bin/node	

COPY --from=unms /usr/local/bin/docker-entrypoint.sh /usr/local/bin/api.sh /usr/local/bin/device-ws.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/api.sh /usr/local/bin/device-ws.sh \
    && sed -i "s#=31415#=31416#g" /home/app/unms/device-ws.js
# end unms #

# start unms-netflow #
WORKDIR /home/app/netflow

COPY --from=unms-netflow /home/app /home/app/netflow

RUN rm -rf node_modules \
    && apk add --no-cache --virtual .build-deps python3 g++ \
    && yarn install --frozen-lockfile --production --no-cache --ignore-engines \
    && yarn cache clean \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* \
    && rm -rf .node-gyp
# end unms-netflow #

# start unms-crm #
RUN mkdir -p /usr/src/ucrm \
    && mkdir -p /tmp/crontabs \
    && mkdir -p /usr/local/etc/php/conf.d \
    && mkdir -p /usr/local/etc/php-fpm.d \
    && mkdir -p /tmp/supervisor.d \
    && mkdir -p /tmp/supervisord

COPY --from=unms-crm --chown=911:911 /usr/src/ucrm /usr/src/ucrm
COPY --from=unms-crm --chown=911:911 /data /data
COPY --from=unms-crm /usr/local/bin/crm* /usr/local/bin/
COPY --from=unms-crm /usr/local/bin/docker* /usr/local/bin/
COPY --from=unms-crm /tmp/crontabs/server /tmp/crontabs/server
COPY --from=unms-crm /tmp/supervisor.d /tmp/supervisor.d
COPY --from=unms-crm /tmp/supervisord /tmp/supervisord

RUN grep -lr "nginx:nginx" /usr/src/ucrm/ | xargs sed -i 's/nginx:nginx/unms:unms/g' \
    && grep -lr "su-exec nginx" /usr/src/ucrm/ | xargs sed -i 's/su-exec nginx/su-exec unms/g' \
    && grep -lr "su-exec nginx" /tmp/ | xargs sed -i 's/su-exec nginx/su-exec unms/g' \
    && sed -i "s#unixUser='nginx'#unixUser='unms'#g" /usr/src/ucrm/scripts/unms_ready.sh \
    && sed -i 's#chmod -R 775 /data/log/var/log#chmod -R 777 /data/log/var/log#g' /usr/src/ucrm/scripts/dirs.sh \
    && sed -i 's#rm -rf /var/log#mv /var/log /data/log/var#g' /usr/src/ucrm/scripts/dirs.sh \
    && sed -i 's#LC_CTYPE=C tr -dc "a-zA-Z0-9" < /dev/urandom | fold -w 48 | head -n 1 || true#head /dev/urandom | tr -dc A-Za-z0-9 | head -c 48#g' \
       /usr/src/ucrm/scripts/parameters.sh \
    && sed -i '/\[program:nginx]/,+10d' /tmp/supervisor.d/server.ini \
    && sed -i "s#http://localhost/%s#http://localhost:9081/%s#g" /usr/src/ucrm/src/AppBundle/Service/UrlGenerator/LocalUrlGenerator.php \
    && sed -i "s#'localhost', '127.0.0.1'#'localhost:9081', '127.0.0.1:9081'#g" /usr/src/ucrm/src/AppBundle/Util/Helpers.php \
    && sed -i "s#crm-extra-programs-enabled && run-parts /etc/periodic/daily#run-parts /etc/periodic/daily#g" /tmp/crontabs/server
# end unms-crm #

# start openresty #
ENV OPEN_RESTY_VERSION=openresty-1.25.3.2

WORKDIR /tmp/src

RUN apk add --no-cache --virtual .build-deps gcc g++ pcre-dev openssl-dev zlib-dev perl ccache \
    && export CC="ccache gcc -fdiagnostics-color=always -g3" \
    && curl -SL https://openresty.org/download/${OPEN_RESTY_VERSION}.tar.gz | tar xvz \
    && cd /tmp/src/${OPEN_RESTY_VERSION} && ./configure \
        --prefix="/usr/local/openresty" \
        --with-cc='ccache gcc -fdiagnostics-color=always -g3' \
        --with-cc-opt="-DNGX_LUA_ABORT_AT_PANIC" \
        --with-pcre-jit \
        --without-http_rds_json_module \
        --without-http_rds_csv_module \
        --without-lua_rds_parser \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-http_v2_module \
        --without-mail_pop3_module \
        --without-mail_imap_module \
        --without-mail_smtp_module \
        --with-http_stub_status_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_auth_request_module \
        --with-http_secure_link_module \
        --with-http_random_index_module \
        --with-http_gzip_static_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-threads \
        --with-compat \
        --with-luajit-xcflags='-DLUAJIT_NUMMODE=2 -DLUAJIT_ENABLE_LUA52COMPAT' \
        -j$(nproc) \
    && make -j$(nproc) \
    && make install \
    && apk del .build-deps \
    && rm -rf /tmp/src /var/cache/apk/* \
    && echo "unms ALL=(ALL) NOPASSWD: /usr/local/openresty/nginx/sbin/nginx -s *" >> /etc/sudoers \
    && echo "unms ALL=(ALL) NOPASSWD: /bin/cat *" >> /etc/sudoers \
    && echo "unms ALL=(ALL) NOPASSWD:SETENV: /refresh-configuration.sh *" >> /etc/sudoers

COPY --from=unms-crm /etc/nginx/available-servers /usr/local/openresty/nginx/conf/ucrm
COPY --from=unms-postgres /usr/local/bin/migrate.sh /
COPY --from=unms-nginx /entrypoint.sh /refresh-certificate.sh /refresh-configuration.sh /openssl.cnf /ip-whitelist.sh /
COPY --from=unms-nginx /usr/local/openresty/nginx/templates /usr/local/openresty/nginx/templates
COPY --from=unms-nginx /www/public /www/public

RUN chmod +x /entrypoint.sh /refresh-certificate.sh /refresh-configuration.sh /ip-whitelist.sh /migrate.sh \
    && sed -i 's#NEW_BIN_DIR="/usr/local/bin"#NEW_BIN_DIR="/usr/bin"#g' /migrate.sh \
    && sed -i "s#-c listen_addresses=''#-c listen_addresses='' -p 50432#g" /migrate.sh \
    && sed -i "s#80#9081#g" /usr/local/openresty/nginx/conf/ucrm/ucrm.conf \
    && sed -i "s#81#9082#g" /usr/local/openresty/nginx/conf/ucrm/suspended_service.conf \
    && sed -i '/conf;/a \ \ include /usr/local/openresty/nginx/conf/ucrm/*.conf;' /usr/local/openresty/nginx/templates/nginx.conf.template \
    && grep -lr "location /nms/ " /usr/local/openresty/nginx/templates | xargs sed -i "s#location /nms/ #location /nms #g" \
    && grep -lr "location /crm/ " /usr/local/openresty/nginx/templates | xargs sed -i "s#location /crm/ #location /crm #g"
# end openresty #

# start php #
ENV PHP_VERSION=php-8.1.34

WORKDIR /tmp/src

RUN set -x \
    && apk add --no-cache --virtual .build-deps autoconf dpkg-dev dpkg file g++ gcc libc-dev make pkgconf re2c gnu-libiconv-dev \
       argon2-dev coreutils curl-dev libsodium-dev libxml2-dev linux-headers oniguruma-dev openssl-dev readline-dev sqlite-dev patch \
    && curl -SL https://www.php.net/get/${PHP_VERSION}.tar.xz/from/this/mirror -o php.tar.xz \
    && tar -xvf php.tar.xz \
    && cp php.tar.xz /usr/src \
    && export CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 -Wno-incompatible-pointer-types" \
    && export CPPFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 -Wno-incompatible-pointer-types" \
    && export LDFLAGS="-Wl,-O1 -pie" \
    && cd /tmp/src/${PHP_VERSION} \
    && curl -fL 'https://github.com/php/php-src/commit/577b8ae4226368e66fee7a9b5c58f9e2428372fc.patch?full_index=1' -o 11678.patch \
	&& echo '6edc20c3bb3e7cc13515abce7f2fffa8ebea6cf7469abfbc78fcdc120350b239 *11678.patch' | sha256sum -c - \
	&& patch -p1 < 11678.patch \
	&& rm 11678.patch \
    && sed -i 's/parser->parser->instate != XML_PARSER_ENTITY_VALUE && parser->parser->instate != XML_PARSER_ATTRIBUTE_VALUE/parser->parser->instate == XML_PARSER_CONTENT/' ext/xml/compat.c \
    && ./configure \
        --with-config-file-path="/usr/local/etc/php" \
        --with-config-file-scan-dir="/usr/local/etc/php/conf.d" \
        --enable-option-checking=fatal \
        --with-mhash \
        --with-pic \
        --enable-ftp \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-password-argon2 \
        --with-sodium=shared \
        --with-pdo-sqlite=/usr \
        --with-sqlite3=/usr \ 
        --with-curl \
        --with-iconv=/usr \
        --with-openssl \
        --with-readline \
        --with-zlib \
        --disable-phpdbg \
        --with-pear \
        --disable-cgi \
        --enable-fpm \
        --with-fpm-user=www-data \
        --with-fpm-group=www-data \
        $([ $TARGETARCH = "arm" ] && echo "--host=arm-unknown-linux-musleabihf --disable-opcache-jit") \
    && make -j $(nproc) \
    && make install \
    && apk del .build-deps \
    && rm -rf /tmp/src /var/cache/apk/*
# end php #

# start php plugins / composer #
ENV PHP_INI_DIR=/usr/local/etc/php \
    SYMFONY_ENV=prod

COPY --from=unms-crm /usr/local/etc/php/php.ini /usr/local/etc/php/
COPY --from=unms-crm /usr/local/etc/php-fpm.conf /usr/local/etc/
COPY --from=unms-crm /usr/local/etc/php-fpm.d /usr/local/etc/php-fpm.d

RUN apk add --no-cache --virtual .build-deps autoconf dpkg-dev dpkg file g++ gcc libc-dev make pkgconf re2c \
    bzip2-dev freetype-dev libjpeg-turbo-dev libpng-dev libwebp-dev libzip-dev gmp-dev icu-dev \
    libxml2-dev postgresql17-dev \
    && docker-php-source extract \
    && cd /usr/src/php \
    && pecl channel-update pecl.php.net \
    && echo '' | pecl install apcu ds \
    && docker-php-ext-enable apcu ds sodium \
    && docker-php-ext-configure gd \
        --enable-gd \
        --with-freetype=/usr/include/ \
        --with-webp=/usr/include/ \
        --with-jpeg=/usr/include/ \
    && docker-php-ext-install -j$(nproc) bcmath bz2 exif gd gmp intl opcache \
       pdo_pgsql soap sockets sysvmsg sysvsem sysvshm zip \
    && curl -sS https://getcomposer.org/installer | php -- \
        --install-dir=/usr/bin --filename=composer \
    && cd /usr/src/ucrm \
    && composer install \
        --classmap-authoritative \
        --no-dev --no-interaction \
    && app/console assets:install --symlink web \
    && composer clear-cache \
    && rm /usr/bin/composer \
    && docker-php-source delete \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* \
    && sed -i 's#nginx#unms#g' /usr/local/etc/php-fpm.d/zz-docker.conf
# end php plugins / composer #

# start siridb #
COPY --from=unms-siridb /etc/siridb/siridb.conf /etc/siridb/siridb.conf

ENV SIRIDB_VERSION=2.0.53

RUN set -x \
    && [ $TARGETARCH = "arm" ] && export LIBCLERI_VERSION=0.12.2 || export LIBCLERI_VERSION=1.0.2 \
    && apk add --no-cache --virtual .build-deps gcc make libuv-dev musl-dev pcre2-dev yajl-dev util-linux-dev \
    && mkdir -p /tmp/src && cd /tmp/src \
    && curl -SL https://github.com/cesbit/libcleri/archive/$([[ $LIBCLERI_VERSION != 0* ]] && echo "v" )${LIBCLERI_VERSION}.tar.gz | tar xvz \
    && curl -SL https://github.com/siridb/siridb-server/archive/${SIRIDB_VERSION}.tar.gz | tar xvz \
    && cd /tmp/src/libcleri-${LIBCLERI_VERSION}/Release \
    && make all -j $(nproc) && make install \
    && cd /tmp/src/siridb-server-${SIRIDB_VERSION}/Release \
    && make clean && make -j $(nproc) && make install \
    && apk del .build-deps \
    && rm -rf /tmp/src \
    && rm -rf /var/cache/apk/*
# end siridb #

# start rabbitmq #
COPY --from=rabbitmq /var/lib/rabbitmq/ /var/lib/rabbitmq/
COPY --from=rabbitmq /etc/rabbitmq/ /etc/rabbitmq/
COPY --from=rabbitmq /opt/rabbitmq/ /opt/rabbitmq/
COPY --from=rabbitmq /usr/local/lib/erlang/ /usr/local/lib/erlang/
COPY --from=rabbitmq /usr/local/bin/ct_run /usr/local/bin/dialyzer /usr/local/bin/e* /usr/local/bin/run_erl /usr/local/bin/t* /usr/local/bin/
# end rabbitmq #

WORKDIR /home/app/unms

ENV PATH=$PATH:/home/app/unms/node_modules/.bin:/opt/rabbitmq/sbin:/usr/local/openresty/bin \
    QUIET_MODE=0 \
    PUBLIC_HTTPS_PORT=443 \
    PUBLIC_WS_PORT=443 \
    HTTP_PORT=80 \
    HTTPS_PORT=443

EXPOSE 80 443 2055/udp

VOLUME ["/config"]

COPY root /
