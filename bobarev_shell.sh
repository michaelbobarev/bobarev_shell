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

prompt_yn() {
    local prompt="$1"
    local default_yes="$2"
    local yn_text="[Y/n]"
    [ "$default_yes" = "false" ] && yn_text="[y/N]"

    while true; do
        read -r -p "$(echo -e "${C_BOLD}$prompt${C_RESET} $yn_text (0 - Назад): ")" choice
        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')
        if [ "$choice" = "0" ] || [ "$choice" = "b" ] || [ "$choice" = "back" ] || [ "$choice" = "назад" ]; then
            echo -e "${C_YELLOW}↩️ Отмена модуля. Возврат в главное меню...${C_RESET}"
            MODULE_CANCELED=true
            return 0
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
    read -r -p "$(echo -e "${C_BOLD}$prompt${C_RESET} [$default_val] (0 - Назад): ")" val
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
    read -r -p "$(echo -e "${C_BOLD}$prompt${C_RESET} (0 - Назад): ")" val
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
    read -r -p "Нажмите Enter для возврата в главное меню..."
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

# 2. Имя хоста (Hostname)
mod_hostname() {
    echo -e "${C_CYAN}🏷️ === 2/18. НАСТРОЙКА HOSTNAME ===${C_RESET}"
    echo "Текущий hostname: $(hostname)"
    
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
        prompt_yn "⚠️ Обнаружена графическая оболочка ($SYSTEM_TYPE). Переключить в консольный режим (multi-user.target)?" false
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        systemctl set-default multi-user.target
        echo -e "${C_BLUE}ℹ️ Режим загрузки изменен на консольный (multi-user.target).${C_RESET}"
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
    read -s -p "Введите новый пароль для $username (Enter, если не менять, 0 - Назад): " pass
    echo ""
    if [ "$pass" = "0" ]; then
        echo -e "${C_YELLOW}↩️ Отмена модуля. Возврат в главное меню...${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi

    if [ -n "$pass" ]; then
        read -s -p "Повторите пароль: " pass_confirm
        echo ""
        while [ "$pass" != "$pass_confirm" ]; do
            echo -e "${C_RED}❌ Пароли не совпадают. Попробуйте снова.${C_RESET}"
            read -s -p "Пароль: " pass
            echo ""
            read -s -p "Повторите пароль: " pass_confirm
            echo ""
        done
        echo "$username:$pass" | chpasswd
        echo -e "${C_GREEN}✅ Пароль установлен.${C_RESET}"
    fi

    prompt_yn "Разрешить sudo без запроса пароля (NOPASSWD)?" true
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    echo "$username ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$username"
    chmod 0440 "/etc/sudoers.d/$username"
    echo -e "${C_GREEN}✅ Sudo NOPASSWD включен для $username.${C_RESET}"
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
        prompt_yn "Скопировать имеющийся SSH-ключ из /root/.ssh/authorized_keys?" true
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        pubkey="$root_key"
    fi

    if [ -z "$pubkey" ]; then
        echo "Вставьте публичный SSH-ключ (ssh-ed25519, ssh-rsa и т.д., 0 - Назад):"
        read -r pubkey
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
        read -r -p "Ваш выбор [1-2, 0]: " mode_choice
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

# 6. Конфигурация SSH (Интеллектуальная проверка портов)
mod_ssh_config() {
    echo -e "${C_CYAN}🔒 === 6/18. КОНФИГУРАЦИЯ SSH (БЕЗОПАСНОСТЬ) ===${C_RESET}"
    backup_file "/etc/ssh/sshd_config"
    local active_ssh_port
    active_ssh_port=$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "14597")

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

    prompt_yn "Отключить вход по паролю (разрешить ТОЛЬКО SSH-ключи)?" false
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

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

        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            ufw allow "$port"/tcp comment 'SSH Port' 2>/dev/null || true
        fi
        echo -e "${C_GREEN}✅ Служба SSH успешно перезапущена (Порт: $port, Вход по паролю: $pass_auth_val).${C_RESET}"
    else
        echo -e "${C_RED}❌ Ошибка синтаксиса в конфигурации SSH! Откат изменений...${C_RESET}"
        rm -f /etc/ssh/sshd_config.d/99-server-security.conf
    fi
}

# 7. Hardening Ядра
mod_hardening() {
    echo -e "${C_CYAN}🛡️ === 7/18. SYSCTL HARDENING ЯДРА И СЕТИ ===${C_RESET}"
    backup_file "/etc/sysctl.d/99-hardening.conf"
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
HARDENING_EOF
    sysctl --system > /dev/null
    echo -e "${C_GREEN}✅ Настройки защиты ядра и сети применены.${C_RESET}"
}

# 8. Firewall UFW
mod_ufw() {
    echo -e "${C_CYAN}🧱 === 8/18. НАСТРОЙКА FIREWALL (UFW) ===${C_RESET}"
    
    local active_ssh_port
    active_ssh_port=$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "14597")

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

    prompt_yn "Разрешить маршрутизацию пакетов (FORWARD ACCEPT)? (Нужно для роутеров и Tailscale Exit-Node)" true
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    ufw default allow routed
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true

    if command -v tailscale &>/dev/null; then
        ufw allow in on tailscale0 comment 'Allow inside Tailscale' 2>/dev/null || true
        ufw allow 41641/udp comment 'Tailscale Direct P2P' 2>/dev/null || true

        local netdev="$DEFAULT_WAN_IF"
        [ -z "$netdev" ] && netdev=$(ip route show default | grep -v tailscale0 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || echo "")
        if [ -n "$netdev" ]; then
            ufw route allow in on tailscale0 out on "$netdev" 2>/dev/null || true
            ufw route allow in on "$netdev" out on tailscale0 2>/dev/null || true
        fi

        prompt_yn "Ограничить доступ к SSH (порт $port) ТОЛЬКО через сеть Tailscale?" true
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi

        ufw allow in on tailscale0 to any port "$port" proto tcp comment 'SSH via Tailscale only'
    else
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

# 10. Tailscale & GRO-оптимизация (Исправлен порядок вызовов)
mod_tailscale() {
    echo -e "${C_CYAN}🔗 === 10/18. НАСТРОЙКА TAILSCALE И GRO-ОПТИМИЗАЦИЯ ===${C_RESET}"
    
    # 1. Сначала опрашиваем параметры пользователя ДО создания служб и симлинков
    echo "Режим работы Tailscale:"
    echo "  1) Обычный узел"
    echo "  2) Сервер как Exit-Node (--advertise-exit-node)"
    echo "  0) Назад"
    local role
    read -r -p "Ваш выбор [1-2, 0] (по умолчанию 1): " role
    if [ "$role" = "0" ]; then
        echo -e "${C_YELLOW}↩️ Отмена модуля. Возврат в главное меню...${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi
    role="${role:-1}"

    local authkey
    read -r -p "Tailscale Auth Key (Enter для авторизации по ссылке, 0 - Назад): " authkey
    if [ "$authkey" = "0" ]; then
        echo -e "${C_YELLOW}↩️ Отмена модуля. Возврат в главное меню...${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi

    # 2. Установка пакета Tailscale (если не установлен)
    if ! command -v tailscale &> /dev/null; then
        echo "Установка пакета Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # 3. Настройка IP forwarding
    tee /etc/sysctl.d/99-tailscale-forward.conf > /dev/null << 'TS_EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
TS_EOF
    sysctl --system > /dev/null

    # 4. Создание и включение службы GRO ТОЛЬКО после подтверждения пользователем
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

    # 5. Запуск Tailscale
    local args=()
    [ -n "$authkey" ] && args+=("--authkey=$authkey")
    [ "$role" = "2" ] && args+=("--advertise-exit-node")

    if [ -n "$authkey" ]; then
        tailscale up "${args[@]}" || true
    else
        tailscale up "${args[@]}" || true
        echo ""
        read -r -p "Нажмите Enter ПОСЛЕ авторизации узла в веб-панели Tailscale..."
    fi

    echo ""
    echo "🔍 Проверка статуса оптимизации Tailscale:"
    systemctl status tailscale-gro.service --no-pager -n 5 || true
    local netdev="$DEFAULT_WAN_IF"
    [ -z "$netdev" ] && netdev=$(ip route show default | grep -v tailscale0 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || echo "")
    if [ -n "$netdev" ]; then
        ethtool -k "$netdev" 2>/dev/null | grep -E 'rx-udp-gro-forwarding|rx-gro-list' || true
    fi
    echo -e "${C_GREEN}✅ Настройка Tailscale завершена.${C_RESET}"
}

# 11. Отключение логирования
mod_disable_logging() {
    echo -e "${C_CYAN}🧹 === 11/18. ОТКЛЮЧЕНИЕ СИСТЕМНОГО ЛОГИРОВАНИЯ ===${C_RESET}"
    backup_file "/etc/systemd/journald.conf"
    cat << 'DISABLE_LOGS_EOF' > /usr/local/bin/disable-logging.sh
#!/bin/bash
sed -i -E '/^\s*#?\s*(Storage|ForwardToSyslog)=/d' /etc/systemd/journald.conf
sed -i '/^\[Journal\]/a Storage=none\nForwardToSyslog=no' /etc/systemd/journald.conf
systemctl restart systemd-journald

systemctl stop rsyslog 2>/dev/null || true
systemctl disable rsyslog 2>/dev/null || true
systemctl mask rsyslog 2>/dev/null || true
systemctl stop armbian-hardware-monitor 2>/dev/null || true
systemctl disable armbian-hardware-monitor 2>/dev/null || true
warp-cli log disable 2>/dev/null || true

if command -v ufw &>/dev/null; then
    ufw logging off 2>/dev/null || true
fi

find /var/log -type f \( -name "*.log*" -o -name "syslog*" -o -name "auth.log*" -o -name "kern.log*" -o -name "ufw.log*" \) -exec truncate -s 0 {} +
find /var/log -type f \( -name "*.[0-9]" -o -name "*.gz" \) -delete
rm -rf /var/log/journal/*
journalctl --vacuum-size=1M
DISABLE_LOGS_EOF
    chmod +x /usr/local/bin/disable-logging.sh
    /usr/local/bin/disable-logging.sh
    echo -e "${C_GREEN}✅ Системное логирование отключено.${C_RESET}"
}

# 12. Оптимизация RAM / Flash
mod_ram_flash_opt() {
    echo -e "${C_CYAN}⚡ === 12/18. ОПТИМИЗАЦИЯ RAM, FLASH И NOATIME ===${C_RESET}"
    backup_file "/etc/fstab"
    tee /etc/sysctl.d/99-ram-opt.conf > /dev/null << 'RAM_OPT_EOF'
vm.swappiness=1
vm.vfs_cache_pressure=50
RAM_OPT_EOF
    sysctl --system > /dev/null

    sed -i -E '/\s+\/\s+/ { /noatime/! s/(\s+ext[234]|\s+xfs|\s+btrfs|\s+f2fs)(\s+)(\S+)/\1\2\3,noatime/ }' /etc/fstab
    mount -o remount,noatime / 2>/dev/null || true

    if ! grep -q "tmpfs /tmp" /etc/fstab; then
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=512M 0 0" >> /etc/fstab
    fi
    if ! grep -q "tmpfs /var/tmp" /etc/fstab; then
        echo "tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,size=256M 0 0" >> /etc/fstab
    fi

    systemctl daemon-reload
    mount -a 2>/dev/null || true
    echo -e "${C_GREEN}✅ Оптимизации RAM/Flash применены.${C_RESET}"
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
    read -r -p "Ваш выбор [0-3]: " swap_choice

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
            prompt_yn "Вы уверены, что хотите полностью удалить Swap?" false
            if [ "$MODULE_CANCELED" = true ]; then return 0; fi

            swapoff -a 2>/dev/null || true
            sed -i '/swap/d' /etc/fstab
            rm -f /swapfile /swap.img
            echo -e "${C_GREEN}✅ Swap полностью отключен и удален.${C_RESET}"
            ;;
        *)
            echo "Пропущено."
            ;;
    esac
}

# 14. Десктоп-утилиты
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

# 17. Полный аудит сервера
mod_server_audit() {
    echo -e "${C_CYAN}🔍 === 17/18. ПОЛНЫЙ АУДИТ И ПРОВЕРКА НАСТРОЕК СЕРВЕРА ===${C_RESET}"
    echo "=== 1. ЧАСОВОЙ ПОЯС ==="
    timedatectl show --property=Timezone --value

    echo -e "\n=== 2. СТАТУС ОБНОВЛЕНИЙ И ZRAM ==="
    systemctl is-active unattended-upgrades 2>/dev/null || echo "Не активен"
    systemctl get-default
    zramctl 2>/dev/null || echo "zram утилиты установлены"

    echo -e "\n=== 3. ИМЯ ХОСТА (HOSTNAME) ==="
    hostnamectl status

    echo -e "\n=== 4. SYSCTL HARDENING ==="
    sysctl kernel.dmesg_restrict kernel.kptr_restrict net.ipv4.tcp_syncookies net.ipv4.conf.all.rp_filter fs.protected_symlinks

    echo -e "\n=== 5. СЕТЕВЫЕ ИНТЕРФЕЙСЫ И UFW ==="
    ip -br a
    ufw status verbose 2>/dev/null || echo "UFW не активен"
    echo "================================================="
}

# 18. Роутер-режим Одноплатного компьютера (Автоопределение конфликта подсетей)
mod_router_sbc() {
    echo -e "${C_CYAN}🛜 === 18/18. ОДНОПЛАТНЫЙ КОМПЬЮТЕР КАК РОУТЕР ===${C_RESET}"

    prompt_yn "Настроить этот узел как LAN-шлюз (роутер) через Tailscale Exit Node?" true
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    local default_lan_if="enP1p17s0"
    local default_wan_if="enP2p33s0"

    # Динамический поиск интерфейсов
    if ! ip link show "$default_lan_if" >/dev/null 2>&1; then
        default_lan_if=$(ip -br link show | grep -v -E 'lo|tailscale' | awk '{print $1}' | head -n 1 || echo "eth0")
    fi
    if ! ip link show "$default_wan_if" >/dev/null 2>&1; then
        default_wan_if=$(ip -br link show | grep -v -E 'lo|tailscale' | awk '{print $1}' | tail -n 1 || echo "eth1")
    fi

    local lan_iface="" wan_iface="" ts_iface="" lan_ip="" lan_cidr="" dhcp_start="" dhcp_end="" exit_node_ip=""
    prompt_clean "LAN интерфейс (подсеть клиентов) (Enter - $default_lan_if)" lan_iface
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    lan_iface="${lan_iface:-$default_lan_if}"

    prompt_clean "WAN интерфейс (провайдер) (Enter - $default_wan_if)" wan_iface
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    wan_iface="${wan_iface:-$default_wan_if}"

    prompt_clean "Tailscale интерфейс (Enter - tailscale0)" ts_iface
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    ts_iface="${ts_iface:-tailscale0}"

    # Проверка конфликта подсетей WAN vs LAN
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

    prompt_clean "IP-адрес Exit Node в сети Tailscale" exit_node_ip
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    if [ -z "$exit_node_ip" ]; then
        echo -e "${C_RED}❌ IP-адрес Exit Node не введен.${C_RESET}" >&2
        return 0
    fi

    if ! command -v tailscale >/dev/null 2>&1; then
        echo -e "${C_RED}❌ Tailscale не установлен. Сначала выполните Модуль 10.${C_RESET}" >&2
        return 0
    fi

    echo -e "${C_BLUE}🌐 [1/5] Включение IP Forwarding в ядре...${C_RESET}"
    backup_file "/etc/sysctl.d/99-tailscale-forward.conf"
    cat > /etc/sysctl.d/99-tailscale-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    sysctl --system >/dev/null

    echo -e "${C_BLUE}⚙️ [2/5] Настройка LAN-интерфейса в systemd-networkd...${C_RESET}"
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

    echo -e "${C_BLUE}📦 [3/5] Настройка DHCP/DNS сервера (dnsmasq)...${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt install -y dnsmasq
    backup_file "/etc/dnsmasq.d/lan-dhcp.conf"
    cat > /etc/dnsmasq.d/lan-dhcp.conf <<EOF
interface=$lan_iface
bind-interfaces
dhcp-range=$dhcp_start,$dhcp_end,255.255.255.0,12h
dhcp-option=3,$lan_ip
dhcp-option=6,1.1.1.1,8.8.8.8
EOF
    systemctl restart dnsmasq

    echo -e "${C_BLUE}🔗 [4/5] Подключение к Exit Node ($exit_node_ip)...${C_RESET}"
    tailscale set --exit-node="$exit_node_ip" --exit-node-allow-lan-access --accept-routes=false || true

    echo -e "${C_BLUE}🧱 [5/5] Настройка правил UFW, MSS Clamping и Kill Switch...${C_RESET}"
    ufw allow in on "$lan_iface" to any port 67 proto udp 2>/dev/null || true
    ufw allow in on "$lan_iface" to any port 53 proto udp 2>/dev/null || true
    ufw allow in on "$lan_iface" to any port 53 proto tcp 2>/dev/null || true
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true

    local before_rules="/etc/ufw/before.rules"
    backup_file "$before_rules"

    # Безопасное встраивание правил роутинга и Kill Switch в /etc/ufw/before.rules
    python3 - "$lan_iface" "$wan_iface" "$ts_iface" <<'PY'
import sys
from pathlib import Path

lan_iface = sys.argv
wan_iface = sys.argv
ts_iface = sys.argv

path = Path("/etc/ufw/before.rules")
content = path.read_text()

# Очистка старого блока, если перенастраиваем
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
    echo -e "${C_GREEN}✅ Настройка одноплатного компьютера в качестве роутера успешно завершена!${C_RESET}"
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ И ЦИКЛ УПРАВЛЕНИЯ
# ==============================================================================

while true; do
    clear
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    echo -e "${C_BOLD}       🛠️  ГЛАВНОЕ МЕНЮ НАСТРОЙКИ СЕРВЕРА И ПК (VPS/DEBIAN)     ${C_RESET}"
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    echo -e " Тип системы: ${C_GREEN}$SYSTEM_TYPE${C_RESET} | Хост: ${C_GREEN}$(hostname)${C_RESET} | Пояс: ${C_GREEN}$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")${C_RESET}"
    echo -e " Tailscale: ${C_GREEN}$(command -v tailscale &>/dev/null && echo "Установлен" || echo "Не установлен")${C_RESET} | UFW: ${C_GREEN}$(ufw status 2>/dev/null | head -n 1 || echo "Неизвестно")${C_RESET}"
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
    echo " --- [ДЕСКТОП ПК / РОУТЕР / ДИАГНОСТИКА] ---"
    echo " 14) 🖥️  Десктоп-утилиты (WiFi, Звук, Bluetooth, Батарея) и автозапуск"
    echo " 15) 📺 Программный сброс HDMI (LightDM)"
    echo " 16) ⏱️  Диагностика времени загрузки системы"
    echo " 17) 🔍 Полный аудит и проверка настроек сервера"
    echo " 18) 🛜 Одноплатный компьютер как роутер"
    echo "-----------------------------------------------------------------"
    echo -e "${C_GREEN}  A) 🚀 ВЫПОЛНИТЬ ВСЮ ПЕРВИЧНУЮ НАСТРОЙКУ С НУЛЯ (МОДУЛИ 1-12)${C_RESET}"
    echo -e "${C_RED}  0) ❌ Выход${C_RESET}"
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    read -r -p "Выберите пункт меню [0-18, A]: " choice

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
        10) mod_tailscale; pause_enter ;;
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