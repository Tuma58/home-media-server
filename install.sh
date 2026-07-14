#!/usr/bin/env bash
# ============================================================
# Torrent + DLNA + SMB — Home Media Server installer/manager
# Ubuntu/Debian
# ============================================================
set -Eeuo pipefail

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { printf "%b[✓]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[!]%b %s\n" "$YELLOW" "$NC" "$*"; }
err()  { printf "%b[✗]%b %s\n" "$RED" "$NC" "$*" >&2; exit 1; }
info() { printf "%b[i]%b %s\n" "$CYAN" "$NC" "$*"; }

# --- User configuration (environment variables may override these) ---
MEDIA_ROOT="${MEDIA_ROOT:-/srv/media}"
MEDIA_GROUP="${MEDIA_GROUP:-media-share}"
TORRENT_USER="${TORRENT_USER:-debian-transmission}"
SAMBA_USER="${SAMBA_USER:-media}"
SAMBA_PASS="${SAMBA_PASS:-}"
DLNA_NAME="${DLNA_NAME:-HomeMedia}"
DLNA_PORT="${DLNA_PORT:-8200}"
TRANSMISSION_PORT="${TRANSMISSION_PORT:-9091}"
TRANSMISSION_USER="${TRANSMISSION_USER:-admin}"
TRANSMISSION_PASS="${TRANSMISSION_PASS:-}"
SAMBA_SHARE_NAME="${SAMBA_SHARE_NAME:-Media}"

# Paths are variables to make non-destructive tests possible.
STATE_DIR="${STATE_DIR:-/etc/torrent-dlna}"
INSTALL_MARKER="$STATE_DIR/installed"
INSTALLING_MARKER="$STATE_DIR/installing"
SAMBA_MAIN_CONF="${SAMBA_MAIN_CONF:-/etc/samba/smb.conf}"
SAMBA_INCLUDE_DIR="${SAMBA_INCLUDE_DIR:-/etc/samba/smb.conf.d}"
SAMBA_SHARES_CONF="${SAMBA_SHARES_CONF:-$SAMBA_INCLUDE_DIR/torrent-dlna-shares.conf}"
MINIDLNA_CONF="${MINIDLNA_CONF:-/etc/minidlna.conf}"
TRANSMISSION_CONF="${TRANSMISSION_CONF:-/etc/transmission-daemon/settings.json}"

require_root() {
    [[ $EUID -eq 0 ]] || err "Запустите от root: sudo bash install.sh"
}

detect_os() {
    [[ -f /etc/os-release ]] || err "Не найдён /etc/os-release"
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "$ID" == ubuntu || "$ID" == debian ]] || \
        err "Поддерживаются только Ubuntu/Debian. Обнаружено: $ID"
    log "Система: $NAME $VERSION_ID"
}

valid_username() {
    [[ ${#1} -le 32 && $1 =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

valid_groupname() {
    [[ ${#1} -le 32 && $1 =~ ^[a-z_][a-z0-9_-]*$ ]]
}

valid_share_name() {
    [[ ${#1} -le 80 && $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

valid_absolute_path() {
    [[ $1 == /* && $1 != *$'\n'* && $1 != *$'\r'* && $1 != *$'\t'* && $1 != *'#'* && $1 != *';'* && $1 != *','* ]]
}

valid_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_single_line() {
    [[ $1 != *$'\n'* && $1 != *$'\r'* ]]
}

random_secret() {
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

json_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

primary_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || true
}

backup_once() {
    local file=$1 backup="$1.torrent-dlna.bak"
    [[ ! -f "$file" || -e "$backup" ]] || cp -a -- "$file" "$backup"
}

is_installed() {
    [[ -f "$INSTALL_MARKER" ]] && return 0
    [[ -f "$INSTALLING_MARKER" ]] && return 1

    # Recognise installations made by older versions of this script.
    command -v transmission-daemon >/dev/null 2>&1 &&
        command -v minidlnad >/dev/null 2>&1 &&
        command -v smbd >/dev/null 2>&1 &&
        [[ -f "$TRANSMISSION_CONF" && -f "$MINIDLNA_CONF" && -f "$SAMBA_MAIN_CONF" ]]
}

install_packages() {
    info "Установка необходимых пакетов..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq transmission-daemon minidlna samba samba-common-bin curl wget ufw
    id "$TORRENT_USER" >/dev/null 2>&1 || \
        err "После установки пакета не найден пользователь $TORRENT_USER"
}

setup_permissions() {
    info "Подготовка каталогов и общей группы..."
    groupadd -f "$MEDIA_GROUP"
    usermod -aG "$MEDIA_GROUP" "$TORRENT_USER"

    mkdir -p -- "$MEDIA_ROOT"/{downloads,incomplete,watch,music,video,photo}
    chown "$TORRENT_USER:$MEDIA_GROUP" "$MEDIA_ROOT"/{downloads,incomplete,watch}
    chown root:"$MEDIA_GROUP" "$MEDIA_ROOT" "$MEDIA_ROOT"/{music,video,photo}
    chmod 2775 "$MEDIA_ROOT" "$MEDIA_ROOT"/{downloads,incomplete,watch,music,video,photo}
    log "Каталоги готовы: $MEDIA_ROOT"
}

configure_transmission() {
    info "Настройка Transmission..."
    systemctl stop transmission-daemon 2>/dev/null || true
    backup_once "$TRANSMISSION_CONF"

    local rpc_user rpc_pass media_root_json
    rpc_user=$(json_escape "$TRANSMISSION_USER")
    rpc_pass=$(json_escape "$TRANSMISSION_PASS")
    media_root_json=$(json_escape "$MEDIA_ROOT")

    cat > "$TRANSMISSION_CONF" <<EOF
{
    "alt-speed-enabled": false,
    "bind-address-ipv4": "0.0.0.0",
    "bind-address-ipv6": "::",
    "blocklist-enabled": false,
    "cache-size-mb": 4,
    "dht-enabled": true,
    "download-dir": "$media_root_json/downloads",
    "download-queue-enabled": true,
    "download-queue-size": 5,
    "encryption": 1,
    "incomplete-dir": "$media_root_json/incomplete",
    "incomplete-dir-enabled": true,
    "lpd-enabled": false,
    "message-level": 1,
    "peer-limit-global": 200,
    "peer-limit-per-torrent": 50,
    "peer-port": 51413,
    "peer-port-random-on-start": false,
    "pex-enabled": true,
    "port-forwarding-enabled": false,
    "preallocation": 1,
    "queue-stalled-enabled": true,
    "queue-stalled-minutes": 30,
    "rename-partial-files": false,
    "rpc-authentication-required": true,
    "rpc-bind-address": "0.0.0.0",
    "rpc-enabled": true,
    "rpc-host-whitelist": "",
    "rpc-host-whitelist-enabled": true,
    "rpc-password": "$rpc_pass",
    "rpc-port": $TRANSMISSION_PORT,
    "rpc-url": "/transmission/",
    "rpc-username": "$rpc_user",
    "rpc-whitelist": "127.0.0.1,192.168.*.*,10.*.*.*,172.16.*.*",
    "rpc-whitelist-enabled": true,
    "scrape-paused-torrents-enabled": true,
    "seed-queue-enabled": false,
    "start-added-torrents": true,
    "trash-original-torrent-files": false,
    "umask": "002",
    "utp-enabled": true,
    "watch-dir": "$media_root_json/watch",
    "watch-dir-enabled": true
}
EOF
    chown "$TORRENT_USER:$TORRENT_USER" "$TRANSMISSION_CONF"
    chmod 600 "$TRANSMISSION_CONF"
    systemctl enable transmission-daemon
    systemctl start transmission-daemon
    log "Transmission настроен"
}

configure_minidlna() {
    info "Настройка MiniDLNA..."
    backup_once "$MINIDLNA_CONF"
    cat > "$MINIDLNA_CONF" <<EOF
# Managed by torrent-dlna install.sh. Further changes are preserved on repeated runs.
media_dir=A,$MEDIA_ROOT/music
media_dir=V,$MEDIA_ROOT/video
media_dir=P,$MEDIA_ROOT/photo

port=$DLNA_PORT
friendly_name=$DLNA_NAME
db_dir=/var/cache/minidlna
log_dir=/var/log
inotify=yes
enable_tivo=no
strict_dlna=no
notify_interval=900
serial=12345678
model_number=1
root_container=B
EOF
    chmod 644 "$MINIDLNA_CONF"
    systemctl enable minidlna
    systemctl restart minidlna
    log "MiniDLNA настроен"
}

ensure_samba_include() {
    mkdir -p -- "$SAMBA_INCLUDE_DIR"
    if [[ ! -s "$SAMBA_SHARES_CONF" ]]; then
        cat > "$SAMBA_SHARES_CONF" <<'EOF'
# Managed by torrent-dlna install.sh.
[global]
min protocol = SMB2
server min protocol = SMB2
EOF
    fi
    chmod 644 "$SAMBA_SHARES_CONF"

    grep -Fq "$SAMBA_SHARES_CONF" "$SAMBA_MAIN_CONF" 2>/dev/null && return 0

    backup_once "$SAMBA_MAIN_CONF"
    local tmp original
    tmp=$(mktemp)
    original=$(mktemp)
    cp -- "$SAMBA_MAIN_CONF" "$original"
    {
        cat "$SAMBA_MAIN_CONF"
        printf '\n# Managed shares from torrent-dlna install.sh\ninclude = %s\n' "$SAMBA_SHARES_CONF"
    } > "$tmp"
    install -m 0644 "$tmp" "$SAMBA_MAIN_CONF"
    rm -f -- "$tmp"
    if ! testparm -s "$SAMBA_MAIN_CONF" >/dev/null 2>&1; then
        cp -- "$original" "$SAMBA_MAIN_CONF"
        rm -f -- "$original"
        warn "Не удалось безопасно подключить файл управляемых шар"
        return 1
    fi
    rm -f -- "$original"
}

samba_config_valid() {
    testparm -s "$SAMBA_MAIN_CONF" >/dev/null 2>&1
}

samba_user_exists() {
    pdbedit -L 2>/dev/null | cut -d: -f1 | grep -Fxq -- "$1"
}

samba_share_defined() {
    local name=$1
    awk '/^\[[^]]+\][[:space:]]*$/{value=$0; sub(/^\[/, "", value); sub(/\][[:space:]]*$/, "", value); print value}' \
        "$SAMBA_MAIN_CONF" "$SAMBA_SHARES_CONF" 2>/dev/null | grep -Fxiq -- "$name"
}

set_samba_password() {
    local username=$1 password=${2:-} password_again
    valid_username "$username" || { warn "Некорректное имя пользователя"; return 1; }

    if [[ -z "$password" ]]; then
        read -r -s -p "Пароль SMB для $username: " password
        printf '\n'
        read -r -s -p "Повторите пароль: " password_again
        printf '\n'
        [[ "$password" == "$password_again" ]] || { warn "Пароли не совпадают"; return 1; }
    fi
    [[ -n "$password" ]] || { warn "Пустой пароль запрещён"; return 1; }
    valid_single_line "$password" || { warn "Пароль должен быть в одной строке"; return 1; }

    if ! id "$username" >/dev/null 2>&1; then
        useradd -M -s /usr/sbin/nologin "$username"
    fi
    usermod -aG "$MEDIA_GROUP" "$username"
    printf '%s\n%s\n' "$password" "$password" | smbpasswd -a -s "$username" >/dev/null
    log "Пользователь SMB $username добавлен/обновлён"
    info "Доступ разрешён к шарам с группой @$MEDIA_GROUP; ограниченные шары задают свой список пользователей."
}

append_samba_share() {
    local name=$1 path=$2 users=$3 backup
    local -a user_list
    valid_share_name "$name" || { warn "Имя шары: только буквы, цифры, точка, _ и -"; return 1; }
    valid_absolute_path "$path" || { warn "Требуется безопасный абсолютный путь"; return 1; }
    [[ -n "$users" ]] || { warn "Укажите хотя бы одного пользователя"; return 1; }

    read -r -a user_list <<< "$users"
    ((${#user_list[@]} > 0)) || { warn "Укажите хотя бы одного пользователя"; return 1; }
    users=${user_list[*]}
    local user
    for user in "${user_list[@]}"; do
        if [[ "$user" == @* ]]; then
            valid_groupname "${user#@}" || { warn "Некорректная группа: $user"; return 1; }
            getent group "${user#@}" >/dev/null || { warn "Группа не найдена: $user"; return 1; }
        else
            valid_username "$user" || { warn "Некорректный пользователь: $user"; return 1; }
            samba_user_exists "$user" || { warn "Пользователь SMB не найден: $user"; return 1; }
        fi
    done

    if samba_share_defined "$name"; then
        warn "Шара $name уже существует"
        return 1
    fi

    backup=$(mktemp)
    cp -- "$SAMBA_SHARES_CONF" "$backup"
    cat >> "$SAMBA_SHARES_CONF" <<EOF

# BEGIN TORRENT-DLNA SHARE: $name
[$name]
   comment = Managed media share
   path = $path
   browseable = yes
   read only = no
   guest ok = no
   valid users = $users
   create mask = 0664
   force create mode = 0660
   directory mask = 2775
   force directory mode = 2770
   force group = $MEDIA_GROUP
# END TORRENT-DLNA SHARE: $name
EOF
    if ! samba_config_valid; then
        cp -- "$backup" "$SAMBA_SHARES_CONF"
        rm -f -- "$backup"
        warn "Samba отклонила конфигурацию; изменение отменено"
        return 1
    fi
    if ! mkdir -p -- "$path" || ! chgrp "$MEDIA_GROUP" "$path" || ! chmod 2775 "$path"; then
        cp -- "$backup" "$SAMBA_SHARES_CONF"
        rm -f -- "$backup"
        warn "Не удалось подготовить каталог; изменение Samba отменено"
        return 1
    fi
    if ! systemctl reload-or-restart smbd; then
        cp -- "$backup" "$SAMBA_SHARES_CONF"
        systemctl reload-or-restart smbd 2>/dev/null || true
        rm -f -- "$backup"
        warn "Не удалось применить конфигурацию; изменение отменено"
        return 1
    fi
    rm -f -- "$backup"
    log "Шара $name добавлена: $path"
}

remove_samba_share() {
    local name=$1 tmp backup
    valid_share_name "$name" || { warn "Некорректное имя шары"; return 1; }
    grep -Fqx "# BEGIN TORRENT-DLNA SHARE: $name" "$SAMBA_SHARES_CONF" || {
        warn "Управляемая шара $name не найдена"
        return 1
    }

    tmp=$(mktemp)
    backup=$(mktemp)
    cp -- "$SAMBA_SHARES_CONF" "$backup"
    awk -v begin="# BEGIN TORRENT-DLNA SHARE: $name" -v end="# END TORRENT-DLNA SHARE: $name" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$SAMBA_SHARES_CONF" > "$tmp"
    install -m 0644 "$tmp" "$SAMBA_SHARES_CONF"
    rm -f -- "$tmp"
    if ! samba_config_valid; then
        cp -- "$backup" "$SAMBA_SHARES_CONF"
        rm -f -- "$backup"
        warn "Samba отклонила конфигурацию; изменение отменено"
        return 1
    fi
    if ! systemctl reload-or-restart smbd; then
        cp -- "$backup" "$SAMBA_SHARES_CONF"
        systemctl reload-or-restart smbd 2>/dev/null || true
        rm -f -- "$backup"
        warn "Не удалось применить конфигурацию; изменение отменено"
        return 1
    fi
    rm -f -- "$backup"
    log "Шара $name удалена из Samba; файлы на диске не удалялись"
}

list_samba_shares() {
    printf '\nУправляемые шары:\n'
    awk '
        /^# BEGIN TORRENT-DLNA SHARE:/ { name=$0; sub(/^# BEGIN TORRENT-DLNA SHARE: /, "", name); path=""; users="" }
        /^[[:space:]]*path[[:space:]]*=/ { path=$0; sub(/^[^=]*=[[:space:]]*/, "", path) }
        /^[[:space:]]*valid users[[:space:]]*=/ { users=$0; sub(/^[^=]*=[[:space:]]*/, "", users) }
        /^# END TORRENT-DLNA SHARE:/ { printf "  %-20s %s  [%s]\n", name, path, users }
    ' "$SAMBA_SHARES_CONF"
    if ! grep -q '^# BEGIN TORRENT-DLNA SHARE:' "$SAMBA_SHARES_CONF"; then
        printf '  (нет)\n'
    fi
    printf '\nПрочие секции в основном smb.conf не изменяются этим меню.\n'
    awk '/^\[[^]]+\]/{ if ($0 != "[global]") print "  " $0 }' "$SAMBA_MAIN_CONF"
}

configure_samba() {
    info "Настройка Samba..."
    groupadd -f "$MEDIA_GROUP"
    ensure_samba_include
    set_samba_password "$SAMBA_USER" "$SAMBA_PASS"
    if samba_share_defined "$SAMBA_SHARE_NAME"; then
        warn "Шара $SAMBA_SHARE_NAME уже существует — существующая секция сохранена"
    else
        append_samba_share "$SAMBA_SHARE_NAME" "$MEDIA_ROOT" "@$MEDIA_GROUP"
    fi
    systemctl enable smbd
    systemctl restart smbd
    systemctl enable nmbd 2>/dev/null || true
    systemctl restart nmbd 2>/dev/null || true
    log "Samba настроена"
}

configure_firewall() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status | grep -q 'Status: active' || return 0
    info "Открытие портов UFW..."
    ufw allow "$TRANSMISSION_PORT/tcp" comment 'Transmission Web UI'
    ufw allow 51413/tcp comment 'Transmission peer TCP'
    ufw allow 51413/udp comment 'Transmission peer UDP'
    ufw allow "$DLNA_PORT/tcp" comment 'MiniDLNA HTTP'
    ufw allow 1900/udp comment 'DLNA SSDP'
    ufw allow 445/tcp comment 'Samba SMB'
    ufw allow 139/tcp comment 'Samba NetBIOS'
}

validate_config() {
    valid_port "$TRANSMISSION_PORT" || err "Некорректный TRANSMISSION_PORT"
    valid_port "$DLNA_PORT" || err "Некорректный DLNA_PORT"
    valid_username "$SAMBA_USER" || err "Некорректный SAMBA_USER"
    valid_username "$TORRENT_USER" || err "Некорректный TORRENT_USER"
    valid_groupname "$MEDIA_GROUP" || err "Некорректный MEDIA_GROUP"
    valid_share_name "$SAMBA_SHARE_NAME" || err "Некорректный SAMBA_SHARE_NAME"
    valid_absolute_path "$MEDIA_ROOT" || err "Некорректный MEDIA_ROOT"
    valid_single_line "$DLNA_NAME" && [[ "$DLNA_NAME" != *'#'* ]] || \
        err "DLNA_NAME должен быть в одной строке и не содержать #"
    valid_single_line "$TRANSMISSION_USER" || err "TRANSMISSION_USER должен быть в одной строке"
}

initialise_secrets() {
    if [[ -z "$TRANSMISSION_PASS" ]]; then
        TRANSMISSION_PASS=$(random_secret)
        warn "Сгенерирован случайный пароль Transmission"
    fi
    if [[ -z "$SAMBA_PASS" ]]; then
        SAMBA_PASS=$(random_secret)
        warn "Сгенерирован случайный пароль Samba"
    fi
    valid_single_line "$TRANSMISSION_PASS" || err "TRANSMISSION_PASS должен быть в одной строке"
    [[ "$TRANSMISSION_PASS" != \{* ]] || \
        err "TRANSMISSION_PASS не должен начинаться с { (Transmission считает такой пароль уже хешированным)"
    valid_single_line "$SAMBA_PASS" || err "SAMBA_PASS должен быть в одной строке"
}

print_summary() {
    local ip
    ip=$(primary_ip)
    printf '\n%b============================================================%b\n' "$GREEN" "$NC"
    printf '%b   Установка завершена%b\n' "$GREEN" "$NC"
    printf '%b============================================================%b\n\n' "$GREEN" "$NC"
    printf '  Transmission: http://%s:%s\n' "${ip:-IP-СЕРВЕРА}" "$TRANSMISSION_PORT"
    printf '    Логин: %s\n    Пароль: %s\n' "$TRANSMISSION_USER" "$TRANSMISSION_PASS"
    printf '  MiniDLNA: %s (порт %s)\n' "$DLNA_NAME" "$DLNA_PORT"
    printf '  Samba: \\\\%s\\%s\n' "${ip:-IP-СЕРВЕРА}" "$SAMBA_SHARE_NAME"
    printf '    Логин: %s\n    Пароль: %s\n' "$SAMBA_USER" "$SAMBA_PASS"
    printf '  Медиа: %s\n\n' "$MEDIA_ROOT"
    warn "Сохраните сгенерированные пароли: повторно они не выводятся."
    info "При следующем запуске откроется меню управления."
}

install_all() {
    mkdir -p -- "$STATE_DIR"
    printf 'started_at=%s\n' "$(date -u +%FT%TZ)" > "$INSTALLING_MARKER"
    chmod 600 "$INSTALLING_MARKER"
    initialise_secrets
    install_packages
    setup_permissions
    configure_transmission
    configure_minidlna
    configure_samba
    configure_firewall
    printf 'installed_at=%s\n' "$(date -u +%FT%TZ)" > "$INSTALL_MARKER"
    chmod 600 "$INSTALL_MARKER"
    rm -f -- "$INSTALLING_MARKER"
    print_summary
}

prepare_management() {
    mkdir -p -- "$STATE_DIR"
    if [[ ! -f "$INSTALL_MARKER" ]]; then
        printf 'adopted_at=%s\n' "$(date -u +%FT%TZ)" > "$INSTALL_MARKER"
        chmod 600 "$INSTALL_MARKER"
        warn "Обнаружена установка старой версии; конфиги приняты без перезаписи."
    fi
}

confirm_partial_install() {
    [[ -f "$INSTALLING_MARKER" ]] && return 0
    local file answer found=false
    for file in "$TRANSMISSION_CONF" "$MINIDLNA_CONF" "$SAMBA_MAIN_CONF"; do
        [[ -f "$file" ]] && { warn "Найден существующий конфиг: $file"; found=true; }
    done
    [[ "$found" == true ]] || return 0

    warn "Полная установка не распознана. Найденные конфиги будут сохранены в одноразовые резервные копии, затем настроены скриптом."
    if [[ "${ALLOW_RECONFIGURE:-0}" == 1 ]]; then
        return 0
    fi
    [[ -t 0 ]] || err "Нужно подтверждение. Запустите в терминале или задайте ALLOW_RECONFIGURE=1."
    read -r -p 'Продолжить настройку [y/N]: ' answer
    [[ "$answer" =~ ^[YyДд]$ ]] || err "Установка отменена"
}

shares_menu() {
    ensure_samba_include || return 0
    local choice name path users answer
    while true; do
        printf '\n--- SMB: общие папки ---\n'
        printf '1) Показать шары\n2) Добавить шару\n3) Удалить шару\n4) Проверить конфигурацию\n0) Назад\n'
        read -r -p 'Выбор: ' choice
        case "$choice" in
            1) list_samba_shares ;;
            2)
                read -r -p 'Имя шары (без пробелов): ' name
                read -r -p 'Абсолютный путь: ' path
                read -r -p "Пользователи SMB через запятую (Enter = все из @$MEDIA_GROUP): " users
                users=${users:-@$MEDIA_GROUP}
                users=${users//,/ }
                append_samba_share "$name" "$path" "$users" || true
                ;;
            3)
                list_samba_shares
                read -r -p 'Имя управляемой шары: ' name
                read -r -p "Удалить шару $name из Samba? Данные останутся [y/N]: " answer
                [[ "$answer" =~ ^[YyДд]$ ]] && remove_samba_share "$name" || true
                ;;
            4)
                if samba_config_valid; then log "Конфигурация Samba корректна"; else warn "Ошибка в конфигурации Samba"; fi
                ;;
            0) return ;;
            *) warn "Неизвестный пункт" ;;
        esac
    done
}

samba_users_menu() {
    groupadd -f "$MEDIA_GROUP"
    local choice username answer
    while true; do
        printf '\n--- SMB: пользователи ---\n'
        printf '1) Показать пользователей\n2) Добавить пользователя / сменить пароль\n3) Отключить пользователя SMB\n4) Включить пользователя SMB\n5) Удалить учётную запись SMB\n0) Назад\n'
        read -r -p 'Выбор: ' choice
        case "$choice" in
            1) pdbedit -L || true ;;
            2)
                read -r -p 'Имя пользователя: ' username
                set_samba_password "$username" || true
                ;;
            3)
                read -r -p 'Имя пользователя: ' username
                valid_username "$username" && smbpasswd -d "$username" && log "$username отключён" || warn "Операция не выполнена"
                ;;
            4)
                read -r -p 'Имя пользователя: ' username
                valid_username "$username" && smbpasswd -e "$username" && log "$username включён" || warn "Операция не выполнена"
                ;;
            5)
                read -r -p 'Имя пользователя: ' username
                read -r -p "Удалить только SMB-учётную запись $username [y/N]: " answer
                if [[ "$answer" =~ ^[YyДд]$ ]] && valid_username "$username"; then
                    smbpasswd -x "$username" && log "SMB-учётная запись удалена; Linux-пользователь сохранён" || warn "Операция не выполнена"
                fi
                ;;
            0) return ;;
            *) warn "Неизвестный пункт" ;;
        esac
    done
}

set_minidlna_value() {
    local key=$1 value=$2 tmp
    valid_single_line "$value" || { warn "Значение должно быть в одной строке"; return 1; }
    [[ "$value" != *'#'* ]] || { warn "Символ # здесь запрещён"; return 1; }
    tmp=$(mktemp)
    awk -v key="$key" -v value="$value" '
        BEGIN { done=0 }
        $0 ~ "^" key "=" && !done { print key "=" value; done=1; next }
        { print }
        END { if (!done) print key "=" value }
    ' "$MINIDLNA_CONF" > "$tmp"
    install -m 0644 "$tmp" "$MINIDLNA_CONF"
    rm -f -- "$tmp"
}

list_dlna_dirs() {
    printf '\nКаталоги DLNA:\n'
    grep -n '^media_dir=' "$MINIDLNA_CONF" || printf '  (нет)\n'
}

add_dlna_dir() {
    local type path line
    read -r -p 'Тип (A=аудио, V=видео, P=фото): ' type
    type=${type^^}
    [[ "$type" =~ ^[AVP]$ ]] || { warn "Допустимы A, V или P"; return 1; }
    read -r -p 'Абсолютный путь: ' path
    valid_absolute_path "$path" || { warn "Некорректный путь"; return 1; }
    line="media_dir=$type,$path"
    grep -Fxq -- "$line" "$MINIDLNA_CONF" && { warn "Этот каталог уже добавлен"; return 1; }
    mkdir -p -- "$path"
    chgrp "$MEDIA_GROUP" "$path"
    chmod 2775 "$path"
    printf '%s\n' "$line" >> "$MINIDLNA_CONF"
    systemctl restart minidlna
    log "Каталог DLNA добавлен"
}

remove_dlna_dir() {
    local number line tmp answer
    local -a dlna_lines
    mapfile -t dlna_lines < <(grep '^media_dir=' "$MINIDLNA_CONF")
    ((${#dlna_lines[@]} > 0)) || { warn "Каталогов нет"; return 1; }
    local i
    for i in "${!dlna_lines[@]}"; do printf '%d) %s\n' "$((i + 1))" "${dlna_lines[$i]}"; done
    read -r -p 'Номер каталога: ' number
    [[ "$number" =~ ^[0-9]+$ ]] || { warn "Некорректный номер"; return 1; }
    number=$((10#$number))
    (( number >= 1 && number <= ${#dlna_lines[@]} )) || {
        warn "Некорректный номер"; return 1;
    }
    line=${dlna_lines[$((number - 1))]}
    read -r -p "Убрать '$line' из DLNA? Файлы останутся [y/N]: " answer
    [[ "$answer" =~ ^[YyДд]$ ]] || return 0
    tmp=$(mktemp)
    awk -v target="$line" '$0 != target' "$MINIDLNA_CONF" > "$tmp"
    install -m 0644 "$tmp" "$MINIDLNA_CONF"
    rm -f -- "$tmp"
    systemctl restart minidlna
    log "Каталог убран из индекса DLNA; файлы не удалялись"
}

rebuild_dlna_database() {
    local db_dir answer
    db_dir=$(awk -F= '$1 == "db_dir" {print $2; exit}' "$MINIDLNA_CONF")
    db_dir=${db_dir:-/var/cache/minidlna}
    valid_absolute_path "$db_dir" || { warn "Небезопасный db_dir в minidlna.conf"; return 1; }
    read -r -p 'Полностью перестроить индекс DLNA [y/N]: ' answer
    [[ "$answer" =~ ^[YyДд]$ ]] || return 0
    systemctl stop minidlna
    rm -f -- "$db_dir/files.db"
    systemctl start minidlna
    log "Перестроение индекса DLNA запущено"
}

dlna_menu() {
    local choice value
    while true; do
        printf '\n--- Управление DLNA ---\n'
        printf '1) Статус\n2) Запустить\n3) Остановить\n4) Перезапустить\n5) Перестроить индекс\n6) Показать медиакаталоги\n7) Добавить медиакаталог\n8) Убрать медиакаталог\n9) Изменить имя сервера\n0) Назад\n'
        read -r -p 'Выбор: ' choice
        case "$choice" in
            1) systemctl --no-pager --full status minidlna || true ;;
            2) systemctl start minidlna; log "MiniDLNA запущен" ;;
            3) systemctl stop minidlna; log "MiniDLNA остановлен" ;;
            4) systemctl restart minidlna; log "MiniDLNA перезапущен" ;;
            5) rebuild_dlna_database || true ;;
            6) list_dlna_dirs ;;
            7) add_dlna_dir || true ;;
            8) remove_dlna_dir || true ;;
            9)
                read -r -p 'Новое имя DLNA-сервера: ' value
                [[ -n "$value" ]] || { warn "Имя не может быть пустым"; continue; }
                set_minidlna_value friendly_name "$value" && systemctl restart minidlna && log "Имя изменено"
                ;;
            0) return ;;
            *) warn "Неизвестный пункт" ;;
        esac
    done
}

services_status() {
    local service state
    for service in transmission-daemon smbd minidlna; do
        state=$(systemctl is-active "$service" 2>/dev/null || true)
        printf '  %-24s %s\n' "$service" "$state"
    done
}

management_menu() {
    if [[ ! -t 0 ]]; then
        warn "Меню требует интерактивный терминал. Запустите: sudo bash install.sh"
        services_status
        return 0
    fi

    local choice
    while true; do
        printf '\n%b=== Torrent + DLNA + SMB: управление ===%b\n' "$GREEN" "$NC"
        printf '1) SMB: общие папки (шары)\n2) SMB: пользователи\n3) DLNA: управление\n4) Статус сервисов\n0) Выход\n'
        read -r -p 'Выбор: ' choice
        case "$choice" in
            1) shares_menu ;;
            2) samba_users_menu ;;
            3) dlna_menu ;;
            4) services_status ;;
            0) return ;;
            *) warn "Неизвестный пункт" ;;
        esac
    done
}

usage() {
    cat <<'EOF'
Использование: sudo bash install.sh [--menu|--status|--help]

Без аргументов: первая установка или меню, если система уже установлена.
  --menu    открыть меню управления
  --status  показать состояние сервисов
  --help    показать эту справку
EOF
}

main() {
    printf '\n%b============================================================%b\n' "$GREEN" "$NC"
    printf '%b   Torrent + DLNA + SMB Server%b\n' "$GREEN" "$NC"
    printf '%b============================================================%b\n\n' "$GREEN" "$NC"

    case "${1:-}" in
        --help|-h) usage; return 0 ;;
        --status)
            require_root
            services_status
            return 0
            ;;
        --menu|'') ;;
        *) err "Неизвестный аргумент: $1 (см. --help)" ;;
    esac

    require_root
    detect_os
    validate_config
    if is_installed; then
        prepare_management
        management_menu
    else
        [[ "${1:-}" != --menu ]] || err "Установка не найдена. Запустите без --menu."
        confirm_partial_install
        install_all
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
