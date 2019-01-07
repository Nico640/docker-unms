# Multi-stage build - See https://docs.docker.com/engine/userguide/eng-image/multistage-build
FROM ubnt/unms:0.14.4 as unms
FROM ubnt/unms-netflow:0.14.4 as unms-netflow
FROM oznu/s6-node:10.15.1-debian-amd64

ENV DEBIAN_FRONTEND=noninteractive

# base deps redis, rabbitmq, postgres 9.6
RUN set -x \
  && echo "deb http://ftp.debian.org/debian stretch-backports main" >> /etc/apt/sources.list \
  && apt-get update \
  && mkdir -p /usr/share/man/man1 /usr/share/man/man7 \
  && mkdir -p /usr/share/man/man7 \
  && apt-get install -y build-essential rabbitmq-server redis-server \
    postgresql-9.6 postgresql-contrib-9.6 postgresql-client-9.6 libpq-dev \
    gzip bash vim openssl libcap-dev dumb-init sudo gettext zlibc zlib1g zlib1g-dev \
    iproute2 netcat wget libpcre3 libpcre3-dev libssl-dev git \
  && apt-get install -y certbot -t stretch-backports

# start ubnt/unms dockerfile #
RUN mkdir -p /home/app/unms

WORKDIR /home/app/unms

# Copy UNMS app from offical image since the source code is not published at this time
COPY --from=unms /home/app/unms /home/app/unms

RUN rm -rf node_modules \
    && JOBS=$(nproc) npm install sharp@latest \
    && JOBS=$(nproc) npm install --production \
    && JOBS=$(nproc) npm install npm \
    && mkdir -p -m 777 "$HOME/unms/public/site-images" \
    && mkdir -p -m 777 "$HOME/unms/data/config-backups" \
    && mkdir -p -m 777 "$HOME/unms/data/unms-backups" \
    && mkdir -p -m 777 "$HOME/unms/data/import"

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

# ubnt/nginx docker file #
ENV NGINX_UID=1000 \
    NGINX_VERSION=nginx-1.14.2 \
    LUAJIT_VERSION=2.1.0-beta3 \
    LUA_NGINX_VERSION=0.10.13

RUN set -x \
    && mkdir -p /tmp/src && cd /tmp/src \
    && wget -q http://nginx.org/download/${NGINX_VERSION}.tar.gz -O nginx.tar.gz \
    && wget -q https://github.com/openresty/lua-nginx-module/archive/v${LUA_NGINX_VERSION}.tar.gz -O lua-nginx-module.tar.gz \
    && wget -q https://github.com/simpl/ngx_devel_kit/archive/v0.3.0.tar.gz -O ndk.tar.gz \
    && wget -q http://luajit.org/download/LuaJIT-${LUAJIT_VERSION}.tar.gz -O luajit.tar.gz \
    && tar -zxvf lua-nginx-module.tar.gz \
    && tar -zxvf ndk.tar.gz \
    && tar -zxvf luajit.tar.gz \
    && tar -zxvf nginx.tar.gz \
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
        --without-http_fastcgi_module \
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
    && rm /usr/bin/luajit-${LUAJIT_VERSION} \
    && rm -rf /tmp/src \
    && rm -rf /var/cache/apk/* \
    && echo "unms ALL=(ALL) NOPASSWD: /usr/sbin/nginx -s *" >> /etc/sudoers \
    && echo "unms ALL=(ALL) NOPASSWD:SETENV: /copy-user-certs.sh reload" >> /etc/sudoers
    && echo "unms ALL=(ALL) NOPASSWD:SETENV: /refresh-certificate.sh *" >> /etc/sudoers

ADD https://github.com/Ubiquiti-App/UNMS/archive/v0.14.4.tar.gz /tmp/unms.tar.gz

RUN cd /tmp \
    && tar -xzf unms.tar.gz \
    && cd UNMS-*/src/nginx \
    && cp entrypoint.sh refresh-certificate.sh refresh-configuration.sh openssl.cnf ip-whitelist.sh / \
    && cp -R templates /templates \
    && mkdir -p /www/public \
    && cp -R public /www/ \
    && chmod +x /entrypoint.sh /refresh-certificate.sh /refresh-configuration.sh /ip-whitelist.sh

# make compatible with debian
RUN sed -i "s#/bin/sh#/bin/bash#g" /entrypoint.sh \
  && sed -i "s#adduser -D#adduser --disabled-password --gecos \"\"#g" /entrypoint.sh
# end ubnt/nginx docker file #

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
