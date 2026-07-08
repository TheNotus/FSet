#!/bin/bash
#
# Скрипт первоначальной настройки сервера
# - Обновление системы
# - Настройка SSH на указанный порт (учитывает sshd_config.d и socket-активацию Ubuntu)
# - Создание пользователя с правами sudo (пароль и опционально SSH-ключ)
# - Отключение входа по root
# - Фаервол: закрытие всех портов кроме разрешённых (SSH + указанные)
# - Fail2Ban: защита SSH от брутфорса (бан на 1 ч после 3 неудачных попыток за 10 мин)
#
# Запуск: sudo ./server-setup.sh
#

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка root
if [[ $EUID -ne 0 ]]; then
   log_error "Скрипт нужно запускать с правами root (sudo)"
   exit 1
fi

# При запуске через pipe (curl ... | sudo bash) stdin — вывод curl, не клавиатура.
# Читаем ввод только с терминала.
TTY="/dev/tty"
if [[ ! -e "$TTY" ]]; then
   log_error "Нет доступа к терминалу. Запустите в интерактивной SSH-сессии."
   exit 1
fi

echo "=========================================="
echo "  Первоначальная настройка сервера"
echo "=========================================="
echo ""

# --- 1. Запрос порта SSH ---
echo "Введите порт для SSH (по умолчанию 22):"
read -r SSH_PORT <"$TTY" || true
SSH_PORT=${SSH_PORT:-22}

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 ]] || [[ "$SSH_PORT" -gt 65535 ]]; then
    log_error "Некорректный порт. Используется 22."
    SSH_PORT=22
fi

# --- 2. Имя нового пользователя ---
echo "Введите имя нового пользователя:"
read -r NEW_USER <"$TTY" || true
if [[ -z "$NEW_USER" ]]; then
    log_error "Имя пользователя не может быть пустым."
    exit 1
fi
if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    log_error "Некорректное имя: строчные латинские буквы, цифры, '-' и '_', до 32 символов."
    exit 1
fi

if id "$NEW_USER" &>/dev/null; then
    log_warn "Пользователь $NEW_USER уже существует — пароль будет заменён."
fi

# --- 3. Пароль: сгенерировать или ввести ---
echo ""
echo "Пароль для пользователя $NEW_USER:"
echo "  1) Сгенерировать случайный пароль"
echo "  2) Ввести пароль вручную"
echo "Выбор (1 или 2):"
read -r PASSWORD_CHOICE <"$TTY" || true

NEW_PASSWORD=""
if [[ "$PASSWORD_CHOICE" == "2" ]]; then
    echo "Введите пароль:"
    read -r -s NEW_PASSWORD <"$TTY" || true
    echo ""
    echo "Повторите пароль:"
    read -r -s NEW_PASSWORD_CONFIRM <"$TTY" || true
    echo ""
    if [[ "$NEW_PASSWORD" != "$NEW_PASSWORD_CONFIRM" ]]; then
        log_error "Пароли не совпадают."
        exit 1
    fi
    if [[ ${#NEW_PASSWORD} -lt 8 ]]; then
        log_error "Пароль должен быть не менее 8 символов."
        exit 1
    fi
else
    # base64 от 24 байт даёт 32 символа — после удаления +/= остаётся не меньше 16
    NEW_PASSWORD=$(openssl rand -base64 24 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
    [[ ${#NEW_PASSWORD} -lt 16 ]] && NEW_PASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
    log_info "Сгенерирован пароль (сохраните его!): $NEW_PASSWORD"
fi

# --- 4. SSH-ключ (рекомендуется) ---
echo ""
echo "Публичный SSH-ключ для $NEW_USER (рекомендуется)."
echo "Вставьте одну строку (ssh-ed25519 AAAA... / ssh-rsa AAAA...) или Enter — пропустить:"
read -r SSH_PUB_KEY <"$TTY" || true
PASSWORD_AUTH="yes"
if [[ -n "$SSH_PUB_KEY" ]]; then
    if ! [[ "$SSH_PUB_KEY" =~ ^(ssh|ecdsa|sk)-[^[:space:]]+[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
        log_error "Строка не похожа на публичный SSH-ключ."
        exit 1
    fi
    echo "Отключить вход по паролю — вход только по ключу? (y/n):"
    read -r KEY_ONLY <"$TTY" || true
    [[ "$KEY_ONLY" =~ ^[yYдД] ]] && PASSWORD_AUTH="no"
fi

# --- 5. Дополнительные порты для фаервола ---
echo ""
echo "Дополнительные порты, которые нужно открыть (кроме SSH)."
echo "Примеры: 80 443 (веб), 3306 (MySQL), через пробел или пусто — только SSH."
echo "Введите порты или Enter:"
read -r EXTRA_PORTS_INPUT <"$TTY" || true
ALLOW_PORTS="$SSH_PORT"
if [[ -n "$EXTRA_PORTS_INPUT" ]]; then
    for p in $EXTRA_PORTS_INPUT; do
        if [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]; then
            [[ " $ALLOW_PORTS " != *" $p "* ]] && ALLOW_PORTS="$ALLOW_PORTS $p"
        else
            log_warn "Пропущен некорректный порт: $p"
        fi
    done
fi

echo ""
echo "Продолжить настройку? (y/n):"
read -r CONFIRM <"$TTY" || true
if [[ ! "$CONFIRM" =~ ^[yYдД] ]]; then
    log_info "Отменено."
    exit 0
fi

# --- Обновление системы ---
log_info "Обновление системы..."
# </dev/null: при запуске через pipe stdin — текст скрипта, dpkg/rpm не должны его читать
if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq </dev/null
    apt-get upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" </dev/null
elif command -v dnf &>/dev/null; then
    dnf update -y -q </dev/null
elif command -v yum &>/dev/null; then
    yum update -y -q </dev/null
else
    log_warn "Менеджер пакетов не найден (apt/dnf/yum). Обновление пропущено."
fi
log_info "Система обновлена."

# --- Создание пользователя с sudo ---
if ! id "$NEW_USER" &>/dev/null; then
    log_info "Создание пользователя $NEW_USER..."
    useradd -m -s /bin/bash "$NEW_USER"
    log_info "Пользователь создан."
else
    log_info "Пользователь $NEW_USER уже есть. Устанавливаю новый пароль..."
fi
echo "$NEW_USER:$NEW_PASSWORD" | chpasswd

if ! command -v sudo &>/dev/null; then
    log_info "Установка sudo..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq sudo </dev/null || log_warn "Не удалось установить sudo."
    elif command -v dnf &>/dev/null; then
        dnf install -y -q sudo </dev/null || log_warn "Не удалось установить sudo."
    elif command -v yum &>/dev/null; then
        yum install -y -q sudo </dev/null || log_warn "Не удалось установить sudo."
    fi
fi

SUDOERS_FILE="/etc/sudoers.d/$NEW_USER"
echo "$NEW_USER ALL=(ALL) ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
if command -v visudo &>/dev/null && ! visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
    rm -f "$SUDOERS_FILE"
    log_error "Некорректный sudoers-файл — удалён, права sudo не выданы."
    exit 1
fi
log_info "Права sudo выданы пользователю $NEW_USER."

# --- Установка SSH-ключа ---
if [[ -n "$SSH_PUB_KEY" ]]; then
    USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
    USER_GROUP=$(id -gn "$NEW_USER")
    install -d -m 700 -o "$NEW_USER" -g "$USER_GROUP" "$USER_HOME/.ssh"
    touch "$USER_HOME/.ssh/authorized_keys"
    grep -qF "$SSH_PUB_KEY" "$USER_HOME/.ssh/authorized_keys" \
        || echo "$SSH_PUB_KEY" >> "$USER_HOME/.ssh/authorized_keys"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
    chown "$NEW_USER:$USER_GROUP" "$USER_HOME/.ssh/authorized_keys"
    log_info "SSH-ключ добавлен в $USER_HOME/.ssh/authorized_keys."
fi

# --- Настройка SSH ---
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_CONFIG_DIR="/etc/ssh/sshd_config.d"
FSET_CONF="$SSH_CONFIG_DIR/00-fset.conf"
BACKUP_SSH="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
FSET_CONF_CREATED=""

if [[ ! -f "$SSH_CONFIG" ]]; then
    log_error "Файл $SSH_CONFIG не найден."
    exit 1
fi

cp "$SSH_CONFIG" "$BACKUP_SSH"
log_info "Резервная копия SSH конфига: $BACKUP_SSH"

restore_ssh_config() {
    cp "$BACKUP_SSH" "$SSH_CONFIG"
    [[ -n "$FSET_CONF_CREATED" ]] && rm -f "$FSET_CONF"
    log_error "Восстановлен бэкап: $BACKUP_SSH"
}

restart_sshd() {
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
}

# Современные дистрибутивы подключают /etc/ssh/sshd_config.d/*.conf через Include,
# и в sshd побеждает ПЕРВОЕ встреченное значение — файлы оттуда (например,
# 50-cloud-init.conf с PasswordAuthentication) перекрывают основной конфиг.
# Поэтому пишем свой файл с именем 00-*, чтобы он читался раньше остальных.
USE_CONFD=""
if grep -qiE "^[[:space:]]*Include[[:space:]].*sshd_config\.d" "$SSH_CONFIG"; then
    mkdir -p "$SSH_CONFIG_DIR"
    USE_CONFD=1
fi

# Правим существующие директивы в основном конфиге; отсутствующие вставляем
# в начало файла — дописывать в конец нельзя: попадут внутрь блока Match
set_sshd_option() {
    local key="$1" value="$2"
    if grep -qE "^#?${key}[[:space:]]" "$SSH_CONFIG"; then
        sed -i -E "s/^#?${key}[[:space:]].*/${key} ${value}/" "$SSH_CONFIG"
    elif [[ -z "$USE_CONFD" ]]; then
        sed -i "1i ${key} ${value}" "$SSH_CONFIG"
    fi
}

set_sshd_option "Port" "$SSH_PORT"
set_sshd_option "PermitRootLogin" "no"
set_sshd_option "PasswordAuthentication" "$PASSWORD_AUTH"
set_sshd_option "PubkeyAuthentication" "yes"

if [[ -n "$USE_CONFD" ]]; then
    cat > "$FSET_CONF" << EOF
# Создано скриптом server-setup.sh
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication $PASSWORD_AUTH
PubkeyAuthentication yes
EOF
    FSET_CONF_CREATED=1
    log_info "Настройки SSH записаны в $FSET_CONF."
fi

# Каталог для privilege separation (нужен для sshd -t и для демона)
mkdir -p /run/sshd
chmod 755 /run/sshd

SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)

# Проверка конфига sshd (показываем ошибку при сбое)
SSHD_ERR=$("$SSHD_BIN" -t 2>&1) || true
if [[ -n "$SSHD_ERR" ]]; then
    log_error "Ошибка в конфиге SSH: $SSHD_ERR"
    restore_ssh_config
    exit 1
fi

# Сверяем ИТОГОВЫЕ значения: sshd -T учитывает Include и порядок директив
check_effective() {
    local key="$1" expected="$2" actual
    actual=$("$SSHD_BIN" -T 2>/dev/null | awk -v k="$key" '$1==k {print $2; exit}')
    if [[ "$actual" != "$expected" ]]; then
        log_error "Итоговое значение $key = '$actual', ожидалось '$expected'."
        log_error "Директиву перекрывает другой конфиг (проверьте $SSH_CONFIG_DIR)."
        return 1
    fi
}

if ! check_effective "port" "$SSH_PORT" \
   || ! check_effective "permitrootlogin" "no" \
   || ! check_effective "passwordauthentication" "$PASSWORD_AUTH"; then
    restore_ssh_config
    exit 1
fi

# Ubuntu 22.10+ запускает SSH через socket-активацию: порт берётся из ssh.socket,
# а Port из sshd_config игнорируется. Отключаем socket — порт будет задавать конфиг.
if systemctl is-enabled ssh.socket &>/dev/null || systemctl is-active ssh.socket &>/dev/null; then
    log_info "Обнаружена socket-активация SSH — отключаю ssh.socket..."
    systemctl disable --now ssh.socket &>/dev/null || true
    systemctl enable ssh.service &>/dev/null || true
fi

if ! restart_sshd; then
    log_error "Не удалось перезапустить SSH."
    restore_ssh_config
    restart_sshd || true
    exit 1
fi

# Убеждаемся, что sshd реально слушает новый порт, ДО настройки фаервола —
# иначе фаервол откроет порт, на котором никто не отвечает
sleep 1
if command -v ss &>/dev/null; then
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${SSH_PORT}$"; then
        log_info "SSH перезапущен и слушает порт $SSH_PORT, root-вход отключён."
    else
        log_error "sshd не слушает порт $SSH_PORT после перезапуска!"
        restore_ssh_config
        restart_sshd || true
        exit 1
    fi
else
    log_warn "Утилита ss не найдена — проверьте вручную, что sshd слушает порт $SSH_PORT."
fi

# --- Фаервол: закрыть все порты кроме нужных ---
configure_firewall() {
    if command -v ufw &>/dev/null; then
        log_info "Настройка UFW: разрешены порты — $ALLOW_PORTS"
        ufw --force reset >/dev/null 2>&1 || true
        ufw default deny incoming
        ufw default allow outgoing
        for port in $ALLOW_PORTS; do
            ufw allow "$port/tcp"
        done
        ufw --force enable
        log_info "UFW включён. Открыты только: $ALLOW_PORTS"
        return 0
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        log_info "Настройка firewalld: разрешены порты — $ALLOW_PORTS"
        # --set-default-zone не сочетается с --permanent (применяется сразу и навсегда)
        firewall-cmd -q --set-default-zone=drop || true
        for port in $ALLOW_PORTS; do
            firewall-cmd -q --permanent --zone=drop --add-port="$port/tcp"
        done
        firewall-cmd -q --reload
        log_info "firewalld настроен. Открыты только: $ALLOW_PORTS"
        return 0
    fi
    if command -v apt-get &>/dev/null; then
        log_info "Установка UFW..."
        if apt-get install -y -qq ufw </dev/null && command -v ufw &>/dev/null; then
            configure_firewall
            return $?
        fi
        log_warn "Не удалось установить UFW."
    fi
    log_warn "Не найден ufw или firewalld. Фаервол не настроен — откройте порты вручную."
    return 1
}

if ! configure_firewall; then
    log_warn "Проверьте доступ по SSH на порту $SSH_PORT перед выходом из сессии."
fi

# --- Fail2Ban: защита SSH от брутфорса ---
install_fail2ban() {
    local jail_local="/etc/fail2ban/jail.local"

    # Источник логов SSH: файлы (rsyslog) или journald —
    # на Debian 12+ / Ubuntu 22.04+ без rsyslog файла auth.log нет
    local jail_log="backend = systemd"
    local extra_pkg="python3-systemd"
    if [[ -f /var/log/auth.log ]]; then
        jail_log="logpath = /var/log/auth.log"
        extra_pkg=""
    elif [[ -f /var/log/secure ]]; then
        jail_log="logpath = /var/log/secure"
        extra_pkg=""
    fi

    if command -v apt-get &>/dev/null; then
        log_info "Установка Fail2Ban..."
        apt-get install -y -qq fail2ban $extra_pkg </dev/null \
            || apt-get install -y -qq fail2ban </dev/null
    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
        local pkg="dnf"
        command -v dnf &>/dev/null || pkg="yum"
        log_info "Установка Fail2Ban..."
        if ! "$pkg" install -y -q fail2ban </dev/null 2>/dev/null; then
            # в RHEL/CentOS fail2ban живёт в EPEL
            "$pkg" install -y -q epel-release </dev/null \
                && "$pkg" install -y -q fail2ban </dev/null
        fi
        if [[ -n "$extra_pkg" ]]; then
            "$pkg" install -y -q "$extra_pkg" </dev/null 2>/dev/null || true
        fi
    else
        log_warn "Fail2Ban не установлен (нет apt/dnf/yum). Настройте вручную при необходимости."
        return 1
    fi

    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2Ban не установился. Пропуск."
        return 1
    fi

    if [[ ! -d /etc/fail2ban ]]; then
        log_warn "Каталог /etc/fail2ban не найден. Fail2Ban не настроен."
        return 1
    fi

    # Локальная конфигурация (не трогаем jail.conf)
    cat > "$jail_local" << EOF
# Локальная конфигурация Fail2Ban (создана скриптом server-setup.sh)
# Документация: man jail.conf

[DEFAULT]
# Время бана в секундах (1 час)
bantime = 3600
# Окно поиска нарушений (10 минут)
findtime = 600
# Максимальное количество попыток входа
maxretry = 3

[sshd]
enabled = true
port = $SSH_PORT
$jail_log
EOF
    log_info "Создан $jail_local (порт SSH: $SSH_PORT, бан 1 ч после 3 попыток за 10 мин)."

    systemctl enable fail2ban &>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || systemctl start fail2ban
    sleep 1
    if fail2ban-client status sshd &>/dev/null; then
        log_info "Fail2Ban запущен, jail sshd активен."
    else
        log_warn "Fail2Ban запущен, но jail sshd может быть не активен. Проверьте: fail2ban-client status sshd"
    fi
    return 0
}

install_fail2ban || true

# --- Итог ---
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
SSH_CMD="ssh -p $SSH_PORT $NEW_USER@${SERVER_IP:-<IP-сервера>}"
echo ""
echo "=========================================="
echo "  Настройка завершена"
echo "=========================================="
echo ""
echo "  SSH порт:        $SSH_PORT"
echo "  Открытые порты:  $ALLOW_PORTS"
echo "  Fail2Ban:        бан 1 ч после 3 неудачных попыток за 10 мин (порт $SSH_PORT)"
echo "  Новый пользователь: $NEW_USER"
[[ "$PASSWORD_CHOICE" != "2" ]] && echo "  Пароль:          $NEW_PASSWORD"
[[ "$PASSWORD_AUTH" == "no" ]] && echo "  Вход по паролю:  отключён (только SSH-ключ)"
echo ""
echo "  Подключение:     $SSH_CMD"
echo ""
log_warn "НЕ ЗАКРЫВАЙТЕ эту сессию! Откройте новое окно терминала и проверьте вход:"
log_warn "  $SSH_CMD"
log_warn "Вход под root отключён. Фаервол: разрешены только порты $ALLOW_PORTS."
log_warn "Проверка Fail2Ban: sudo fail2ban-client status sshd"
echo ""
