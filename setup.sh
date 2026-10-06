#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export GIT_TERMINAL_PROMPT=0
umask 022
SECONDS=0
LAST=0
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE=/opt/magento-native
APP=$STATE/app

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail 'Run as root in a disposable sandbox.'
source /etc/os-release
[[ $ID == debian && $VERSION_ID == 12 ]] || fail 'This script targets Debian 12.'
case $(dpkg --print-architecture) in
    amd64|arm64) ;;
    *) fail 'Only AMD64 and ARM64 are supported.' ;;
esac
command -v docker >/dev/null || fail 'Docker CLI and a running local Linux Docker engine are required.'
[[ $(docker info --format '{{.OSType}}') == linux ]] || fail 'A running local Linux Docker engine is required.'
for name in magento-native-db magento-native-search; do
    if docker container inspect "$name" >/dev/null 2>&1; then fail "Container $name already exists; use a fresh sandbox."; fi
done
[[ ! -e $STATE ]] || fail "$STATE already exists. Use a fresh sandbox; this is not an upgrade script."
mkdir -p "$STATE"/{logs,downloads,run,security}
touch "$STATE/logs/bootstrap.log"
chmod 600 "$STATE/logs/bootstrap.log"
exec > >(tee -a "$STATE/logs/bootstrap.log") 2>&1
printf 'stage\tseconds\n' > "$STATE/timings.tsv"

mark() {
    local now=$SECONDS
    printf '%s\t%d\n' "$1" "$((now - LAST))" | tee -a "$STATE/timings.tsv"
    LAST=$now
}
fetch() { curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 900 --proto '=https' --proto-redir '=https' "$@"; }
wait_for() {
    local label=$1 end=$((SECONDS + 300))
    shift
    until "$@" >/dev/null 2>&1; do
        (( SECONDS < end )) || fail "Timed out waiting for $label. See $STATE/logs."
        sleep 2
    done
}
POLICY_SET=0
restore_policy() {
    if (( POLICY_SET )); then
        rm -f /usr/sbin/policy-rc.d
        if [[ -e $STATE/policy-rc.d.original || -L $STATE/policy-rc.d.original ]]; then
            mv "$STATE/policy-rc.d.original" /usr/sbin/policy-rc.d
        fi
        POLICY_SET=0
    fi
}
DB_STARTED=0
SEARCH_STARTED=0
finish() {
    local rc=$?
    restore_policy
    if (( rc )); then
        if (( DB_STARTED )); then docker logs magento-native-db > "$STATE/logs/database.log" 2>&1 || true; fi
        if (( SEARCH_STARTED )); then docker logs magento-native-search > "$STATE/logs/opensearch.log" 2>&1 || true; fi
        echo "Setup failed. Inspect $STATE/logs; do not treat this lab as ready." >&2
    fi
    exit "$rc"
}
trap finish EXIT
if [[ -e /usr/sbin/policy-rc.d || -L /usr/sbin/policy-rc.d ]]; then
    mv /usr/sbin/policy-rc.d "$STATE/policy-rc.d.original"
fi
POLICY_SET=1
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
apt-get -o APT::Update::Error-Mode=any update -qq
apt-get install -y --no-install-recommends ca-certificates curl gnupg git unzip patch python3 procps util-linux xz-utils
python3 - <<'PY'
import socket
import sys
conflicts = []
for port, service in ((13306, 'MySQL'), (19200, 'OpenSearch HTTP'), (8888, 'nginx')):
    with socket.socket() as sock:
        try:
            sock.bind(('127.0.0.1', port))
        except OSError as error:
            conflicts.append(f'{service}: cannot bind 127.0.0.1:{port}: {error}')
if conflicts:
    sys.exit('\n'.join(conflicts) + '\nPort 8080 is not checked or used by this preflight.')
PY
fetch https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/magento-php.gpg
fetch https://nginx.org/keys/nginx_signing.key -o "$STATE/downloads/nginx.asc"
gpg --batch --yes --dearmor -o /usr/share/keyrings/magento-nginx.gpg "$STATE/downloads/nginx.asc"
chmod 644 /usr/share/keyrings/magento-*.gpg
printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/magento-php.gpg] https://packages.sury.org/php/ bookworm main' \
    'deb [signed-by=/usr/share/keyrings/magento-nginx.gpg] https://nginx.org/packages/debian bookworm nginx' \
    > /etc/apt/sources.list.d/magento-native.list
apt-get -o APT::Update::Error-Mode=any update -qq
apt-get install -y --no-install-recommends \
    php8.5-cli php8.5-fpm php8.5-mysql php8.5-xml php8.5-mbstring php8.5-curl \
    php8.5-zip php8.5-bcmath php8.5-soap php8.5-gd php8.5-intl \
    'nginx=1.30.*'
restore_policy
mark apt_packages

cat > /etc/php/8.5/mods-available/magento-lab.ini <<'INI'
memory_limit=2G
max_execution_time=1800
realpath_cache_size=10M
realpath_cache_ttl=7200
date.timezone=UTC
opcache.validate_timestamps=1
INI
phpenmod -v 8.5 magento-lab
install -d -o www-data -g www-data "$STATE/home"
fetch https://getcomposer.org/download/2.10.0/composer.phar -o "$STATE/downloads/composer.phar"
fetch https://getcomposer.org/download/2.10.0/composer.phar.sha256sum -o "$STATE/downloads/composer.sha256sum"
(cd "$STATE/downloads" && sha256sum -c composer.sha256sum)
docker pull mysql:8.4
docker pull opensearchproject/opensearch:3.1.0
mark tools_and_images

git clone --depth 1 --branch 2.4.9 https://github.com/magento/magento2.git "$APP"
[[ $(git -C "$APP" rev-parse HEAD) == 755e34dd689021c5165db9d35ecff74f7dc51527 ]] || fail 'Unexpected Magento source commit.'
rm -rf "$APP/.git"
chown -R www-data:www-data "$APP"
runuser -u www-data -- env HOME="$STATE/home" COMPOSER_HOME="$STATE/home/.composer" \
    php8.5 "$STATE/downloads/composer.phar" install --working-dir="$APP" --no-dev --prefer-dist --no-interaction --no-progress
runuser -u www-data -- php8.5 "$STATE/downloads/composer.phar" check-platform-reqs --working-dir="$APP" --no-dev
mark source_and_composer
python3 "$HERE/security.py" apply --root "$APP" --output "$STATE/security" --target latest
chown -R www-data:www-data "$APP"
mark adobe_patches

DB_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
ADMIN_PASSWORD=Aa1!$(python3 -c 'import secrets; print(secrets.token_hex(18))')
export DB_PASSWORD ADMIN_PASSWORD
python3 - <<'PY'
import json, os
from pathlib import Path
p = Path('/opt/magento-native/credentials.json')
p.touch(mode=0o600)
p.write_text(json.dumps({'url': 'http://localhost:8888/', 'admin_url': 'http://localhost:8888/admin_local/',
                         'username': 'localadmin', 'password': os.environ['ADMIN_PASSWORD'],
                         'db_password': os.environ['DB_PASSWORD']}, indent=2) + '\n')
PY
(umask 077; printf 'MYSQL_DATABASE=magento\nMYSQL_USER=magento\nMYSQL_PASSWORD=%s\nMYSQL_ROOT_PASSWORD=%s\n' \
    "$DB_PASSWORD" "$(python3 -c 'import secrets; print(secrets.token_hex(24))')" > "$STATE/mysql.env")
docker run -d --name magento-native-db --env-file "$STATE/mysql.env" \
    -p 127.0.0.1:13306:3306 mysql:8.4 --log-bin-trust-function-creators=1
DB_STARTED=1
wait_for MySQL php8.5 -r 'new PDO("mysql:host=127.0.0.1;port=13306;dbname=magento", "magento", getenv("DB_PASSWORD"));'
mark database_start

docker run -d --name magento-native-search --ulimit nofile=65536:65536 \
    -p 127.0.0.1:19200:9200 \
    -e discovery.type=single-node -e node.store.allow_mmap=false \
    -e OPENSEARCH_JAVA_OPTS='-Xms1g -Xmx1g' \
    -e DISABLE_INSTALL_DEMO_CONFIG=true -e DISABLE_SECURITY_PLUGIN=true \
    opensearchproject/opensearch:3.1.0
SEARCH_STARTED=1
wait_for OpenSearch curl -fsS --max-time 10 'http://127.0.0.1:19200/_cluster/health?wait_for_status=yellow&timeout=5s'
mark opensearch_start

cd "$APP"
mage() { runuser -u www-data -- env HOME="$STATE/home" php8.5 "$APP/bin/magento" "$@"; }
mage setup:install --base-url=http://localhost:8888/ --backend-frontname=admin_local \
    --db-host=127.0.0.1:13306 --db-name=magento --db-user=magento --db-password="$DB_PASSWORD" \
    --admin-firstname=Local --admin-lastname=Admin --admin-email=admin@example.test \
    --admin-user=localadmin --admin-password="$ADMIN_PASSWORD" \
    --language=en_US --currency=USD --timezone=UTC --use-rewrites=1 \
    --search-engine=opensearch --opensearch-host=127.0.0.1 --opensearch-port=19200 \
    --opensearch-enable-auth=0 --no-interaction
mage deploy:mode:set developer
for module in Magento_AdminAdobeImsTwoFactorAuth Magento_TwoFactorAuth; do
    if [[ -d $APP/app/code/Magento/${module#Magento_} ]]; then mage module:disable "$module"; fi
done
mage indexer:reindex
mage cache:flush
mark magento_install

cat > "$STATE/php-fpm.conf" <<CONF
[global]
pid = $STATE/run/php-fpm.pid
error_log = $STATE/logs/php-fpm.log
[magento]
user = www-data
group = www-data
listen = $STATE/run/php-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 10s
catch_workers_output = yes
CONF
cat > "$STATE/nginx.conf" <<CONF
user www-data;
worker_processes 1;
pid $STATE/run/nginx.pid;
error_log $STATE/logs/nginx-error.log;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log $STATE/logs/nginx-access.log;
    upstream fastcgi_backend { server unix:$STATE/run/php-fpm.sock; }
    server {
        listen 127.0.0.1:8888;
        server_name localhost;
        set \$MAGE_ROOT $APP;
        set \$MAGE_DEBUG_SHOW_ARGS 0;
        client_max_body_size 64m;
        include $APP/nginx.conf.sample;
    }
}
CONF
ln -s /etc/nginx/fastcgi_params "$STATE/fastcgi_params"
php-fpm8.5 --test --fpm-config "$STATE/php-fpm.conf"
nginx -t -c "$STATE/nginx.conf"
nohup php-fpm8.5 --nodaemonize --fpm-config "$STATE/php-fpm.conf" > "$STATE/logs/fpm-launch.log" 2>&1 < /dev/null &
FPM_PID=$!
nohup nginx -g 'daemon off;' -c "$STATE/nginx.conf" > "$STATE/logs/nginx-launch.log" 2>&1 < /dev/null &
NGINX_PID=$!
storefront_ready() {
    [[ $(curl -sS --max-time 120 -o /dev/null -w '%{http_code}' http://localhost:8888/) == 200 ]]
}
wait_for Storefront storefront_ready
kill -0 "$FPM_PID" "$NGINX_PID"
nohup runuser -u www-data -- bash -c "while true; do php8.5 '$APP/bin/magento' cron:run; sleep 60; done" \
    > "$STATE/logs/cron.log" 2>&1 < /dev/null &
python3 "$HERE/security.py" status --root "$APP" --output "$STATE/security"
mark first_http_response
printf 'total\t%d\n' "$SECONDS" | tee -a "$STATE/timings.tsv"
echo "Ready. Logs: $STATE/logs; timings: $STATE/timings.tsv"
python3 - <<'PY'
import json
from pathlib import Path
p = Path('/opt/magento-native')
result = json.loads((p / 'credentials.json').read_text())
result.pop('db_password')
result['security_level'] = json.loads((p / 'security/receipt.json').read_text())['security_level']
print(json.dumps(result))
PY
