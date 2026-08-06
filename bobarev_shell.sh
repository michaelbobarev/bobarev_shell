#!/bin/bash
# ==============================================================================
# СИСТЕМА АВТОМАТИЧЕСКОЙ НАСТРОЙКИ СЕРВЕРА И ПК (DEBIAN / ARMBIAN / UBUNTU)
# Автор: Michael Bobarev, Bobarev.com
# ==============================================================================
set -euo pipefail

# ANSI-цвета для терминала
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[0;31m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'
readonly C_RESET='\033[0m'

# Глобальные флаги состояния
MODULE_CANCELED=false
DRY_RUN=false

# Временная папка для атомарной записи и логов
TMP_DIR="/tmp/server_setup_$(date +%s)"
LOG_FILE="/var/log/server_setup.log"
mkdir -p "$TMP_DIR"

# Очистка временных файлов при выходе
trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ И АТОМАРНЫЕ ОПЕРАЦИИ
# ==============================================================================

# Логирование действий
log_msg() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Атомарная запись конфигов через временный файл + mv
write_file_atomic() {
    local target_path="$1"
    local content="$2"
    local mode="${3:-0644}"
    local tmp_file
    tmp_file=$(mktemp "$TMP_DIR/atomic_XXXXXX")

    if [ "$DRY_RUN" = true ]; then
        echo -e "${C_YELLOW}[DRY-RUN] Запись файла: $target_path (Права: $mode)${C_RESET}"
        return 0
    fi

    echo "$content" > "$tmp_file"
    chmod "$mode" "$tmp_file"
    mkdir -p "$(dirname "$target_path")"
    mv "$tmp_file" "$target_path"
    log_msg "INFO" "Файл $target_path успешно атомарно обновлен."
}

# Создание резервной копии конфигурационного файла
backup_if_missing() {
    local file="$1"
    if [ -f "$file" ] && [ ! -f "${file}.bak" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${C_YELLOW}[DRY-RUN] Создание бэкапа: ${file}.bak${C_RESET}"
            return 0
        fi
        cp "$file" "${file}.bak"
        echo -e "${C_BLUE}💾 Создана резервная копия: ${file}.bak${C_RESET}"
        log_msg "INFO" "Создан бэкап: ${file}.bak"
    fi
}

# Безопасный перезапуск службы
service_restart_safe() {
    local service_name="$1"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${C_YELLOW}[DRY-RUN] Перезапуск службы: $service_name${C_RESET}"
        return 0
    fi

    if systemctl is-active --quiet "$service_name" 2>/dev/null || systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        systemctl restart "$service_name"
        echo -e "${C_GREEN}✅ Служба $service_name успешно перезапущена.${C_RESET}"
        log_msg "INFO" "Служба $service_name перезапущена."
    fi
}

# Безопасная установка пакета при его отсутствии
ensure_package() {
    local pkg_name="$1"
    if ! command -v "$pkg_name" &>/dev/null && ! dpkg -s "$pkg_name" &>/dev/null; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${C_YELLOW}[DRY-RUN] Установка пакета: $pkg_name${C_RESET}"
            return 0
        fi
        export DEBIAN_FRONTEND=noninteractive
        apt update -qq && apt install -y "$pkg_name"
        log_msg "INFO" "Установлен пакет: $pkg_name"
    fi
}

# Проверка базовых системных зависимостей скрипта
check_dependencies() {
    local missing_deps=()
    local req_tools=("ip" "systemctl" "python3" "awk" "grep" "curl" "sed")

    for tool in "${req_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_deps+=("$tool")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${C_RED}❌ Ошибка: В системе отсутствуют критические утилиты: ${missing_deps[*]}${C_RESET}" >&2
        echo -e "${C_YELLOW}Пожалуйста, установите их через apt install и повторите запуск.${C_RESET}" >&2
        exit 1
    fi
}

# Автоопределение типа системы
SYSTEM_TYPE="Cloud_VPS"
if [ -f /etc/armbian-release ] || [ -f /etc/default/armbian-zram ] || grep -q -i "armbian\|nanopi\|raspberry" /etc/os-release 2>/dev/null; then
    SYSTEM_TYPE="SBC_Armbian"
elif [ -d /sys/class/power_supply ] && ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
    SYSTEM_TYPE="Laptop_PC"
elif [ "$(systemctl get-default 2>/dev/null)" = "graphical.target" ] || command -v xrandr >/dev/null 2>&1; then
    SYSTEM_TYPE="Desktop_PC"
fi

# Динамическое определение сетевых интерфейсов
DEFAULT_WAN_IF=$(ip route show default 2>/dev/null | grep -v tailscale0 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || echo "")

# Определение активного пользователя системы
get_active_user() {
    local u="${SUDO_USER:-${LOGNAME:-${USER:-}}}"
    if [ -z "$u" ] || [ "$u" = "root" ]; then
        u=$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $1!="nobody" {print $1; exit}' || echo "")
    fi
    if [ -z "$u" ]; then
        u=$(id -nu 2>/dev/null || logname 2>/dev/null || echo "nobody")
    fi
    echo "$u"
}

# Парсинг имени узла и аккаунта Tailscale
get_tailscale_whoami() {
    python3 -c '
import subprocess, re
try:
    whoami_raw = subprocess.check_output(["tailscale", "whoami"], stderr=subprocess.STDOUT, text=True)
except Exception:
    whoami_raw = ""

email_match = re.search(r"[\w\.-]+@[\w\.-]+\.\w+", whoami_raw)
ts_user = email_match.group(0) if email_match else "N/A"

ts_name = "N/A"
fqdn_match = re.search(r"([a-zA-Z0-9\.-]+\.(?:ts|tailscale)\.net)", whoami_raw)
if fqdn_match:
    ts_name = fqdn_match.group(1)
else:
    node_sec = re.search(r"Node:\s*\n?\s*(?:Name:)?\s*([a-zA-Z0-9\.-]+)", whoami_raw, re.IGNORECASE)
    if node_sec:
        ts_name = node_sec.group(1)
    else:
        mac_sec = re.search(r"Machine:\s*([a-zA-Z0-9\.-]+)", whoami_raw, re.IGNORECASE)
        if mac_sec:
            ts_name = mac_sec.group(1)
        else:
            words = [w for w in whoami_raw.replace("\n", " ").split() if "@" not in w and not w.endswith(":") and w.lower() not in ["machine", "node", "user"]]
            if words:
                ts_name = words[0]

print(f"{ts_name}|{ts_user}")
' 2>/dev/null || echo "N/A|N/A"
}

# Проверка активности веб-интерфейса Tailscale Web
is_tailscale_web_active() {
    local web_val
    web_val=$(tailscale get webclient 2>/dev/null || echo "false")
    if [ "$web_val" = "true" ]; then
        return 0
    fi
    if systemctl is-active --quiet tailscale-web.service 2>/dev/null; then
        return 0
    fi
    if ps aux 2>/dev/null | grep -v grep | grep -q -iE "tailscale.*web"; then
        return 0
    fi
    return 1
}

# Проверка занятости сетевого TCP-порта
is_port_free() {
    local port="$1"
    python3 - "$port" << 'PY' 2>/dev/null
import sys, socket
port = int(sys.argv[1])
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('0.0.0.0', port))
    s.close()
    sys.exit(0) # Свободен
except OSError:
    sys.exit(1) # Занят
PY
}

# Определение IPv4 подсети сетевого интерфейса
get_interface_subnet() {
    local iface="$1"
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 | cut -d. -f1-3 || echo ""
}

# Диалог подтверждения да/нет (с отменяемостью по кнопке 0)
prompt_yn() {
    local prompt="$1"
    local default_yes="$2"
    local yn_text="[Y/n]"
    [ "$default_yes" = "false" ] && yn_text="[y/N]"

    while true; do
        read -r -p "$(echo -e "${C_BOLD}$prompt${C_RESET} $yn_text (0 - Назад): ")" choice < /dev/tty
        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')
        if [ "$choice" = "0" ] || [ "$choice" = "b" ] || [ "$choice" = "back" ] || [ "$choice" = "назад" ]; then
            echo -e "${C_YELLOW}↩️ Отмена модуля. Возврат в главное меню...${C_RESET}"
            MODULE_CANCELED=true
            return 1
        elif [ -z "$choice" ]; then
            if [ "$default_yes" = "true" ]; then return 0; else return 1; fi
        elif [ "$choice" = "y" ] || [ "$choice" = "yes" ]; then
            return 0
        elif [ "$choice" = "n" ] || [ "$choice" = "no" ]; then
            return 1
        fi
        echo "Пожалуйста, введите 'y' (да), 'n' (нет) или '0' (назад)."
    done
}

prompt_clean() {
    local prompt="$1"
    local var_name="$2"
    local val
    read -r -p "$(echo -e "${C_BOLD}$prompt${C_RESET} (0 - Назад): ")" val < /dev/tty
    if [ "$val" = "0" ] || [ "$val" = "b" ] || [ "$val" = "back" ] || [ "$val" = "назад" ]; then
        echo -e "${C_YELLOW}↩️ Отмена модуля. Возврат в главное меню...${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi
    eval "$var_name=\"\$val\""
}

pause_enter() {
    echo ""
    read -r -p "Нажмите Enter для продолжения..." < /dev/tty
}

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ МОДУЛЯ TAILSCALE И СЕТИ
# ==============================================================================

ensure_tailscale_installed() {
    if ! command -v tailscale &>/dev/null; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${C_YELLOW}[DRY-RUN] Установка Tailscale пропущена.${C_RESET}"
            return 0
        fi
        echo -e "${C_BLUE}📦 Установка и настройка пакета Tailscale...${C_RESET}"
        curl -fsSL https://tailscale.com/install.sh | sh

        mkdir -p /etc/systemd/system/tailscaled.service.d
        write_file_atomic "/etc/systemd/system/tailscaled.service.d/override.conf" \
"[Unit]
After=network-online.target NetworkManager-wait-online.service systemd-networkd-wait-online.service
Wants=network-online.target"

        systemctl daemon-reload

        write_file_atomic "/etc/sysctl.d/99-tailscale-forward.conf" \
"net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1"

        sysctl --system > /dev/null

        local authkey=""
        read -r -p "Tailscale Auth Key (Enter для авторизации по ссылке, 0 - Назад): " authkey < /dev/tty
        if [ "$authkey" = "0" ]; then
            return 1
        fi

        if [ -n "$authkey" ]; then
            tailscale up --authkey="$authkey" --force-reauth || true
        else
            echo -e "${C_BLUE}ℹ️ Запрос новой ссылки авторизации у сервера Tailscale...${C_RESET}"
            tailscale up --force-reauth || true
            echo ""
            read -r -p "Нажмите Enter ПОСЛЕ авторизации узла в веб-панели Tailscale..." < /dev/tty
        fi

        tailscale set --auto-update 2>/dev/null || true
        echo -e "${C_GREEN}✅ Tailscale успешно установлен и авторизован.${C_RESET}"
    fi
    return 0
}

ts_apply_exit_node() {
    echo "Настройка Exit Node:"
    echo "  1) Включить анонс сервера как Exit-Node (tailscale set --advertise-exit-node=true)"
    echo "  2) Выключить анонс сервера как Exit-Node (tailscale set --advertise-exit-node=false)"
    echo "  3) Подключиться к внешнему Exit-Node (tailscale set --exit-node=<IP>)"
    echo "  4) Отключиться от внешнего Exit-Node (tailscale set --exit-node=)"
    echo "  0) Отмена / Назад"
    local en_choice
    read -r -p "Ваш выбор [0-4]: " en_choice < /dev/tty
    case "$en_choice" in
        1) tailscale set --advertise-exit-node=true 2>/dev/null || true; echo -e "${C_GREEN}✅ Анонс Exit Node включен.${C_RESET}" ;;
        2) tailscale set --advertise-exit-node=false 2>/dev/null || true; echo -e "${C_GREEN}✅ Анонс Exit Node выключен.${C_RESET}" ;;
        3)
            local target_ip=""
            prompt_clean "Введите IP-адрес или имя Exit Node" target_ip
            if [ "$MODULE_CANCELED" = true ]; then MODULE_CANCELED=false; return 0; fi
            if [ -n "$target_ip" ]; then
                tailscale set --exit-node="$target_ip" --exit-node-allow-lan-access 2>/dev/null || true
                echo -e "${C_GREEN}✅ Подключен к Exit Node $target_ip.${C_RESET}"
            fi
            ;;
        4) tailscale set --exit-node= 2>/dev/null || true; echo -e "${C_GREEN}✅ Отключен от Exit Node.${C_RESET}" ;;
    esac
}

ts_apply_routes() {
    echo "Анонсирование локальных подсетей (LAN):"
    local detected_subnet
    detected_subnet=$(get_interface_subnet "$DEFAULT_WAN_IF")
    local default_route_spec=""
    [ -n "$detected_subnet" ] && default_route_spec="${detected_subnet}.0/24"

    echo "  1) Задать подсеть для анонса (по умолчанию: ${default_route_spec:-192.168.1.0/24})"
    echo "  2) Отключить анонс подсетей (tailscale set --advertise-routes=)"
    echo "  0) Назад"
    local ar_choice
    read -r -p "Ваш выбор [0-2]: " ar_choice < /dev/tty
    case "$ar_choice" in
        1)
            local routes_input=""
            prompt_clean "Введите подсеть CIDR (Enter - ${default_route_spec:-192.168.1.0/24})" routes_input
            if [ "$MODULE_CANCELED" = true ]; then MODULE_CANCELED=false; return 0; fi
            routes_input="${routes_input:-${default_route_spec:-192.168.1.0/24}}"
            tailscale set --advertise-routes="$routes_input" 2>/dev/null || true
            echo -e "${C_GREEN}✅ Анонсируется подсеть $routes_input.${C_RESET}"
            ;;
        2)
            tailscale set --advertise-routes= 2>/dev/null || true
            echo -e "${C_GREEN}✅ Анонсирование подсетей отключено.${C_RESET}"
            ;;
    esac
}

ts_apply_webclient() {
    echo "Настройка веб-интерфейса Tailscale Web (tailscale set --webclient):"
    echo "  1) Включить веб-интерфейс Tailscale Web (tailscale set --webclient=true)"
    echo "  2) Отключить веб-интерфейс Tailscale Web (tailscale set --webclient=false)"
    echo "  0) Назад"
    local web_choice
    read -r -p "Ваш выбор [0-2]: " web_choice < /dev/tty
    case "$web_choice" in
        1)
            ensure_tailscale_installed
            tailscale set --webclient=true 2>/dev/null || true

            local current_ts_ip
            current_ts_ip=$(tailscale whoami 2>/dev/null | grep -i "^  Addresses:" | grep -oP '100\.\d+\.\d+\.\d+' | head -n 1 || echo "100.100.100.100")
            echo -e "${C_GREEN}✅ Нативный веб-интерфейс Tailscale Web включен (tailscale set --webclient=true).${C_RESET}"
            echo -e "${C_CYAN}🌐 Адреса веб-панели:${C_RESET}"
            echo -e "   • Локально на устройстве:  http://100.100.100.100"
            echo -e "   • Удаленно из сети Tailnet: http://${current_ts_ip}:5252"
            ;;
        2)
            tailscale set --webclient=false 2>/dev/null || true
            service_restart_safe "tailscaled"
            echo -e "${C_GREEN}✅ Нативный веб-интерфейс Tailscale Web отключен (tailscale set --webclient=false).${C_RESET}"
            ;;
    esac
}

# ==============================================================================
# МОДУЛИ НАСТРОЙКИ СИСТЕМЫ
# ==============================================================================

# 1. Часовой пояс
mod_1_timezone() {
    echo -e "${C_CYAN}🌐 === 1/18. НАСТРОЙКА ЧАСОВОГО ПОЯСА ===${C_RESET}"
    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Europe/Moscow")
    echo "Текущий часовой пояс: $current_tz"
    local tz=""
    prompt_clean "Введите новый часовой пояс (Enter - $current_tz)" tz
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    tz="${tz:-$current_tz}"
    if [ "$DRY_RUN" = false ]; then
        timedatectl set-timezone "$tz" || true
    fi
    echo -e "${C_GREEN}✅ Часовой пояс установлен в $tz.${C_RESET}"
}

# 2. Имя хоста
mod_2_hostname() {
    echo -e "${C_CYAN}🏷️ === 2/18. НАСТРОЙКА ИМЕНИ ХОСТА ===${C_RESET}"
    echo "Текущее имя хоста: $(hostname)"
    
    local default_brand_host="Server_VPS"
    case "$SYSTEM_TYPE" in
        SBC_Armbian) default_brand_host="Server_SBC" ;;
        Desktop_PC|Laptop_PC) default_brand_host="Server_PC" ;;
        *) default_brand_host="Server_VPS" ;;
    esac

    local new_host=""
    prompt_clean "Введите имя хоста (Enter - $default_brand_host)" new_host
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    new_host="${new_host:-$default_brand_host}"
    if [ "$DRY_RUN" = false ]; then
        hostnamectl set-hostname "$new_host"
        if ! grep -q "$new_host" /etc/hosts; then
            sed -i "s/127.0.0.1\tlocalhost/127.0.0.1\tlocalhost $new_host/" /etc/hosts
        fi
        sed -i 's/preserve_hostname: false/preserve_hostname: true/g' /etc/cloud/cloud.cfg 2>/dev/null || true
    fi
    echo -e "${C_GREEN}✅ Hostname изменен на $new_host.${C_RESET}"
}

# 3. Обновление пакетов
mod_3_apt_update() {
    echo -e "${C_CYAN}📦 === 3/18. ОБНОВЛЕНИЕ ПАКЕТОВ И ОЧИСТКА ===${C_RESET}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${C_YELLOW}[DRY-RUN] Обновление пакетов пропущено.${C_RESET}"
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt upgrade -y

    local zram_pkg="zram-tools"
    if [ -f /etc/default/armbian-zram ] || [ -f /etc/init.d/armbian-zram ]; then
        echo -e "${C_BLUE}ℹ️ Обнаружен встроенный Armbian zram, установка стороннего zram-tools пропущена.${C_RESET}"
        zram_pkg=""
        systemctl disable --now zramswap.service 2>/dev/null || true
        systemctl mask zramswap.service 2>/dev/null || true
    fi

    apt install -y sudo ufw unattended-upgrades ethtool curl wget ca-certificates gnupg $zram_pkg
    dpkg-reconfigure --priority=low unattended-upgrades
    apt autoremove -y && apt clean
    systemctl enable unattended-upgrades

    local current_target
    current_target=$(systemctl get-default)
    if [ "$current_target" = "graphical.target" ]; then
        if prompt_yn "⚠️ Обнаружена графическая оболочка ($SYSTEM_TYPE). Переключить в консольный режим (multi-user.target)?" false; then
            systemctl set-default multi-user.target
            echo -e "${C_BLUE}ℹ️ Режим загрузки изменен на консольный (multi-user.target).${C_RESET}"
        else
            if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        fi
    else
        systemctl set-default multi-user.target
    fi
    echo -e "${C_GREEN}✅ Система обновлена, базовые утилиты установлены.${C_RESET}"
}

# 4. Пользователь и Sudo
mod_4_user_setup() {
    echo -e "${C_CYAN}👤 === 4/18. СОЗДАНИЕ И НАСТРОЙКА ПОЛЬЗОВАТЕЛЯ ===${C_RESET}"
    local active_user
    active_user=$(get_active_user)
    local username=""
    prompt_clean "Имя sudo-пользователя (Enter - $active_user)" username
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    username="${username:-$active_user}"

    if [ "$DRY_RUN" = false ]; then
        if ! id "$username" &>/dev/null; then
            adduser --disabled-password --gecos "" "$username"
            echo -e "${C_GREEN}✅ Пользователь $username создан.${C_RESET}"
        fi
        usermod -aG sudo "$username"

        local pass
        read -s -p "Введите новый пароль для $username (Enter, если не менять, 0 - Назад): " pass < /dev/tty
        echo ""
        if [ "$pass" = "0" ]; then
            MODULE_CANCELED=true
            return 0
        fi

        if [ -n "$pass" ]; then
            read -s -p "Повторите пароль: " pass_confirm < /dev/tty
            echo ""
            while [ "$pass" != "$pass_confirm" ]; do
                echo -e "${C_RED}❌ Пароли не совпадают. Попробуйте снова.${C_RESET}"
                read -s -p "Пароль: " pass < /dev/tty
                echo ""
                read -s -p "Повторите пароль: " pass_confirm < /dev/tty
                echo ""
            done
            echo "$username:$pass" | chpasswd
            echo -e "${C_GREEN}✅ Пароль установлен.${C_RESET}"
        fi
    fi

    if prompt_yn "Разрешить sudo без запроса пароля (NOPASSWD)?" true; then
        write_file_atomic "/etc/sudoers.d/$username" "$username ALL=(ALL) NOPASSWD: ALL" "0440"
        echo -e "${C_GREEN}✅ Sudo NOPASSWD включен для $username.${C_RESET}"
    else
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        rm -f "/etc/sudoers.d/$username"
    fi
}

# 5. SSH-ключи
mod_5_ssh_key() {
    echo -e "${C_CYAN}🔑 === 5/18. НАСТРОЙКА SSH-КЛЮЧЕЙ ===${C_RESET}"
    local active_user
    active_user=$(get_active_user)
    local target_user=""
    prompt_clean "Для какого пользователя установить ключ? (Enter - $active_user)" target_user
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    target_user="${target_user:-$active_user}"

    if [ "$DRY_RUN" = false ] && ! id "$target_user" &>/dev/null; then
        adduser --disabled-password --gecos "" "$target_user"
        usermod -aG sudo "$target_user"
    fi

    local target_home
    target_home=$(getent passwd "$target_user" | cut -d: -f6 || echo "/home/$target_user")
    [ -z "$target_home" ] && target_home="/home/$target_user"

    mkdir -p "$target_home/.ssh"

    local pubkey=""
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        local root_key
        root_key=$(head -n 1 /root/.ssh/authorized_keys)
        if prompt_yn "Скопировать имеющийся SSH-ключ из /root/.ssh/authorized_keys?" true; then
            pubkey="$root_key"
        else
            if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        fi
    fi

    if [ -z "$pubkey" ]; then
        echo "Вставьте публичный SSH-ключ (ssh-ed25519, ssh-rsa и т.д., 0 - Назад):"
        read -r pubkey < /dev/tty
        if [ "$pubkey" = "0" ]; then
            MODULE_CANCELED=true
            return 0
        fi
    fi

    if [ -n "$pubkey" ] && [ "$DRY_RUN" = false ]; then
        echo "Режим записи:"
        echo "  1) Дописать в конец authorized_keys (безопасно)"
        echo "  2) Перезаписать файл authorized_keys"
        echo "  0) Назад / Отмена"
        local mode_choice
        read -r -p "Ваш выбор [1-2, 0]: " mode_choice < /dev/tty
        if [ "$mode_choice" = "0" ]; then
            MODULE_CANCELED=true
            return 0
        fi

        if [ "$mode_choice" = "2" ]; then
            write_file_atomic "$target_home/.ssh/authorized_keys" "$pubkey" "0600"
            echo -e "${C_GREEN}✅ Файл перезаписан.${C_RESET}"
        else
            if ! grep -qF "$pubkey" "$target_home/.ssh/authorized_keys" 2>/dev/null; then
                echo "$pubkey" >> "$target_home/.ssh/authorized_keys"
                echo -e "${C_GREEN}✅ Ключ добавлен в конец authorized_keys.${C_RESET}"
            fi
        fi
    fi

    if [ "$DRY_RUN" = false ]; then
        chmod 755 "$target_home" 2>/dev/null || true
        chmod 700 "$target_home/.ssh"
        chmod 600 "$target_home/.ssh/authorized_keys" 2>/dev/null || true
        chown -R "$target_user:$target_user" "$target_home/.ssh"
    fi
    echo -e "${C_GREEN}✅ Права на $target_home/.ssh проверены и выставлены.${C_RESET}"
}

# 6. Конфигурация SSH
mod_6_ssh_config() {
    echo -e "${C_CYAN}🔒 === 6/18. КОНФИГУРАЦИЯ SSH (БЕЗОПАСНОСТЬ) ===${C_RESET}"
    
    # Проверка наличия хотя бы одного sudo-пользователя перед критическими изменениями
    local sudo_users_count
    sudo_users_count=$(getent group sudo | cut -d: -f4 | tr ',' ' ' | wc -w || echo "0")
    if [ "$sudo_users_count" -eq 0 ]; then
        echo -e "${C_RED}❌ Ошибка: В системе нет ни одного пользователя с правами sudo!${C_RESET}" >&2
        echo -e "${C_YELLOW}Сначала создайте пользователя в Модуле 4.${C_RESET}" >&2
        return 1
    fi

    backup_if_missing "/etc/ssh/sshd_config"
    local active_ssh_port
    active_ssh_port=$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")

    local port=""
    while true; do
        prompt_clean "Введите порт SSH (Enter - $active_ssh_port)" port
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        port="${port:-$active_ssh_port}"

        if [ "$port" != "$active_ssh_port" ] && ! is_port_free "$port"; then
            echo -e "${C_RED}⚠️ ВНИМАНИЕ: Порт $port уже ЗАНЯТ другим процессом в системе!${C_RESET}"
            continue
        fi
        break
    done

    echo -e "${C_YELLOW}⚠️ ВНИМАНИЕ: Вы собираетесь изменить конфигурацию SSH (Порт: $port).${C_RESET}"
    if ! prompt_yn "Подтверждаете изменение конфигурации SSH?" true; then
        return 0
    fi

    local pass_auth_val="yes"
    local kbd_auth_val="yes"

    if prompt_yn "Отключить вход по паролю (разрешить ТОЛЬКО SSH-ключи)?" false; then
        local has_any_key=false
        for user_home in /root /home/*; do
            if [ -s "$user_home/.ssh/authorized_keys" ]; then
                has_any_key=true
                break
            fi
        done

        if [ "$has_any_key" = true ]; then
            pass_auth_val="no"
            kbd_auth_val="no"
            echo -e "${C_GREEN}✅ Найдены SSH-ключи. Вход по паролю будет отключен.${C_RESET}"
        else
            echo -e "${C_YELLOW}⚠️ На сервере не найдено SSH-ключей! Вход по паролю остается ВКЛЮЧЕННЫМ.${C_RESET}"
        fi
    else
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    fi

    local ssh_conf_content
    ssh_conf_content="# Server Security Hardening Configuration
Port $port
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $pass_auth_val
KbdInteractiveAuthentication $kbd_auth_val
ChallengeResponseAuthentication no
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
TCPKeepAlive yes"

    write_file_atomic "/etc/ssh/sshd_config.d/99-server-security.conf" "$ssh_conf_content" "0644"

    # Проверка синтаксиса конфигурации SSH перед перезапуском (Rollback при ошибке)
    if [ "$DRY_RUN" = false ]; then
        if sshd -t; then
            systemctl disable --now ssh.socket 2>/dev/null || true
            systemctl enable --now ssh.service
            systemctl restart sshd

            if prompt_yn "Ограничить доступ к SSH ТОЛЬКО через сеть Tailscale?" true; then
                if ensure_tailscale_installed; then
                    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
                        ufw allow in on tailscale0 to any port "$port" proto tcp comment 'SSH via Tailscale only' 2>/dev/null || true
                        ufw delete allow "$port"/tcp 2>/dev/null || true
                        echo -e "${C_GREEN}✅ SSH доступ ограничен: разрешен ТОЛЬКО через сеть Tailscale.${C_RESET}"
                    fi
                fi
            else
                if [ "$MODULE_CANCELED" = true ]; then return 0; fi
                if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
                    ufw allow "$port"/tcp comment 'SSH Public Port' 2>/dev/null || true
                fi
            fi
            echo -e "${C_GREEN}✅ Служба SSH успешно перезапущена.${C_RESET}"
        else
            echo -e "${C_RED}❌ Ошибка синтаксиса SSH! Выполняется откат изменений...${C_RESET}" >&2
            rm -f /etc/ssh/sshd_config.d/99-server-security.conf
            systemctl restart sshd
            return 1
        fi
    fi
}

# 7. Защита ядра и сети (С оптимизацией BBR, FastOpen и безопасными таймаутами)
mod_7_hardening() {
    echo -e "${C_CYAN}🛡️ === 7/18. ЗАЩИТА ЯДРА, СЕТИ И УСКОРЕНИЕ TCP BBR ===${C_RESET}"
    backup_if_missing "/etc/sysctl.d/99-hardening.conf"
    
    modprobe tcp_bbr 2>/dev/null || true

    # Безопасные сетевые параметры (tcp_timestamps = 1 сохраняет окно TCP и PAWS)
    local sysctl_content="# Kernel Security Hardening
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
kernel.unprivileged_bpf_disabled = 1
kernel.perf_event_paranoid = 3
kernel.sysrq = 0
net.core.bpf_jit_harden = 2

# Сетевая безопасность
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
net.ipv4.icmp_echo_ignore_all = 0

# Защита файловой системы
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 1
fs.protected_regular = 1

# Оптимизация задержек: Google BBR + FQ Queue + TCP FastOpen
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 1"

    write_file_atomic "/etc/sysctl.d/99-server-hardening.conf" "$sysctl_content" "0644"

    if [ "$DRY_RUN" = false ]; then
        sysctl --system > /dev/null
    fi
    echo -e "${C_GREEN}✅ Настройки защиты ядра, сети и ускорения Google BBR применены.${C_RESET}"
}

# 8. Firewall UFW
mod_8_ufw() {
    echo -e "${C_CYAN}🧱 === 8/18. НАСТРОЙКА FIREWALL (UFW) ===${C_RESET}"
    
    local active_ssh_port
    active_ssh_port=$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")

    local port=""
    while true; do
        prompt_clean "Введите порт SSH для разрешения в UFW (Enter - $active_ssh_port)" port
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        port="${port:-$active_ssh_port}"

        if [ "$port" != "$active_ssh_port" ] && ! is_port_free "$port"; then
            echo -e "${C_RED}⚠️ ВНИМАНИЕ: Порт $port уже ЗАНЯТ другим процессом!${C_RESET}"
            continue
        fi
        break
    done

    echo -e "${C_YELLOW}⚠️ ВНИМАНИЕ: Вы собираетесь перезапустить и включить межсетевой экран UFW.${C_RESET}"
    if ! prompt_yn "Подтверждаете включение UFW?" true; then
        return 0
    fi

    if [ "$DRY_RUN" = false ]; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing

        if prompt_yn "Разрешить маршрутизацию пакетов (FORWARD ACCEPT)? (Нужно для роутеров и Exit-Node)" true; then
            ufw default allow routed
            sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true
        else
            if [ "$MODULE_CANCELED" = true ]; then return 0; fi
            ufw default deny routed
            sed -i 's/DEFAULT_FORWARD_POLICY="ACCEPT"/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw 2>/dev/null || true
        fi

        if prompt_yn "Ограничить доступ к SSH ТОЛЬКО через сеть Tailscale?" true; then
            if ensure_tailscale_installed; then
                ufw allow in on tailscale0 comment 'Allow inside Tailscale' 2>/dev/null || true
                ufw allow 41641/udp comment 'Tailscale Direct P2P' 2>/dev/null || true

                local netdev="$DEFAULT_WAN_IF"
                [ -z "$netdev" ] && netdev=$(ip route show default | grep -v tailscale0 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || echo "")
                if [ -n "$netdev" ]; then
                    ufw route allow in on tailscale0 out on "$netdev" 2>/dev/null || true
                    ufw route allow in on "$netdev" out on tailscale0 2>/dev/null || true
                fi
                ufw allow in on tailscale0 to any port "$port" proto tcp comment 'SSH via Tailscale only'
            else
                ufw allow "$port"/tcp comment 'SSH Public Port'
            fi
        else
            if [ "$MODULE_CANCELED" = true ]; then return 0; fi
            ufw allow "$port"/tcp comment 'SSH Public Port'
        fi

        ufw --force enable
        ufw logging off 2>/dev/null || true
    fi
    echo -e "${C_GREEN}✅ Межсетевой экран UFW включен (логирование UFW отключено).${C_RESET}"
}

# 9. Блокировка Root
mod_9_lock_root() {
    echo -e "${C_CYAN}🔐 === 9/18. БЛОКИРОВКА ПАРОЛЯ ROOT ===${C_RESET}"
    local sudo_count
    sudo_count=$(getent group sudo | cut -d: -f4 | tr ',' ' ' | wc -w || echo "0")

    if [ "$sudo_count" -gt 0 ]; then
        echo -e "${C_YELLOW}⚠️ ВНИМАНИЕ: Вы собираетесь заблокировать пароль учетной записи root.${C_RESET}"
        if prompt_yn "Подтверждаете блокировку пароля root?" true; then
            if [ "$DRY_RUN" = false ]; then
                passwd -l root
            fi
            echo -e "${C_GREEN}✅ Пароль root заблокирован.${C_RESET}"
        fi
    else
        echo -e "${C_RED}❌ ВНИМАНИЕ: В группе sudo нет пользователей! Блокировка root отменена во избежание потери доступа.${C_RESET}"
    fi
}

# 10. Tailscale
mod_10_tailscale() {
    while true; do
        clear
        echo -e "${C_CYAN}🔗 === 10/18. УПРАВЛЕНИЕ И НАСТРОЙКА TAILSCALE CLI ===${C_RESET}"
        
        if command -v tailscale &>/dev/null; then
            local ts_name ts_ip ts_exit ts_adv_exit ts_adv_routes ts_accept ts_stealth ts_web_fmt
            local adv_exit_fmt adv_routes_fmt accept_fmt stealth_fmt

            IFS="|" read -r ts_name ts_user <<< "$(get_tailscale_whoami)"
            [ -z "$ts_name" ] && ts_name="Не привязан"

            ts_ip=$(tailscale whoami 2>/dev/null | grep -i "^  Addresses:" | grep -oP '100\.\d+\.\d+\.\d+' | head -n 1 || echo "N/A")
            ts_exit=$(tailscale get exit-node 2>/dev/null || echo "none")
            ts_adv_exit=$(tailscale get advertise-exit-node 2>/dev/null || echo "false")
            ts_adv_routes=$(tailscale get advertise-routes 2>/dev/null || echo "")
            ts_accept=$(tailscale get accept-routes 2>/dev/null || echo "false")
            ts_stealth=$(tailscale get stateful-filtering 2>/dev/null || echo "false")

            if is_tailscale_web_active; then ts_web_fmt="Включен"; else ts_web_fmt="Отключен"; fi
            [ "$ts_adv_exit" = "true" ] && adv_exit_fmt="Включен" || adv_exit_fmt="Отключен"
            [ -n "$ts_adv_routes" ] && [ "$ts_adv_routes" != "нет" ] && adv_routes_fmt="$ts_adv_routes" || adv_routes_fmt="Не анонсируются"
            [ "$ts_accept" = "true" ] && accept_fmt="Включен" || accept_fmt="Отключен"
            [ "$ts_stealth" = "true" ] && stealth_fmt="Включен" || stealth_fmt="Отключен"

            echo -e " Узел:                       ${C_GREEN}$ts_name${C_RESET} | IP: ${C_GREEN}$ts_ip${C_RESET}"
            echo -e " Внешний Exit-Node:          ${C_BLUE}$ts_exit${C_RESET} | Анонс Exit-Node: ${C_BLUE}$adv_exit_fmt${C_RESET}"
            echo -e " Свои подсети (LAN):         ${C_BLUE}$adv_routes_fmt${C_RESET}"
            echo -e " Прием подсетей из Tailscale: ${C_BLUE}$accept_fmt${C_RESET}"
            echo -e " Стелс-режим:                ${C_BLUE}$stealth_fmt${C_RESET}"
            echo -e " Веб-интерфейс Tailscale Web:${C_BLUE}$ts_web_fmt${C_RESET}"
        else
            echo -e " Статус: ${C_YELLOW}Пакет Tailscale еще не установлен в системе.${C_RESET}"
        fi
        echo -e "${C_CYAN}-----------------------------------------------------------------${C_RESET}"
        echo " Выберите действие:"
        echo "  1) 🔑 Первичный запуск и авторизация (tailscale up)"
        echo "  2) 🌐 Настройка Exit Node (Анонс / Подключение / Отключение)"
        echo "  3) 🔀 Анонсирование локальных подсетей (--advertise-routes)"
        echo "  4) 🛡️  Прием подсетей из Tailscale (--accept-routes)"
        echo "  5) 🔒 Стелс-режим (--stateful-filtering)"
        echo "  6) ⚡ Настройка GRO-оптимизации (tailscale-gro.service)"
        echo "  7) 💻 Настройка веб-интерфейса Tailscale Web (tailscale set --webclient)"
        echo "  8) 🔄 Полный сброс настроек подключения (tailscale up --reset)"
        echo "  0) ↩️ Назад в Главное меню"
        echo -e "${C_CYAN}=================================================================${C_RESET}"
        
        local ts_choice
        read -r -p "Ваш выбор [0-8]: " ts_choice < /dev/tty
        
        case "$ts_choice" in
            1) ensure_tailscale_installed; pause_enter ;;
            2) ts_apply_exit_node; pause_enter ;;
            3) ts_apply_routes; pause_enter ;;
            4)
                echo "Прием подсетей из Tailscale (--accept-routes):"
                echo "  1) Включить (tailscale set --accept-routes=true)"
                echo "  2) Отключить (tailscale set --accept-routes=false)"
                local ac_choice
                read -r -p "Ваш выбор [1-2, 0]: " ac_choice < /dev/tty
                [ "$ac_choice" = "1" ] && tailscale set --accept-routes=true 2>/dev/null || true
                [ "$ac_choice" = "2" ] && tailscale set --accept-routes=false 2>/dev/null || true
                pause_enter
                ;;
            5)
                echo "Стелс-режим (Stateful Filtering):"
                echo "  1) Включить (tailscale set --stateful-filtering=true)"
                echo "  2) Отключить (tailscale set --stateful-filtering=false)"
                local sf_choice
                read -r -p "Ваш выбор [1-2, 0]: " sf_choice < /dev/tty
                [ "$sf_choice" = "1" ] && tailscale set --stateful-filtering=true 2>/dev/null || true
                [ "$sf_choice" = "2" ] && tailscale set --stateful-filtering=false 2>/dev/null || true
                pause_enter
                ;;
            6)
                write_file_atomic "/usr/local/bin/tailscale-gro.sh" \
"#!/bin/bash
while ! ip route show default | grep -v tailscale0 >/dev/null 2>&1; do sleep 2; done
NETDEV=\$(ip route show default | grep -v tailscale0 | awk '{for(i=1;i<=NF;i++) if(\$i==\"dev\") print \$(i+1)}' | head -n 1)
if [ -n \"\$NETDEV\" ]; then ethtool -K \"\$NETDEV\" rx-udp-gro-forwarding on rx-gro-list off || true; fi" "0755"

                write_file_atomic "/etc/systemd/system/tailscale-gro.service" \
"[Unit]
Description=Ethtool rx-udp-gro-forwarding for Tailscale
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/tailscale-gro.sh

[Install]
WantedBy=multi-user.target" "0644"

                service_restart_safe "tailscale-gro.service"
                pause_enter
                ;;
            7) ts_apply_webclient; pause_enter ;;
            8)
                if prompt_yn "Вы действительно хотите сбросить все параметры Tailscale?" false; then
                    tailscale up --reset 2>&1 | grep -v "accept-routes" || true
                    echo -e "${C_GREEN}✅ Настройки сброшены.${C_RESET}"
                fi
                pause_enter
                ;;
            0) break ;;
        esac
    done
}

# 11. Отключение логирования
mod_11_disable_logging() {
    echo -e "${C_CYAN}🧹 === 11/18. ОТКЛЮЧЕНИЕ СИСТЕМНОГО ЛОГИРОВАНИЯ И АУДИТА ===${C_RESET}"
    backup_if_missing "/etc/systemd/journald.conf"

    local clean_script_content="#!/bin/bash
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

SERVICES_TO_DISABLE=(\"rsyslog\" \"auditd\" \"armbian-hardware-monitor\")
for svc in \"\${SERVICES_TO_DISABLE[@]}\"; do
  if systemctl list-unit-files | grep -q \"^\${svc}.service\"; then
    systemctl stop \"\$svc\" 2>/dev/null || true
    systemctl disable \"\$svc\" 2>/dev/null || true
    systemctl mask \"\$svc\" 2>/dev/null || true
  fi
done

if command -v auditctl &> /dev/null; then auditctl -e 0 2>/dev/null || true; fi
if command -v ufw &>/dev/null; then ufw logging off 2>/dev/null || true; fi

mkdir -p /etc/apt/apt.conf.d
cat << 'APT_CLEAN_EOF' > /etc/apt/apt.conf.d/99clean-logs
DPkg::Post-Invoke {\"truncate -s 0 /var/log/dpkg.log /var/log/alternatives.log /var/log/apt/*.log 2>/dev/null || true\";};
APT_CLEAN_EOF

find /var/log -type f \( -name \"*.log*\" -o -name \"syslog*\" -o -name \"auth.log*\" -o -name \"kern.log*\" -o -name \"dpkg*\" \) -exec truncate -s 0 {} + 2>/dev/null || true
rm -rf /var/log/journal /run/log/journal 2>/dev/null || true"

    write_file_atomic "/usr/local/bin/disable-logging.sh" "$clean_script_content" "0755"

    write_file_atomic "/etc/systemd/system/clean-logs-boot.service" \
"[Unit]
Description=Automated System Log Cleanup on Boot
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable-logging.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target" "0644"

    if [ "$DRY_RUN" = false ]; then
        systemctl daemon-reload
        systemctl enable clean-logs-boot.service 2>/dev/null || true
        /usr/local/bin/disable-logging.sh
    fi
    echo -e "${C_GREEN}✅ Системное логирование отключено, авто-очистка логов настроена.${C_RESET}"
}

# 12. Оптимизация RAM / Flash
mod_12_ram_flash_opt() {
    echo -e "${C_CYAN}⚡ === 12/18. ОПТИМИЗАЦИЯ RAM, FLASH (COMMIT=120, NOATIME) ===${C_RESET}"
    backup_if_missing "/etc/fstab"

    write_file_atomic "/etc/sysctl.d/99-ram-opt.conf" \
"# Оптимизация ресурса памяти MicroSD / eMMC / SSD
vm.swappiness=1
vm.vfs_cache_pressure=50
vm.dirty_writeback_centisecs=1500
vm.dirty_background_ratio=5
vm.dirty_ratio=10
kernel.dmesg_restrict=1" "0644"

    if [ "$DRY_RUN" = false ]; then
        sysctl --system > /dev/null

        python3 - << 'PY' 2>/dev/null || true
from pathlib import Path
fstab_path = Path("/etc/fstab")
if fstab_path.exists():
    lines = fstab_path.read_text().splitlines()
    new_lines = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            new_lines.append(line)
            continue
        parts = line.split()
        if len(parts) >= 4 and parts[1] == "/":
            opts = parts[3].split(",")
            if "noatime" not in opts: opts.append("noatime")
            if "commit=120" not in opts: opts.append("commit=120")
            parts[3] = ",".join(opts)
            new_lines.append("\t".join(parts))
        else:
            new_lines.append(line)
    fstab_path.write_text("\n".join(new_lines) + "\n")
PY

        local root_dev
        root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}' || echo "")
        if [ -n "$root_dev" ] && command -v tune2fs >/dev/null 2>&1; then
            tune2fs -E mount_opts=commit=120 "$root_dev" 2>/dev/null || true
        fi

        mount -o remount,noatime,commit=120 / 2>/dev/null || true

        for dev_sched in /sys/block/sd*/queue/scheduler /sys/block/mmcblk*/queue/scheduler /sys/block/nvme*/queue/scheduler; do
            if [ -f "$dev_sched" ]; then echo "mq-deadline" > "$dev_sched" 2>/dev/null || true; fi
        done
    fi
    echo -e "${C_GREEN}✅ Оптимизации RAM / Flash применены.${C_RESET}"
}

# 13. Менеджер Swap
mod_13_swap_manager() {
    echo -e "${C_CYAN}💾 === 13/18. УПРАВЛЕНИЕ ФАЙЛОМ ПОДКАЧКИ (SWAP) ===${C_RESET}"
    free -h
    echo "-------------------------------------------------"

    echo "Выберите действие:"
    echo "  1) Создать / Увеличить Swap до 2 GB"
    echo "  2) Создать Swap с произвольным размером (1G, 4G, 8G и т.д.)"
    echo "  3) Полностью отключить и удалить файл Swap"
    echo "  0) Назад / Отмена"
    local swap_choice
    read -r -p "Ваш выбор [0-3]: " swap_choice < /dev/tty

    case "$swap_choice" in
        1|2)
            local swap_size="2G"
            if [ "$swap_choice" = "2" ]; then
                prompt_clean "Введите размер Swap (например, 1G, 4G, 8G) (Enter - 4G)" swap_size
                if [ "$MODULE_CANCELED" = true ]; then return 0; fi
                swap_size="${swap_size:-4G}"
            fi

            if [ "$DRY_RUN" = false ]; then
                swapoff /swap.img 2>/dev/null || true
                swapoff /swapfile 2>/dev/null || true
                rm -f /swap.img /swapfile

                if ! fallocate -l "$swap_size" /swapfile 2>/dev/null; then
                    local num_mb
                    num_mb=$(echo "$swap_size" | sed -E 's/([0-9]+)[Gg]/\1 * 1024/e; s/([0-9]+)[Mm]/\1/e' 2>/dev/null || echo "2048")
                    dd if=/dev/zero of=/swapfile bs=1M count="$num_mb" status=progress
                fi
                chmod 600 /swapfile
                mkswap /swapfile
                swapon /swapfile
                sed -i '/swap/d' /etc/fstab
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            echo -e "${C_GREEN}✅ Swap ($swap_size) настроен.${C_RESET}"
            ;;
        3)
            if prompt_yn "Вы уверены, что хотите удалить Swap?" false; then
                if [ "$DRY_RUN" = false ]; then
                    swapoff -a 2>/dev/null || true
                    sed -i '/swap/d' /etc/fstab
                    rm -f /swapfile /swap.img
                fi
                echo -e "${C_GREEN}✅ Swap удален.${C_RESET}"
            fi
            ;;
    esac
}

# 14. PC-утилиты
mod_14_desktop_apps() {
    echo -e "${C_CYAN}🖥️ === 14/18. PC-УТИЛИТЫ И АВТОЗАПУСК (DEBIAN PC/XFCE) ===${C_RESET}"
    ensure_package "network-manager-gnome"
    ensure_package "pasystray"
    ensure_package "blueman"
    ensure_package "cbatticon"

    local target_user
    target_user=$(get_active_user)
    local target_home
    target_home=$(getent passwd "$target_user" | cut -d: -f6 || echo "/home/$target_user")
    [ -z "$target_home" ] && target_home="/home/$target_user"

    local autostart_dir="$target_home/.config/autostart"
    mkdir -p "$autostart_dir"

    write_file_atomic "$autostart_dir/nm-applet.desktop" "[Desktop Entry]\nType=Application\nName=Network Manager\nExec=nm-applet\nX-GNOME-Autostart-enabled=true" "0644"
    write_file_atomic "$autostart_dir/pasystray.desktop" "[Desktop Entry]\nType=Application\nName=PulseAudio Tray\nExec=pasystray\nX-GNOME-Autostart-enabled=true" "0644"
    write_file_atomic "$autostart_dir/blueman.desktop" "[Desktop Entry]\nType=Application\nName=Bluetooth Manager\nExec=blueman-applet\nX-GNOME-Autostart-enabled=true" "0644"
    write_file_atomic "$autostart_dir/cbatticon.desktop" "[Desktop Entry]\nType=Application\nName=Battery Icon\nExec=cbatticon\nX-GNOME-Autostart-enabled=true" "0644"

    if [ "$DRY_RUN" = false ]; then
        chown -R "$target_user:$target_user" "$target_home/.config" 2>/dev/null || true
    fi
    echo -e "${C_GREEN}✅ Трей-утилиты добавлены в автозапуск.${C_RESET}"
}

# 15. Программный сброс HDMI
mod_15_hdmi_reset() {
    echo -e "${C_CYAN}📺 === 15/18. ПРОГРАММНЫЙ СБРОС HDMI (LIGHTDM / XRANDR) ===${C_RESET}"
    write_file_atomic "/usr/local/bin/reset-hdmi.sh" \
"#!/bin/bash
HDMI_OUTPUT=\$(xrandr 2>/dev/null | grep -E \"^HDMI-[0-9A-Z-]+ connected\" | awk '{print \$1}' | head -n 1 || true)
if [ -n \"\$HDMI_OUTPUT\" ]; then
    sleep 3; xrandr --output \"\$HDMI_OUTPUT\" --off; sleep 1; xrandr --output \"\$HDMI_OUTPUT\" --auto
fi" "0755"

    if [ -f /etc/lightdm/lightdm.conf ] && [ "$DRY_RUN" = false ]; then
        backup_if_missing "/etc/lightdm/lightdm.conf"
        if ! grep -q "display-setup-script=/usr/local/bin/reset-hdmi.sh" /etc/lightdm/lightdm.conf; then
            if grep -q "\[Seat:\*\]" /etc/lightdm/lightdm.conf; then
                sed -i '/\[Seat:\*\]/a display-setup-script=/usr/local/bin/reset-hdmi.sh' /etc/lightdm/lightdm.conf
            else
                echo -e "\n[Seat:*]\ndisplay-setup-script=/usr/local/bin/reset-hdmi.sh" >> /etc/lightdm/lightdm.conf
            fi
        fi
    fi
    echo -e "${C_GREEN}✅ Скрипт сброса HDMI подключен к LightDM.${C_RESET}"
}

# 16. Диагностика времени загрузки
mod_16_boot_diag() {
    echo -e "${C_CYAN}⏱️ === 16/18. ДИАГНОСТИКА ВРЕМЕНИ ЗАГРУЗКИ СИСТЕМЫ ===${C_RESET}"
    if [ "$(cat /proc/1/comm 2>/dev/null)" != "systemd" ]; then
        echo -e "${C_RED}❌ Система запущенна без systemd.${C_RESET}"
        return 0
    fi

    local target_user
    target_user=$(get_active_user)
    local target_home
    target_home=$(getent passwd "$target_user" | cut -d: -f6 || echo "/home/$target_user")
    [ -z "$target_home" ] && target_home="/home/$target_user"

    local output_dir="$target_home/Downloads"
    mkdir -p "$output_dir"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="$output_dir/boot_report_${timestamp}.txt"
    local svg_file="$output_dir/boot_${timestamp}.svg"

    echo "📊 Анализ загрузки системы для пользователя $target_user..."
    systemd-analyze | tee "$report_file"
    systemd-analyze blame | head -n 15 | tee -a "$report_file"
    systemd-analyze critical-chain | tee -a "$report_file"
    systemd-analyze plot > "$svg_file" 2>/dev/null || true

    if [ "$DRY_RUN" = false ]; then
        chown -R "$target_user:$target_user" "$output_dir" 2>/dev/null || true
    fi
    echo -e "${C_GREEN}✅ Диагностика завершена. Отчет сохранен в $output_dir.${C_RESET}"
}

# 17. Полный аудит сервера
mod_17_server_audit() {
    echo -e "${C_CYAN}🔍 === 17/18. ПОЛНЫЙ ИНТЕЛЛЕКТУАЛЬНЫЙ АУДИТ И ДИАГНОСТИКА ===${C_RESET}\n"
    local active_user
    active_user=$(get_active_user)

    echo -e "${C_BOLD}--- 1. Базовая система и параметры хоста ---${C_RESET}"
    echo -e "  • Часовой пояс: ${C_GREEN}$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")${C_RESET}"
    echo -e "  • Имя хоста:    ${C_GREEN}$(hostname)${C_RESET}"
    
    echo -e "\n${C_BOLD}--- 2. Пользователи и SSH-доступ ---${C_RESET}"
    echo -e "  • Активный sudo-пользователь: ${C_GREEN}$active_user${C_RESET}"
    echo -e "  • Порт SSH: ${C_GREEN}$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")${C_RESET}"

    local root_ssh
    root_ssh=$(sshd -T 2>/dev/null | grep -i "^permitrootlogin " | awk '{print $2}' || echo "yes")
    [ "$root_ssh" = "no" ] && echo -e "  • Вход root по SSH: ${C_GREEN}✅ Запрещен${C_RESET}" || echo -e "  • Вход root по SSH: ${C_RED}❌ Разрешен${C_RESET}"

    echo -e "\n${C_BOLD}--- 3. Проверка защиты ядра, сети и BBR (sysctl) ---${C_RESET}"
    check_sysctl_param() {
        local param="$1" expected="$2" name="$3"
        local val
        val=$(sysctl -n "$param" 2>/dev/null || echo "0")
        [ "$val" = "$expected" ] && echo -e "  • $name ($param = $val): ${C_GREEN}✅ В норме${C_RESET}" || echo -e "  • $name ($param = $val, ожидается $expected): ${C_RED}❌ Не настроено${C_RESET}"
    }

    check_sysctl_param "kernel.dmesg_restrict" "1" "Ограничение dmesg"
    check_sysctl_param "kernel.kptr_restrict" "2" "Скрытие указателей ядра kptr"
    check_sysctl_param "net.ipv4.tcp_syncookies" "1" "Защита TCP SYN Cookies"
    check_sysctl_param "net.ipv4.tcp_congestion_control" "bbr" "Ускорение TCP Google BBR"

    echo -e "\n${C_BOLD}--- 4. Сетевая безопасность и Firewall (UFW) ---${C_RESET}"
    command -v ufw &>/dev/null && ufw status | grep -q "active" && echo -e "  • Статус UFW: ${C_GREEN}✅ Активен${C_RESET}" || echo -e "  • Статус UFW: ${C_RED}❌ Не активен${C_RESET}"

    echo -e "\n${C_BOLD}--- 5. Состояние и настройки сети Tailscale ---${C_RESET}"
    if command -v tailscale &>/dev/null; then
        local ts_name ts_ip ts_user ts_exit
        IFS="|" read -r ts_name ts_user <<< "$(get_tailscale_whoami)"
        ts_ip=$(tailscale whoami 2>/dev/null | grep -i "^  Addresses:" | grep -oP '100\.\d+\.\d+\.\d+' | head -n 1 || echo "N/A")
        ts_exit=$(tailscale get exit-node 2>/dev/null || echo "none")

        echo -e "  • Имя узла Tailnet:          ${C_BLUE}$ts_name${C_RESET}"
        echo -e "  • IP-адрес Tailscale:        ${C_BLUE}$ts_ip${C_RESET}"
        echo -e "  • Аккаунт:                   ${C_BLUE}$ts_user${C_RESET}"
        echo -e "  • Внешний Exit-Node:         ${C_BLUE}$ts_exit${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 6. Логирование и диск ---${C_RESET}"
    echo -e "  • Размер папки /var/log: ${C_BLUE}$(du -sh /var/log 2>/dev/null | awk '{print $1}' || echo "0")${C_RESET}"
    echo -e "\n${C_CYAN}=================================================================${C_RESET}"
}

# 18. Роутер-режим Одноплатного компьютера
mod_18_router_sbc() {
    echo -e "${C_CYAN}🛜 === 18/18. ОДНОПЛАТНЫЙ КОМПЬЮТЕР КАК РОУТЕР (LAN-ШЛЮЗ) ===${C_RESET}"

    local default_lan_if
    default_lan_if=$(ip -br link show | grep -v -E 'lo|tailscale' | awk '{print $1}' | head -n 1 || echo "eth0")
    local default_wan_if
    default_wan_if=$(ip -br link show | grep -v -E 'lo|tailscale' | awk '{print $1}' | tail -n 1 || echo "eth1")

    local lan_iface="" wan_iface="" ts_iface="" lan_ip="" lan_cidr=""
    prompt_clean "LAN интерфейс (Enter - $default_lan_if)" lan_iface
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    lan_iface="${lan_iface:-$default_lan_if}"

    prompt_clean "WAN интерфейс (Enter - $default_wan_if)" wan_iface
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    wan_iface="${wan_iface:-$default_wan_if}"

    prompt_clean "Tailscale интерфейс (Enter - tailscale0)" ts_iface
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    ts_iface="${ts_iface:-tailscale0}"

    local default_lan_ip="192.168.50.1"
    prompt_clean "IP-адрес роутера в LAN (Enter - $default_lan_ip)" lan_ip
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    lan_ip="${lan_ip:-$default_lan_ip}"

    prompt_clean "Маска подсети LAN CIDR (Enter - 24)" lan_cidr
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    lan_cidr="${lan_cidr:-24}"

    write_file_atomic "/etc/sysctl.d/99-tailscale-forward.conf" \
"net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1" "0644"

    if [ "$DRY_RUN" = false ]; then
        sysctl --system >/dev/null

        write_file_atomic "/etc/systemd/network/10-lan.network" \
"[Match]
Name=$lan_iface

[Link]
IgnoreCarrier=yes

[Network]
Address=$lan_ip/$lan_cidr
LinkLocalAddressing=no
ConfigureWithoutCarrier=yes" "0644"

        service_restart_safe "systemd-networkd"
        ensure_package "dnsmasq"

        local lan_prefix
        lan_prefix=$(echo "$lan_ip" | cut -d. -f1-3)

        write_file_atomic "/etc/dnsmasq.d/lan-dhcp.conf" \
"interface=$lan_iface
bind-interfaces
dhcp-range=${lan_prefix}.10,${lan_prefix}.254,255.255.255.0,12h
dhcp-option=3,$lan_ip
dhcp-option=6,1.1.1.1,8.8.8.8" "0644"

        service_restart_safe "dnsmasq"

        python3 - "$lan_iface" "$wan_iface" "$ts_iface" <<'PY'
import sys
from pathlib import Path

lan_iface, wan_iface, ts_iface = sys.argv[1], sys.argv[2], sys.argv[3]
path = Path("/etc/ufw/before.rules")
if path.exists():
    content = path.read_text()
    start = content.find("# --- Router Rules BEGIN ---")
    if start != -1:
        end = content.find("# --- Router Rules END ---", start)
        if end != -1: content = content[:start] + content[end+len("# --- Router Rules END ---"):]

    router_block = f"""# --- Router Rules BEGIN ---
*mangle
:PREROUTING ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
-A FORWARD -o {ts_iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT

*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o {ts_iface} -j MASQUERADE
COMMIT

*filter
:ufw-before-forward - [0:0]
-A ufw-before-forward -i {ts_iface} -o {lan_iface} -m state --state RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-forward -i {lan_iface} -o {ts_iface} -j ACCEPT
-A ufw-before-forward -i {lan_iface} -o {wan_iface} -j DROP
COMMIT
# --- Router Rules END ---
"""
    path.write_text(router_block + "\n" + content)
PY

        if command -v iptables-restore >/dev/null 2>&1; then
            iptables-restore --test < /etc/ufw/before.rules || true
        fi
        ufw reload 2>/dev/null || true
    fi
    echo -e "${C_GREEN}✅ Одноплатный компьютер успешно настроен как роутер!${C_RESET}"
}

# ==============================================================================
# ОБРАБОТКА АРГУМЕНТОВ И ГЛАВНОЕ МЕНЮ
# ==============================================================================

# Проверка флагов запуска (например: ./setup.sh --dry-run)
for arg in "$@"; do
    case "$arg" in
        -d|--dry-run)
            DRY_RUN=true
            echo -e "${C_YELLOW}⚠️ ЗАПУЩЕН РЕЖИМ DRY-RUN: Изменения в систему вноситься не будут!${C_RESET}"
            ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo -e "${C_RED}❌ Ошибка: этот скрипт должен запускаться от имени root.${C_RESET}" >&2
    exit 1
fi

check_dependencies

while true; do
    clear
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    echo -e "${C_BOLD}       🛠️  ГЛАВНОЕ МЕНЮ НАСТРОЙКИ СЕРВЕРА И ПК     ${C_RESET}"
    echo -e "${C_BOLD}       Автор: Michael Bobarev, Bobarev.com${C_RESET}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${C_YELLOW}       [ РЕЖИМ ПРЕВЬЮ / DRY-RUN АКТИВЕН ]${C_RESET}"
    fi
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    echo -e " Тип системы: ${C_GREEN}$SYSTEM_TYPE${C_RESET} | Хост: ${C_GREEN}$(hostname)${C_RESET}"
    
    ts_main_status="Не установлен"
    if command -v tailscale &>/dev/null; then
        if is_tailscale_web_active; then ts_main_status="Установлен (Web UI)"; else ts_main_status="Установлен"; fi
    fi

    echo -e " Tailscale: ${C_GREEN}$ts_main_status${C_RESET} | UFW: ${C_GREEN}$(ufw status 2>/dev/null | head -n 1 || echo "Неизвестно")${C_RESET}"
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    echo " --- [БАЗОВАЯ СИСТЕМА И СЕРВЕР] ---"
    echo "  1) 🌐 Часовой пояс"
    echo "  2) 🏷️  Имя хоста"
    echo "  3) 📦 Обновление системы"
    echo "  4) 👤 Создание/настройка пользователя"
    echo "  5) 🔑 Привязка/обновление SSH-ключа"
    echo "  6) 🔒 Безопасность SSH"
    echo "  7) 🛡️  Защита ядра и сети"
    echo "  8) 🧱 Межсетевой экран UFW"
    echo "  9) 🔐 Блокировка пароля root"
    echo " 10) 🔗 Настройка Tailscale и GRO-оптимизация"
    echo " 11) 🧹 Отключение системного логирования"
    echo " 12) ⚡ Оптимизация RAM / Flash"
    echo " 13) 💾 Управление файлом подкачки"
    echo " --- [PC / РОУТЕР / ДИАГНОСТИКА] ---"
    echo " 14) 🖥️  PC-утилиты (WiFi, Звук, Bluetooth, Батарея) и автозапуск"
    echo " 15) 📺 Программный сброс HDMI (LightDM)"
    echo " 16) ⏱️  Диагностика времени загрузки системы"
    echo " 17) 🔍 Полный аудит и проверка настроек сервера"
    echo " 18) 🛜 Одноплатный компьютер как роутер"
    echo "-----------------------------------------------------------------"
    echo -e "${C_GREEN}  A) 🚀 ВЫПОЛНИТЬ ВСЮ ПЕРВИЧНУЮ НАСТРОЙКУ С НУЛЯ (МОДУЛИ 1-12)${C_RESET}"
    echo -e "${C_RED}  0) ❌ Выход${C_RESET}"
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    read -r -p "Выберите пункт меню [0-18, A]: " choice < /dev/tty

    MODULE_CANCELED=false

    case "$choice" in
        1) mod_1_timezone; pause_enter ;;
        2) mod_2_hostname; pause_enter ;;
        3) mod_3_apt_update; pause_enter ;;
        4) mod_4_user_setup; pause_enter ;;
        5) mod_5_ssh_key; pause_enter ;;
        6) mod_6_ssh_config; pause_enter ;;
        7) mod_7_hardening; pause_enter ;;
        8) mod_8_ufw; pause_enter ;;
        9) mod_9_lock_root; pause_enter ;;
        10) mod_10_tailscale ;;
        11) mod_11_disable_logging; pause_enter ;;
        12) mod_12_ram_flash_opt; pause_enter ;;
        13) mod_13_swap_manager; pause_enter ;;
        14) mod_14_desktop_apps; pause_enter ;;
        15) mod_15_hdmi_reset; pause_enter ;;
        16) mod_16_boot_diag; pause_enter ;;
        17) mod_17_server_audit; pause_enter ;;
        18) mod_18_router_sbc; pause_enter ;;
        a|A)
            echo "🚀 ЗАПУСК ПОЛНОЙ ПОСЛЕДОВАТЕЛЬНОЙ НАСТРОЙКИ СЕРВЕРА..."
            for m in mod_1_timezone mod_2_hostname mod_3_apt_update mod_4_user_setup mod_5_ssh_key mod_6_ssh_config mod_7_hardening mod_8_ufw mod_9_lock_root mod_10_tailscale mod_11_disable_logging mod_12_ram_flash_opt; do
                MODULE_CANCELED=false
                $m
                if [ "$MODULE_CANCELED" = true ]; then
                    echo -e "${C_YELLOW}🛑 Последовательная установка прервана.${C_RESET}"
                    break
                fi
            done
            pause_enter
            ;;
        0) echo "Выход."; exit 0 ;;
        *) echo "Неверный выбор."; pause_enter ;;
    esac
done