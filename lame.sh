#!/bin/bash
# lamp.sh v4.0.0 — Установка LAMP/LEMP на Debian 12
# Репозиторий: https://github.com/saym101/-LAMP-Apache-Angie-PHP-/
# Лицензия: MIT

readonly SCRIPT_VERSION="4.0.0"
readonly PHP_VER="8.3"
readonly SITE_ROOT="/var/www/html"
readonly BACKUP_DIR="/backups/web-lamp"
readonly STATE_DIR="/var/lib/lamp-setup"
readonly CREDS_FILE="/root/mariadb_credentials.txt"
readonly CERTBOT_CRON_FILE="/root/certbot_cron.txt"
readonly LOG_FILE="${PWD}/lamp_$(date +%Y-%m-%d).log"
readonly TPL_URL="https://raw.githubusercontent.com/saym101/-LAMP-Apache-Angie-PHP-/main/templates/index.html.tpl"

declare -A colors=(
    [r]=$(tput setaf 1) [g]=$(tput setaf 2) [y]=$(tput setaf 3)
    [c]=$(tput setaf 6) [b]=$(tput bold)    [x]=$(tput sgr0)
)

HAS_APACHE=false; HAS_ANGIE=false; HAS_PHP=false; HAS_MARIADB=false

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee >(sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE")) 2>&1

# ============================================================
# Утилиты
# ============================================================

log_msg() { local l="$1"; shift; echo "${colors[$l]}$*${colors[x]}" >&2; }

confirm() {
    local msg="$1" default="${2:-n}" answer
    while true; do
        read -r -p "${msg} [${default,,}] " answer
        answer="${answer,,}"; [[ -z "$answer" ]] && answer="${default,,}"
        [[ "$answer" =~ ^(y|n)$ ]] && break
        log_msg r "Введите 'y' или 'n'."
    done
    [[ "$answer" == "y" ]]
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

ensure_package() {
    local pkg="$1"
    pkg_installed "$pkg" && return 0
    log_msg c "Установка $pkg..."
    apt-get install -y "$pkg" >/dev/null 2>&1 || { log_msg r "Не удалось установить $pkg"; return 1; }
}

get_public_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || hostname -I | awk '{print $1}'
}

# ============================================================
# Состояние системы
# ============================================================

detect_state() {
    HAS_APACHE=false; HAS_ANGIE=false; HAS_PHP=false; HAS_MARIADB=false
    pkg_installed apache2             && HAS_APACHE=true
    pkg_installed angie               && HAS_ANGIE=true
    pkg_installed "php${PHP_VER}-fpm" && HAS_PHP=true
    pkg_installed mariadb-server      && HAS_MARIADB=true
}

# ============================================================
# Базовые зависимости
# ============================================================

setup_base() {
    log_msg g "=== Проверка зависимостей ==="
    apt-get update -qq >/dev/null 2>&1
    for pkg in curl mc wget gnupg ca-certificates lsb-release whiptail; do
        ensure_package "$pkg" || return 1
    done
    mkdir -p "$STATE_DIR" "$BACKUP_DIR"
    # mc: подсветка синтаксиса для неизвестных файлов
    [ -f /usr/share/mc/syntax/sh.syntax ] && cp /usr/share/mc/syntax/sh.syntax /usr/share/mc/syntax/unknown.syntax 2>/dev/null
}

# ============================================================
# PHP 8.3
# ============================================================

setup_php() {
    if pkg_installed "php${PHP_VER}-fpm"; then
        log_msg y "PHP ${PHP_VER} уже установлен"; return 0
    fi
    log_msg g "=== Установка PHP ${PHP_VER} ==="

    if [ ! -f /etc/apt/sources.list.d/php.list ]; then
        mkdir -p /usr/share/keyrings
        curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg \
            https://packages.sury.org/php/apt.gpg 2>/dev/null \
            || { log_msg r "Ошибка загрузки ключа Sury"; return 1; }
        echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bookworm main" \
            > /etc/apt/sources.list.d/php.list
        apt-get update -qq >/dev/null 2>&1
    fi

    # Модули под WordPress / DLE + imagick
    local modules="php${PHP_VER}-fpm php${PHP_VER}-common php${PHP_VER}-mysql php${PHP_VER}-xml \
php${PHP_VER}-curl php${PHP_VER}-gd php${PHP_VER}-mbstring php${PHP_VER}-zip \
php${PHP_VER}-intl php${PHP_VER}-bcmath php${PHP_VER}-imagick"

    log_msg c "Устанавливаю модули PHP..."
    # shellcheck disable=SC2086
    apt-get install -y $modules >/dev/null 2>&1 || { log_msg r "Ошибка установки PHP"; return 1; }

    local ini="/etc/php/${PHP_VER}/fpm/php.ini"
    if [ -f "$ini" ]; then
        sed -i 's/^expose_php\s*=\s*On/expose_php = Off/'          "$ini"
        sed -i 's/^;cgi\.fix_pathinfo\s*=\s*1/cgi.fix_pathinfo=0/' "$ini"
    fi

    systemctl enable  "php${PHP_VER}-fpm" >/dev/null 2>&1
    systemctl restart "php${PHP_VER}-fpm" >/dev/null 2>&1
    log_msg g "PHP ${PHP_VER} установлен"
}

configure_socket() {
    local server="$1"
    local pool="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
    [ -f "$pool" ] || return 0
    sed -i 's/^listen\.owner\s*=.*/listen.owner = www-data/' "$pool"
    sed -i 's/^listen\.group\s*=.*/listen.group = www-data/' "$pool"
    sed -i 's/^listen\.mode\s*=.*/listen.mode = 0660/'       "$pool"
    if [[ "$server" == "angie" ]] && id angie &>/dev/null; then
        groups angie | grep -qw www-data || usermod -a -G www-data angie 2>/dev/null
    fi
    systemctl restart "php${PHP_VER}-fpm" >/dev/null 2>&1
}

# ============================================================
# Angie
# ============================================================

setup_angie() {
    pkg_installed angie && { log_msg y "Angie уже установлен"; return 0; }
    log_msg g "=== Установка Angie ==="
    mkdir -p /usr/share/keyrings
    curl -sSLo /usr/share/keyrings/angie-archive-keyring.gpg \
        https://angie.software/keys/angie-signing.gpg 2>/dev/null \
        || { log_msg r "Ошибка загрузки ключа Angie"; return 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "deb [signed-by=/usr/share/keyrings/angie-archive-keyring.gpg] \
https://download.angie.software/angie/${ID}/${VERSION_ID} ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/angie.list
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y angie >/dev/null 2>&1 || { log_msg r "Ошибка установки Angie"; return 1; }
    systemctl enable angie >/dev/null 2>&1
    log_msg g "Angie установлен"
}

remove_angie() {
    log_msg y "=== Удаление Angie ==="
    systemctl stop angie 2>/dev/null; systemctl disable angie 2>/dev/null
    apt-get purge -y angie >/dev/null 2>&1; apt-get autoremove -y >/dev/null 2>&1
    rm -f /etc/apt/sources.list.d/angie.list /usr/share/keyrings/angie-archive-keyring.gpg
    log_msg g "Angie удалён"
}

configure_angie_vhost() {
    mkdir -p /etc/angie/http.d
    cat > /etc/angie/http.d/default.conf <<CONF
server {
    listen 80 default_server;
    server_name _;
    root ${SITE_ROOT};
    index index.php index.html index.htm;
    server_tokens off;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / { try_files \$uri \$uri/ =404; }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    location ~ /\.ht { deny all; }
}
CONF
    angie -t >/dev/null 2>&1 || { log_msg r "Ошибка конфига Angie:"; angie -t; return 1; }
    systemctl reload-or-restart angie >/dev/null 2>&1
}

configure_angie_ssl_vhost() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/${domain}"
    [ -f "${cert_path}/fullchain.pem" ] || { log_msg r "Сертификат не найден: ${cert_path}"; return 1; }
    mkdir -p /etc/angie/http.d
    cat > /etc/angie/http.d/default.conf <<CONF
server {
    listen 80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl default_server;
    server_name _;
    root ${SITE_ROOT};
    index index.php index.html index.htm;
    server_tokens off;
    ssl_certificate     ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location / { try_files \$uri \$uri/ =404; }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    location ~ /\.ht { deny all; }
}
CONF
    angie -t >/dev/null 2>&1 || { log_msg r "Ошибка SSL-конфига Angie:"; angie -t; return 1; }
    systemctl reload-or-restart angie >/dev/null 2>&1
    log_msg g "SSL-конфиг Angie обновлён"
}

# ============================================================
# Apache
# ============================================================

setup_apache() {
    pkg_installed apache2 && { log_msg y "Apache уже установлен"; return 0; }
    log_msg g "=== Установка Apache ==="
    apt-get install -y apache2 >/dev/null 2>&1 || { log_msg r "Ошибка установки Apache"; return 1; }
    systemctl enable apache2 >/dev/null 2>&1
    log_msg g "Apache установлен"
}

remove_apache() {
    log_msg y "=== Удаление Apache ==="
    systemctl stop apache2 2>/dev/null; systemctl disable apache2 2>/dev/null
    apt-get purge -y apache2 apache2-bin apache2-data apache2-utils >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
    log_msg g "Apache удалён"
}

configure_apache_vhost() {
    a2enmod proxy proxy_fcgi setenvif >/dev/null 2>&1
    cat > /etc/apache2/sites-available/000-default.conf <<CONF
<VirtualHost *:80>
    ServerName localhost
    DocumentRoot ${SITE_ROOT}
    <Directory ${SITE_ROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    <FilesMatch \.php\$>
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost"
    </FilesMatch>
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
CONF
    apache2ctl configtest >/dev/null 2>&1 || { log_msg r "Ошибка конфига Apache:"; apache2ctl configtest; return 1; }
    systemctl restart apache2 >/dev/null 2>&1
}

configure_apache_ssl() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/${domain}"
    a2enmod ssl rewrite >/dev/null 2>&1
    cat > /etc/apache2/sites-available/000-default.conf <<CONF
<VirtualHost *:80>
    ServerName ${domain}
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}\$1 [R=301,L]
</VirtualHost>
CONF
    cat > /etc/apache2/sites-available/000-default-ssl.conf <<CONF
<VirtualHost *:443>
    ServerName ${domain}
    DocumentRoot ${SITE_ROOT}
    SSLEngine on
    SSLCertificateFile    ${cert_path}/fullchain.pem
    SSLCertificateKeyFile ${cert_path}/privkey.pem
    <Directory ${SITE_ROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    <FilesMatch \.php\$>
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost"
    </FilesMatch>
    ErrorLog \${APACHE_LOG_DIR}/ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/ssl_access.log combined
</VirtualHost>
CONF
    a2ensite 000-default-ssl >/dev/null 2>&1
    apache2ctl configtest >/dev/null 2>&1 && systemctl restart apache2 >/dev/null 2>&1
    log_msg g "Apache SSL-конфиг обновлён"
}

# ============================================================
# MariaDB
# ============================================================

setup_mariadb() {
    if pkg_installed mariadb-server; then
        log_msg y "MariaDB уже установлена"; return 0
    fi
    log_msg g "=== Установка MariaDB ==="
    apt-get install -y mariadb-server >/dev/null 2>&1 || { log_msg r "Ошибка установки MariaDB"; return 1; }
    systemctl enable mariadb >/dev/null 2>&1
    systemctl start  mariadb >/dev/null 2>&1

    # Пароль: только буквы и цифры, 20 символов
    local root_pass
    root_pass=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)

    mysql -u root <<SQL 2>/dev/null
ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_pass}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

    mkdir -p /root
    cat > "$CREDS_FILE" <<EOF
MariaDB root credentials
Установлено: $(date "+%Y-%m-%d %H:%M:%S")
Host:     localhost
User:     root
Password: ${root_pass}
Строка:   mysql -u root -p'${root_pass}'
EOF
    chmod 600 "$CREDS_FILE"

    echo ""
    log_msg g "╔══════════════════════════════════════════╗"
    log_msg g "  MariaDB установлена"
    log_msg g "  root пароль: ${colors[y]}${root_pass}${colors[g]}"
    log_msg g "  Сохранено:   $CREDS_FILE"
    log_msg g "╚══════════════════════════════════════════╝"
    log_msg r "⚠  Сохраните пароль в надёжном месте!"
    echo ""
}

# ============================================================
# Бэкап конфигурации
# ============================================================

backup_config() {
    local server="$1"
    local ts; ts=$(date +%Y-%m-%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/lamp_${server}_${ts}.tar.gz"
    mkdir -p "$BACKUP_DIR"
    local conf_dir
    [[ "$server" == "apache" ]] && conf_dir="/etc/apache2" || conf_dir="/etc/angie"
    if [ -d "$conf_dir" ]; then
        tar -czf "$backup_file" "$conf_dir" 2>/dev/null \
            && log_msg g "Бэкап сохранён: $backup_file" \
            || log_msg y "Предупреждение: бэкап создан с ошибками"
    else
        log_msg y "Директория $conf_dir не найдена, бэкап пропущен"
    fi
}

# ============================================================
# UFW
# ============================================================

open_ufw_ports() {
    command -v ufw &>/dev/null || return 0
    ufw status 2>/dev/null | grep -q "Status: active" || return 0
    echo ""
    if confirm "Открыть порт 80 (HTTP) в UFW?" "y"; then
        ufw allow 80/tcp >/dev/null 2>&1 && log_msg g "Порт 80 открыт"
    fi
    if confirm "Открыть порт 443 (HTTPS) в UFW?" "y"; then
        ufw allow 443/tcp >/dev/null 2>&1 && log_msg g "Порт 443 открыт"
    fi
}

# ============================================================
# Certbot
# ============================================================

setup_certbot() {
    detect_state
    if ! $HAS_APACHE && ! $HAS_ANGIE; then
        log_msg r "Сначала установите веб-сервер (пункт 1 или 2)"; return 1
    fi
    local active_server
    $HAS_APACHE && active_server="apache" || active_server="angie"

    log_msg g "=== Установка Certbot ==="
    ensure_package certbot || return 1
    [[ "$active_server" == "apache" ]] && { ensure_package python3-certbot-apache || return 1; }

    echo ""
    echo "${colors[b]}Выберите тип сертификата:${colors[x]}"
    echo "  1) По IP-адресу        (срок: 6 дней — нужно автообновление)"
    echo "  2) По домену/поддомену (срок: 45/90 дней)"
    echo "  0) Отмена"
    echo ""
    read -r -p "Ваш выбор: " ssl_choice
    case "$ssl_choice" in
        1) _certbot_ip     "$active_server" ;;
        2) _certbot_domain "$active_server" ;;
        0) return 0 ;;
        *) log_msg r "Неверный выбор"; return 1 ;;
    esac
}

_certbot_ip() {
    local server="$1"
    local pub_ip; pub_ip=$(get_public_ip)
    echo ""
    log_msg c "Публичный IP: ${pub_ip}"
    read -r -p "Введите IP (Enter = ${pub_ip}): " input_ip
    [[ -z "$input_ip" ]] && input_ip="$pub_ip"

    log_msg y "Для проверки HTTP-01 порт 80 должен быть открыт снаружи"
    log_msg g "Получаю сертификат для IP: ${input_ip}"

    local svc; [[ "$server" == "apache" ]] && svc="apache2" || svc="angie"
    systemctl stop "$svc" 2>/dev/null

    certbot certonly \
        --standalone \
        --preferred-challenges http-01 \
        --profile shortlived \
        --agree-tos \
        --register-unsafely-without-email \
        -d "$input_ip"
    local ret=$?
    systemctl start "$svc" >/dev/null 2>&1

    [ $ret -ne 0 ] && { log_msg r "Certbot завершился с ошибкой (код $ret)"; return 1; }

    if [[ "$server" == "angie" ]]; then
        configure_angie_ssl_vhost "$input_ip" || return 1
    else
        configure_apache_ssl "$input_ip" || return 1
    fi

    # Каждые 4 дня — с запасом для 6-дневного срока
    local cron_line="0 3 */4 * * certbot renew --quiet --post-hook \"systemctl reload ${svc}\""
    _save_certbot_cron "$cron_line" "IP / 6 дней" "$input_ip"
    open_ufw_ports
}

_certbot_domain() {
    local server="$1"
    echo ""
    read -r -p "Введите домен или поддомен (например: sub.example.com): " domain
    [[ -z "$domain" ]] && { log_msg r "Домен не введён"; return 1; }
    read -r -p "Email для уведомлений Let's Encrypt: " le_email
    [[ -z "$le_email" ]] && { log_msg r "Email не введён"; return 1; }

    local svc; [[ "$server" == "apache" ]] && svc="apache2" || svc="angie"
    local ret=0

    if [[ "$server" == "apache" ]]; then
        certbot --apache --agree-tos --email "$le_email" --non-interactive --redirect -d "$domain"
        ret=$?
    else
        certbot certonly --webroot -w "$SITE_ROOT" \
            --agree-tos --email "$le_email" --non-interactive -d "$domain"
        ret=$?
        [ $ret -eq 0 ] && configure_angie_ssl_vhost "$domain"
    fi

    [ $ret -ne 0 ] && { log_msg r "Certbot завершился с ошибкой (код $ret)"; return 1; }

    # Стандартный: дважды в сутки
    local cron_line="0 0,12 * * * certbot renew --quiet --post-hook \"systemctl reload ${svc}\""
    _save_certbot_cron "$cron_line" "домен / 45-90 дней" "$domain"
    open_ufw_ports
}

_save_certbot_cron() {
    local cron_line="$1" cert_type="$2" target="$3"
    cat >> "$CERTBOT_CRON_FILE" <<EOF

# Certbot автообновление | Тип: ${cert_type} | Цель: ${target}
# Добавлено: $(date "+%Y-%m-%d %H:%M:%S")
${cron_line}
EOF
    echo ""
    log_msg g "══════════════════════════════════════════════════"
    log_msg g "  SSL получен!  Тип: ${cert_type}  →  ${target}"
    echo ""
    log_msg b "  Добавьте строку в cron (crontab -e):"
    echo ""
    echo "  ${colors[y]}${cron_line}${colors[x]}"
    echo ""
    log_msg c "  Сохранено в: $CERTBOT_CRON_FILE"
    log_msg g "══════════════════════════════════════════════════"
    echo ""
}

# ============================================================
# Тестовые файлы
# ============================================================

_get_phpinfo_name() {
    local name_file="${STATE_DIR}/phpinfo_name"
    if [ -f "$name_file" ]; then
        cat "$name_file"
    else
        local name; name=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 16)
        echo "$name" > "$name_file"
        echo "$name"
    fi
}

deploy_test() {
    mkdir -p "$SITE_ROOT"
    chown -R www-data:www-data "$SITE_ROOT"
    chmod 755 "$SITE_ROOT"
    _deploy_index_html
    _deploy_phpinfo
    chown www-data:www-data "${SITE_ROOT}/index.html"
    chmod 644 "${SITE_ROOT}/index.html"
    echo ""
    log_msg r "╔══════════════════════════════════════════════╗"
    log_msg r "  ⚠  Тестовые файлы содержат данные о системе."
    log_msg r "     Удалите их после проверки!"
    log_msg r "     Меню → «Удалить тестовые файлы»"
    log_msg r "╚══════════════════════════════════════════════╝"
    echo ""
}

_deploy_index_html() {
    detect_state
    local ws_name ws_class php_name php_class php_link
    local site_domain; site_domain=$(hostname -f 2>/dev/null || echo "localhost")

    $HAS_APACHE && { ws_name="Apache"; ws_class="status-ok"; }
    $HAS_ANGIE  && { ws_name="Angie";  ws_class="status-ok"; }
    [[ -z "$ws_name" ]] && { ws_name="unknown"; ws_class="status-no"; }

    if $HAS_PHP; then
        local phpinfo_name; phpinfo_name=$(_get_phpinfo_name)
        php_name="PHP ${PHP_VER} ✅"; php_class="status-ok"
        php_link="<p><a href=\"/${phpinfo_name}.php\">🔍 PHP Info</a></p>"
    else
        php_name="не установлен"; php_class="status-no"; php_link=""
    fi

    local tpl_file; tpl_file=$(mktemp /tmp/lamp_tpl.XXXXXX)
    if curl -sSLf --max-time 10 -o "$tpl_file" "$TPL_URL" 2>/dev/null && [ -s "$tpl_file" ]; then
        log_msg c "Шаблон загружен с GitHub"
    else
        log_msg y "GitHub недоступен — встроенный шаблон"
        cat > "$tpl_file" <<'FALLBACK'
<!DOCTYPE html>
<html lang="ru">
<head><meta charset="UTF-8"><title>LAMP/LEMP Test</title>
<style>
  body{font-family:system-ui,sans-serif;max-width:800px;margin:2rem auto;padding:0 1rem}
  h1{color:#2e7d32;text-align:center}.info{background:#f5f5f5;padding:1rem;border-radius:4px;margin:1rem 0}
  .status-ok{color:#2e7d32;font-weight:bold}.status-no{color:#c62828;font-weight:bold}a{color:#1976d2}
</style></head>
<body>
  <h1>✅ Веб-сервер работает</h1>
  <div class="info">
    <p><strong>Корень:</strong> {{SITE_ROOT}}</p>
    <p><strong>Домен:</strong> {{SITE_DOMAIN}}</p>
    <p><strong>Сервер:</strong> <span class="{{WEB_SERVER_CLASS}}">{{WEB_SERVER_NAME}}</span></p>
    <p><strong>PHP:</strong> <span class="{{PHP_CLASS}}">{{PHP_NAME}}</span></p>
  </div>
  {{PHP_LINK}}
  <p><small>lamp.sh v{{SCRIPT_VERSION}}</small></p>
</body></html>
FALLBACK
    fi

    sed \
        -e "s|{{SITE_ROOT}}|${SITE_ROOT}|g"           \
        -e "s|{{SITE_DOMAIN}}|${site_domain}|g"       \
        -e "s|{{WEB_SERVER_CLASS}}|${ws_class}|g"     \
        -e "s|{{WEB_SERVER_NAME}}|${ws_name}|g"       \
        -e "s|{{PHP_CLASS}}|${php_class}|g"           \
        -e "s|{{PHP_NAME}}|${php_name}|g"             \
        -e "s|{{PHP_LINK}}|${php_link}|g"             \
        -e "s|{{SCRIPT_VERSION}}|${SCRIPT_VERSION}|g" \
        "$tpl_file" > "${SITE_ROOT}/index.html"
    rm -f "$tpl_file"
}

_deploy_phpinfo() {
    local phpinfo_name; phpinfo_name=$(_get_phpinfo_name)
    cat > "${SITE_ROOT}/${phpinfo_name}.php" <<'PHPEOF'
<?php phpinfo();
PHPEOF
    chown www-data:www-data "${SITE_ROOT}/${phpinfo_name}.php"
    chmod 644 "${SITE_ROOT}/${phpinfo_name}.php"
    log_msg g "Тестовые файлы: $SITE_ROOT"
    log_msg c "phpinfo URL:    http://$(get_public_ip)/${phpinfo_name}.php"
}

remove_test_files() {
    local removed=0
    [ -f "${SITE_ROOT}/index.html" ] && { rm -f "${SITE_ROOT}/index.html"; ((removed++)); }
    local name_file="${STATE_DIR}/phpinfo_name"
    if [ -f "$name_file" ]; then
        local phpinfo_name; phpinfo_name=$(cat "$name_file")
        [ -f "${SITE_ROOT}/${phpinfo_name}.php" ] && {
            rm -f "${SITE_ROOT}/${phpinfo_name}.php"
            rm -f "$name_file"
            ((removed++))
        }
    fi
    [ $removed -gt 0 ] && log_msg g "Удалено файлов: $removed" \
                       || log_msg y "Тестовые файлы не найдены"
}

test_files_exist() {
    local name_file="${STATE_DIR}/phpinfo_name"
    [ -f "${SITE_ROOT}/index.html" ] || \
    { [ -f "$name_file" ] && [ -f "${SITE_ROOT}/$(cat "$name_file").php" ]; }
}

# ============================================================
# Установка веб-сервера
# ============================================================

install_webserver() {
    local target="$1"
    detect_state

    if [[ "$target" == "angie" ]] && $HAS_APACHE; then
        log_msg y "⚠  Обнаружен Apache — будет удалён и заменён на Angie."
        confirm "Продолжить?" "n" || return 0
        backup_config "apache"; remove_apache
    fi
    if [[ "$target" == "apache" ]] && $HAS_ANGIE; then
        log_msg y "⚠  Обнаружен Angie — будет удалён и заменён на Apache."
        confirm "Продолжить?" "n" || return 0
        backup_config "angie"; remove_angie
    fi

    [[ "$target" == "angie"  ]] && $HAS_ANGIE  && { log_msg y "Angie уже установлен";  return 0; }
    [[ "$target" == "apache" ]] && $HAS_APACHE && { log_msg y "Apache уже установлен"; return 0; }

    if [[ "$target" == "angie" ]]; then
        setup_angie              || return 1
        setup_php                || return 1
        configure_angie_vhost    || return 1
        configure_socket "angie" || return 1
        # Перезапуск после PHP — сокет появляется уже после старта Angie
        log_msg c "Перезапуск Angie для подключения PHP-FPM..."
        systemctl restart angie >/dev/null 2>&1
    else
        setup_apache               || return 1
        setup_php                  || return 1
        configure_apache_vhost     || return 1
        configure_socket "apache"  || return 1
    fi
    deploy_test
    open_ufw_ports
}

# ============================================================
# Смена веб-сервера
# ============================================================

switch_webserver() {
    detect_state
    if ! $HAS_APACHE && ! $HAS_ANGIE; then
        log_msg y "Нет установленного веб-сервера"; return 0
    fi

    local from_server to_server
    $HAS_APACHE && { from_server="apache"; to_server="Angie";  }
    $HAS_ANGIE  && { from_server="angie";  to_server="Apache"; }

    log_msg g "Замена: ${from_server^} → ${to_server}"
    confirm "Создать бэкап и выполнить замену?" "y" || return 0

    backup_config "$from_server"

    if $HAS_APACHE; then
        remove_apache
        setup_angie              || return 1
        setup_php                || return 1
        configure_angie_vhost    || return 1
        configure_socket "angie" || return 1
        # Перезапуск после PHP — сокет появляется уже после старта Angie
        log_msg c "Перезапуск Angie для подключения PHP-FPM..."
        systemctl restart angie >/dev/null 2>&1
    else
        remove_angie
        setup_apache               || return 1
        setup_php                  || return 1
        configure_apache_vhost     || return 1
        configure_socket "apache"  || return 1
    fi
    deploy_test
    log_msg g "=== Замена завершена: ${from_server^} → ${to_server} ==="
}

# ============================================================
# Строка статуса
# ============================================================

status_line() {
    local s=""
    $HAS_APACHE  && s+="${colors[g]}Apache${colors[x]}  "
    $HAS_ANGIE   && s+="${colors[g]}Angie${colors[x]}   "
    $HAS_PHP     && s+="${colors[c]}PHP ${PHP_VER}${colors[x]}  "
    $HAS_MARIADB && s+="${colors[c]}MariaDB${colors[x]}"
    [[ -z "$s" ]] && s="${colors[y]}ничего не установлено${colors[x]}"
    echo "  Статус: $s"
}

# ============================================================
# Главное меню
# ============================================================

menu() {
    while true; do
        detect_state
        clear
        echo "${colors[g]}══════════════════════════════════════${colors[x]}"
        echo "${colors[g]}  LAMP/LEMP Installer v${SCRIPT_VERSION}${colors[x]}"
        echo "${colors[g]}══════════════════════════════════════${colors[x]}"
        status_line
        echo ""

        if ! $HAS_APACHE && ! $HAS_ANGIE; then
            echo "  1) Установить Angie  + PHP ${PHP_VER}"
            echo "  2) Установить Apache + PHP ${PHP_VER}"
            echo "  3) Установить MariaDB"
            echo "  0) Выход"
            echo ""
            read -r -p "Ваш выбор: " choice
            case "$choice" in
                1) install_webserver "angie"  ;;
                2) install_webserver "apache" ;;
                3) setup_mariadb ;;
                0) log_msg g "Выход."; exit 0 ;;
                *) log_msg r "Неверный выбор" ;;
            esac
        else
            local sw_label=""
            $HAS_APACHE && sw_label="Apache → Angie  + PHP ${PHP_VER}"
            $HAS_ANGIE  && sw_label="Angie  → Apache + PHP ${PHP_VER}"

            local item=1
            declare -A actions=()

            echo "  ${item}) Сменить веб-сервер: ${sw_label}"
            actions[$item]="switch"; ((item++))

            if ! $HAS_MARIADB; then
                echo "  ${item}) Установить MariaDB"
                actions[$item]="mariadb"; ((item++))
            fi

            echo "  ${item}) Настроить SSL (Certbot)"
            actions[$item]="ssl"; ((item++))

            if test_files_exist; then
                echo "  ${item}) Удалить тестовые файлы"
                actions[$item]="rmtest"; ((item++))
            fi

            echo "  0) Выход"
            echo ""
            read -r -p "Ваш выбор: " choice

            if [[ "$choice" == "0" ]]; then
                log_msg g "Выход."; exit 0
            elif [[ -n "${actions[$choice]}" ]]; then
                case "${actions[$choice]}" in
                    switch)  switch_webserver ;;
                    mariadb) setup_mariadb    ;;
                    ssl)     setup_certbot    ;;
                    rmtest)  remove_test_files ;;
                esac
            else
                log_msg r "Неверный выбор"
            fi
            unset actions
        fi

        echo ""
        log_msg g "Готово. Лог: $LOG_FILE"
        read -r -p "Нажмите Enter для продолжения..."
    done
}

# ============================================================
# Точка входа
# ============================================================

main() {
    [[ $EUID -ne 0 ]] && { echo "Запустите от root: sudo bash $0"; exit 1; }
    setup_base || { log_msg r "Критическая ошибка"; exit 1; }
    menu
}
main "$@"
