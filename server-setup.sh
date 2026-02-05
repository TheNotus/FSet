#!/bin/bash
#
# Скрипт первоначальной настройки сервера
# - Обновление системы
# - Настройка SSH на указанный порт
# - Создание пользователя с правами sudo
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
read SSH_PORT <"$TTY"
SSH_PORT=${SSH_PORT:-22}

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 ]] || [[ "$SSH_PORT" -gt 65535 ]]; then
    log_error "Некорректный порт. Используется 22."
    SSH_PORT=22
fi

# --- 2. Имя нового пользователя ---
echo "Введите имя нового пользователя:"
read NEW_USER <"$TTY"
if [[ -z "$NEW_USER" ]]; then
    log_error "Имя пользователя не может быть пустым."
    exit 1
fi

if id "$NEW_USER" &>/dev/null; then
    log_warn "Пользователь $NEW_USER уже существует. Пароль не будет изменён, если выберете генерацию."
fi

# --- 3. Пароль: сгенерировать или ввести ---
echo ""
echo "Пароль для пользователя $NEW_USER:"
echo "  1) Сгенерировать случайный пароль"
echo "  2) Ввести пароль вручную"
echo "Выбор (1 или 2):"
read PASSWORD_CHOICE <"$TTY"

NEW_PASSWORD=""
if [[ "$PASSWORD_CHOICE" == "2" ]]; then
    echo "Введите пароль:"
    read -s NEW_PASSWORD <"$TTY"
    echo ""
    echo "Повторите пароль:"
    read -s NEW_PASSWORD_CONFIRM <"$TTY"
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
    NEW_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
    [[ -z "$NEW_PASSWORD" ]] && NEW_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
    log_info "Сгенерирован пароль (сохраните его!): $NEW_PASSWORD"
fi

# --- 4. Дополнительные порты для фаервола ---
echo ""
echo "Дополнительные порты, которые нужно открыть (кроме SSH)."
echo "Примеры: 80 443 (веб), 3306 (MySQL), через пробел или пусто — только SSH."
echo "Введите порты или Enter:"
read EXTRA_PORTS_INPUT <"$TTY"
ALLOW_PORTS="$SSH_PORT"
if [[ -n "$EXTRA_PORTS_INPUT" ]]; then
    for p in $EXTRA_PORTS_INPUT; do
        if [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]; then
            [[ " $ALLOW_PORTS " != *" $p "* ]] && ALLOW_PORTS="$ALLOW_PORTS $p"
        fi
    done
fi

echo ""
echo "Продолжить настройку? (y/n):"
read CONFIRM <"$TTY"
if [[ ! "$CONFIRM" =~ ^[yYдД] ]]; then
    log_info "Отменено."
    exit 0
fi

# --- Обновление системы ---
log_info "Обновление системы..."
if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get upgrade -y -qq
elif command -v dnf &>/dev/null; then
    dnf update -y -q
elif command -v yum &>/dev/null; then
    yum update -y -q
else
    log_warn "Менеджер пакетов не найден (apt/dnf/yum). Обновление пропущено."
fi
log_info "Система обновлена."

# --- Создание пользователя с sudo ---
if ! id "$NEW_USER" &>/dev/null; then
    log_info "Создание пользователя $NEW_USER..."
    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$NEW_PASSWORD" | chpasswd
    log_info "Пользователь создан."
else
    log_info "Пользователь $NEW_USER уже есть. Устанавливаю новый пароль..."
    echo "$NEW_USER:$NEW_PASSWORD" | chpasswd
fi
SUDOERS_FILE="/etc/sudoers.d/$NEW_USER"
echo "$NEW_USER ALL=(ALL) ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
log_info "Права sudo выданы пользователю $NEW_USER."

# --- Настройка SSH ---
SSH_CONFIG="/etc/ssh/sshd_config"
BACKUP_SSH="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"

if [[ ! -f "$SSH_CONFIG" ]]; then
    log_error "Файл $SSH_CONFIG не найден."
    exit 1
fi

cp "$SSH_CONFIG" "$BACKUP_SSH"
log_info "Резервная копия SSH конфига: $BACKUP_SSH"

# Порт (sed -E для #? в regex)
if grep -qE "^#?Port " "$SSH_CONFIG"; then
    sed -i -E "s/^#?Port .*/Port $SSH_PORT/" "$SSH_CONFIG"
else
    echo "Port $SSH_PORT" >> "$SSH_CONFIG"
fi

# Отключить вход под root
if grep -qE "^#?PermitRootLogin " "$SSH_CONFIG"; then
    sed -i -E "s/^#?PermitRootLogin .*/PermitRootLogin no/" "$SSH_CONFIG"
else
    echo "PermitRootLogin no" >> "$SSH_CONFIG"
fi

# Рекомендуемые опции (если ещё не заданы)
for opt in "PasswordAuthentication yes" "PubkeyAuthentication yes"; do
    key="${opt%% *}"
    if ! grep -qE "^#?${key} " "$SSH_CONFIG"; then
        echo "$opt" >> "$SSH_CONFIG"
    fi
done

# Проверка конфига sshd (показываем ошибку при сбое)
SSHD_ERR=$(sshd -t 2>&1) || true
if [[ -z "$SSHD_ERR" ]]; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    log_info "SSH перезапущен. Порт: $SSH_PORT, root-вход отключён."
else
    log_error "Ошибка в конфиге SSH: $SSHD_ERR"
    log_error "Восстановлен бэкап: $BACKUP_SSH"
    cp "$BACKUP_SSH" "$SSH_CONFIG"
    exit 1
fi

# --- Фаервол: закрыть все порты кроме нужных ---
configure_firewall() {
    if command -v ufw &>/dev/null; then
        log_info "Настройка UFW: разрешены порты — $ALLOW_PORTS"
        ufw -q reset 2>/dev/null || true
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow from 127.0.0.1
        for port in $ALLOW_PORTS; do
            ufw allow "$port/tcp"
        done
        ufw -f enable
        ufw reload
        log_info "UFW включён. Открыты только: $ALLOW_PORTS"
        return 0
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        log_info "Настройка firewalld: разрешены порты — $ALLOW_PORTS"
        firewall-cmd -q --permanent --set-default-zone=drop 2>/dev/null || true
        for port in $ALLOW_PORTS; do
            firewall-cmd -q --permanent --add-port="$port/tcp"
        done
        firewall-cmd --reload
        log_info "firewalld настроен. Открыты только: $ALLOW_PORTS"
        return 0
    fi
    if command -v apt-get &>/dev/null && ! command -v ufw &>/dev/null; then
        log_info "Установка UFW..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ufw -qq
        configure_firewall
        return $?
    fi
    log_warn "Не найден ufw или firewalld. Фаервол не настроен — откройте порты вручную."
    return 1
}

if configure_firewall; then true; else
    log_warn "Проверьте доступ по SSH на порту $SSH_PORT перед выходом из сессии."
fi

# --- Fail2Ban: защита SSH от брутфорса ---
install_fail2ban() {
    local jail_local="/etc/fail2ban/jail.local"
    local jail_conf="/etc/fail2ban/jail.conf"
    # Лог для SSH: Debian/Ubuntu — auth.log, RHEL/CentOS — secure
    local auth_log="/var/log/auth.log"
    [[ -f /var/log/secure ]] && auth_log="/var/log/secure"

    if command -v apt-get &>/dev/null; then
        log_info "Установка Fail2Ban..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban -qq
    elif command -v dnf &>/dev/null; then
        log_info "Установка Fail2Ban..."
        dnf install -y fail2ban -q 2>/dev/null || yum install -y epel-release -q && yum install -y fail2ban -q
    else
        log_warn "Fail2Ban не установлен (нет apt/dnf). Настройте вручную при необходимости."
        return 1
    fi

    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2Ban не установился. Пропуск."
        return 1
    fi

    # Локальная конфигурация (не трогаем jail.conf)
    if [[ -f "$jail_conf" ]]; then
        # Создаём минимальный jail.local с нашими настройками (приоритет над jail.conf)
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
filter = sshd
logpath = $auth_log
EOF
        log_info "Создан $jail_local (порт SSH: $SSH_PORT, бан 1 ч после 3 попыток за 10 мин)."
    else
        log_warn "Файл $jail_conf не найден. Fail2Ban не настроен."
        return 1
    fi

    systemctl enable fail2ban
    systemctl start fail2ban
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
echo ""
log_warn "Вход под root отключён. Входите как $NEW_USER на порт $SSH_PORT."
log_warn "Фаервол: разрешены только порты $ALLOW_PORTS, остальные закрыты."
log_warn "Проверка Fail2Ban: sudo fail2ban-client status sshd"
echo ""
