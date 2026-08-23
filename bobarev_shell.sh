#!/bin/bash
set -euo pipefail

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ, ANSI-ЦВЕТА И АВТООПРЕДЕЛЕНИЕ
# ==============================================================================

C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

MODULE_CANCELED=false

# Безопасное добавление (а не перезапись) путей
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Глобальные переменные UI
export TERM_COLS=$(tput cols 2>/dev/null || echo 85)
export TERM_LINES=$(tput lines 2>/dev/null || echo 27)
export WT_WIDTH=$((TERM_COLS < 85 ? TERM_COLS : 85))
export WT_HEIGHT=$((TERM_LINES < 27 ? TERM_LINES : 27))

SYSTEM_TYPE="Cloud_VPS"
if [ -f /etc/armbian-release ] || [ -f /etc/default/armbian-zram ] || grep -q -i "armbian\|nanopi\|raspberry" /etc/os-release 2>/dev/null; then
    SYSTEM_TYPE="SBC_Armbian"
elif [ -d /sys/class/power_supply ] && ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
    SYSTEM_TYPE="Laptop_PC"
elif [ "$(systemctl get-default 2>/dev/null)" = "graphical.target" ]; then
    SYSTEM_TYPE="Desktop_PC"
fi

DEFAULT_WAN_IF=$(ip route show default 2>/dev/null | grep -v tailscale0 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || echo "")

silent_run() { "$@" >/dev/null 2>&1 || true; }

get_sshd_cmd() {
    if command -v sshd &>/dev/null; then echo "sshd"
    elif [ -x /usr/sbin/sshd ]; then echo "/usr/sbin/sshd"
    elif [ -x /sbin/sshd ]; then echo "/sbin/sshd"
    else echo ""; fi
}

get_active_user() {
    local u="${SUDO_USER:-${LOGNAME:-${USER:-}}}"
    if [ -z "$u" ] || [ "$u" = "root" ]; then
        u=$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $1!="nobody" {print $1; exit}' || echo "")
    fi
    if [ -z "$u" ]; then u=$(id -nu 2>/dev/null || logname 2>/dev/null || echo "nobody"); fi
    echo "$u"
}

get_tailscale_whoami() {
    local raw=$(tailscale whoami 2>/dev/null || echo "")
    local ts_user="N/A"
    local ts_name="N/A"
    
    if [ -n "$raw" ]; then
        ts_user=$(echo "$raw" | grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | head -n 1 || echo "N/A")
        ts_name=$(echo "$raw" | grep -oE '[a-zA-Z0-9.-]+\.(ts|tailscale)\.net' | head -n 1 || echo "N/A")
        
        if [ "$ts_name" = "N/A" ]; then
            ts_name=$(tailscale status --peers=false 2>/dev/null | awk 'NR==1 {print $2}')
            [ -z "$ts_name" ] && ts_name="N/A"
        fi
    fi
    echo "${ts_name}|${ts_user}"
}

is_tailscale_authenticated() {
    ! command -v tailscale &>/dev/null && return 1
    local ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    [ -n "$ts_ip" ] && return 0
    local status_out=$(tailscale status --peers=false 2>/dev/null || echo "Logged out")
    echo "$status_out" | grep -q -iE "Logged out|NeedsLogin|Stopped" && return 1
    return 0
}

is_tailscale_web_active() {
    local web_val=$(tailscale get webclient 2>/dev/null || echo "false")
    [ "$web_val" = "true" ] && return 0
    systemctl is-active --quiet tailscale-web.service 2>/dev/null && return 0
    ps aux 2>/dev/null | grep -v grep | grep -q -iE "tailscale.*web" && return 0
    return 1
}

enable_routing_optimizations() {
    cat << 'ETHTOOL_SCRIPT_EOF' > /usr/local/bin/tailscale-gro.sh
#!/bin/bash
while ! ip route show default | grep -v tailscale0 >/dev/null 2>&1; do sleep 2; done
NETDEV=$(ip route show default | grep -v tailscale0 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
if [ -n "$NETDEV" ]; then
    ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off || true
fi
ETHTOOL_SCRIPT_EOF
    chmod +x /usr/local/bin/tailscale-gro.sh

    tee /etc/systemd/system/tailscale-gro.service > /dev/null << 'ETHTOOL_SVC_EOF'
[Unit]
Description=Ethtool rx-udp-gro-forwarding for Tailscale
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/tailscale-gro.sh
[Install]
WantedBy=multi-user.target
ETHTOOL_SVC_EOF
    systemctl daemon-reload
    silent_run systemctl enable --now tailscale-gro.service

    if dpkg -l | grep -qw iptables-persistent; then
        silent_run systemctl stop netfilter-persistent 2>/dev/null
        silent_run systemctl disable netfilter-persistent 2>/dev/null
        silent_run apt-get purge -yq iptables-persistent netfilter-persistent
        echo -e "${C_BLUE}ℹ️ Удален конфликтующий пакет iptables-persistent (управление возвращено UFW).${C_RESET}"
    fi

    if command -v ufw &>/dev/null && [ -f /etc/ufw/before.rules ]; then
        if ! grep -q "TCPMSS" /etc/ufw/before.rules; then
            sed -i '1s/^/*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n\n/' /etc/ufw/before.rules
        fi
        if [ -f /etc/ufw/before6.rules ] && ! grep -q "TCPMSS" /etc/ufw/before6.rules; then
            sed -i '1s/^/*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n\n/' /etc/ufw/before6.rules
        fi
        silent_run ufw reload
    fi

    iptables -t mangle -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    
    if command -v ip6tables &>/dev/null; then
        ip6tables -t mangle -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        ip6tables -t mangle -A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi

    echo -e "${C_GREEN}✅ Аппаратное ускорение (GRO) и нативная фиксация MTU (MSS Clamping в UFW) успешно включены.${C_RESET}"
}

is_port_free() {
    local port_raw="$1"
    local port=$(echo "$port_raw" | tr -dc '0-9')
    [ -z "$port" ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ] && return 1

    if command -v ss &>/dev/null; then
        ss -tulnH "sport = :$port" 2>/dev/null | grep -q . && return 1
        return 0
    fi
    if command -v lsof &>/dev/null; then
        lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null && return 1
        return 0
    fi

    local hex_port=$(printf '%04X' "$port")
    grep -qwi "$hex_port" /proc/net/tcp /proc/net/tcp6 2>/dev/null && return 1
    return 0
}

get_interface_subnet() {
    local iface="$1"
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 | cut -d. -f1-3 || echo ""
}

ensure_tailscale_installed() {
    if ! command -v tailscale &>/dev/null; then
        echo -e "${C_BLUE}📦 Установка пакета Tailscale в систему...${C_RESET}"
        curl -fsSL https://tailscale.com/install.sh | sh

        mkdir -p /etc/systemd/system/tailscaled.service.d
        cat << 'TS_OVERRIDE' > /etc/systemd/system/tailscaled.service.d/override.conf
[Unit]
After=network-online.target NetworkManager-wait-online.service systemd-networkd-wait-online.service
Wants=network-online.target
TS_OVERRIDE
        systemctl daemon-reload

        mkdir -p /etc/sysctl.d
        tee /etc/sysctl.d/99-tailscale-forward.conf > /dev/null << 'TS_EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
TS_EOF
        sysctl --system > /dev/null
    fi

    if is_tailscale_authenticated; then
        local current_ip=$(tailscale ip -4 2>/dev/null || echo "100.x.x.x")
        echo -e "${C_GREEN}✅ Узел уже подключен к сети (IP: $current_ip).${C_RESET}"
        return 0
    fi

    echo -e "${C_CYAN}🔑 Первичное подключение узла...${C_RESET}"
    local authkey=""
    prompt_clean "Ключ авторизации (Оставьте пустым для входа по ссылке)" authkey
    if [ "$MODULE_CANCELED" = true ]; then
        MODULE_CANCELED=false
        return 1
    fi

    if [ -n "$authkey" ]; then
        silent_run tailscale up --authkey="$authkey" --force-reauth
    else
        echo -e "${C_BLUE}ℹ️ Запрос ссылки авторизации... Скопируйте ссылку, которая появится ниже:${C_RESET}"
        tailscale up --force-reauth || true
        echo ""
        whiptail --title "Авторизация" --msgbox "Если вы перешли по ссылке выше и подтвердили авторизацию в браузере, нажмите ОК для продолжения настройки." 10 $WT_WIDTH
    fi

    silent_run tailscale set --auto-update
    echo -e "${C_GREEN}✅ Узел успешно подключен.${C_RESET}"
    return 0
}

# ------------------------------------------------------------------------------
# БЕЗОПАСНЫЕ ФУНКЦИИ ВВОДА WHIPTAIL
# ------------------------------------------------------------------------------
prompt_yn() {
    local prompt="$1"
    local default_yes="$2"
    if [ "$default_yes" = "true" ]; then
        if whiptail --title "Подтверждение" --yesno "$prompt" 11 $WT_WIDTH; then return 0; else return 1; fi
    else
        if whiptail --title "Подтверждение" --yesno "$prompt" 11 $WT_WIDTH --defaultno; then return 0; else return 1; fi
    fi
}

prompt_default() {
    local prompt="$1"
    local default_val="$2"
    local var_name="$3"
    local val
    if val=$(whiptail --title "Ввод данных" --inputbox "$prompt" 10 $WT_WIDTH "$default_val" 3>&1 1>&2 2>&3); then
        printf -v "$var_name" "%s" "${val:-$default_val}"
        return 0
    else
        echo -e "${C_YELLOW}↩️ Отмена. Возврат в меню...${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi
}

prompt_clean() {
    local prompt="$1"
    local var_name="$2"
    local val
    if val=$(whiptail --title "Ввод данных" --inputbox "$prompt" 10 $WT_WIDTH 3>&1 1>&2 2>&3); then
        printf -v "$var_name" "%s" "$val"
        return 0
    else
        echo -e "${C_YELLOW}↩️ Отмена. Возврат в меню...${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi
}

backup_file() {
    local file="$1"
    if [ -f "$file" ] && [ ! -f "${file}.bak" ]; then
        cp "$file" "${file}.bak"
        echo -e "${C_BLUE}💾 Создана резервная копия: ${file}.bak${C_RESET}"
    fi
}

pause_enter() {
    echo ""
    read -r -p "Нажмите Enter для возврата в меню..." < /dev/tty || true
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${C_RED}❌ Ошибка: этот скрипт должен запускаться от имени суперпользователя (root).${C_RESET}" >&2
    exit 1
fi

# ==============================================================================
# МОДУЛИ НАСТРОЙКИ
# ==============================================================================

# 1. Часовой пояс
mod_timezone() {
    echo -e "${C_CYAN}🌐 === 1/18. НАСТРОЙКА ЧАСОВОГО ПОЯСА ===${C_RESET}"
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Europe/Moscow")
    echo "Текущий часовой пояс: $current_tz"
    local tz=""
    prompt_default "Введите новый часовой пояс:" "$current_tz" tz
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    silent_run timedatectl set-timezone "$tz"
    echo -e "${C_GREEN}✅ Часовой пояс установлен в $tz.${C_RESET}"
}

# 2. Имя хоста
mod_hostname() {
    echo -e "${C_CYAN}🏷️ === 2/18. НАСТРОЙКА ИМЕНИ ХОСТА ===${C_RESET}"
    echo "Текущее имя хоста: $(hostname)"
    
    local default_brand_host="Server_VPS"
    case "$SYSTEM_TYPE" in
        SBC_Armbian) default_brand_host="Server_SBC" ;;
        Desktop_PC|Laptop_PC) default_brand_host="Server_PC" ;;
    esac

    local new_host=""
    prompt_default "Введите новое имя сервера:" "$default_brand_host" new_host
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    hostnamectl set-hostname "$new_host"
    if ! grep -q "$new_host" /etc/hosts; then
        silent_run sed -i -E "s/^127\.0\.0\.1[[:space:]]+localhost/& $new_host/" /etc/hosts
    fi
    silent_run sed -i 's/preserve_hostname: false/preserve_hostname: true/g' /etc/cloud/cloud.cfg
    echo -e "${C_GREEN}✅ Имя сервера изменено на $new_host.${C_RESET}"
}

# 3. Обновление пакетов
mod_apt_update() {
    echo -e "${C_CYAN}📦 === 3/18. ОБНОВЛЕНИЕ ПАКЕТОВ И ОЧИСТКА ===${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get upgrade -yq

    local zram_pkg="zram-tools"
    if [ -f /etc/default/armbian-zram ] || [ -f /etc/init.d/armbian-zram ]; then
        echo -e "${C_BLUE}ℹ️ Обнаружен встроенный менеджер памяти Armbian. Сторонняя утилита zram-tools пропущена.${C_RESET}"
        zram_pkg=""
        # ИСПРАВЛЕНИЕ МИНЫ №3: Больше не отключаем системный ZRAM!
    fi

    apt-get install -yq sudo ufw unattended-upgrades ethtool curl wget ca-certificates gnupg whiptail jq $zram_pkg
    silent_run dpkg-reconfigure --priority=low unattended-upgrades
    apt-get autoremove -yq && apt-get clean
    systemctl enable unattended-upgrades

    local current_target=$(systemctl get-default)
    echo "Текущий режим загрузки: $current_target"

    if [ "$current_target" = "graphical.target" ]; then
        if prompt_yn "⚠️ Обнаружена графическая оболочка ($SYSTEM_TYPE). Переключить систему в консольный режим работы?" "false"; then
            systemctl set-default multi-user.target
            echo -e "${C_BLUE}ℹ️ Режим загрузки изменен на консольный.${C_RESET}"
        else
            if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        fi
    else
        systemctl set-default multi-user.target
    fi
    echo -e "${C_GREEN}✅ Система успешно обновлена, базовые утилиты установлены.${C_RESET}"
}

# 4. Пользователь и Sudo
mod_user_setup() {
    echo -e "${C_CYAN}👤 === 4/18. СОЗДАНИЕ И НАСТРОЙКА ПОЛЬЗОВАТЕЛЯ ===${C_RESET}"
    local active_user=$(get_active_user)
    local username=""
    prompt_default "Имя администратора:" "$active_user" username
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    if ! id "$username" &>/dev/null; then
        if getent group "$username" &>/dev/null; then
            adduser --disabled-password --gecos "" --ingroup users "$username" || true
        else
            adduser --disabled-password --gecos "" "$username" || true
        fi
        
        if ! id "$username" &>/dev/null; then
            useradd -m -s /bin/bash "$username" || true
        fi
        echo -e "${C_GREEN}✅ Учетная запись $username создана.${C_RESET}"
    fi
    
    usermod -aG sudo "$username" || true

    local pass
    if ! pass=$(whiptail --title "Пароль" --passwordbox "Введите новый пароль для $username (пусто - отмена):" 10 $WT_WIDTH 3>&1 1>&2 2>&3); then
        echo -e "${C_YELLOW}ℹ️ Смена пароля отменена.${C_RESET}"
    elif [ -z "$pass" ]; then
        echo -e "${C_YELLOW}ℹ️ Смена пароля пропущена.${C_RESET}"
    else
        local pass_confirm
        if ! pass_confirm=$(whiptail --title "Подтверждение" --passwordbox "Повторите пароль:" 10 $WT_WIDTH 3>&1 1>&2 2>&3); then
            echo -e "${C_RED}❌ Отмена. Пароль не изменен.${C_RESET}"
        elif [ "$pass" != "$pass_confirm" ]; then
            echo -e "${C_RED}❌ Введенные пароли не совпадают. Попробуйте снова.${C_RESET}"
        else
            echo "$username:$pass" | chpasswd
            echo -e "${C_GREEN}✅ Пароль успешно установлен.${C_RESET}"
        fi
    fi

    if prompt_yn "Разрешить этому пользователю выполнять команды от имени администратора без запроса пароля?" "true"; then
        echo "$username ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$username"
        chmod 0440 "/etc/sudoers.d/$username"
        echo -e "${C_GREEN}✅ Беспарольный доступ включен.${C_RESET}"
    else
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        rm -f "/etc/sudoers.d/$username"
        echo "ℹ️ Система будет запрашивать пароль при каждом повышении прав."
    fi
}

# 5. SSH-ключи
mod_ssh_key() {
    echo -e "${C_CYAN}🔑 === 5/18. НАСТРОЙКА КЛЮЧЕЙ ДОСТУПА ===${C_RESET}"
    local active_user=$(get_active_user)
    local target_user=""
    prompt_default "Для какого пользователя привязать ключ?" "$active_user" target_user
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    if ! id "$target_user" &>/dev/null; then
        echo "Пользователь $target_user не найден, создаем..."
        adduser --disabled-password --gecos "" "$target_user"
        usermod -aG sudo "$target_user"
    fi

    local target_home=$(getent passwd "$target_user" | cut -d: -f6)
    [ -z "$target_home" ] && target_home="/home/$target_user"

    mkdir -p "$target_home/.ssh"

    local pubkey=""
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        local root_key=$(head -n 1 /root/.ssh/authorized_keys)
        if prompt_yn "Скопировать существующий ключ безопасности из профиля root?" "true"; then
            pubkey="$root_key"
        fi
    fi

    if [ -z "$pubkey" ]; then
        if ! pubkey=$(whiptail --title "Ввод ключа" --inputbox "Вставьте ваш публичный ключ безопасности (ssh-ed25519, ssh-rsa и т.д.):" 10 $WT_WIDTH 3>&1 1>&2 2>&3) || [ -z "$pubkey" ]; then
            echo -e "${C_YELLOW}↩️ Отмена. Возврат в главное меню...${C_RESET}"
            return 0
        fi
    fi

    if [ -n "$pubkey" ]; then
        local mode_choice
        if ! mode_choice=$(whiptail --title "Параметры сохранения" --menu "Выберите действие:" 12 $WT_WIDTH 2 \
        "1" "Добавить ключ в существующий список" \
        "2" "Полностью перезаписать список ключей" 3>&1 1>&2 2>&3); then
            echo -e "${C_YELLOW}↩️ Отмена сохранения.${C_RESET}"
            return 0
        fi

        if [ "$mode_choice" = "2" ]; then
            echo "$pubkey" > "$target_home/.ssh/authorized_keys"
            echo -e "${C_GREEN}✅ Файл с ключами перезаписан.${C_RESET}"
        else
            if ! grep -qF "$pubkey" "$target_home/.ssh/authorized_keys" 2>/dev/null; then
                echo "$pubkey" >> "$target_home/.ssh/authorized_keys"
                echo -e "${C_GREEN}✅ Ключ успешно добавлен.${C_RESET}"
            else
                echo -e "${C_BLUE}ℹ️ Этот ключ уже привязан к профилю.${C_RESET}"
            fi
        fi
    fi

    silent_run chmod 755 "$target_home"
    chmod 700 "$target_home/.ssh"
    silent_run chmod 600 "$target_home/.ssh/authorized_keys"
    chown -R "$target_user:$target_user" "$target_home/.ssh"
    echo -e "${C_GREEN}✅ Права доступа к директории ключей проверены и настроены.${C_RESET}"
}

# 6. Конфигурация SSH
mod_ssh_config() {
    echo -e "${C_CYAN}🔒 === 6/18. БЕЗОПАСНОСТЬ УДАЛЕННОГО ДОСТУПА ===${C_RESET}"
    backup_file "/etc/ssh/sshd_config"

    silent_run sed -i -E 's/^\s*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)\s+/# &/g' /etc/ssh/sshd_config

    local sshd_cmd=$(get_sshd_cmd)
    local active_ssh_port="22"
    if [ -n "$sshd_cmd" ]; then
        active_ssh_port=$($sshd_cmd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")
    fi
    active_ssh_port=$(echo "$active_ssh_port" | tr -dc '0-9')

    local port=""
    while true; do
        prompt_default "Введите сетевой порт для удаленного подключения:" "${active_ssh_port:-22}" port
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        port=$(echo "$port" | tr -dc '0-9')

        if [ -z "$port" ]; then
            whiptail --msgbox "Ошибка: Значение порта должно состоять только из цифр." 8 $WT_WIDTH
            continue
        fi

        if [ "$port" != "$active_ssh_port" ] && ! is_port_free "$port"; then
            if ! prompt_yn "Внимание: Указанный порт, возможно, занят. Вы всё равно хотите его использовать?" "false"; then
                if [ "$MODULE_CANCELED" = true ]; then return 0; fi
                continue
            fi
        fi
        break
    done

    local active_user=$(get_active_user)
    local user_home=$(getent passwd "$active_user" | cut -d: -f6)
    [ -z "$user_home" ] && user_home="/home/$active_user"
    
    local pass_auth_val="yes"
    local kbd_auth_val="yes"

    if [ -s "$user_home/.ssh/authorized_keys" ] || [ -s "/root/.ssh/authorized_keys" ]; then
        if whiptail --title "Подтверждение" --yesno "Отключить авторизацию по паролю\n(разрешить доступ ТОЛЬКО по привязанным ключам)?" 11 $WT_WIDTH; then
            pass_auth_val="no"
            kbd_auth_val="no"
            echo -e "${C_GREEN}✅ Выбрано: Вход по паролю будет отключен.${C_RESET}"
        else
            echo -e "${C_YELLOW}⚠️ Выбрано: Вход по паролю оставлен включенным.${C_RESET}"
        fi
    else
        whiptail --msgbox "Внимание: На сервере не найдено ни одного привязанного ключа безопасности!\nВход по паролю ОСТАЕТСЯ ВКЛЮЧЕННЫМ для предотвращения полной потери доступа." 11 $WT_WIDTH
        echo -e "${C_YELLOW}⚠️ Вход по паролю сохранен.${C_RESET}"
    fi

    local disable_root="no"
    if whiptail --title "Подтверждение" --yesno "Запретить прямой вход для пользователя root по SSH?" 11 $WT_WIDTH; then
        disable_root="no"
        echo -e "${C_GREEN}✅ Выбрано: Вход для root запрещен.${C_RESET}"
    else
        disable_root="yes"
        echo -e "${C_YELLOW}⚠️ Выбрано: Вход для root разрешен.${C_RESET}"
    fi

    local conf_dir="/etc/ssh/sshd_config.d"
    mkdir -p "$conf_dir"
    
    if [ -f /etc/ssh/sshd_config ]; then
        silent_run sed -i '/^\s*Include \/etc\/ssh\/sshd_config\.d\/\*\.conf/d' /etc/ssh/sshd_config
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi

    local ts_restrict_comment=""
    local restrict_choice=false
    if prompt_yn "Скрыть доступ к серверу (разрешить подключения только участникам вашей закрытой сети Tailscale)?" "true"; then
        restrict_choice=true
        ts_restrict_comment="# SSH via Tailscale only"
    fi

    echo -e "${C_BLUE}🧹 Очистка сторонних конфигураций SSH...${C_RESET}"
    rm -f "$conf_dir"/*.conf 2>/dev/null
    
    local conf_file="$conf_dir/00-bobarev-security.conf"
    
    tee "$conf_file" > /dev/null << SSH_HARDENING_EOF
# Server Security Hardening Configuration
$ts_restrict_comment
Port $port
PermitRootLogin $disable_root
PubkeyAuthentication yes
PasswordAuthentication $pass_auth_val
KbdInteractiveAuthentication $kbd_auth_val
AuthorizedKeysFile .ssh/authorized_keys
StrictModes yes
UsePAM yes
MaxAuthTries 3
MaxSessions 3
MaxStartups 10:30:60
AllowTcpForwarding yes
PermitTunnel no
GatewayPorts clientspecified
AllowAgentForwarding no
X11Forwarding no
PermitTTY yes
PrintMotd no
TCPKeepAlive yes
SSH_HARDENING_EOF

    local test_ok=false
    if [ -n "$sshd_cmd" ]; then
        if $sshd_cmd -t 2>/dev/null; then test_ok=true; fi
    else
        test_ok=true
    fi

    if [ "$test_ok" = true ]; then
        silent_run systemctl disable --now ssh.socket
        silent_run systemctl enable --now ssh.service
        silent_run systemctl restart sshd
        silent_run systemctl restart ssh

        if [ "$restrict_choice" = true ]; then
            if ensure_tailscale_installed || true; then
                if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
                    silent_run ufw allow in on tailscale0 to any port "$port" proto tcp comment 'SSH via Tailscale only'
                    silent_run ufw delete allow "$port"/tcp
                    echo -e "${C_GREEN}✅ Сервер изолирован от интернета: удаленный доступ разрешен ТОЛЬКО из закрытой сети.${C_RESET}"
                else
                    echo -e "${C_BLUE}ℹ️ Правило изоляции сохранено. Оно вступит в силу при включении брандмауэра (Модуль 8).${C_RESET}"
                fi
            else
                echo -e "${C_YELLOW}⚠️ Подключение к закрытой сети отменено. Оставлен обычный публичный доступ.${C_RESET}"
                silent_run ufw allow "$port"/tcp comment 'SSH Public Port'
            fi
        else
            silent_run ufw allow "$port"/tcp comment 'SSH Public Port'
        fi
        echo -e "${C_GREEN}✅ Служба удаленного доступа успешно перезапущена с абсолютным приоритетом параметров.${C_RESET}"
    else
        echo -e "${C_RED}❌ Ошибка применения параметров безопасности! Выполнен откат изменений...${C_RESET}"
        rm -f "$conf_file"
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi
}

# 7. Защита ядра и сети
mod_hardening() {
    echo -e "${C_CYAN}🛡️ === 7/18. ЗАЩИТА ЯДРА И УСКОРЕНИЕ МАРШРУТИЗАЦИИ ===${C_RESET}"
    backup_file "/etc/sysctl.d/99-hardening.conf"
    
    silent_run modprobe tcp_bbr

    mkdir -p /etc/sysctl.d
    tee /etc/sysctl.d/99-server-hardening.conf > /dev/null << 'HARDENING_EOF'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
kernel.unprivileged_bpf_disabled = 1
kernel.perf_event_paranoid = 3
kernel.sysrq = 0
net.core.bpf_jit_harden = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_echo_ignore_all = 1
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 1
fs.protected_regular = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 0
HARDENING_EOF
    sysctl --system > /dev/null
    echo -e "${C_GREEN}✅ Настройки системной защиты и ускорения сетевых протоколов успешно применены.${C_RESET}"
}

# 8. Firewall UFW
mod_ufw() {
    echo -e "${C_CYAN}🧱 === 8/18. НАСТРОЙКА БРАНДМАУЭРА ===${C_RESET}"
    
    local active_ssh_port="22"
    local sshd_cmd=$(get_sshd_cmd)
    if [ -n "$sshd_cmd" ]; then
        active_ssh_port=$($sshd_cmd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")
    fi
    active_ssh_port=$(echo "$active_ssh_port" | tr -dc '0-9')
    local port="${active_ssh_port:-22}"

    echo -e "${C_BLUE}ℹ️ Автоматически определен порт SSH: $port${C_RESET}"

    silent_run ufw --force reset
    silent_run ufw default deny incoming
    silent_run ufw default allow outgoing

    if prompt_yn "Разрешить сквозную маршрутизацию пакетов (необходимо для работы в качестве роутера)?" "true"; then
        silent_run ufw default allow routed
        silent_run sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    else
        silent_run ufw default deny routed
        silent_run sed -i 's/DEFAULT_FORWARD_POLICY="ACCEPT"/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
    fi

    local is_ts_restricted_in_mod6=false
    if grep -q "SSH via Tailscale only" /etc/ssh/sshd_config.d/00-bobarev-security.conf 2>/dev/null; then
        is_ts_restricted_in_mod6=true
    fi

    local do_restrict=false
    if [ "$is_ts_restricted_in_mod6" = true ]; then
        echo -e "${C_BLUE}ℹ️ Ограничение удаленного доступа применено автоматически.${C_RESET}"
        do_restrict=true
    elif prompt_yn "Разрешить подключения к серверу ТОЛЬКО участникам вашей закрытой сети Tailscale?" "true"; then
        do_restrict=true
    fi

    if [ "$do_restrict" = true ]; then
        if ensure_tailscale_installed || true; then
            silent_run ufw allow in on tailscale0 comment 'Allow inside Tailscale'
            silent_run ufw allow 41641/udp comment 'Tailscale Direct P2P'
            local netdev="$DEFAULT_WAN_IF"
            if [ -n "$netdev" ]; then
                silent_run ufw route allow in on tailscale0 out on "$netdev"
                silent_run ufw route allow in on "$netdev" out on tailscale0
            fi
            silent_run ufw allow in on tailscale0 to any port "$port" proto tcp comment 'SSH via Tailscale only'
            echo -e "${C_GREEN}✅ Брандмауэр настроен: подключения разрешены ТОЛЬКО из закрытой сети.${C_RESET}"
        else
            silent_run ufw allow "$port"/tcp comment 'SSH Public Port'
        fi
    else
        silent_run ufw allow "$port"/tcp comment 'SSH Public Port'
    fi

    silent_run ufw --force enable
    silent_run ufw logging off
    echo -e "${C_GREEN}✅ Межсетевой экран (UFW) включен и активно защищает систему.${C_RESET}"
}

# 9. Блокировка Root
mod_lock_root() {
    local mode="${1:-}"
    if [ "$mode" = "auto" ]; then
        if prompt_yn "Заблокировать прямой доступ для суперпользователя (root)?" "true"; then
            if [ $(getent group sudo | cut -d: -f4 | tr ',' ' ' | wc -w) -gt 0 ]; then
                silent_run passwd -l root
                echo -e "${C_GREEN}✅ Доступ для суперпользователя заблокирован.${C_RESET}"
            fi
        fi
        return 0
    fi

    echo -e "${C_CYAN}🔐 === 9/18. УПРАВЛЕНИЕ СИСТЕМНЫМ ДОСТУПОМ ===${C_RESET}"
    
    local root_choice
    if ! root_choice=$(whiptail --title "Системный доступ" --menu "Выберите желаемое действие:" 12 $WT_WIDTH 2 \
    "1" "Заблокировать" \
    "2" "Разблокировать" 3>&1 1>&2 2>&3); then
        return 0
    fi

    case "$root_choice" in
        1)
            if [ $(getent group sudo | cut -d: -f4 | tr ',' ' ' | wc -w) -gt 0 ]; then
                silent_run passwd -l root
                echo -e "${C_GREEN}✅ Доступ для суперпользователя заблокирован.${C_RESET}"
            else
                echo -e "${C_YELLOW}⚠️ В системе нет других администраторов! Блокировка отменена для сохранения контроля.${C_RESET}"
            fi
            ;;
        2) silent_run passwd -u root; echo -e "${C_GREEN}✅ Доступ для суперпользователя разблокирован.${C_RESET}" ;;
    esac
}
mod_lock_root_auto() { mod_lock_root "auto"; }

# 10. Tailscale
mod_tailscale() {
    local mode="${1:-}"
    if [ "$mode" = "auto" ]; then
        if command -v tailscale &>/dev/null; then
            echo -e "${C_BLUE}ℹ️ Пакет Tailscale уже установлен. Применение дополнительных настроек...${C_RESET}"
            ensure_tailscale_installed || true
            enable_routing_optimizations || true
        else
            if prompt_yn "Установить и настроить закрытую сеть Tailscale на этом сервере?" "true"; then
                ensure_tailscale_installed || true
                enable_routing_optimizations || true
            else
                echo -e "${C_YELLOW}⏭️ Установка Tailscale пропущена пользователем.${C_RESET}"
            fi
        fi
        return 0
    fi

    while true; do
        local ts_choice
        if ! ts_choice=$(whiptail --title "Настройка закрытой сети" --menu "Управление сетевым узлом:" 18 $WT_WIDTH 9 \
        "1" "🔑 Авторизация" \
        "2" "🌐 Настройка шлюза (Exit Node)" \
        "3" "🔀 Трансляция локальных сетей" \
        "4" "🛡️ Прием маршрутов" \
        "5" "🔒 Стелс-режим" \
        "6" "⚡ Ускорение и MSS Clamping" \
        "7" "💻 Локальный веб-интерфейс" \
        "8" "🔄 Полный сброс" \
        "0" "↩️ Вернуться назад" 3>&1 1>&2 2>&3); then
            break
        fi

        if [ "$ts_choice" = "0" ]; then break; fi
        clear

        case "$ts_choice" in
            1)
                if is_tailscale_authenticated; then
                    if prompt_yn "Узел уже находится в сети. Желаете выполнить повторную привязку?" "false"; then
                        local authkey=""
                        prompt_clean "Ключ авторизации:" authkey
                        if [ -n "$authkey" ]; then
                            silent_run tailscale up --authkey="$authkey" --force-reauth
                        else
                            silent_run tailscale up --force-reauth
                            read -r -p "Нажмите Enter ПОСЛЕ подтверждения в браузере..." < /dev/tty || true
                        fi
                    fi
                else
                    ensure_tailscale_installed || true
                fi
                pause_enter
                ;;
            2)
                local en_choice
                if en_choice=$(whiptail --title "Настройка шлюза" --menu "Действие:" 12 $WT_WIDTH 4 "1" "Назначить этот сервер шлюзом" "2" "Отключить трансляцию шлюза" "3" "Подключиться к удаленному шлюзу" "4" "Отключиться от шлюза" 3>&1 1>&2 2>&3); then
                    case "$en_choice" in
                        1) 
                            silent_run tailscale set --advertise-exit-node=true
                            # ИСПРАВЛЕНИЕ МИНЫ №1: Принудительно разрешаем маршрутизацию UFW для Exit Node
                            if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
                                silent_run ufw route allow in on tailscale0 comment 'Tailscale Exit Node Forwarding'
                                silent_run ufw route allow out on tailscale0 comment 'Tailscale Exit Node Forwarding'
                            fi
                            echo -e "${C_GREEN}✅ Сервер объявлен сетевым шлюзом.${C_RESET}" 
                            ;;
                        2) silent_run tailscale set --advertise-exit-node=false; echo -e "${C_GREEN}✅ Функция сетевого шлюза отключена.${C_RESET}" ;;
                        3)
                            local target_ip=""
                            prompt_clean "IP-адрес или имя удаленного шлюза:" target_ip
                            if [ -n "$target_ip" ]; then
                                silent_run tailscale set --exit-node="$target_ip" --exit-node-allow-lan-access
                                echo -e "${C_GREEN}✅ Весь трафик перенаправлен через выбранный узел.${C_RESET}"
                            fi
                            ;;
                        4) silent_run tailscale set --exit-node=; echo -e "${C_GREEN}✅ Перенаправление трафика отключено.${C_RESET}" ;;
                    esac
                fi
                pause_enter
                ;;
            3)
                local sub=$(get_interface_subnet "$DEFAULT_WAN_IF")
                local r_input=""
                prompt_default "Сетевой диапазон для трансляции:" "${sub}.0/24" r_input
                if [ -n "$r_input" ]; then
                    silent_run tailscale set --advertise-routes="$r_input"
                    echo -e "${C_GREEN}✅ Выбранный диапазон ($r_input) транслируется в общую сеть.${C_RESET}"
                fi
                pause_enter
                ;;
            4)
                if prompt_yn "Разрешить принятие внешних сетевых маршрутов от других устройств в вашей сети?" "true"; then
                    silent_run tailscale set --accept-routes=true; echo -e "${C_GREEN}✅ Принятие маршрутов включено.${C_RESET}"
                else
                    silent_run tailscale set --accept-routes=false; echo -e "${C_BLUE}✅ Принятие маршрутов отключено.${C_RESET}"
                fi
                pause_enter
                ;;
            5)
                if prompt_yn "Включить скрытый режим работы (отбрасывание нежелательного входящего трафика)?" "true"; then
                    silent_run tailscale set --stateful-filtering=true; echo -e "${C_GREEN}✅ Скрытый режим работы активирован.${C_RESET}"
                else
                    silent_run tailscale set --stateful-filtering=false; echo -e "${C_BLUE}✅ Скрытый режим отключен.${C_RESET}"
                fi
                pause_enter
                ;;
            6)
                if prompt_yn "Активировать аппаратное ускорение и нативную фиксацию MTU (MSS Clamping)?" "true"; then enable_routing_optimizations; fi
                pause_enter
                ;;
            7)
                if prompt_yn "Включить встроенную панель управления в браузере?" "true"; then
                    silent_run tailscale set --webclient=true
                    echo -e "${C_GREEN}✅ Встроенная панель управления успешно запущена.${C_RESET}"
                else
                    silent_run tailscale set --webclient=false
                    echo -e "${C_BLUE}✅ Панель управления остановлена.${C_RESET}"
                fi
                pause_enter
                ;;
            8)
                if prompt_yn "Полностью сбросить все сетевые параметры к заводским значениям?" "false"; then
                    tailscale up --reset 2>&1 | grep -v "accept-routes" || true
                    echo -e "${C_GREEN}✅ Сетевые параметры очищены.${C_RESET}"
                fi
                pause_enter
                ;;
        esac
    done
}
mod_tailscale_auto() { mod_tailscale "auto"; }

# 11. Управление логированием (Интерактивный менеджер)
mod_logging_manager() {
    echo -e "${C_CYAN}📝 === 11/18. УПРАВЛЕНИЕ СИСТЕМНЫМИ ЖУРНАЛАМИ ===${C_RESET}"
    
    local log_choice
    if ! log_choice=$(whiptail --title "Управление логами" --menu "Выберите режим работы системных журналов:" 14 $WT_WIDTH 4 \
    "1" "Безопасное ограничение (100 МБ / 1 месяц)" \
    "2" "Указать свой лимит (Custom)" \
    "3" "Полностью отключить логирование (Stealth)" \
    "0" "Оставить без изменений" 3>&1 1>&2 2>&3); then
        return 0
    fi
    
    if [ "$log_choice" = "0" ]; then return 0; fi
    
    backup_file "/etc/systemd/journald.conf"
    
    if [ "$log_choice" = "1" ] || [ "$log_choice" = "2" ]; then
        local log_size="100M"
        if [ "$log_choice" = "2" ]; then
            prompt_default "Введите максимальный размер логов (например: 50M, 200M, 1G):" "100M" log_size
            [ "$MODULE_CANCELED" = true ] && return 0
        fi
        
        silent_run sed -i -E '/^\s*#?\s*(Storage|ForwardToSyslog|ForwardToKMsg|ForwardToConsole|ForwardToWall)=/d' /etc/systemd/journald.conf
        silent_run sed -i -E 's/^\s*#?\s*SystemMaxUse=.*/SystemMaxUse='"$log_size"'/' /etc/systemd/journald.conf
        if ! grep -q "^SystemMaxUse=" /etc/systemd/journald.conf; then
            echo "SystemMaxUse=$log_size" >> /etc/systemd/journald.conf
        fi
        silent_run sed -i -E 's/^\s*#?\s*MaxRetentionSec=.*/MaxRetentionSec=1month/' /etc/systemd/journald.conf
        if ! grep -q "^MaxRetentionSec=" /etc/systemd/journald.conf; then
            echo "MaxRetentionSec=1month" >> /etc/systemd/journald.conf
        fi
        
        silent_run systemctl restart systemd-journald
        silent_run systemctl disable clean-logs-boot.service 2>/dev/null || true
        rm -f /usr/local/bin/disable-logging.sh
        
        echo -e "${C_GREEN}✅ Системные журналы безопасно ограничены объемом $log_size.${C_RESET}"
    
    elif [ "$log_choice" = "3" ]; then
        cat << 'DISABLE_LOGS_EOF' > /usr/local/bin/disable-logging.sh
#!/bin/bash
set -euo pipefail
sed -i -E '/^\s*#?\s*(Storage|ForwardToSyslog|ForwardToKMsg|ForwardToConsole|ForwardToWall)=/d' /etc/systemd/journald.conf
cat << 'CONF' >> /etc/systemd/journald.conf
[Journal]
Storage=none
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=no
CONF

journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
systemctl restart systemd-journald

for svc in rsyslog auditd armbian-hardware-monitor; do
  if systemctl list-unit-files | grep -q "^${svc}.service"; then
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
  fi
done
[ -x "$(command -v auditctl)" ] && auditctl -e 0 2>/dev/null || true
[ -x "$(command -v warp-cli)" ] && warp-cli log disable 2>/dev/null || true
[ -x "$(command -v ufw)" ] && ufw logging off >/dev/null 2>&1 || true

mkdir -p /etc/apt/apt.conf.d
cat << 'APT_CLEAN_EOF' > /etc/apt/apt.conf.d/99clean-logs
DPkg::Post-Invoke {"truncate -s 0 /var/log/dpkg.log /var/log/alternatives.log /var/log/apt/*.log 2>/dev/null || true";};
APT_CLEAN_EOF

find /var/log -type f \( -name "*.log*" -o -name "syslog*" -o -name "auth.log*" -o -name "kern.log*" -o -name "ufw.log*" -o -name "dpkg*" -o -name "wtmp*" -o -name "btmp*" -o -name "lastlog*" \) -exec truncate -s 0 {} + 2>/dev/null || true
find /var/log -type f \( -name "*.[0-9]" -o -name "*.gz" \) -delete 2>/dev/null || true
rm -rf /var/log/journal /run/log/journal 2>/dev/null || true
journalctl --vacuum-size=1M 2>/dev/null || true
DISABLE_LOGS_EOF

        chmod +x /usr/local/bin/disable-logging.sh

        tee /etc/systemd/system/clean-logs-boot.service > /dev/null << 'BOOT_CLEAN_SVC_EOF'
[Unit]
Description=Automated System Log Cleanup on Boot
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable-logging.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BOOT_CLEAN_SVC_EOF

        systemctl daemon-reload
        silent_run systemctl enable clean-logs-boot.service
        /usr/local/bin/disable-logging.sh
        echo -e "${C_GREEN}✅ Полное отключение системного журналирования успешно настроено.${C_RESET}"
    fi
}
mod_logging_manager_auto() {
    silent_run sed -i -E '/^\s*#?\s*(Storage|ForwardToSyslog|ForwardToKMsg|ForwardToConsole|ForwardToWall)=/d' /etc/systemd/journald.conf
    silent_run sed -i -E 's/^\s*#?\s*SystemMaxUse=.*/SystemMaxUse=100M/' /etc/systemd/journald.conf
    if ! grep -q "^SystemMaxUse=" /etc/systemd/journald.conf; then echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf; fi
    silent_run sed -i -E 's/^\s*#?\s*MaxRetentionSec=.*/MaxRetentionSec=1month/' /etc/systemd/journald.conf
    if ! grep -q "^MaxRetentionSec=" /etc/systemd/journald.conf; then echo "MaxRetentionSec=1month" >> /etc/systemd/journald.conf; fi
    silent_run systemctl restart systemd-journald
}

# 12. Оптимизация RAM / Flash
mod_ram_flash_opt() {
    echo -e "${C_CYAN}⚡ === 12/18. ОПТИМИЗАЦИЯ ПАМЯТИ И НАКОПИТЕЛЕЙ ===${C_RESET}"
    backup_file "/etc/fstab"

    mkdir -p /etc/sysctl.d
    cat << 'EOF' > /etc/sysctl.d/99-ram-opt.conf
vm.swappiness=1
vm.vfs_cache_pressure=50
vm.dirty_writeback_centisecs=1500
vm.dirty_background_ratio=5
vm.dirty_ratio=10
kernel.dmesg_restrict=1
EOF
    sysctl --system > /dev/null

    # ИСПРАВЛЕНИЕ МИНЫ №2: Проверка файловой системы перед установкой commit=120
    local root_fs=$(df -T / 2>/dev/null | awk 'NR==2 {print $2}' || echo "unknown")
    if [ "$root_fs" = "ext3" ] || [ "$root_fs" = "ext4" ]; then
        awk '
        BEGIN { OFS="\t" }
        !/^#/ && $2 == "/" {
            if ($4 !~ /(^|,)noatime(,|$)/) $4 = $4 ",noatime"
            if ($4 !~ /(^|,)commit=120(,|$)/) $4 = $4 ",commit=120"
        }
        { print }' /etc/fstab > /tmp/fstab.tmp && cat /tmp/fstab.tmp > /etc/fstab && rm -f /tmp/fstab.tmp

        local root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}' || echo "")
        if [ -n "$root_dev" ] && command -v tune2fs >/dev/null 2>&1; then
            silent_run tune2fs -E mount_opts=commit=120 "$root_dev"
        fi
        silent_run mount -o remount,noatime,commit=120 /
        echo -e "${C_GREEN}✅ Настройки noatime и commit=120 успешно применены (ФС: $root_fs).${C_RESET}"
    else
        # Если это BTRFS, XFS или другое, применяем только безопасный noatime
        awk '
        BEGIN { OFS="\t" }
        !/^#/ && $2 == "/" {
            if ($4 !~ /(^|,)noatime(,|$)/) $4 = $4 ",noatime"
        }
        { print }' /etc/fstab > /tmp/fstab.tmp && cat /tmp/fstab.tmp > /etc/fstab && rm -f /tmp/fstab.tmp
        silent_run mount -o remount,noatime /
        echo -e "${C_YELLOW}⚠️ Файловая система '$root_fs' не поддерживает commit=120. Применен только noatime.${C_RESET}"
    fi

    for dev_sched in /sys/block/sd*/queue/scheduler /sys/block/mmcblk*/queue/scheduler /sys/block/nvme*/queue/scheduler; do
        if [ -f "$dev_sched" ]; then echo "mq-deadline" > "$dev_sched" 2>/dev/null || true; fi
    done

    TMPFS_ENTRIES=(
        "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=512M 0 0"
        "tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,size=256M 0 0"
    )

    for entry in "${TMPFS_ENTRIES[@]}"; do
        mount_point=$(echo "$entry" | awk '{print $2}')
        if ! grep -q "$mount_point" /etc/fstab; then
            mkdir -p "$mount_point"
            echo "$entry" >> /etc/fstab
        fi
    done

    systemctl daemon-reload
    silent_run mount -a
}

# 13. Менеджер Swap
mod_swap_manager() {
    local swap_choice
    if ! swap_choice=$(whiptail --title "Файл подкачки (Swap)" --menu "Управление виртуальной памятью:" 12 $WT_WIDTH 3 \
    "1" "Создать базовый объем (2 Гигабайта)" \
    "2" "Указать собственный объем" \
    "3" "Полностью отключить файл подкачки" 3>&1 1>&2 2>&3); then
        return 0
    fi

    clear
    case "$swap_choice" in
        1|2)
            local swap_size="2G"
            if [ "$swap_choice" = "2" ]; then prompt_default "Желаемый объем памяти:" "4G" swap_size; fi
            silent_run swapoff /swap.img
            silent_run swapoff /swapfile
            rm -f /swap.img /swapfile
            
            if ! fallocate -l "$swap_size" /swapfile 2>/dev/null; then
                local num_mb=$(echo "$swap_size" | sed -E 's/([0-9]+)[Gg]/\1 * 1024/e; s/([0-9]+)[Mm]/\1/e' 2>/dev/null || echo "2048")
                dd if=/dev/zero of=/swapfile bs=1M count="$num_mb" status=progress
            fi
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            sed -i '/swap/d' /etc/fstab
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            echo -e "${C_GREEN}✅ Файл подкачки размером $swap_size успешно инициализирован!${C_RESET}"
            ;;
        3)
            silent_run swapoff -a
            sed -i '/swap/d' /etc/fstab
            rm -f /swapfile /swap.img
            echo -e "${C_GREEN}✅ Использование виртуальной памяти отключено.${C_RESET}"
            ;;
    esac
}

# 14. Системные утилиты и режим процессора
mod_desktop_apps() {
    echo -e "${C_CYAN}🖥️ === 14/18. СИСТЕМНЫЕ УТИЛИТЫ И РЕЖИМ ПРОЦЕССОРА ===${C_RESET}"

    local gov_choice
    if gov_choice=$(whiptail --title "Управление питанием процессора" --menu "\nВыберите желаемый режим работы:\n\nТекущий режим напрямую влияет на скорость\nработы, нагрев и энергопотребление." 17 $WT_WIDTH 4 \
    "1" "⚡ Performance (Максимальный)" \
    "2" "⚖️ Ondemand (Нормальный)" \
    "3" "🍃 Powersave (Эко-режим)" \
    "0" "⏭️ Без изменений" 3>&1 1>&2 2>&3) && [ "$gov_choice" != "0" ]; then
        local selected_gov="ondemand"
        local gov_name="Нормальный (Ondemand)"
        
        case "$gov_choice" in
            1) selected_gov="performance"; gov_name="Максимальный (Performance)" ;;
            2) selected_gov="ondemand"; gov_name="Нормальный (Ondemand)" ;;
            3) selected_gov="powersave"; gov_name="Эко-режим (Powersave)" ;;
        esac

        echo -e "${C_BLUE}⚙️ Установка режима процессора: $gov_name...${C_RESET}"
        export DEBIAN_FRONTEND=noninteractive
        silent_run apt-get update
        silent_run apt-get install -yq cpufrequtils
        
        echo "GOVERNOR=$selected_gov" > /etc/default/cpufrequtils
        silent_run systemctl restart cpufrequtils 2>/dev/null || true
        
        for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
            [ -f "$cpu" ] && echo "$selected_gov" > "$cpu" 2>/dev/null
        done
        echo -e "${C_GREEN}✅ Режим процессора успешно изменен на $gov_name.${C_RESET}"
    else
        echo -e "${C_YELLOW}⏭️ Настройка режима процессора пропущена.${C_RESET}"
    fi

    if whiptail --title "Графическое окружение" --yesno "\nУстановить трей-апплеты (сеть, звук, bluetooth, батарея) и добавить их в автозапуск?\n\n(Имеет смысл только для систем с графическим рабочим столом)." 13 $WT_WIDTH; then
        echo -e "${C_BLUE}📦 Установка утилит для графического интерфейса...${C_RESET}"
        export DEBIAN_FRONTEND=noninteractive
        silent_run apt-get update
        silent_run apt-get install -yq network-manager-gnome pasystray blueman cbatticon

        local target_user=$(get_active_user)
        local target_home=$(getent passwd "$target_user" | cut -d: -f6)
        [ -z "$target_home" ] && target_home="/home/$target_user"

        local autostart_dir="$target_home/.config/autostart"
        mkdir -p "$autostart_dir"

        cat <<EOF > "$autostart_dir/nm-applet.desktop"
[Desktop Entry]
Type=Application
Name=Network Manager
Exec=nm-applet
X-GNOME-Autostart-enabled=true
EOF
        cat <<EOF > "$autostart_dir/pasystray.desktop"
[Desktop Entry]
Type=Application
Name=PulseAudio Tray
Exec=pasystray
X-GNOME-Autostart-enabled=true
EOF
        cat <<EOF > "$autostart_dir/blueman.desktop"
[Desktop Entry]
Type=Application
Name=Bluetooth Manager
Exec=blueman-applet
X-GNOME-Autostart-enabled=true
EOF
        cat <<EOF > "$autostart_dir/cbatticon.desktop"
[Desktop Entry]
Type=Application
Name=Battery Icon
Exec=cbatticon
X-GNOME-Autostart-enabled=true
EOF

        silent_run chown -R "$target_user:$target_user" "$target_home/.config"
        echo -e "${C_GREEN}✅ Инструменты графического окружения добавлены в автозапуск для $target_user.${C_RESET}"
    else
        echo -e "${C_YELLOW}⏭️ Установка графических утилит пропущена.${C_RESET}"
    fi
}

# 15. Программный сброс HDMI
mod_hdmi_reset() {
    echo -e "${C_CYAN}📺 === 15/18. СБРОС ВИДЕОВЫХОДА HDMI ===${C_RESET}"
    cat << 'HDMI_EOF' > /usr/local/bin/reset-hdmi.sh
#!/bin/bash
HDMI_OUTPUT=$(xrandr 2>/dev/null | grep -E "^HDMI-[0-9A-Z-]+ connected" | awk '{print $1}' | head -n 1 || true)
if [ -n "$HDMI_OUTPUT" ]; then
    sleep 3
    xrandr --output "$HDMI_OUTPUT" --off
    sleep 1
    xrandr --output "$HDMI_OUTPUT" --auto
fi
HDMI_EOF
    chmod +x /usr/local/bin/reset-hdmi.sh

    if [ -f /etc/lightdm/lightdm.conf ]; then
        backup_file "/etc/lightdm/lightdm.conf"
        if ! grep -q "display-setup-script=/usr/local/bin/reset-hdmi.sh" /etc/lightdm/lightdm.conf; then
            if grep -q "\[Seat:\*\]" /etc/lightdm/lightdm.conf; then
                silent_run sed -i '/\[Seat:\*\]/a display-setup-script=/usr/local/bin/reset-hdmi.sh' /etc/lightdm/lightdm.conf
            else
                echo -e "\n[Seat:*]\ndisplay-setup-script=/usr/local/bin/reset-hdmi.sh" >> /etc/lightdm/lightdm.conf
            fi
        fi
        echo -e "${C_GREEN}✅ Скрипт автоматического сброса HDMI подключен к дисплейному менеджеру LightDM.${C_RESET}"
    else
        echo -e "${C_GREEN}✅ Скрипт /usr/local/bin/reset-hdmi.sh создан. Конфигурация LightDM не найдена.${C_RESET}"
    fi
}

# 16. Диагностика времени загрузки
mod_boot_diag() {
    echo -e "${C_CYAN}⏱️ === 16/18. АНАЛИЗ ВРЕМЕНИ ЗАГРУЗКИ СИСТЕМЫ ===${C_RESET}"
    if [ "$(cat /proc/1/comm 2>/dev/null)" != "systemd" ]; then
        echo -e "${C_RED}❌ Ошибка: система запущена без systemd. Диагностика невозможна.${C_RESET}"
        return
    fi

    local target_user=$(get_active_user)
    local target_home=$(getent passwd "$target_user" | cut -d: -f6)
    [ -z "$target_home" ] && target_home="/home/$target_user"

    local output_dir="$target_home/Downloads"
    mkdir -p "$output_dir"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="$output_dir/boot_report_${timestamp}.txt"
    local svg_file="$output_dir/boot_${timestamp}.svg"

    echo "📊 Сбор данных о загрузке системы..."
    echo "--- 1. Общее время старта ---" | tee "$report_file"
    systemd-analyze | tee -a "$report_file"
    echo "" | tee -a "$report_file"

    echo "--- 2. Топ тяжелых сервисов (Top 15) ---" | tee -a "$report_file"
    systemd-analyze blame | head -n 15 | tee -a "$report_file"
    echo "" | tee -a "$report_file"

    echo "--- 3. Цепочка блокировок (Critical Chain) ---" | tee -a "$report_file"
    systemd-analyze critical-chain | tee -a "$report_file"
    echo "" | tee -a "$report_file"

    silent_run systemd-analyze plot > "$svg_file"
    silent_run chown -R "$target_user:$target_user" "$output_dir"
    
    echo -e "${C_GREEN}✅ Диагностика успешно завершена.${C_RESET}"
    echo "📄 Текстовый отчёт сохранен: $report_file"
    echo "📊 SVG-график сохранен:      $svg_file"
}

# 17. Полный аудит сервера
mod_server_audit() {
    clear
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    echo -e "${C_BOLD}       🔍  ПОЛНЫЙ ИНТЕЛЛЕКТУАЛЬНЫЙ АУДИТ И ДИАГНОСТИКА     ${C_RESET}"
    echo -e "${C_CYAN}=================================================================${C_RESET}\n"
    
    local active_user=$(get_active_user)

    echo -e "${C_BOLD}--- 1. Базовая система, хост и обновления ---${C_RESET}"
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    echo -e "  • Часовой пояс:              ${C_GREEN}$current_tz${C_RESET}"
    echo -e "  • Имя хоста:                 ${C_GREEN}$(hostname)${C_RESET}"
    echo -e "  • Тип системы (окружение):   ${C_BLUE}$SYSTEM_TYPE${C_RESET}"
    echo -e "  • Режим загрузки (systemd):  ${C_BLUE}$(systemctl get-default 2>/dev/null || echo "N/A")${C_RESET}"
    
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        echo -e "  • Авто-обновления (security): ${C_GREEN}✅ Активны${C_RESET}"
    else
        echo -e "  • Авто-обновления (security): ${C_RED}❌ Отключены${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 2. Аппаратная часть (Процессор и Температура) ---${C_RESET}"
    local cpu_temp="Нет сенсора"
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        local raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        if [ -n "$raw_temp" ] && [ "$raw_temp" -gt 0 ]; then
            cpu_temp=$(awk "BEGIN {printf \"%.1f°C\", $raw_temp/1000}")
            if [ "$raw_temp" -gt 75000 ]; then
                cpu_temp="${C_RED}🔥 $cpu_temp (Критический перегрев / Троттлинг!)${C_RESET}"
            elif [ "$raw_temp" -gt 60000 ]; then
                cpu_temp="${C_YELLOW}⚠️ $cpu_temp (Высокий нагрев)${C_RESET}"
            else
                cpu_temp="${C_GREEN}❄️ $cpu_temp (В норме)${C_RESET}"
            fi
        fi
    fi

    local cpu_gov="Неизвестно"
    [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] && cpu_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)

    local cpu_freq="Неизвестно"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        local raw_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
        [ -n "$raw_freq" ] && cpu_freq="$(awk "BEGIN {printf \"%d MHz\", $raw_freq/1000}")"
    fi
    
    local load_avg=$(uptime | awk -F'load average:' '{ print $2 }' | sed 's/^[ \t]*//')

    echo -e "  • Температура CPU:           $cpu_temp"
    echo -e "  • Режим процессора (Gov):    ${C_BLUE}$cpu_gov${C_RESET}"
    echo -e "  • Текущая частота CPU:       ${C_BLUE}$cpu_freq${C_RESET}"
    echo -e "  • Средняя нагрузка (Load):   ${C_BLUE}$load_avg${C_RESET}"

    echo -e "\n${C_BOLD}--- 3. Учетные записи, пользователи и Sudo ---${C_RESET}"
    echo -e "  • Основной администратор:    ${C_GREEN}$active_user${C_RESET}"
    if [ -f "/etc/sudoers.d/$active_user" ]; then
        echo -e "  • Права Sudo для $active_user:  ${C_GREEN}✅ NOPASSWD (без пароля)${C_RESET}"
    else
        echo -e "  • Права Sudo для $active_user:  ${C_BLUE}ℹ️ Стандартный запрос пароля${C_RESET}"
    fi

    local root_locked=$(passwd -S root 2>/dev/null | awk '{print $2}' || true)
    
    if [ "$root_locked" = "L" ] || [ "$root_locked" = "LK" ] || [ "$root_locked" = "NP" ]; then
        echo -e "  • Статус учетной записи root: ${C_GREEN}✅ Заблокирована (безопасно)${C_RESET}"
    else
        echo -e "  • Статус учетной записи root: ${C_RED}❌ Активна (разрешен вход)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 4. Безопасность и конфигурация SSH ---${C_RESET}"
    local ssh_port="22" root_ssh="yes" pass_auth="yes"
    local sshd_cmd=$(get_sshd_cmd)

    if [ -n "$sshd_cmd" ]; then
        local conf_port=$($sshd_cmd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1)
        local conf_root=$($sshd_cmd -T 2>/dev/null | grep -i "^permitrootlogin " | awk '{print $2}' | head -n 1)
        local conf_pass=$($sshd_cmd -T 2>/dev/null | grep -i "^passwordauthentication " | awk '{print $2}' | head -n 1)
        
        [ -n "$conf_port" ] && ssh_port="$conf_port"
        [ -n "$conf_root" ] && root_ssh="$conf_root"
        [ -n "$conf_pass" ] && pass_auth="$conf_pass"
    fi

    local port_status_human
    if [ "$ssh_port" = "22" ]; then
        port_status_human="${C_YELLOW}⚠️ 22 (Стандартный порт, рекомендуется сменить)${C_RESET}"
    else
        port_status_human="${C_GREEN}✅ $ssh_port${C_RESET}"
    fi

    local root_status_human
    case "${root_ssh,,}" in
        no) root_status_human="${C_GREEN}✅ Запрещен${C_RESET}" ;;
        prohibit-password|without-password) root_status_human="${C_GREEN}✅ Только по ключам${C_RESET}" ;;
        yes|*) root_status_human="${C_RED}❌ Разрешен${C_RESET}" ;;
    esac

    local pass_status_human
    case "${pass_auth,,}" in
        no) pass_status_human="${C_GREEN}✅ Отключен (только ключи)${C_RESET}" ;;
        yes|*) pass_status_human="${C_YELLOW}⚠️ Включен${C_RESET}" ;;
    esac

    echo -e "  • Используемый порт SSH:     $port_status_human"
    echo -e "  • Вход root по SSH:          $root_status_human"
    echo -e "  • Вход по паролю SSH:        $pass_status_human"

    echo -e "\n${C_BOLD}--- 5. Защита ядра и сетевые оптимизации ---${C_RESET}"
    check_param() {
        local param="$1" expected="$2" name="$3" ok_msg="$4" err_msg="$5"
        local val=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
        if [ "$val" = "$expected" ]; then
            echo -e "  • $name: ${C_GREEN}✅ $ok_msg${C_RESET}"
        else
            echo -e "  • $name: ${C_YELLOW}⚠️ $err_msg (текущее значение: $val)${C_RESET}"
        fi
    }
    check_param "kernel.dmesg_restrict" "1" "Ограничение буфера ядра" "Включено" "Отключено"
    check_param "net.ipv4.tcp_syncookies" "1" "Защита SYN-cookies" "Включена" "Отключена"
    check_param "net.ipv4.tcp_congestion_control" "bbr" "Алгоритм TCP BBR" "Активен" "Стандартный"
    check_param "net.ipv4.tcp_rfc1337" "1" "Защита Time-Wait (RFC1337)" "Включена" "Отключена"

    echo -e "\n${C_BOLD}--- 6. Межсетевой экран (UFW) ---${C_RESET}"
    if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
        echo -e "  • Статус брандмауэра:        ${C_GREEN}✅ Активен${C_RESET}"
        
        local fwd_policy=$(grep -E "^DEFAULT_FORWARD_POLICY=" /etc/default/ufw 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "DROP")
        if [ "$fwd_policy" = "ACCEPT" ]; then
            echo -e "  • Сквозная маршрутизация:    ${C_GREEN}✅ Разрешена (работает как шлюз)${C_RESET}"
        else
            echo -e "  • Сквозная маршрутизация:    ${C_YELLOW}⚠️ Запрещена (только локальный трафик)${C_RESET}"
        fi

        if LC_ALL=C ufw status 2>/dev/null | grep -iE "SSH via Tailscale only" >/dev/null; then
            echo -e "  • Изоляция SSH-порта:        ${C_GREEN}🔒 Скрыт (только через Tailscale)${C_RESET}"
        else
            echo -e "  • Изоляция SSH-порта:        ${C_YELLOW}🌍 Публичный (открыт интернету)${C_RESET}"
        fi

        if LC_ALL=C ufw status 2>/dev/null | grep -qw "41641/udp"; then
            echo -e "  • Прямые P2P соединения:     ${C_GREEN}✅ Разрешены (Tailscale порт 41641)${C_RESET}"
        fi
    else
        echo -e "  • Статус брандмауэра:        ${C_RED}❌ Не активен${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 7. Закрытая меш-сеть Tailscale ---${C_RESET}"
    if command -v tailscale &>/dev/null; then
        echo -e "  • Пакет Tailscale:           ${C_GREEN}✅ Установлен и работает${C_RESET}"
        local ts_name ts_ip ts_exit ts_adv_exit ts_accept ts_stealth
        IFS="|" read -r ts_name _ <<< "$(get_tailscale_whoami)"
        ts_ip=$(tailscale whoami 2>/dev/null | grep -i "^  Addresses:" | grep -oP '100\.\d+\.\d+\.\d+' | head -n 1 || echo "Нет IP")
        
        ts_exit=$(tailscale get exit-node 2>/dev/null || echo "")
        local ts_exit_human
        if [ -z "$ts_exit" ] || [ "$ts_exit" = "none" ] || [ "$ts_exit" = "false" ]; then
            ts_exit_human="Свой интернет (напрямую)"
        else
            ts_exit_human="Через чужой узел ($ts_exit)"
        fi
        
        ts_adv_exit=$(tailscale get advertise-exit-node 2>/dev/null || echo "false")
        local ts_adv_exit_human
        [ "$ts_adv_exit" = "true" ] && ts_adv_exit_human="${C_GREEN}Да (работает как VPN-сервер)${C_RESET}" || ts_adv_exit_human="${C_BLUE}Нет${C_RESET}"
        
        ts_accept=$(tailscale get accept-routes 2>/dev/null || echo "false")
        local ts_accept_human
        [ "$ts_accept" = "true" ] && ts_accept_human="${C_GREEN}Да (видит чужие локалки)${C_RESET}" || ts_accept_human="${C_BLUE}Нет${C_RESET}"
        
        ts_stealth=$(tailscale get stateful-filtering 2>/dev/null || echo "false")
        local ts_stealth_human
        [ "$ts_stealth" = "true" ] && ts_stealth_human="${C_GREEN}Включен (блокирует входящие)${C_RESET}" || ts_stealth_human="${C_BLUE}Выключен (открыт для своих)${C_RESET}"

        echo -e "  • Имя устройства в сети:     ${C_BLUE}$ts_name${C_RESET}"
        echo -e "  • Внутренний IP-адрес:       ${C_BLUE}$ts_ip${C_RESET}"
        echo -e "  • Выход в интернет:          ${C_BLUE}$ts_exit_human${C_RESET}"
        echo -e "  • Раздает свой интернет:     $ts_adv_exit_human"
        echo -e "  • Доступ к чужим сетям:      $ts_accept_human"
        echo -e "  • Режим невидимки (Stealth): $ts_stealth_human"

        if systemctl is-active --quiet tailscale-gro.service 2>/dev/null; then
            echo -e "  • Ускорение трафика (GRO):   ${C_GREEN}✅ Работает${C_RESET}"
        else
            echo -e "  • Ускорение трафика (GRO):   ${C_YELLOW}⚠️ Отключено${C_RESET}"
        fi
    else
        echo -e "  • Программа Tailscale:       ${C_YELLOW}⚠️ Не установлена${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 8. Сетевые интерфейсы и Диагностика ---${C_RESET}"
    local active_ifs=$(ip -br link show | grep -v "DOWN" | awk '{print $1}')
    for iface in $active_ifs; do
        local mtu=$(cat /sys/class/net/"$iface"/mtu 2>/dev/null || echo "N/A")
        local speed=$(cat /sys/class/net/"$iface"/speed 2>/dev/null || echo "N/A")
        
        if [ "$speed" != "N/A" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
            speed="${speed} Мбит/с"
        elif [ "$iface" = "tailscale0" ] || [[ "$iface" == *"wg"* ]] || [[ "$iface" == *"lo"* ]]; then
            speed="Виртуальный линк"
        else
            speed="Не определена"
        fi
        
        local rx_err=$(cat /sys/class/net/"$iface"/statistics/rx_errors 2>/dev/null || echo "0")
        local tx_err=$(cat /sys/class/net/"$iface"/statistics/tx_errors 2>/dev/null || echo "0")
        local rx_drop=$(cat /sys/class/net/"$iface"/statistics/rx_dropped 2>/dev/null || echo "0")
        local tx_drop=$(cat /sys/class/net/"$iface"/statistics/tx_dropped 2>/dev/null || echo "0")
        
        local total_err=$((rx_err + tx_err))
        local total_drop=$((rx_drop + tx_drop))
        
        local err_str="${C_GREEN}0 ✅${C_RESET}"
        [ "$total_err" -gt 0 ] && err_str="${C_RED}$total_err ❌${C_RESET}"
        
        local drop_str="${C_GREEN}0 ✅${C_RESET}"
        [ "$total_drop" -gt 0 ] && drop_str="${C_YELLOW}$total_drop ⚠️${C_RESET}"

        echo -e "  • Интерфейс ${C_BLUE}$iface${C_RESET} (MTU: ${C_GREEN}$mtu${C_RESET}, Линк: ${C_GREEN}$speed${C_RESET})"
        echo -e "    └─ Пакеты: Ошибки (Errors) = $err_str | Отброшены (Dropped) = $drop_str"
    done

    echo -e ""
    local mss_active=false
    if command -v ufw &>/dev/null && [ -f /etc/ufw/before.rules ] && grep -q "TCPMSS" /etc/ufw/before.rules; then mss_active=true; fi
    if command -v iptables &>/dev/null && iptables -t mangle -L FORWARD -n 2>/dev/null | grep -q "TCPMSS"; then mss_active=true; fi
    
    if [ "$mss_active" = true ]; then
        echo -e "  • Фиксация MSS (MSS Clamping): ${C_GREEN}✅ Работает (предотвращает зависание сайтов)${C_RESET}"
    else
        echo -e "  • Фиксация MSS (MSS Clamping): ${C_YELLOW}⚠️ Не обнаружена (возможны потери скорости)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 9. Оптимизация памяти, накопителей и Swap ---${C_RESET}"
    
    local vm_swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "N/A")
    local swappiness_human
    if [ "$vm_swappiness" = "1" ]; then
        swappiness_human="${C_GREEN}✅ 1 (Максимальное сбережение накопителя)${C_RESET}"
    elif [ "$vm_swappiness" = "60" ]; then
        swappiness_human="${C_YELLOW}⚠️ 60 (Стандартное, частая запись на диск)${C_RESET}"
    elif [ "$vm_swappiness" = "N/A" ]; then
        swappiness_human="${C_RED}❌ Ошибка чтения${C_RESET}"
    else
        swappiness_human="${C_BLUE}$vm_swappiness (Пользовательское значение)${C_RESET}"
    fi
    echo -e "  • Параметр vm.swappiness:    $swappiness_human"

    if mount | grep " / " | grep -q "noatime"; then
        echo -e "  • Метки времени (noatime):   ${C_GREEN}✅ Отключены (износ флеш-памяти снижен)${C_RESET}"
    else
        echo -e "  • Метки времени (noatime):   ${C_YELLOW}⚠️ Включены (лишняя нагрузка на диск)${C_RESET}"
    fi

    if mount | grep " / " | grep -q "commit=120"; then
        echo -e "  • Отложенная запись (commit): ${C_GREEN}✅ 120 сек. (бережет накопитель от частых записей)${C_RESET}"
    else
        echo -e "  • Отложенная запись (commit): ${C_YELLOW}⚠️ Стандартная (повышенный износ флеш-памяти)${C_RESET}"
    fi

    local current_swap=$(swapon --show --noheadings 2>/dev/null | awk '{print $1 " (" $3 ")"}' | paste -sd ", " - || echo "")
    [ -z "$current_swap" ] && current_swap="Отключен"
    echo -e "  • Активный файл Swap:        ${C_BLUE}$current_swap${C_RESET}"

    echo -e "\n${C_CYAN}=================================================================${C_RESET}"
}

# 18. Режим локального маршрутизатора (Нативная интеграция с UFW)
mod_router_sbc() {
    echo -e "${C_CYAN}📡 === 18/18. РЕЖИМ ЛОКАЛЬНОГО МАРШРУТИЗАТОРА ===${C_RESET}"
    
    if ! whiptail --title "Режим Маршрутизатора" --yesno "Превратить этот сервер в локальный LAN-шлюз (Роутер)?\n\nБудет настроен DHCP-сервер (dnsmasq), DNS, NAT, MSS Clamping, защита от конфликтов и строгий Kill Switch. Трафик клиентов пойдет ТОЛЬКО через Tailscale Exit-Node." 12 $WT_WIDTH; then
        echo -e "${C_YELLOW}⏭️ Настройка маршрутизатора отменена.${C_RESET}"
        return 0
    fi

    local available_ifs=$(ip -br link show | grep -vE "DOWN|tailscale0|lo|wg" | awk '{print $1}')
    if [ -z "$available_ifs" ]; then
        whiptail --msgbox "Ошибка: Не найдено подходящих физических интерфейсов для локальной сети!" 8 $WT_WIDTH
        return 0
    fi

    local lan_if=""
    prompt_clean "Введите имя LAN-интерфейса, к которому подключены клиенты (Доступно: $(echo $available_ifs | tr '\n' ' ')): " lan_if
    if [ "$MODULE_CANCELED" = true ] || [ -z "$lan_if" ]; then return 0; fi

    local lan_ip="192.168.199.1"
    prompt_clean "Введите статический IP для этого шлюза (например, 192.168.199.1):" lan_ip
    [ "$MODULE_CANCELED" = true ] && return 0

    if [[ "$lan_ip" == 100.* ]]; then
        whiptail --msgbox "⚠️ ВНИМАНИЕ: Подсеть 100.x.x.x конфликтует с адресацией Tailscale (CGNAT). Пожалуйста, используйте диапазоны 192.168.x.x или 10.x.x.x!" 10 $WT_WIDTH
        return 0
    fi

    local subnet_prefix=$(echo "$lan_ip" | cut -d. -f1-3)
    local dhcp_start="${subnet_prefix}.50"
    local dhcp_end="${subnet_prefix}.200"

    echo -e "${C_BLUE}📦 Установка необходимых пакетов (dnsmasq, iptables, network-manager)...${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    silent_run apt-get update
    silent_run apt-get install -yq dnsmasq iptables network-manager

    # Антидот: Удаляем конфликтующий пакет
    if dpkg -l | grep -qw iptables-persistent; then
        silent_run systemctl stop netfilter-persistent 2>/dev/null
        silent_run systemctl disable netfilter-persistent 2>/dev/null
        silent_run apt-get purge -yq iptables-persistent netfilter-persistent
        echo -e "${C_BLUE}ℹ️ Удален конфликтующий пакет iptables-persistent (управление возвращено UFW).${C_RESET}"
    fi

    echo -e "${C_BLUE}⚙️ Настройка статического IP ($lan_ip) для $lan_if...${C_RESET}"
    if command -v nmcli &>/dev/null; then
        silent_run nmcli con delete "$lan_if" 2>/dev/null
        silent_run nmcli con add type ethernet ifname "$lan_if" con-name "$lan_if" ipv4.method manual ipv4.addresses "$lan_ip/24" ipv4.dns "8.8.8.8,1.1.1.1"
        silent_run nmcli con up "$lan_if"
    else
        ip addr flush dev "$lan_if" 2>/dev/null
        ip addr add "$lan_ip/24" dev "$lan_if"
        ip link set dev "$lan_if" up
    fi

    echo -e "${C_BLUE}⚙️ Настройка сервера DHCP и DNS...${C_RESET}"
    backup_file "/etc/dnsmasq.conf"
    
    if systemctl is-active --quiet systemd-resolved; then
        sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf 2>/dev/null
        systemctl restart systemd-resolved 2>/dev/null
    fi

    cat <<EOF > /etc/dnsmasq.conf
domain-needed
bogus-priv
interface=$lan_if
bind-interfaces
listen-address=$lan_ip
dhcp-range=$dhcp_start,$dhcp_end,12h
dhcp-option=3,$lan_ip
dhcp-option=6,8.8.8.8,1.1.1.1
EOF
    systemctl unmask dnsmasq 2>/dev/null || true
    systemctl enable dnsmasq 2>/dev/null
    systemctl restart dnsmasq || echo -e "${C_YELLOW}⚠️ Ошибка запуска dnsmasq. Проверьте конфликты порта 53.${C_RESET}"

    echo -e "${C_BLUE}🛡️ Настройка разрешений брандмауэра для локальной сети...${C_RESET}"
    if command -v ufw &>/dev/null; then
        silent_run ufw allow in on "$lan_if" to any port 67 proto udp comment 'LAN DHCP'
        silent_run ufw allow in on "$lan_if" to any port 53 proto udp comment 'LAN DNS (UDP/TCP)'
        silent_run ufw route allow in on "$lan_if" comment 'LAN Forwarding'
    else
        iptables -D INPUT -i "$lan_if" -p udp -m multiport --dports 53,67 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -i "$lan_if" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -i "$lan_if" -p udp -m multiport --dports 53,67 -j ACCEPT
        iptables -I INPUT -i "$lan_if" -p tcp --dport 53 -j ACCEPT
    fi

    echo -e "${C_BLUE}⚙️ Включение маршрутизации и трансляции адресов (NAT)...${C_RESET}"
    sed -i -E 's/^\s*#?\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-router.conf
    sysctl -p /etc/sysctl.d/99-router.conf >/dev/null 2>&1

    # Нативная интеграция NAT и MSS Clamping в UFW
    if command -v ufw &>/dev/null && [ -f /etc/ufw/before.rules ]; then
        if ! grep -q "POSTROUTING -o tailscale0 -j MASQUERADE" /etc/ufw/before.rules; then
            sed -i '1s/^/*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -o tailscale0 -j MASQUERADE\nCOMMIT\n\n/' /etc/ufw/before.rules
        fi
        if ! grep -q "TCPMSS" /etc/ufw/before.rules; then
            sed -i '1s/^/*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n\n/' /etc/ufw/before.rules
        fi
        silent_run ufw reload
    fi

    # На лету (в память)
    iptables -t nat -D POSTROUTING -o tailscale0 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
    iptables -t mangle -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -D FORWARD -i "$lan_if" -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i "$lan_if" -j ACCEPT
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

    local wan_if=$(ip route show default 2>/dev/null | grep -v tailscale0 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
    if [ -n "$wan_if" ] && [ "$wan_if" != "$lan_if" ]; then
        echo -e "${C_BLUE}🛡️ Активация Kill Switch (блокировка прямого выхода через $wan_if)...${C_RESET}"
        if command -v ufw &>/dev/null; then
            silent_run ufw route deny in on "$lan_if" out on "$wan_if" comment 'Kill Switch'
        else
            iptables -D FORWARD -i "$lan_if" -o "$wan_if" -j DROP 2>/dev/null || true
            iptables -I FORWARD 1 -i "$lan_if" -o "$wan_if" -j DROP
        fi
    else
        echo -e "${C_YELLOW}⚠️ WAN интерфейс не определен, Kill Switch пропущен.${C_RESET}"
    fi

    echo -e "\n${C_GREEN}🎉 Режим маршрутизатора (на базе UFW) успешно развернут!${C_RESET}"
    echo -e "  • LAN Интерфейс:       ${C_BLUE}$lan_if ($lan_ip)${C_RESET}"
    echo -e "  • Пул адресов DHCP:    ${C_BLUE}$dhcp_start - $dhcp_end${C_RESET}"
    echo -e "  • Открытые порты:      ${C_GREEN}53 (DNS) и 67 (DHCP) разрешены${C_RESET}"
    echo -e "  • Маршрутизация (NAT): ${C_GREEN}Через сеть Tailscale${C_RESET}"
    echo -e "  • MSS Clamping:        ${C_GREEN}Включен (встроен в UFW)${C_RESET}"
    if [ -n "$wan_if" ] && [ "$wan_if" != "$lan_if" ]; then
        echo -e "  • Kill Switch:         ${C_GREEN}Включен (Прямой выход через $wan_if заблокирован!)${C_RESET}"
    fi
}

# ==============================================================================
# === 🚀 ЗАПУСК ГЛАВНОГО МЕНЮ (ВСЕГДА В САМОМ КОНЦЕ ФАЙЛА) ===
# ==============================================================================
while true; do
    ts_main_status="Отсутствует"
    if command -v tailscale &>/dev/null; then
        if is_tailscale_web_active; then ts_main_status="Активна (с Web)"; else ts_main_status="Активна"; fi
    fi
    
    if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
        ufw_status="Активен"
    else
        ufw_status="Не активен"
    fi
    
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")

    export TERM_COLS=$(tput cols 2>/dev/null || echo 85)
    export TERM_LINES=$(tput lines 2>/dev/null || echo 27)
    export WT_WIDTH=$((TERM_COLS < 85 ? TERM_COLS : 85))
    export WT_HEIGHT=$((TERM_LINES < 27 ? TERM_LINES : 27))
    WT_MENU=$((WT_HEIGHT - 14))
    if [ "$WT_MENU" -lt 6 ]; then WT_MENU=6; fi

    choice=""
    if ! choice=$(whiptail --title "🛠️ ГЛАВНОЕ МЕНЮ" \
    --menu "\n  💻 Системные данные:
  • Хост: $(hostname) ($SYSTEM_TYPE)
  • Часовой пояс: $tz
  • Статус UFW: $ufw_status
  • Сеть Tailscale: $ts_main_status

  📌 Выберите желаемый этап настройки:" $WT_HEIGHT $WT_WIDTH $WT_MENU \
    "1" "🌐 Часовой пояс" \
    "2" "🏷️ Имя сервера" \
    "3" "📦 Обновление компонентов" \
    "4" "👤 Создание и настройка пользователя" \
    "5" "🔑 Привязка ключа безопасности" \
    "6" "🔒 Конфигурация удаленного доступа" \
    "7" "🛡️ Настройка системной защиты" \
    "8" "🔥 Управление брандмауэром" \
    "9" "🔐 Блокировка доступа суперпользователя" \
    "10" "🔗 Настройка закрытой сети Tailscale" \
    "11" "📝 Управление системными журналами" \
    "12" "⚡ Оптимизация памяти" \
    "13" "💾 Управление файлом подкачки" \
    "14" "🖥️ Утилиты ПК и режим процессора" \
    "15" "📺 Сброс видеовыхода HDMI" \
    "16" "⏱️ Анализ времени загрузки" \
    "17" "🔍 Интеллектуальный аудит системы" \
    "18" "📡 Режим локального маршрутизатора" \
    "A" "🚀 Выполнить первичную настройку целиком (Шаги 1-12)" \
    "0" "❌ Завершить работу" 3>&1 1>&2 2>&3) || [ "$choice" = "0" ]; then
        clear
        echo "Работа скрипта завершена."
        exit 0
    fi

    MODULE_CANCELED=false
    clear

    case "$choice" in
        1) mod_timezone; pause_enter ;;
        2) mod_hostname; pause_enter ;;
        3) mod_apt_update; pause_enter ;;
        4) mod_user_setup; pause_enter ;;
        5) mod_ssh_key; pause_enter ;;
        6) mod_ssh_config; pause_enter ;;
        7) mod_hardening; pause_enter ;;
        8) mod_ufw; pause_enter ;;
        9) mod_lock_root; pause_enter ;;
        10) mod_tailscale ;;
        11) mod_logging_manager; pause_enter ;;
        12) mod_ram_flash_opt; pause_enter ;;
        13) mod_swap_manager; pause_enter ;;
        14) mod_desktop_apps; pause_enter ;;
        15) mod_hdmi_reset; pause_enter ;;
        16) mod_boot_diag; pause_enter ;;
        17) mod_server_audit; pause_enter ;;
        18) mod_router_sbc; pause_enter ;;
        A)
            echo "🚀 ЗАПУСК ПОСЛЕДОВАТЕЛЬНОЙ НАСТРОЙКИ ВСЕХ КОМПОНЕНТОВ..."
            local_aborted=false
            for m in mod_timezone mod_hostname mod_apt_update mod_user_setup mod_ssh_key mod_ssh_config mod_hardening mod_ufw mod_lock_root_auto mod_tailscale_auto mod_logging_manager_auto mod_ram_flash_opt; do
                MODULE_CANCELED=false
                $m
                if [ "$MODULE_CANCELED" = true ]; then
                    echo -e "${C_YELLOW}🛑 Автоматическая настройка прервана.${C_RESET}"
                    local_aborted=true
                    break
                fi
            done
            if [ "$local_aborted" = false ]; then echo -e "\n${C_GREEN}🎉 ВСЕ ЭТАПЫ НАСТРОЙКИ УСПЕШНО ЗАВЕРШЕНЫ!${C_RESET}"; fi
            pause_enter
            ;;
    esac
done
