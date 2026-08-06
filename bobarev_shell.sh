#!/bin/bash
set -euo pipefail

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ, ANSI-ЦВЕТА И АВТООПРЕДЕЛЕНИЕ
# ==============================================================================

# ANSI-цвета для терминала
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

# Флаг отмены модуля
MODULE_CANCELED=false

# Определение типа системы (VPS, SBC/Armbian, ПК/Десктоп)
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

# Динамическое определение активного пользователя системы
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

# Проверка активности веб-интерфейса Tailscale Web через нативный статус CLI
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
port = int(sys.argv)
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

# Определение IPv4 подсети сетевого интерфейса (например, 192.168.1)
get_interface_subnet() {
    local iface="$1"
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 | cut -d. -f1-3 || echo ""
}

# Автоматическая установка и авторизация Tailscale при необходимости
ensure_tailscale_installed() {
    if ! command -v tailscale &>/dev/null; then
        echo -e "${C_BLUE}📦 Для ограничения SSH через Tailscale требуется установка пакета...${C_RESET}"
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

        local authkey
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

prompt_default() {
    local prompt="$1"
    local default_val="$2"
    local var_name="$3"
    local val
    read -r -p "$(echo -e "${C_BOLD}$prompt${C_RESET} [$default_val] (0 - Назад): ")" val < /dev/tty
    if [ "$val" = "0" ] || [ "$val" = "b" ] || [ "$val" = "back" ] || [ "$val" = "назад" ]; then
        echo -e "${C_YELLOW}↩️ Отмена модуля. Возврат в главное меню...${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi
    eval "$var_name=\"\${val:-\$default_val}\""
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

backup_file() {
    local file="$1"
    if [ -f "$file" ] && [ ! -f "${file}.bak" ]; then
        cp "$file" "${file}.bak"
        echo -e "${C_BLUE}💾 Создана резервная копия: ${file}.bak${C_RESET}"
    fi
}

pause_enter() {
    echo ""
    read -r -p "Нажмите Enter для продолжения..." < /dev/tty
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${C_RED}❌ Ошибка: этот скрипт должен запускаться от имени root.${C_RESET}" >&2
    exit 1
fi

# ==============================================================================
# МОДУЛИ НАСТРОЙКИ
# ==============================================================================

# 1. Часовой пояс
mod_timezone() {
    echo -e "${C_CYAN}🌐 === 1/18. НАСТРОЙКА ЧАСОВОГО ПОЯСА ===${C_RESET}"
    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Europe/Moscow")
    echo "Текущий часовой пояс: $current_tz"
    local tz=""
    prompt_clean "Введите новый часовой пояс (Enter - $current_tz)" tz
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    tz="${tz:-$current_tz}"
    timedatectl set-timezone "$tz" || true
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
        *) default_brand_host="Server_VPS" ;;
    esac

    local new_host=""
    prompt_clean "Введите имя хоста (Enter - $default_brand_host)" new_host
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    new_host="${new_host:-$default_brand_host}"
    hostnamectl set-hostname "$new_host"
    if ! grep -q "$new_host" /etc/hosts; then
        sed -i "s/127.0.0.1\tlocalhost/127.0.0.1\tlocalhost $new_host/" /etc/hosts
    fi
    sed -i 's/preserve_hostname: false/preserve_hostname: true/g' /etc/cloud/cloud.cfg 2>/dev/null || true
    echo -e "${C_GREEN}✅ Hostname изменен на $new_host.${C_RESET}"
}

# 3. Обновление пакетов
mod_apt_update() {
    echo -e "${C_CYAN}📦 === 3/18. ОБНОВЛЕНИЕ ПАКЕТОВ И ОЧИСТКА ===${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt upgrade -y

    # Детекция Armbian для защиты от конфликта zram
    local zram_pkg="zram-tools"
    if [ -f /etc/default/armbian-zram ] || [ -f /etc/init.d/armbian-zram ]; then
        echo -e "${C_BLUE}ℹ️ Обнаружен встроенный Armbian zram, установка стороннего zram-tools пропущена во избежание конфликта.${C_RESET}"
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
    echo "Текущий режим загрузки системы: $current_target"

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
mod_user_setup() {
    echo -e "${C_CYAN}👤 === 4/18. СОЗДАНИЕ И НАСТРОЙКА ПОЛЬЗОВАТЕЛЯ ===${C_RESET}"
    local active_user
    active_user=$(get_active_user)
    local username=""
    prompt_clean "Имя sudo-пользователя (Enter - $active_user)" username
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    username="${username:-$active_user}"

    if ! id "$username" &>/dev/null; then
        adduser --disabled-password --gecos "" "$username"
        echo -e "${C_GREEN}✅ Пользователь $username создан.${C_RESET}"
    fi
    usermod -aG sudo "$username"

    local pass
    read -s -p "Введите новый пароль для $username (Enter, если не менять, 0 - Назад): " pass < /dev/tty
    echo ""
    if [ "$pass" = "0" ]; then
        echo -e "${C_YELLOW}↩️ Отмена модуля. Возврат в главное меню...${C_RESET}"
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

    if prompt_yn "Разрешить sudo без запроса пароля (NOPASSWD)?" true; then
        echo "$username ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$username"
        chmod 0440 "/etc/sudoers.d/$username"
        echo -e "${C_GREEN}✅ Sudo NOPASSWD включен для $username.${C_RESET}"
    else
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        rm -f "/etc/sudoers.d/$username"
        echo "ℹ️ Sudo будет запрашивать пароль."
    fi
}

# 5. SSH-ключи
mod_ssh_key() {
    echo -e "${C_CYAN}🔑 === 5/18. НАСТРОЙКА SSH-КЛЮЧЕЙ ===${C_RESET}"
    local active_user
    active_user=$(get_active_user)
    local target_user=""
    prompt_clean "Для какого пользователя установить ключ? (Enter - $active_user)" target_user
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    target_user="${target_user:-$active_user}"

    if ! id "$target_user" &>/dev/null; then
        echo "Пользователь $target_user не существует, создаем..."
        adduser --disabled-password --gecos "" "$target_user"
        usermod -aG sudo "$target_user"
    fi

    local target_home
    target_home=$(getent passwd "$target_user" | cut -d: -f6)
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
            echo -e "${C_YELLOW}↩️ Отмена модуля. Возврат в главное меню...${C_RESET}"
            MODULE_CANCELED=true
            return 0
        fi
    fi

    if [ -n "$pubkey" ]; then
        echo "Режим записи:"
        echo "  1) Дописать в конец authorized_keys (безопасно)"
        echo "  2) Перезаписать файл authorized_keys"
        echo "  0) Назад / Отмена"
        local mode_choice
        read -r -p "Ваш выбор [1-2, 0]: " mode_choice < /dev/tty
        if [ "$mode_choice" = "0" ]; then
            echo -e "${C_YELLOW}↩️ Отмена модуля. Возврат в главное меню...${C_RESET}"
            MODULE_CANCELED=true
            return 0
        fi

        if [ "$mode_choice" = "2" ]; then
            echo "$pubkey" > "$target_home/.ssh/authorized_keys"
            echo -e "${C_GREEN}✅ Файл перезаписан.${C_RESET}"
        else
            if ! grep -qF "$pubkey" "$target_home/.ssh/authorized_keys" 2>/dev/null; then
                echo "$pubkey" >> "$target_home/.ssh/authorized_keys"
                echo -e "${C_GREEN}✅ Ключ добавлен в конец authorized_keys.${C_RESET}"
            else
                echo -e "${C_BLUE}ℹ️ Этот ключ уже существует в файле.${C_RESET}"
            fi
        fi
    fi

    chmod 755 "$target_home" 2>/dev/null || true
    chmod 700 "$target_home/.ssh"
    chmod 600 "$target_home/.ssh/authorized_keys" 2>/dev/null || true
    chown -R "$target_user:$target_user" "$target_home/.ssh"
    echo -e "${C_GREEN}✅ Права на $target_home/.ssh проверены и выставлены.${C_RESET}"
}

# 6. Конфигурация SSH
mod_ssh_config() {
    echo -e "${C_CYAN}🔒 === 6/18. КОНФИГУРАЦИЯ SSH (БЕЗОПАСНОСТЬ) ===${C_RESET}"
    backup_file "/etc/ssh/sshd_config"
    local active_ssh_port
    active_ssh_port=$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")

    local port=""
    while true; do
        prompt_clean "Введите порт SSH (Enter - $active_ssh_port)" port
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        port="${port:-$active_ssh_port}"

        # Интеллектуальная проверка доступности порта
        if [ "$port" != "$active_ssh_port" ] && ! is_port_free "$port"; then
            echo -e "${C_RED}⚠️ ВНИМАНИЕ: Порт $port уже ЗАНЯТ другим процессом в системе!${C_RESET}"
            echo -e "${C_YELLOW}Пожалуйста, выберите другой порт.${C_RESET}"
            continue
        fi
        break
    done

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
            echo -e "${C_GREEN}✅ Найдены действующие SSH-ключи. Вход по паролю будет отключен.${C_RESET}"
        else
            echo -e "${C_YELLOW}⚠️ ВНИМАНИЕ: На сервере не найдено ни одного SSH-ключа!${C_RESET}"
            echo -e "${C_YELLOW}⚠️ Вход по паролю ОСТАЕТСЯ ВКЛЮЧЕННЫМ, чтобы избежать блокировки доступа.${C_RESET}"
            pass_auth_val="yes"
            kbd_auth_val="yes"
        fi
    else
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    fi

    # Гарантируем существование директории sshd_config.d и директивы Include
    mkdir -p /etc/ssh/sshd_config.d
    if [ -f /etc/ssh/sshd_config ] && ! grep -q -i "Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
        echo -e "\nInclude /etc/ssh/sshd_config.d/*.conf" >> /etc/ssh/sshd_config
    fi

    tee /etc/ssh/sshd_config.d/99-server-security.conf > /dev/null << SSH_HARDENING_EOF
# Server Security Hardening Configuration
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
TCPKeepAlive yes
SSH_HARDENING_EOF

    if sshd -t; then
        systemctl disable --now ssh.socket 2>/dev/null || true
        systemctl enable --now ssh.service
        systemctl restart sshd

        # Автоматическая связка с Tailscale
        if prompt_yn "Ограничить доступ к SSH ТОЛЬКО через сеть Tailscale?" true; then
            if ensure_tailscale_installed; then
                if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
                    ufw allow in on tailscale0 to any port "$port" proto tcp comment 'SSH via Tailscale only' 2>/dev/null || true
                    ufw delete allow "$port"/tcp 2>/dev/null || true
                    echo -e "${C_GREEN}✅ SSH доступ ограничен: разрешен ТОЛЬКО через сеть Tailscale.${C_RESET}"
                else
                    echo -e "${C_BLUE}ℹ️ Ограничение SSH сохранено. Правило будет задействовано при включении UFW в Модуле 8.${C_RESET}"
                fi
            else
                echo -e "${C_YELLOW}⚠️ Установка Tailscale отменена. SSH настроен в обычном режиме (порт $port).${C_RESET}"
                if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
                    ufw allow "$port"/tcp comment 'SSH Public Port' 2>/dev/null || true
                fi
            fi
        else
            if [ "$MODULE_CANCELED" = true ]; then return 0; fi
            if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
                ufw allow "$port"/tcp comment 'SSH Public Port' 2>/dev/null || true
            fi
        fi

        echo -e "${C_GREEN}✅ Служба SSH успешно перезапущена (Порт: $port, Вход по паролю: $pass_auth_val).${C_RESET}"
    else
        echo -e "${C_RED}❌ Ошибка синтаксиса в конфигурации SSH! Откат изменений...${C_RESET}"
        rm -f /etc/ssh/sshd_config.d/99-server-security.conf
    fi
}

# 7. Защита ядра и сети (С оптимизацией BBR, FastOpen и RFC1337)
mod_hardening() {
    echo -e "${C_CYAN}🛡️ === 7/18. ЗАЩИТА ЯДРА, СЕТИ И УСКОРЕНИЕ TCP BBR ===${C_RESET}"
    backup_file "/etc/sysctl.d/99-hardening.conf"
    
    # Попытка подгрузить модуль BBR в ядре
    modprobe tcp_bbr 2>/dev/null || true

    mkdir -p /etc/sysctl.d
    tee /etc/sysctl.d/99-server-hardening.conf > /dev/null << 'HARDENING_EOF'
# Kernel Security Hardening
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
kernel.unprivileged_bpf_disabled = 1
kernel.perf_event_paranoid = 3
kernel.sysrq = 0
net.core.bpf_jit_harden = 2

# Сетевая безопасность и защита от атак
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

# Защита файловой системы
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 1
fs.protected_regular = 1

# Оптимизация сетевых задержек: Google BBR + FQ Queue + TCP FastOpen + RFC1337
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 0
HARDENING_EOF
    sysctl --system > /dev/null
    echo -e "${C_GREEN}✅ Настройки защиты ядра, сети и ускорения Google BBR применены.${C_RESET}"
}

# 8. Firewall UFW
mod_ufw() {
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

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    if prompt_yn "Разрешить маршрутизацию пакетов (FORWARD ACCEPT)? (Нужно для роутеров и Tailscale Exit-Node)" true; then
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
            echo -e "${C_YELLOW}⚠️ Установка Tailscale отменена. Открываем публичный порт SSH ($port).${C_RESET}"
            ufw allow "$port"/tcp comment 'SSH Public Port'
        fi
    else
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        ufw allow "$port"/tcp comment 'SSH Public Port'
    fi

    ufw --force enable
    ufw logging off 2>/dev/null || true
    echo -e "${C_GREEN}✅ Межсетевой экран UFW включен (логирование UFW отключено).${C_RESET}"
}

# 9. Блокировка Root
mod_lock_root() {
    echo -e "${C_CYAN}🔐 === 9/18. БЛОКИРОВКА ПАРОЛЯ ROOT ===${C_RESET}"
    if [ $(getent group sudo | cut -d: -f4 | tr ',' ' ' | wc -w) -gt 0 ]; then
        passwd -l root
        echo -e "${C_GREEN}✅ Пароль root заблокирован.${C_RESET}"
    else
        echo -e "${C_YELLOW}⚠️ ВНИМАНИЕ: В группе sudo нет пользователей! Запрет root отменен.${C_RESET}"
    fi
}

# 10. Tailscale, GRO-оптимизация, Нативный Web UI & Интерактивная безопасность
mod_tailscale() {
    while true; do
        clear
        echo -e "${C_CYAN}🔗 === 10/18. УПРАВЛЕНИЕ И НАСТРОЙКА TAILSCALE CLI ===${C_RESET}"
        
        # Предварительный вывод статуса узла с понятным форматированием значений
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

            if is_tailscale_web_active; then
                ts_web_fmt="Включен"
            else
                ts_web_fmt="Отключен"
            fi

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
            1)
                ensure_tailscale_installed
                pause_enter
                ;;
            2)
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
                        if [ "$MODULE_CANCELED" = true ]; then MODULE_CANCELED=false; continue; fi
                        if [ -n "$target_ip" ]; then
                            tailscale set --exit-node="$target_ip" --exit-node-allow-lan-access 2>/dev/null || true
                            echo -e "${C_GREEN}✅ Подключен к Exit Node $target_ip.${C_RESET}"
                            echo -e "${C_YELLOW}💡 ВНИМАНИЕ: Если пропал интернет при подключении к Exit Node:${C_RESET}"
                            echo -e "   1. На удаленном Exit Node сервере должен быть включен анонс (Пункт 2 -> 1)."
                            echo -e "   2. В админке (admin.tailscale.com -> Machines -> Сервер -> Edit route settings)"
                            echo -e "      обязательно должна быть включена галочка 'Approve exit node'."
                            echo -e "   3. На удаленном сервере должен быть включен IP Forwarding и UFW / NAT."
                        fi
                        ;;
                    4) tailscale set --exit-node= 2>/dev/null || true; echo -e "${C_GREEN}✅ Отключен от Exit Node (Интернет через физический провайдер восстановлен).${C_RESET}" ;;
                esac
                pause_enter
                ;;
            3)
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
                        if [ "$MODULE_CANCELED" = true ]; then
                            MODULE_CANCELED=false
                            continue
                        fi
                        routes_input="${routes_input:-${default_route_spec:-192.168.1.0/24}}"
                        tailscale set --advertise-routes="$routes_input" 2>/dev/null || true
                        echo -e "${C_GREEN}✅ Анонсируется подсеть $routes_input.${C_RESET}"
                        pause_enter
                        ;;
                    2)
                        tailscale set --advertise-routes= 2>/dev/null || true
                        echo -e "${C_GREEN}✅ Анонсирование подсетей отключено.${C_RESET}"
                        pause_enter
                        ;;
                    0)
                        ;;
                esac
                ;;
            4)
                echo "Прием подсетей из Tailscale (--accept-routes):"
                echo "  1) Включить прием подсетей из Tailscale (tailscale set --accept-routes=true)"
                echo "  2) Отключить прием подсетей из Tailscale (tailscale set --accept-routes=false)"
                echo "  0) Назад"
                local ac_choice
                read -r -p "Ваш выбор [0-2]: " ac_choice < /dev/tty
                case "$ac_choice" in
                    1) tailscale set --accept-routes=true 2>/dev/null || true; echo -e "${C_GREEN}✅ Прием подсетей из Tailscale включен (--accept-routes=true).${C_RESET}" ;;
                    2) tailscale set --accept-routes=false 2>/dev/null || true; echo -e "${C_BLUE}ℹ️ Прием подсетей из Tailscale отключен.${C_RESET}" ;;
                esac
                pause_enter
                ;;
            5)
                echo "Стелс-режим (Stateful Filtering):"
                echo "  1) Включить стелс-режим (tailscale set --stateful-filtering=true)"
                echo "  2) Отключить стелс-режим (tailscale set --stateful-filtering=false)"
                echo "  0) Назад"
                local sf_choice
                read -r -p "Ваш выбор [0-2]: " sf_choice < /dev/tty
                case "$sf_choice" in
                    1) tailscale set --stateful-filtering=true 2>/dev/null || true; echo -e "${C_GREEN}✅ Стелс-режим (Stateful Filtering) включен.${C_RESET}" ;;
                    2) tailscale set --stateful-filtering=false 2>/dev/null || true; echo -e "${C_GREEN}✅ Стелс-режим отключен.${C_RESET}" ;;
                esac
                pause_enter
                ;;
            6)
                echo "Настройка GRO-оптимизации (tailscale-gro.service):"
                echo "  1) Включить GRO-оптимизацию (создать и запустить tailscale-gro.service)"
                echo "  2) Отключить GRO-оптимизацию (остановить и удалить tailscale-gro.service)"
                echo "  0) Назад"
                local gro_choice
                read -r -p "Ваш выбор [0-2]: " gro_choice < /dev/tty
                case "$gro_choice" in
                    1)
                        cat << 'ETHTOOL_SCRIPT_EOF' > /usr/local/bin/tailscale-gro.sh
#!/bin/bash
while ! ip route show default | grep -v tailscale0 >/dev/null 2>&1; do
    sleep 2
done
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
                        systemctl enable --now tailscale-gro.service
                        echo -e "${C_GREEN}✅ Служба GRO-оптимизации tailscale-gro.service включена.${C_RESET}"
                        ;;
                    2)
                        systemctl disable --now tailscale-gro.service 2>/dev/null || true
                        rm -f /etc/systemd/system/tailscale-gro.service /usr/local/bin/tailscale-gro.sh
                        systemctl daemon-reload
                        local netdev="$DEFAULT_WAN_IF"
                        [ -z "$netdev" ] && netdev=$(ip route show default | grep -v tailscale0 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || echo "")
                        if [ -n "$netdev" ]; then
                            ethtool -K "$netdev" rx-udp-gro-forwarding off 2>/dev/null || true
                        fi
                        echo -e "${C_BLUE}ℹ️ Служба GRO-оптимизации отключена и удалена.${C_RESET}"
                        ;;
                esac
                pause_enter
                ;;
            7)
                echo "Настройка веб-интерфейса Tailscale Web (tailscale set --webclient):"
                echo "  1) Включить веб-интерфейс Tailscale Web (tailscale set --webclient=true)"
                echo "  2) Отключить веб-интерфейс Tailscale Web (tailscale set --webclient=false)"
                echo "  0) Назад"
                local web_choice
                read -r -p "Ваш выбор [0-2]: " web_choice < /dev/tty
                case "$web_choice" in
                    1)
                        if ! command -v tailscale &>/dev/null; then
                            ensure_tailscale_installed
                        fi

                        # Нативный и безопасный метод из официальной документации
                        tailscale set --webclient=true 2>/dev/null || true

                        # Очищаем старые службы, если они создавались ранее
                        systemctl disable --now tailscale-web.service 2>/dev/null || true
                        rm -f /etc/systemd/system/tailscale-web.service
                        systemctl daemon-reload

                        local current_ts_ip
                        current_ts_ip=$(tailscale whoami 2>/dev/null | grep -i "^  Addresses:" | grep -oP '100\.\d+\.\d+\.\d+' | head -n 1 || echo "100.100.100.100")
                        echo -e "${C_GREEN}✅ Нативный веб-интерфейс Tailscale Web успешно включен (tailscale set --webclient=true).${C_RESET}"
                        echo -e "${C_CYAN}🌐 Доступные адреса веб-панели в браузере:${C_RESET}"
                        echo -e "   • Локально на устройстве:  http://100.100.100.100"
                        echo -e "   • Удаленно из сети Tailnet: http://${current_ts_ip}:5252"
                        ;;
                    2)
                        # Нативное отключение + перезапуск демона tailscaled для применения изменения в памяти
                        tailscale set --webclient=false 2>/dev/null || true

                        if systemctl is-active --quiet tailscaled 2>/dev/null; then
                            systemctl restart tailscaled 2>/dev/null || true
                        elif command -v launchctl &>/dev/null; then
                            launchctl kickstart -k system/com.tailscale.tailscaled 2>/dev/null || true
                        fi

                        # Очистка и завершение возможных старых фоновых служб
                        systemctl disable --now tailscale-web.service 2>/dev/null || true
                        pkill -9 -f "tailscale.*web" 2>/dev/null || true
                        rm -f /etc/systemd/system/tailscale-web.service
                        systemctl daemon-reload

                        echo -e "${C_GREEN}✅ Нативный веб-интерфейс Tailscale Web отключен (tailscale set --webclient=false), демон tailscaled перезапущен.${C_RESET}"
                        ;;
                esac
                pause_enter
                ;;
            8)
                echo "⚠️ Сброс параметров Tailscale к значениям по умолчанию (tailscale up --reset):"
                if prompt_yn "Вы действительно хотите сбросить все текущие параметры Tailscale?" false; then
                    if [ "$MODULE_CANCELED" = true ]; then
                        MODULE_CANCELED=false
                        continue
                    fi
                    tailscale up --reset 2>&1 | grep -v "accept-routes" || true
                    echo -e "${C_GREEN}✅ Настройки Tailscale сброшены к значениям по умолчанию.${C_RESET}"
                else
                    if [ "$MODULE_CANCELED" = true ]; then
                        MODULE_CANCELED=false
                        continue
                    fi
                fi
                pause_enter
                ;;
            0)
                break
                ;;
        esac
    done
}

# 11. Отключение системного логирования (С АВТО-ОЧИСТКОЙ ПРИ ПЕРЕЗАГРУЗКЕ И APT)
mod_disable_logging() {
    echo -e "${C_CYAN}🧹 === 11/18. ОТКЛЮЧЕНИЕ СИСТЕМНОГО ЛОГИРОВАНИЯ И АУДИТА ===${C_RESET}"
    backup_file "/etc/systemd/journald.conf"

    cat << 'DISABLE_LOGS_EOF' > /usr/local/bin/disable-logging.sh
#!/bin/bash
set -euo pipefail

echo "🚀 Начинаем полное отключение логирования и аудита..."

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
echo "✅ Служба systemd-journald переведена в режим Storage=none."

SERVICES_TO_DISABLE=(
  "rsyslog"
  "auditd"
  "armbian-hardware-monitor"
)

for svc in "${SERVICES_TO_DISABLE[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}.service"; then
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
    echo "✅ Служба $svc остановлена и заблокирована."
  fi
done

if command -v auditctl &> /dev/null; then
    auditctl -e 0 2>/dev/null || true
    echo "✅ Аудит ядра (auditctl) отключен."
fi

if command -v warp-cli &> /dev/null; then
    warp-cli log disable 2>/dev/null || true
    echo "✅ Логи Cloudflare WARP отключены."
fi

if command -v ufw &>/dev/null; then
    ufw logging off 2>/dev/null || true
    echo "✅ Логирование UFW отключено."
fi

# 1. Автоматическая очистка APT / DPKG логов после любых установок пакетов
mkdir -p /etc/apt/apt.conf.d
cat << 'APT_CLEAN_EOF' > /etc/apt/apt.conf.d/99clean-logs
DPkg::Post-Invoke {"truncate -s 0 /var/log/dpkg.log /var/log/alternatives.log /var/log/apt/*.log 2>/dev/null || true";};
APT_CLEAN_EOF

# 2. Очистка журналов и удаление структуры /var/log/journal
find /var/log -type f \( -name "*.log*" -o -name "syslog*" -o -name "auth.log*" -o -name "kern.log*" -o -name "ufw.log*" -o -name "dpkg*" -o -name "wtmp*" -o -name "btmp*" -o -name "lastlog*" \) -exec truncate -s 0 {} + 2>/dev/null || true
find /var/log -type f \( -name "*.[0-9]" -o -name "*.gz" \) -delete 2>/dev/null || true
rm -rf /var/log/journal /run/log/journal 2>/dev/null || true
echo "✅ Папка /var/log и бинарные журналы очищены."

journalctl --vacuum-size=1M 2>/dev/null || true
echo "✅ Журнал journald принудительно очищен."

echo "🎉 Системное логирование и аудит полностью отключены!"
DISABLE_LOGS_EOF

    chmod +x /usr/local/bin/disable-logging.sh

    # 3. Автоматический запуск очистки логов при КАЖДОЙ загрузке системы (systemd boot service)
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
    systemctl enable clean-logs-boot.service 2>/dev/null || true

    /usr/local/bin/disable-logging.sh
    echo -e "${C_GREEN}✅ Полное авто-отключение системного логирования и постоянная очистка при перезагрузках/APT настроена.${C_RESET}"
}

# 12. Оптимизация RAM / Flash (Надежная двойная запись noatime + commit=120)
mod_ram_flash_opt() {
    echo -e "${C_CYAN}⚡ === 12/18. ОПТИМИЗАЦИЯ RAM, FLASH (COMMIT=120, NOATIME, I/O) ===${C_RESET}"
    backup_file "/etc/fstab"

    # 1. Буферизация записи грязных страниц в RAM для ресурса Flash
    mkdir -p /etc/sysctl.d
    cat << 'EOF' > /etc/sysctl.d/99-ram-opt.conf
# Оптимизация ресурса памяти MicroSD / eMMC / SSD
vm.swappiness=1
vm.vfs_cache_pressure=50
vm.dirty_writeback_centisecs=1500
vm.dirty_background_ratio=5
vm.dirty_ratio=10

# Ограничение доступа к буферу ядра (dmesg)
kernel.dmesg_restrict=1
EOF
    sysctl --system > /dev/null

    # 2. Гарантированная запись опций noatime,commit=120 в /etc/fstab через Python
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
        if len(parts) >= 4 and parts == "/":
            opts = parts[3].split(",")
            if "noatime" not in opts:
                opts.append("noatime")
            if "commit=120" not in opts:
                opts.append("commit=120")
            parts[3] = ",".join(opts)
            new_lines.append("\t".join(parts))
        else:
            new_lines.append(line)
    fstab_path.write_text("\n".join(new_lines) + "\n")
PY

    # 3. Дополнительно прописываем commit=120 в суперблок Ext4 (если корень на ext4)
    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}' || echo "")
    if [ -n "$root_dev" ] && command -v tune2fs >/dev/null 2>&1; then
        tune2fs -E mount_opts=commit=120 "$root_dev" 2>/dev/null || true
    fi

    # Перемонтирование с новыми опциями
    mount -o remount,noatime,commit=120 / 2>/dev/null || true

    # 4. Настройка I/O планировщика mq-deadline для Flash-накопителей
    for dev_sched in /sys/block/sd*/queue/scheduler /sys/block/mmcblk*/queue/scheduler /sys/block/nvme*/queue/scheduler; do
        if [ -f "$dev_sched" ]; then
            echo "mq-deadline" > "$dev_sched" 2>/dev/null || true
        fi
    done

    # 5. Монтирование временных директорий и логов в RAM (tmpfs)
    TMPFS_ENTRIES=(
        "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=512M 0 0"
        "tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,size=256M 0 0"
        "tmpfs /var/log/cloudflare-warp tmpfs defaults,noatime,size=16M 0 0"
    )

    for entry in "${TMPFS_ENTRIES[@]}"; do
        mount_point=$(echo "$entry" | awk '{print $2}')
        if ! grep -q "$mount_point" /etc/fstab; then
            mkdir -p "$mount_point"
            echo "$entry" >> /etc/fstab
            echo "  - Добавлен $mount_point в tmpfs."
        fi
    done

    systemctl daemon-reload
    mount -a 2>/dev/null || true
    echo -e "${C_GREEN}✅ Оптимизации RAM / Flash (noatime, commit=120, dirty-writeback) гарантированно применены и сохранены.${C_RESET}"
}

# 13. Менеджер Swap
mod_swap_manager() {
    echo -e "${C_CYAN}💾 === 13/18. УПРАВЛЕНИЕ ФАЙЛОМ ПОДКАЧКИ (SWAP) ===${C_RESET}"
    echo "=== Текущее состояние Swap ==="
    free -h
    echo "-------------------------------------------------"
    swapon --show 2>/dev/null || true
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
            echo "Создание Swap размером $swap_size..."
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
            sysctl vm.swappiness=60 2>/dev/null || true
            if grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
                sed -i 's/vm.swappiness=.*/vm.swappiness=60/' /etc/sysctl.conf
            else
                echo 'vm.swappiness=60' >> /etc/sysctl.conf
            fi
            echo -e "${C_GREEN}✅ Swap ($swap_size) успешно настроен!${C_RESET}"
            ;;
        3)
            if prompt_yn "Вы уверены, что хотите полностью удалить Swap?" false; then
                swapoff -a 2>/dev/null || true
                sed -i '/swap/d' /etc/fstab
                rm -f /swapfile /swap.img
                echo -e "${C_GREEN}✅ Swap полностью отключен и удален.${C_RESET}"
            else
                if [ "$MODULE_CANCELED" = true ]; then return 0; fi
            fi
            ;;
        *)
            echo "Пропущено."
            ;;
    esac
}

# 14. PC-утилиты
mod_desktop_apps() {
    echo -e "${C_CYAN}🖥️ === 14/18. PC-УТИЛИТЫ И АВТОЗАПУСК (DEBIAN PC/XFCE) ===${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt install -y network-manager-gnome pasystray blueman cbatticon 2>/dev/null || true

    local target_user
    target_user=$(get_active_user)

    local target_home
    target_home=$(getent passwd "$target_user" | cut -d: -f6)
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

    chown -R "$target_user:$target_user" "$target_home/.config" 2>/dev/null || true
    echo -e "${C_GREEN}✅ Трей-утилиты установлены и добавлены в автозапуск для $target_user.${C_RESET}"
}

# 15. Программный сброс HDMI
mod_hdmi_reset() {
    echo -e "${C_CYAN}📺 === 15/18. ПРОГРАММНЫЙ СБРОС HDMI (LIGHTDM / XRANDR) ===${C_RESET}"
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
                sed -i '/\[Seat:\*\]/a display-setup-script=/usr/local/bin/reset-hdmi.sh' /etc/lightdm/lightdm.conf
            else
                echo -e "\n[Seat:*]\ndisplay-setup-script=/usr/local/bin/reset-hdmi.sh" >> /etc/lightdm/lightdm.conf
            fi
        fi
        echo -e "${C_GREEN}✅ Скрипт сброса HDMI подключен к LightDM.${C_RESET}"
    else
        echo -e "${C_GREEN}✅ Скрипт /usr/local/bin/reset-hdmi.sh создан. Файл LightDM не найден.${C_RESET}"
    fi
}

# 16. Диагностика времени загрузки
mod_boot_diag() {
    echo -e "${C_CYAN}⏱️ === 16/18. ДИАГНОСТИКА ВРЕМЕНИ ЗАГРУЗКИ СИСТЕМЫ ===${C_RESET}"
    if [ "$(cat /proc/1/comm 2>/dev/null)" != "systemd" ]; then
        echo -e "${C_RED}❌ Ошибка: система запущенна без systemd в качестве PID 1.${C_RESET}"
        return
    fi

    local target_user
    target_user=$(get_active_user)

    local target_home
    target_home=$(getent passwd "$target_user" | cut -d: -f6)
    [ -z "$target_home" ] && target_home="/home/$target_user"

    local output_dir="$target_home/Downloads"
    mkdir -p "$output_dir"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="$output_dir/boot_report_${timestamp}.txt"
    local svg_file="$output_dir/boot_${timestamp}.svg"

    echo "📊 Анализ загрузки системы для пользователя $target_user..."
    echo "--- 1. Общее время старта ---" | tee "$report_file"
    systemd-analyze | tee -a "$report_file"
    echo "" | tee -a "$report_file"

    echo "--- 2. Топ тяжелых сервисов (Top 15) ---" | tee -a "$report_file"
    systemd-analyze blame | head -n 15 | tee -a "$report_file"
    echo "" | tee -a "$report_file"

    echo "--- 3. Цепочка блокировок (Critical Chain) ---" | tee -a "$report_file"
    systemd-analyze critical-chain | tee -a "$report_file"
    echo "" | tee -a "$report_file"

    systemd-analyze plot > "$svg_file" 2>/dev/null || true
    chown -R "$target_user:$target_user" "$output_dir" 2>/dev/null || true
    echo -e "${C_GREEN}✅ Диагностика завершена.${C_RESET}"
    echo "📄 Текстовый отчёт: $report_file"
    echo "📊 SVG-график:      $svg_file"
}

# 17. Полный аудит сервера (ИНТЕЛЛЕКТУАЛЬНАЯ ДИАГНОСТИКА С ГЛУБОКИМ ТАЙЛСКЕЙЛ-АНАЛИЗОМ)
mod_server_audit() {
    echo -e "${C_CYAN}🔍 === 17/18. ПОЛНЫЙ ИНТЕЛЛЕКТУАЛЬНЫЙ АУДИТ И ДИАГНОСТИКА ===${C_RESET}\n"
    
    local active_user
    active_user=$(get_active_user)

    echo -e "${C_BOLD}--- 1. Базовая система и параметры хоста ---${C_RESET}"
    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    echo -e "  • Часовой пояс: ${C_GREEN}$current_tz${C_RESET}"
    echo -e "  • Имя хоста:    ${C_GREEN}$(hostname)${C_RESET}"
    
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        echo -e "  • Авто-обновления безопасности: ${C_GREEN}✅ Включены${C_RESET}"
    else
        echo -e "  • Авто-обновления безопасности: ${C_RED}❌ Отключены${C_RESET} ${C_YELLOW}(💡 Рекомендация: Выполните Пункт 3)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 2. Пользователи и SSH-доступ ---${C_RESET}"
    echo -e "  • Активный sudo-пользователь: ${C_GREEN}$active_user${C_RESET}"
    
    local ssh_port
    ssh_port=$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")
    echo -e "  • Порт SSH: ${C_GREEN}$ssh_port${C_RESET}"

    local root_ssh
    root_ssh=$(sshd -T 2>/dev/null | grep -i "^permitrootlogin " | awk '{print $2}' || echo "yes")
    if [ "$root_ssh" = "no" ]; then
        echo -e "  • Вход root по SSH: ${C_GREEN}✅ Запрещен${C_RESET}"
    else
        echo -e "  • Вход root по SSH: ${C_RED}❌ Разрешен${C_RESET} ${C_YELLOW}(💡 Рекомендация: Настройте Пункт 6)${C_RESET}"
    fi

    local pass_auth
    pass_auth=$(sshd -T 2>/dev/null | grep -i "^passwordauthentication " | awk '{print $2}' || echo "yes")
    if [ "$pass_auth" = "no" ]; then
        echo -e "  • Вход по паролю SSH: ${C_GREEN}✅ Отключен (Только ключи)${C_RESET}"
    else
        echo -e "  • Вход по паролю SSH: ${C_YELLOW}⚠️ Включен${C_RESET} ${C_YELLOW}(💡 Рекомендация: Привяжите ключи в Пункте 5 и отключите пароль в Пункте 6)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 3. Проверка защиты ядра, сети и BBR (sysctl) ---${C_RESET}"
    local sysctl_ok=true

    check_sysctl_param() {
        local param="$1"
        local expected="$2"
        local name="$3"
        local val
        val=$(sysctl -n "$param" 2>/dev/null || echo "0")
        if [ "$val" = "$expected" ]; then
            echo -e "  • $name ($param = $val): ${C_GREEN}✅ В норме${C_RESET}"
        else
            echo -e "  • $name ($param = $val, ожидается $expected): ${C_RED}❌ Не настроено${C_RESET}"
            sysctl_ok=false
        fi
    }

    check_sysctl_param "kernel.dmesg_restrict" "1" "Ограничение dmesg"
    check_sysctl_param "kernel.kptr_restrict" "2" "Скрытие указателей ядра kptr"
    check_sysctl_param "kernel.yama.ptrace_scope" "1" "Защита ptrace"
    check_sysctl_param "kernel.unprivileged_bpf_disabled" "1" "Блокировка eBPF"
    check_sysctl_param "net.core.bpf_jit_harden" "2" "Защита BPF JIT"
    check_sysctl_param "net.ipv4.tcp_syncookies" "1" "Защита TCP SYN Cookies"
    check_sysctl_param "net.ipv4.conf.all.rp_filter" "2" "Фильтр спуфинга rp_filter"
    check_sysctl_param "net.ipv4.conf.all.accept_redirects" "0" "Запрет ICMP редиректов"
    check_sysctl_param "net.ipv4.tcp_congestion_control" "bbr" "Ускорение TCP Google BBR"
    check_sysctl_param "fs.protected_symlinks" "1" "Защита симлинков"
    check_sysctl_param "fs.protected_hardlinks" "1" "Защита хардлинков"

    if [ "$sysctl_ok" = false ]; then
        echo -e "  ${C_YELLOW}💡 Рекомендация: Примените полную защиту ядра и сети в Пункте 7${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 4. Сетевая безопасность и Firewall (UFW) ---${C_RESET}"
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        echo -e "  • Статус UFW: ${C_GREEN}✅ Активен${C_RESET}"
    else
        echo -e "  • Статус UFW: ${C_RED}❌ Не активен${C_RESET} ${C_YELLOW}(💡 Рекомендация: Включите UFW в Пункте 8)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 5. Состояние учетных записей ---${C_RESET}"
    local root_locked
    root_locked=$(passwd -S root 2>/dev/null | awk '{print $2}' || echo "P")
    if [ "$root_locked" = "L" ] || [ "$root_locked" = "LK" ] || [ "$root_locked" = "NP" ]; then
        echo -e "  • Статус пароля root: ${C_GREEN}✅ Заблокирован${C_RESET}"
    else
        echo -e "  • Статус пароля root: ${C_RED}❌ Активен${C_RESET} ${C_YELLOW}(💡 Рекомендация: Заблокируйте root в Пункте 9)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 6. Состояние и настройки сети Tailscale ---${C_RESET}"
    if command -v tailscale &>/dev/null; then
        echo -e "  • Пакет Tailscale: ${C_GREEN}✅ Установлен${C_RESET}"
        
        local ts_name ts_ip ts_user ts_exit ts_adv_exit ts_adv_routes ts_accept_routes ts_stealth
        local adv_exit_fmt adv_routes_fmt accept_fmt stealth_fmt

        IFS="|" read -r ts_name ts_user <<< "$(get_tailscale_whoami)"
        [ -z "$ts_name" ] && ts_name="N/A"
        [ -z "$ts_user" ] && ts_user="N/A"

        ts_ip=$(tailscale whoami 2>/dev/null | grep -i "^  Addresses:" | grep -oP '100\.\d+\.\d+\.\d+' | head -n 1 || echo "N/A")
        ts_exit=$(tailscale get exit-node 2>/dev/null || echo "none")
        ts_adv_exit=$(tailscale get advertise-exit-node 2>/dev/null || echo "false")
        ts_adv_routes=$(tailscale get advertise-routes 2>/dev/null || echo "")
        ts_accept_routes=$(tailscale get accept-routes 2>/dev/null || echo "false")
        ts_stealth=$(tailscale get stateful-filtering 2>/dev/null || echo "false")

        [ "$ts_adv_exit" = "true" ] && adv_exit_fmt="Включен" || adv_exit_fmt="Отключен"
        [ -n "$ts_adv_routes" ] && [ "$ts_adv_routes" != "нет" ] && adv_routes_fmt="$ts_adv_routes" || adv_routes_fmt="Не анонсируются"
        [ "$ts_accept_routes" = "true" ] && accept_fmt="Включен" || accept_fmt="Отключен"
        [ "$ts_stealth" = "true" ] && stealth_fmt="Включен" || stealth_fmt="Отключен"

        echo -e "  • Имя узла Tailnet:          ${C_BLUE}$ts_name${C_RESET}"
        echo -e "  • IP-адрес Tailscale:        ${C_BLUE}$ts_ip${C_RESET}"
        echo -e "  • Аккаунт:                   ${C_BLUE}$ts_user${C_RESET}"
        echo -e "  • Внешний Exit-Node:         ${C_BLUE}$ts_exit${C_RESET}"
        echo -e "  • Анонс Exit-Node:           ${C_BLUE}$adv_exit_fmt${C_RESET}"
        echo -e "  • Анонсируемые подсети:      ${C_BLUE}$adv_routes_fmt${C_RESET}"

        if [ "$ts_accept_routes" = "true" ]; then
            echo -e "  • Прием подсетей из Tailscale: ${C_GREEN}✅ $accept_fmt${C_RESET}"
        else
            echo -e "  • Прием подсетей из Tailscale: ${C_BLUE}🛡️ $accept_fmt${C_RESET}"
        fi

        if [ "$ts_stealth" = "true" ]; then
            echo -e "  • Стелс-режим:              ${C_GREEN}🔒 $stealth_fmt${C_RESET}"
        else
            echo -e "  • Стелс-режим:              ${C_BLUE}🌐 $stealth_fmt${C_RESET}"
        fi

        if systemctl is-active --quiet tailscale-gro.service 2>/dev/null; then
            echo -e "  • Служба GRO-оптимизации:     ${C_GREEN}✅ Активна${C_RESET}"
        else
            echo -e "  • Служба GRO-оптимизации:     ${C_YELLOW}⚠️ Не активна${C_RESET} ${C_YELLOW}(💡 Рекомендация: Выполните Пункт 10)${C_RESET}"
        fi

        if is_tailscale_web_active; then
            echo -e "  • Веб-интерфейс Tailscale Web: ${C_GREEN}✅ Включен${C_RESET}"
        else
            echo -e "  • Веб-интерфейс Tailscale Web: ${C_BLUE}🌐 Отключен${C_RESET}"
        fi

        # Парсинг только реальных пунктов предупреждений (начинающихся с дефиса '- ') без дублей и пустых заголовков
        local health_warn
        health_warn=$(tailscale status --peers=false 2>/dev/null | grep -E "^\s*-\s+" | grep -v "accept-routes" || echo "")
        if [ -n "$health_warn" ]; then
            echo -e "  • Предупреждения Tailscale Health Check:\n${C_YELLOW}$health_warn${C_RESET}"
        else
            echo -e "  • Предупреждения сети Tailnet: ${C_GREEN}✅ Отсутствуют (Сеть здорова)${C_RESET}"
        fi
    else
        echo -e "  • Пакет Tailscale: ${C_YELLOW}⚠️ Не установлен${C_RESET} ${C_YELLOW}(💡 Рекомендация: Настройте Пункт 10)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 7. Логирование и очистка диска ---${C_RESET}"
    local journal_storage
    journal_storage=$(grep -E "^\s*Storage=" /etc/systemd/journald.conf 2>/dev/null | cut -d= -f2 || echo "auto")
    if [ "$journal_storage" = "none" ]; then
        echo -e "  • Логирование journald: ${C_GREEN}✅ Отключено${C_RESET}"
    else
        echo -e "  • Логирование journald: ${C_YELLOW}⚠️ Включено${C_RESET} ${C_YELLOW}(💡 Рекомендация: Отключите в Пункте 11)${C_RESET}"
    fi

    if systemctl is-active --quiet rsyslog 2>/dev/null; then
        echo -e "  • Служба rsyslog: ${C_YELLOW}⚠️ Активна${C_RESET} ${C_YELLOW}(💡 Рекомендация: Заблокируйте в Пункте 11)${C_RESET}"
    else
        echo -e "  • Служба rsyslog: ${C_GREEN}✅ Остановлена/Заблокирована${C_RESET}"
    fi

    local var_log_size
    var_log_size=$(du -sh /var/log 2>/dev/null | awk '{print $1}' || echo "0")
    echo -e "  • Размер папки /var/log: ${C_BLUE}$var_log_size${C_RESET}"

    echo -e "\n${C_BOLD}--- 8. Память, Флеш-накопитель и Swap ---${C_RESET}"
    local swap_swappiness
    swap_swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "60")
    if [ "$swap_swappiness" -le 10 ]; then
        echo -e "  • Параметр swappiness: ${C_GREEN}✅ Оптимизирован ($swap_swappiness)${C_RESET}"
    else
        echo -e "  • Параметр swappiness: ${C_YELLOW}⚠️ Стандартный ($swap_swappiness)${C_RESET} ${C_YELLOW}(💡 Рекомендация: Оптимизируйте в Пункте 12)${C_RESET}"
    fi

    local dirty_writeback
    dirty_writeback=$(sysctl -n vm.dirty_writeback_centisecs 2>/dev/null || echo "500")
    if [ "$dirty_writeback" -ge 1000 ]; then
        local dirty_sec=$((dirty_writeback / 100))
        echo -e "  • Буферизация записи RAM: ${C_GREEN}✅ Оптимизирована (${dirty_sec} сек)${C_RESET}"
    else
        echo -e "  • Буферизация записи RAM: ${C_YELLOW}⚠️ Стандартная (${dirty_writeback}cs)${C_RESET} ${C_YELLOW}(💡 Рекомендация: Выполните Пункт 12)${C_RESET}"
    fi

    if mount | grep " / " | grep -q "noatime"; then
        echo -e "  • Флаг noatime на корень (/): ${C_GREEN}✅ Включен${C_RESET}"
    else
        echo -e "  • Флаг noatime на корень (/): ${C_YELLOW}⚠️ Отсутствует${C_RESET} ${C_YELLOW}(💡 Рекомендация: Выполните Пункт 12)${C_RESET}"
    fi

    if grep -E '\s+/\s+' /etc/fstab 2>/dev/null | grep -q "commit=120" || mount | grep " / " | grep -q "commit=120" || grep -E '\s+/\s+' /proc/mounts 2>/dev/null | grep -q "commit=120"; then
        echo -e "  • Флаг commit=120 на корень (/): ${C_GREEN}✅ Включен${C_RESET}"
    else
        echo -e "  • Флаг commit=120 на корень (/): ${C_YELLOW}⚠️ Отсутствует${C_RESET} ${C_YELLOW}(💡 Рекомендация: Выполните Пункт 12)${C_RESET}"
    fi

    local current_swap
    current_swap=$(swapon --show --noheadings 2>/dev/null | awk '{print $1 " (" $3 ")"}' | paste -sd ", " - || echo "")
    [ -z "$current_swap" ] && current_swap="Отключен"
    echo -e "  • Состояние Swap: ${C_BLUE}$current_swap${C_RESET}"

    echo -e "\n${C_CYAN}=================================================================${C_RESET}"
}

# 18. Роутер-режим Одноплатного компьютера
mod_router_sbc() {
    echo -e "${C_CYAN}🛜 === 18/18. ОДНОПЛАТНЫЙ КОМПЬЮТЕР КАК РОУТЕР (LAN-ШЛЮЗ) ===${C_RESET}"

    local default_lan_if
    default_lan_if=$(ip -br link show | grep -v -E 'lo|tailscale' | awk '{print $1}' | head -n 1 || echo "eth0")
    local default_wan_if
    default_wan_if=$(ip -br link show | grep -v -E 'lo|tailscale' | awk '{print $1}' | tail -n 1 || echo "eth1")

    local lan_iface="" wan_iface="" ts_iface="" lan_ip="" lan_cidr="" dhcp_start="" dhcp_end=""
    prompt_clean "LAN интерфейс (подсеть клиентов) (Enter - $default_lan_if)" lan_iface
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    lan_iface="${lan_iface:-$default_lan_if}"

    prompt_clean "WAN интерфейс (провайдер) (Enter - $default_wan_if)" wan_iface
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    wan_iface="${wan_iface:-$default_wan_if}"

    prompt_clean "Tailscale интерфейс (Enter - tailscale0)" ts_iface
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    ts_iface="${ts_iface:-tailscale0}"

    local wan_subnet
    wan_subnet=$(get_interface_subnet "$wan_iface")

    while true; do
        local default_lan_ip="192.168.50.1"
        if [ -n "$wan_subnet" ] && [ "$wan_subnet" = "192.168.50" ]; then
            default_lan_ip="10.50.0.1"
        fi

        prompt_clean "IP-адрес роутера в LAN (Enter - $default_lan_ip)" lan_ip
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        lan_ip="${lan_ip:-$default_lan_ip}"

        local lan_subnet
        lan_subnet=$(echo "$lan_ip" | cut -d. -f1-3)

        if [ -n "$wan_subnet" ] && [ "$wan_subnet" = "$lan_subnet" ]; then
            echo -e "${C_RED}⚠️ КОНФЛИКТ ПОДСЕТЕЙ! Интерфейс WAN ($wan_iface) находится в подсети ${wan_subnet}.x, которая совпадает с LAN (${lan_subnet}.x)!${C_RESET}"
            echo -e "${C_YELLOW}💡 Укажите другую подсеть для LAN (например, 192.168.50.1 или 10.50.0.1).${C_RESET}"
            continue
        fi
        break
    done

    prompt_clean "Маска подсети LAN CIDR (Enter - 24)" lan_cidr
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    lan_cidr="${lan_cidr:-24}"

    local lan_prefix
    lan_prefix=$(echo "$lan_ip" | cut -d. -f1-3)

    prompt_clean "Начальный IP DHCP диапазона (Enter - ${lan_prefix}.10)" dhcp_start
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    dhcp_start="${dhcp_start:-${lan_prefix}.10}"

    prompt_clean "Конечный IP DHCP диапазона (Enter - ${lan_prefix}.254)" dhcp_end
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    dhcp_end="${dhcp_end:-${lan_prefix}.254}"

    echo -e "${C_BLUE}🌐 [1/4] Включение IP Forwarding в ядре...${C_RESET}"
    backup_file "/etc/sysctl.d/99-tailscale-forward.conf"
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-tailscale-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    sysctl --system >/dev/null

    echo -e "${C_BLUE}⚙️ [2/4] Настройка LAN-интерфейса в systemd-networkd...${C_RESET}"
    mkdir -p /etc/systemd/network
    backup_file "/etc/systemd/network/10-lan.network"
    cat > /etc/systemd/network/10-lan.network <<EOF
[Match]
Name=$lan_iface

[Link]
IgnoreCarrier=yes

[Network]
Address=$lan_ip/$lan_cidr
LinkLocalAddressing=no
ConfigureWithoutCarrier=yes
EOF
    systemctl restart systemd-networkd 2>/dev/null || true

    echo -e "${C_BLUE}📦 [3/4] Настройка DHCP/DNS сервера (dnsmasq)...${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt install -y dnsmasq
    mkdir -p /etc/dnsmasq.d
    backup_file "/etc/dnsmasq.d/lan-dhcp.conf"
    cat > /etc/dnsmasq.d/lan-dhcp.conf <<EOF
interface=$lan_iface
bind-interfaces
dhcp-range=$dhcp_start,$dhcp_end,255.255.255.0,12h
dhcp-option=3,$lan_ip
dhcp-option=6,1.1.1.1,8.8.8.8
EOF
    systemctl restart dnsmasq

    echo -e "${C_BLUE}🧱 [4/4] Настройка правил UFW, MSS Clamping и Kill Switch...${C_RESET}"
    ufw allow in on "$lan_iface" to any port 67 proto udp 2>/dev/null || true
    ufw allow in on "$lan_iface" to any port 53 proto udp 2>/dev/null || true
    ufw allow in on "$lan_iface" to any port 53 proto tcp 2>/dev/null || true
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true

    local before_rules="/etc/ufw/before.rules"
    backup_file "$before_rules"

    python3 - "$lan_iface" "$wan_iface" "$ts_iface" <<'PY'
import sys
from pathlib import Path

lan_iface = sys.argv
wan_iface = sys.argv
ts_iface = sys.argv[3]

path = Path("/etc/ufw/before.rules")
content = path.read_text()

start = content.find("# --- Router Rules BEGIN ---")
if start != -1:
    end = content.find("# --- Router Rules END ---", start)
    if end != -1:
        end += len("# --- Router Rules END ---")
        content = content[:start] + content[end:]

router_block = f"""# --- Router Rules BEGIN ---
*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A FORWARD -o {ts_iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o {ts_iface} -j MASQUERADE
COMMIT

*filter
:ufw-before-input - [0:0]
:ufw-before-output - [0:0]
:ufw-before-forward - [0:0]

# --- LAN to Tailscale Routing & Kill Switch ---
-A ufw-before-forward -i {ts_iface} -o {lan_iface} -m state --state RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-forward -i {lan_iface} -o {ts_iface} -j ACCEPT
-A ufw-before-forward -i {lan_iface} -o {wan_iface} -j DROP

COMMIT
# --- Router Rules END ---
"""

content = router_block + "\n" + content
path.write_text(content)
PY

    if command -v iptables-restore >/dev/null 2>&1; then
        if ! iptables-restore --test < /etc/ufw/before.rules; then
            echo -e "${C_RED}❌ Ошибка синтаксиса в /etc/ufw/before.rules! Откат изменений...${C_RESET}" >&2
            cp "${before_rules}.bak" "$before_rules"
            return 1
        fi
    fi

    ufw reload 2>/dev/null || true
    echo -e "${C_GREEN}✅ Настройка одноплатного компьютера в качестве LAN-роутера успешно завершена!${C_RESET}"
    echo -e "${C_BLUE}ℹ️ Подключение к Exit Node выполняйте в Модуле 10 при необходимости.${C_RESET}"
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ И ЦИКЛ УПРАВЛЕНИЯ
# ==============================================================================

while true; do
    clear
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    echo -e "${C_BOLD}       🛠️  ГЛАВНОЕ МЕНЮ НАСТРОЙКИ СЕРВЕРА И ПК     ${C_RESET}"
    echo -e "${C_BOLD}       Автор: Michael Bobarev, Bobarev.com${C_RESET}"
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    echo -e " Тип системы: ${C_GREEN}$SYSTEM_TYPE${C_RESET} | Хост: ${C_GREEN}$(hostname)${C_RESET} | Пояс: ${C_GREEN}$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")${C_RESET}"
    
    ts_main_status="Не установлен"
    if command -v tailscale &>/dev/null; then
        if is_tailscale_web_active; then
            ts_main_status="Установлен (Web UI)"
        else
            ts_main_status="Установлен"
        fi
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
        11) mod_disable_logging; pause_enter ;;
        12) mod_ram_flash_opt; pause_enter ;;
        13) mod_swap_manager; pause_enter ;;
        14) mod_desktop_apps; pause_enter ;;
        15) mod_hdmi_reset; pause_enter ;;
        16) mod_boot_diag; pause_enter ;;
        17) mod_server_audit; pause_enter ;;
        18) mod_router_sbc; pause_enter ;;
        a|A)
            echo "🚀 ЗАПУСК ПОЛНОЙ ПОСЛЕДОВАТЕЛЬНОЙ НАСТРОЙКИ СЕРВЕРА..."
            local_aborted=false
            for m in mod_timezone mod_hostname mod_apt_update mod_user_setup mod_ssh_key mod_ssh_config mod_hardening mod_ufw mod_lock_root mod_tailscale mod_disable_logging mod_ram_flash_opt; do
                MODULE_CANCELED=false
                $m
                if [ "$MODULE_CANCELED" = true ]; then
                    echo -e "${C_YELLOW}🛑 Последовательная установка прервана пользователем.${C_RESET}"
                    local_aborted=true
                    break
                fi
            done
            if [ "$local_aborted" = false ]; then
                echo -e "${C_GREEN}🎉 ВСЕ СЕРВЕРНЫЕ МОДУЛИ УСПЕШНО ВЫПОЛНЕНЫ!${C_RESET}"
            fi
            pause_enter
            ;;
        0)
            echo "Выход из скрипта."
            exit 0
            ;;
        *)
            echo "Неверный выбор. Нажмите Enter для повтора..."
            pause_enter
            ;;
    esac
done