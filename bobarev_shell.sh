#!/bin/bash
set -euo pipefail

# ==============================================================================
# СКРИПТ КОМПЛЕКСНОЙ НАСТРОЙКИ СЕРВЕРА (BOBAREV SHELL)
# Версия: 3.2.4 (Gold Master - Cascade NaiveProxy -> Tailscale -> WARP Edition)
# ==============================================================================

C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

MODULE_CANCELED=false

export PATH="/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

export TERM_COLS=$(tput cols 2>/dev/null || echo 85)
export TERM_LINES=$(tput lines 2>/dev/null || echo 27)
export WT_WIDTH=$((TERM_COLS < 85 ? TERM_COLS : 85))
export WT_HEIGHT=$((TERM_LINES < 27 ? TERM_LINES : 27))

# Пиннинг проверенных версий из стека NaiveProxy
CADDY_VERSION_PIN="v2.11.7"
XCADDY_VERSION_PIN="v0.4.6"
FORWARDPROXY_REF_PIN="d62c80d3dd2c706b6b87579844d2397bddd18317"
GO_VERSION_PIN="1.26.5"
GO_SHA256_AMD64="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
GO_SHA256_ARM64="fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49"

CADDY_BIN="/usr/local/bin/caddy"
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_SERVICE="/etc/systemd/system/caddy.service"
NAIVE_DIR="/etc/naiveproxy"
NAIVE_USERS_FILE="/etc/naiveproxy/users.conf"
NAIVE_PASS_FILE="/etc/naiveproxy/users.pass"
WEBROOT="/var/www/html"
LOG_DIR="/var/log/caddy"

SYSTEM_TYPE="Cloud_VPS"
if [ -f /etc/armbian-release ] || [ -f /etc/default/armbian-zram ] || grep -q -i "armbian\|nanopi\|raspberry" /etc/os-release 2>/dev/null; then
    SYSTEM_TYPE="SBC_Armbian"
elif [ -d /sys/class/power_supply ] && ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
    SYSTEM_TYPE="Laptop_PC"
elif [ "$(systemctl get-default 2>/dev/null)" = "graphical.target" ]; then
    SYSTEM_TYPE="Desktop_PC"
fi

get_system_type_human() {
    case "$SYSTEM_TYPE" in
        SBC_Armbian) echo "Одноплатный мини-ПК (Armbian)" ;;
        Laptop_PC)   echo "Ноутбук (Портативный ПК)" ;;
        Desktop_PC)  echo "Стационарный компьютер (ПК)" ;;
        *)           echo "Облачный сервер (VPS)" ;;
    esac
}

get_system_type_short() {
    case "$SYSTEM_TYPE" in
        SBC_Armbian) echo "Мини-ПК Armbian" ;;
        Laptop_PC)   echo "Ноутбук" ;;
        Desktop_PC)  echo "Компьютер" ;;
        *)           echo "Сервер VPS" ;;
    esac
}

get_wan_if() {
    ip -4 route show table main default 2>/dev/null | grep -vE "tailscale0|wg[0-9]+|warp|tun[0-9]+" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || echo ""
}

DEFAULT_WAN_IF=$(get_wan_if)

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
        u=$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $1!="nobody" {print $1; exit}' 2>/dev/null || echo "")
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
            ts_name=$(tailscale status --peers=false 2>/dev/null | awk 'NR==1 {print $2}' || echo "")
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
    ! command -v tailscale &>/dev/null && return 1
    local web_val=$(tailscale get webclient 2>/dev/null || echo "false")
    [ "$web_val" = "true" ] && return 0
    systemctl is-active --quiet tailscale-web.service 2>/dev/null && return 0
    ps aux 2>/dev/null | grep -v grep | grep -q -iE "tailscale.*web" && return 0
    return 1
}

is_derp_active() {
    systemctl is-active --quiet derper.service 2>/dev/null && return 0
    return 1
}

is_naive_active() {
    systemctl is-active --quiet caddy.service 2>/dev/null && [ -f "$CADDYFILE" ] && grep -q "forward_proxy" "$CADDYFILE" 2>/dev/null && return 0
    return 1
}

is_warp_active() {
    systemctl is-active --quiet wg-quick@warp.service 2>/dev/null && return 0
    ip link show warp >/dev/null 2>&1 && return 0
    return 1
}

ensure_wg_kernel_modules() {
    silent_run modprobe wireguard
    silent_run modprobe ip6table_mangle
    silent_run modprobe xt_TCPMSS
    mkdir -p /etc/modules-load.d
    cat << 'MOD_EOF' > /etc/modules-load.d/bobarev-network-modules.conf
ip6table_mangle
xt_TCPMSS
MOD_EOF
}

get_tailscale_netfilter_mode() {
    ! command -v tailscale &>/dev/null && { echo "none"; return 0; }
    if [ -f /etc/default/bobarev-netfilter ]; then
        local saved_mode=$(grep -E '^TS_NETFILTER_MODE=' /etc/default/bobarev-netfilter 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
        if [ "$saved_mode" = "off" ] || [ "$saved_mode" = "on" ]; then
            echo "$saved_mode"
            return 0
        fi
    fi
    local pref_line=$(tailscale debug prefs 2>/dev/null | grep -i '"NetfilterMode"' || echo "")
    if echo "$pref_line" | grep -q -iE '"off"|:[[:space:]]*0[,[:space:]]*$'; then
        echo "off"
        return 0
    elif echo "$pref_line" | grep -q -iE '"nodivert"|:[[:space:]]*1[,[:space:]]*$'; then
        echo "nodivert"
        return 0
    elif echo "$pref_line" | grep -q -iE '"on"|:[[:space:]]*2[,[:space:]]*$'; then
        echo "on"
        return 0
    fi
    if iptables -S FORWARD 2>/dev/null | grep -q "ts-forward"; then
        echo "on"
    else
        echo "off"
    fi
}

get_iface_status_tag() {
    local iface="$1"
    local state="Отключен"
    if ip link show "$iface" 2>/dev/null | grep -q "<[^>]*UP"; then
        state="Активен"
    fi
    local ip4=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || echo "")
    if [ -n "$ip4" ]; then
        echo "[${state}: ${ip4}]"
    else
        echo "[${state}: без IP]"
    fi
}

# ------------------------------------------------------------------------------
# ДИНАМИЧЕСКИЙ ВЫБОР ИНТЕРФЕЙСОВ И ХЕЛПЕРЫ UFW / NAT / DERP / КАСКАД
# ------------------------------------------------------------------------------
disable_ufw_strict_rpfilter() {
    if [ -f /etc/ufw/sysctl.conf ]; then
        sed -i 's/rp_filter=1/rp_filter=0/g' /etc/ufw/sysctl.conf 2>/dev/null || true
    fi
    for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
        [ -f "$rp" ] && echo 0 > "$rp" 2>/dev/null || true
    done
}

ensure_ufw_mangle_tcpmss() {
    if [ -f /etc/ufw/before.rules ] && ! grep -q "TCPMSS" /etc/ufw/before.rules; then
        sed -i '1s/^/*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n\n/' /etc/ufw/before.rules
    fi
    if [ -f /etc/ufw/before6.rules ] && ! grep -q "TCPMSS" /etc/ufw/before6.rules; then
        sed -i '1s/^/*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n\n/' /etc/ufw/before6.rules
    fi
}

ensure_ufw_nat_rule() {
    local rule="$1"
    [ ! -f /etc/ufw/before.rules ] && return 0
    if ! grep -q "^\*nat" /etc/ufw/before.rules; then
        sed -i '1s/^/*nat\n:PREROUTING ACCEPT [0:0]\n:POSTROUTING ACCEPT [0:0]\nCOMMIT\n\n/' /etc/ufw/before.rules
    else
        if ! grep -q "^:PREROUTING" /etc/ufw/before.rules; then
            sed -i '/^\*nat/a :PREROUTING ACCEPT [0:0]' /etc/ufw/before.rules
        fi
        if ! grep -q "^:POSTROUTING" /etc/ufw/before.rules; then
            sed -i '/^\*nat/a :POSTROUTING ACCEPT [0:0]' /etc/ufw/before.rules
        fi
    fi
    if ! grep -qF -- "$rule" /etc/ufw/before.rules; then
        sed -i "/^:POSTROUTING/a $rule" /etc/ufw/before.rules
    fi
}

apply_wan_exit_nat() {
    local wan_dev="$1"
    local quiet="${2:-false}"
    [ -z "$wan_dev" ] && return 0

    local iface_ip_info=$(ip -4 -o addr show dev "$wan_dev" 2>/dev/null || echo "")
    local pub_ip=$(echo "$iface_ip_info" | awk '{print $4}' | cut -d/ -f1 | head -n 1 || echo "")
    local is_mask_32=$(echo "$iface_ip_info" | grep -qw "/32" && echo "yes" || echo "no")

    for r_if in $(ip -br link show 2>/dev/null | grep -v "DOWN" | awk '{print $1}' | sed 's/@.*//' | grep -vE "^(lo|${wan_dev}|docker.*|veth.*|br-.*)$" || true); do
        iptables -C FORWARD -i "$r_if" -o "$wan_dev" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$r_if" -o "$wan_dev" -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -i "$wan_dev" -o "$r_if" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$wan_dev" -o "$r_if" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    done

    iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o "$wan_dev" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.144.144.0/24 -o "$wan_dev" -j MASQUERADE 2>/dev/null || true
    while iptables -t nat -D POSTROUTING -o "$wan_dev" -j MASQUERADE 2>/dev/null; do :; done
    if [ -n "$pub_ip" ]; then
        iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o "$wan_dev" -j SNAT --to-source "$pub_ip" 2>/dev/null || true
        while iptables -t nat -D POSTROUTING -o "$wan_dev" -j SNAT --to-source "$pub_ip" 2>/dev/null; do :; done
    fi

    if [ -f /etc/ufw/before.rules ]; then
        sed -i "/-o ${wan_dev} -j MASQUERADE/d" /etc/ufw/before.rules 2>/dev/null || true
        sed -i "/-o ${wan_dev} -j SNAT/d" /etc/ufw/before.rules 2>/dev/null || true
    fi

    if [ "$is_mask_32" = "yes" ] && [ -n "$pub_ip" ]; then
        iptables -t nat -A POSTROUTING -o "$wan_dev" -j SNAT --to-source "$pub_ip"
        ensure_ufw_nat_rule "-A POSTROUTING -o $wan_dev -j SNAT --to-source $pub_ip"
        if [ "$quiet" != "true" ]; then
            echo -e "${C_BLUE}ℹ️ Обнаружена маска /32 на интерфейсе $wan_dev: закреплена постоянная привязка SNAT ($pub_ip).${C_RESET}"
        fi
    else
        iptables -t nat -A POSTROUTING -o "$wan_dev" -j MASQUERADE
        ensure_ufw_nat_rule "-A POSTROUTING -o $wan_dev -j MASQUERADE"
        if [ "$quiet" != "true" ]; then
            echo -e "${C_BLUE}ℹ️ Закреплено правило маскарадинга (MASQUERADE) для $wan_dev в /etc/ufw/before.rules.${C_RESET}"
        fi
    fi
    return 0
}

select_and_apply_routed_interfaces() {
    local wan_dev="$1"
    [ -z "$wan_dev" ] && return 0

    local candidate_ifs=$(ip -br link show 2>/dev/null | grep -v "DOWN" | awk '{print $1}' | sed 's/@.*//' | grep -vE "^(lo|${wan_dev}|docker.*|veth.*|br-.*)$" || echo "")
    if [ -z "$candidate_ifs" ]; then
        echo -e "${C_BLUE}ℹ️ Дополнительные интерфейсы не обнаружены (базовая маршрутизация для $wan_dev включена).${C_RESET}"
        return 0
    fi

    local checklist_items=()
    local count=0
    for cif in $candidate_ifs; do
        local st_tag=$(get_iface_status_tag "$cif")
        checklist_items+=("$cif" "Транзит <-> $wan_dev $st_tag" "ON")
        count=$((count + 1))
    done

    local selected_ifs=""
    local list_h=$((count < 6 ? 6 : count))
    local box_h=$((list_h + 8))
    if selected_ifs=$(whiptail --title "Маршрутизация интерфейсов" --checklist "Выберите интерфейсы для сквозной маршрутизации с $wan_dev (Пробел — выбор, Enter — ОК):" $box_h $WT_WIDTH $list_h "${checklist_items[@]}" 3>&1 1>&2 2>&3); then
        selected_ifs=$(echo "$selected_ifs" | tr -d '"')
        for sif in $selected_ifs; do
            silent_run ufw route allow in on "$sif" out on "$wan_dev" comment "Route $sif to $wan_dev"
            silent_run ufw route allow in on "$wan_dev" out on "$sif" comment "Route $wan_dev to $sif"
            echo -e "${C_BLUE}ℹ️ Разрешена сквозная маршрутизация: $sif <-> $wan_dev.${C_RESET}"
        done
    fi
    return 0
}

flush_and_reload_nat() {
    local wan_dev=$(get_wan_if)
    iptables -t nat -F 2>/dev/null || true
    if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
        silent_run ufw reload
    fi
    if [ -n "$wan_dev" ]; then
        local fwd_pol=$(grep -E "^DEFAULT_FORWARD_POLICY=" /etc/default/ufw 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "DROP")
        if [ "$fwd_pol" = "ACCEPT" ] || [ "$(tailscale get advertise-exit-node 2>/dev/null || echo 'false')" = "true" ] || ip link show tun0 >/dev/null 2>&1; then
            apply_wan_exit_nat "$wan_dev" "true" || true
        fi
    fi
    if is_warp_active; then
        iptables -t nat -C POSTROUTING -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o warp -j MASQUERADE 2>/dev/null || true
    fi
    if [ -x /usr/local/bin/bobarev-cascade-ru.sh ]; then
        /usr/local/bin/bobarev-cascade-ru.sh >/dev/null 2>&1 || true
    fi
    if [ -x /usr/local/bin/bobarev-router-up.sh ]; then
        /usr/local/bin/bobarev-router-up.sh >/dev/null 2>&1 || true
    fi
    return 0
}

clean_tailscale_iptables_chains() {
    while iptables -D FORWARD -j ts-forward 2>/dev/null; do :; done
    while iptables -D INPUT -j ts-input 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -j ts-postrouting 2>/dev/null; do :; done
    iptables -F ts-forward 2>/dev/null || true
    iptables -X ts-forward 2>/dev/null || true
    iptables -F ts-input 2>/dev/null || true
    iptables -X ts-input 2>/dev/null || true
    iptables -t nat -F ts-postrouting 2>/dev/null || true
    iptables -t nat -X ts-postrouting 2>/dev/null || true

    if command -v ip6tables &>/dev/null; then
        while ip6tables -D FORWARD -j ts-forward 2>/dev/null; do :; done
        while ip6tables -D INPUT -j ts-input 2>/dev/null; do :; done
        while ip6tables -t nat -D POSTROUTING -j ts-postrouting 2>/dev/null; do :; done
        ip6tables -F ts-forward 2>/dev/null || true
        ip6tables -X ts-forward 2>/dev/null || true
        ip6tables -F ts-input 2>/dev/null || true
        ip6tables -X ts-input 2>/dev/null || true
        ip6tables -t nat -F ts-postrouting 2>/dev/null || true
        ip6tables -t nat -X ts-postrouting 2>/dev/null || true
    fi
}

set_tailscale_netfilter_priority() {
    local target_mode="$1"
    local quiet="${2:-false}"
    local wan_dev=$(get_wan_if)

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    mkdir -p /etc/sysctl.d
    cat << 'TS_EOF' > /etc/sysctl.d/99-tailscale-forward.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
TS_EOF

    echo "TS_NETFILTER_MODE=\"$target_mode\"" > /etc/default/bobarev-netfilter

    if [ "$target_mode" = "off" ]; then
        silent_run tailscale set --netfilter-mode=off
        clean_tailscale_iptables_chains

        if [ -n "$wan_dev" ]; then
            for r_if in $(ip -br link show 2>/dev/null | grep -v "DOWN" | awk '{print $1}' | sed 's/@.*//' | grep -vE "^(lo|${wan_dev}|docker.*|veth.*|br-.*)$" || true); do
                silent_run ufw route allow in on "$r_if" out on "$wan_dev" comment "Route $r_if to $wan_dev"
                silent_run ufw route allow in on "$wan_dev" out on "$r_if" comment "Route $wan_dev to $r_if"
            done
            apply_wan_exit_nat "$wan_dev" "true"
        fi
        flush_and_reload_nat
        clean_tailscale_iptables_chains
        if [ "$quiet" != "true" ]; then
            echo -e "${C_GREEN}✅ Приоритет сетевых правил передан брандмауэру UFW (системный режим).${C_RESET}"
        fi
    else
        silent_run tailscale set --netfilter-mode=on
        flush_and_reload_nat
        if [ "$quiet" != "true" ]; then
            echo -e "${C_BLUE}ℹ️ Приоритет сетевых правил оставлен Tailscale (встроенный авто-режим).${C_RESET}"
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# СТЕК КАСКАДА: NAIVEPROXY (CADDY 2) -> TAILSCALE -> CLOUDFLARE WARP
# ------------------------------------------------------------------------------
install_naive_camouflage_site() {
    mkdir -p "$WEBROOT"
    cat << 'CAMO_EOF' > "$WEBROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>DevStack — Linux & Infrastructure Notes</title>
<style>
:root{--bg:#080B0F;--bg2:#0D1117;--border:#21262D;--gold:#D4A017;--text:#E6EDF3;--dim:#7D8590}
*{margin:0;padding:0;box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,sans-serif;line-height:1.6}
header{border-bottom:1px solid var(--border);background:var(--bg2);padding:18px 24px}
.wrap{max-width:960px;margin:0 auto;padding:48px 24px}
h1{font-size:38px;margin-bottom:16px}
h1 span{color:var(--gold)}
p{color:var(--dim);max-width:640px;margin-bottom:24px}
.card{border:1px solid var(--border);border-radius:10px;padding:24px;background:var(--bg2);margin-bottom:16px}
.tag{font-family:monospace;font-size:12px;color:var(--gold);text-transform:uppercase}
</style>
</head>
<body>
<header><strong>&gt;_ DevStack</strong> &middot; Infrastructure &amp; Kernel Notes</header>
<div class="wrap">
  <h1>Linux, Networking &amp; <span>Self-Hosted Systems</span></h1>
  <p>Technical notes on low-latency routing, kernel hardening, BBR congestion control, and modern HTTP/3 edge servers.</p>
  <div class="card">
    <div class="tag">Networking &bull; 2026</div>
    <h3>Tuning Linux Kernel UDP Buffers and TCP BBR for High-Throughput Tunnels</h3>
    <p>Practical sysctl configurations for minimizing packet loss and jitter across distributed mesh networks.</p>
  </div>
  <div class="card">
    <div class="tag">Security &bull; 2026</div>
    <h3>Zero-Trust SSH Hardening and Automated Firewall Isolation</h3>
    <p>Replacing legacy port exposure with encrypted mesh interfaces and strict conntrack policies.</p>
  </div>
</div>
</body>
</html>
CAMO_EOF
    chmod 644 "$WEBROOT/index.html"
}

ensure_go_and_build_caddy_naive() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -yq curl wget git tar unzip openssl ca-certificates apache2-utils

    export PATH="/usr/local/go/bin:$PATH"
    local need_go=true
    if command -v go &>/dev/null; then
        local gver=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+' || echo "0.0")
        local gmaj=$(echo "$gver" | cut -d. -f1)
        local gmin=$(echo "$gver" | cut -d. -f2)
        if [ "${gmaj:-0}" -gt 1 ] || { [ "${gmaj:-0}" -eq 1 ] && [ "${gmin:-0}" -ge 25 ]; }; then
            need_go=false
        fi
    fi

    # Используем физический диск вместо маленького tmpfs (/tmp), чтобы сборка не падала с "no space left on device"
    local build_tmp_dir="/root/.caddy-build-tmp"
    mkdir -p "$build_tmp_dir"

    if [ "$need_go" = true ]; then
        echo -e "${C_BLUE}📦 Установка компилятора Go ${GO_VERSION_PIN} с проверкой SHA256...${C_RESET}"
        local arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
        local exp_sha="$GO_SHA256_AMD64"
        if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
            arch="arm64"
            exp_sha="$GO_SHA256_ARM64"
        else
            arch="amd64"
        fi
        local go_tmp="${build_tmp_dir}/go_${GO_VERSION_PIN}.tar.gz"
        wget -q --tries=3 --timeout=30 "https://go.dev/dl/go${GO_VERSION_PIN}.linux-${arch}.tar.gz" -O "$go_tmp"
        local act_sha=$(sha256sum "$go_tmp" | awk '{print $1}')
        if [ "$act_sha" != "$exp_sha" ]; then
            rm -rf "$build_tmp_dir"
            echo -e "${C_RED}❌ Ошибка: контрольная сумма SHA256 архива Go не совпала!${C_RESET}"
            return 1
        fi
        rm -rf /usr/local/go
        tar -C /usr/local -xzf "$go_tmp"
        rm -f "$go_tmp"
        echo 'export PATH="/usr/local/go/bin:$PATH"' > /etc/profile.d/go.sh
        export PATH="/usr/local/go/bin:$PATH"
        echo -e "${C_GREEN}✅ Компилятор Go ${GO_VERSION_PIN} успешно установлен.${C_RESET}"
    fi

    if [ -x "$CADDY_BIN" ] && "$CADDY_BIN" list-modules 2>/dev/null | grep -q "http.handlers.forward_proxy"; then
        rm -rf "$build_tmp_dir"
        echo -e "${C_GREEN}✅ Бинарник Caddy с модулем NaiveProxy (forward_proxy) уже скомпилирован.${C_RESET}"
        return 0
    fi

    echo -e "${C_BLUE}🔨 Сборка Caddy ${CADDY_VERSION_PIN} с модулем klzgrad/forwardproxy@naive (занимает 3-10 минут)...${C_RESET}"
    export GOPATH="/root/go"
    export GOCACHE="/root/.cache/go-build"
    export GOTMPDIR="$build_tmp_dir"
    export TMPDIR="$build_tmp_dir"

    go install "github.com/caddyserver/xcaddy/cmd/xcaddy@${XCADDY_VERSION_PIN}"

    "$GOPATH/bin/xcaddy" build "$CADDY_VERSION_PIN" \
        --with "github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${FORWARDPROXY_REF_PIN}" \
        --output "$CADDY_BIN" || true

    rm -rf "$build_tmp_dir"
    unset GOTMPDIR TMPDIR

    if [ ! -f "$CADDY_BIN" ]; then
        echo -e "${C_RED}❌ Ошибка сборки: бинарный файл $CADDY_BIN не был создан (проверьте наличие свободного места на диске df -h).${C_RESET}"
        return 1
    fi

    chmod +x "$CADDY_BIN"
    if ! "$CADDY_BIN" list-modules 2>/dev/null | grep -q "http.handlers.forward_proxy"; then
        echo -e "${C_RED}❌ Ошибка сборки: модуль http.handlers.forward_proxy не найден в Caddy.${C_RESET}"
        return 1
    fi
    echo -e "${C_GREEN}✅ Caddy ${CADDY_VERSION_PIN} + NaiveProxy успешно собран!${C_RESET}"
    return 0
}

render_naive_caddyfile() {
    [ ! -f /etc/default/bobarev-cascade ] && return 1
    # shellcheck disable=SC1091
    source /etc/default/bobarev-cascade
    local dom="${NAIVE_DOMAIN:-}"
    local email="${NAIVE_EMAIL:-admin@${dom}}"
    [ -z "$dom" ] && return 1

    mkdir -p /etc/caddy "$NAIVE_DIR" "$WEBROOT" "$LOG_DIR"
    touch "$NAIVE_USERS_FILE"
    chmod 600 "$NAIVE_USERS_FILE"
    install_naive_camouflage_site

    local auth_lines=""
    while IFS=: read -r u h; do
        [ -z "$u" ] || [ -z "$h" ] && continue
        auth_lines+="            ${u} ${h}"$'\n'
    done < "$NAIVE_USERS_FILE"

    if [ -z "$auth_lines" ]; then
        local dummy_hash=$(printf '%s\n' "disabled_placeholder" | htpasswd -niBC 12 "__disabled__" | cut -d: -f2)
        auth_lines="            __disabled__ ${dummy_hash}"$'\n'
    fi

    cat << EOF > "$CADDYFILE"
{
    order forward_proxy before file_server
    servers :443 {
        protocols h1 h2 h3
    }
    log {
        output file "${LOG_DIR}/access.log" {
            roll_size 20mb
            roll_keep 3
        }
    }
}

:443, ${dom} {
    tls ${email}

    @naive_proxy method CONNECT
    route @naive_proxy {
        request_header Authorization "{http.request.header.Proxy-Authorization}"
        basic_auth bcrypt {
${auth_lines}        }
        request_header -Authorization
        forward_proxy {
            hide_ip
            hide_via
        }
    }

    file_server {
        root "${WEBROOT}"
    }

    handle_errors {
        @proxy_auth_error expression {http.error.status_code} == 401
        handle @proxy_auth_error {
            header -WWW-Authenticate
            respond "Not Found" 404
        }
    }
}
EOF
    chmod 600 "$CADDYFILE"

    cat << 'SVC_EOF' > "$CADDY_SERVICE"
[Unit]
Description=Bobarev Shell NaiveProxy (Caddy 2)
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVC_EOF

    systemctl daemon-reload
    systemctl enable caddy.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet caddy.service; then
        systemctl reload caddy.service 2>/dev/null || systemctl restart caddy.service
    else
        systemctl restart caddy.service
    fi
}

add_or_update_naive_user() {
    local u_name="$1"
    local u_pass="$2"
    mkdir -p "$NAIVE_DIR"
    touch "$NAIVE_USERS_FILE" "$NAIVE_PASS_FILE"
    chmod 600 "$NAIVE_USERS_FILE" "$NAIVE_PASS_FILE"

    if ! command -v htpasswd &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -yq apache2-utils >/dev/null 2>&1
    fi

    local b_hash=$(printf '%s\n' "$u_pass" | htpasswd -niBC 12 "$u_name" 2>/dev/null | cut -d: -f2)
    if [ -z "$b_hash" ]; then
        echo -e "${C_RED}❌ Не удалось создать bcrypt-хеш пароля.${C_RESET}"
        return 1
    fi

    sed -i "/^${u_name}:/d" "$NAIVE_USERS_FILE" 2>/dev/null || true
    echo "${u_name}:${b_hash}" >> "$NAIVE_USERS_FILE"

    sed -i "/^${u_name}:/d" "$NAIVE_PASS_FILE" 2>/dev/null || true
    echo "${u_name}:${u_pass}" >> "$NAIVE_PASS_FILE"
    chmod 600 "$NAIVE_USERS_FILE" "$NAIVE_PASS_FILE"
    return 0
}

print_naive_shadowrocket_links() {
    if [ ! -f /etc/default/bobarev-cascade ] || [ ! -s "$NAIVE_PASS_FILE" ]; then
        echo -e "${C_YELLOW}⚠️ Пользователи NaiveProxy еще не созданы или Сервер 1 не настроен.${C_RESET}"
        return 0
    fi
    # shellcheck disable=SC1091
    source /etc/default/bobarev-cascade
    local dom="${NAIVE_DOMAIN:-$(hostname)}"

    local show_real=false
    if prompt_yn "Показать реальные пароли в ссылках для копирования в Shadowrocket?\n\n• Да: готовые рабочие ссылки.\n• Нет: скрыть пароли звездочками (безопасно для скриншотов)." "true"; then
        show_real=true
    fi

    echo -e "\n${C_CYAN}📋 === ГОТОВЫЕ ССЫЛКИ ДЛЯ SHADOWROCKET ===${C_RESET}"
    while IFS=: read -r u p; do
        [ -z "$u" ] || [ -z "$p" ] && continue
        local disp_p="********"
        local b64_str="Скрыто_для_скриншота"
        if [ "$show_real" = true ]; then
            disp_p="$p"
            b64_str=$(printf '%s' "${u}:${p}@${dom}:443" | base64 -w0 2>/dev/null || printf '%s' "${u}:${p}@${dom}:443" | base64)
        fi
        echo -e "\n👤 Пользователь: ${C_BOLD}${u}${C_RESET} (Сервер: ${C_GREEN}${dom}${C_RESET}, Порт: ${C_GREEN}443${C_RESET})"
        echo -e "  • ${C_BLUE}Универсальная ссылка HTTPS (вставляется напрямую в Shadowrocket):${C_RESET}"
        echo -e "    ${C_GREEN}https://${u}:${disp_p}@${dom}:443?padding=true#${dom}-${u}${C_RESET}"
        echo -e "  • ${C_BLUE}Прямая ссылка HTTP/2 (альтернативный формат Shadowrocket):${C_RESET}"
        echo -e "    ${C_GREEN}http2://${b64_str}?obfs=none#${dom}-HTTP2-${u}${C_RESET}"
    done < "$NAIVE_PASS_FILE"

    echo -e "\n${C_BLUE}💡 Ручная настройка в Shadowrocket (если добавляете вручную):${C_RESET}"
    echo -e "  • Тип (Type): ${C_BOLD}HTTPS${C_RESET} или ${C_BOLD}HTTP2${C_RESET}"
    echo -e "  • Адрес (Address): ${C_BOLD}${dom}${C_RESET} | Порт (Port): ${C_BOLD}443${C_RESET}"
    echo -e "  • Пользователь и Пароль: ваши данные выше | TLS: ${C_BOLD}Включен (ON)${C_RESET}"
    echo -e "  • Название (Remarks): ${C_BOLD}${dom}${C_RESET}"
}

setup_cascade_server1_ru() {
    echo -e "${C_CYAN}🔒 === НАСТРОЙКА СЕРВЕРА 1 (ВХОД РФ): NAIVEPROXY -> TAILSCALE ===${C_RESET}"
    ensure_tailscale_installed || true
    enable_routing_optimizations || true

    local saved_dom=""
    local saved_email=""
    local saved_exit=""
    if [ -f /etc/default/bobarev-cascade ]; then
        # shellcheck disable=SC1091
        source /etc/default/bobarev-cascade
        saved_dom="${NAIVE_DOMAIN:-}"
        saved_email="${NAIVE_EMAIL:-}"
        saved_exit="${EXIT_TS_IP:-}"
    fi

    local n_dom=""
    prompt_default "1/4. Введите ваш домен, направленный по DNS (A-запись без прокси Cloudflare) на этот РФ-сервер:" "${saved_dom:-ru.yourdomain.com}" n_dom
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_dom" ]; then return 0; fi

    local n_email=""
    prompt_default "2/4. Введите ваш Email для автоматического выпуска SSL-сертификата Let's Encrypt:" "${saved_email:-admin@${n_dom}}" n_email
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_email" ]; then return 0; fi

    local n_user=""
    prompt_default "3/4. Введите имя пользователя для подключения в Shadowrocket:" "user1" n_user
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_user" ]; then return 0; fi
    n_user=$(echo "$n_user" | tr -dc 'a-zA-Z0-9_-')

    local rand_pass=$(openssl rand -base64 18 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16 || echo "NaivePass2026")
    local n_pass=""
    prompt_default "Пароль для пользователя $n_user (минимум 8 символов):" "$rand_pass" n_pass
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_pass" ]; then return 0; fi

    local ts_peers=$(tailscale status 2>/dev/null | awk 'NR>1 {print $1 " (" $2 ")"}' | tr '\n' ' ' || echo "")
    [ -n "$ts_peers" ] && echo -e "${C_BLUE}ℹ️ Доступные узлы в вашей сети Tailscale: $ts_peers${C_RESET}"

    local exit_ts_ip=""
    prompt_default "4/4. Введите Tailscale IP вашего Зарубежного Сервера 2 (например, 100.x.y.z):" "${saved_exit:-}" exit_ts_ip
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    if is_derp_active; then
        echo -e "${C_YELLOW}⚠️ Внимание: служба личного DERP на порту 443 остановлена, так как порт 443 передается NaiveProxy (Caddy).${C_RESET}"
        silent_run systemctl stop derper.service
        silent_run systemctl disable derper.service
    fi

    ensure_go_and_build_caddy_naive || return 1

    local wan_dev=$(get_wan_if)
    local pub_ip=$(ip -4 -o addr show dev "${wan_dev:-eth0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || echo "")

    cat << EOF > /etc/default/bobarev-cascade
CASCADE_ROLE="ru_entry"
NAIVE_DOMAIN="$n_dom"
NAIVE_EMAIL="$n_email"
EXIT_TS_IP="$exit_ts_ip"
SERVER_PUB_IP="$pub_ip"
EOF
    chmod 600 /etc/default/bobarev-cascade

    add_or_update_naive_user "$n_user" "$n_pass"
    render_naive_caddyfile

    # Создание службы маршрутизации и TCP-тюнинга для российского сервера
    cat << 'RU_SH_EOF' > /usr/local/bin/bobarev-cascade-ru.sh
#!/bin/bash
[ ! -f /etc/default/bobarev-cascade ] && exit 0
source /etc/default/bobarev-cascade
[ "${CASCADE_ROLE:-}" != "ru_entry" ] && exit 0

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_notsent_lowat=16384 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true

WAN_IF=$(ip -4 route show table main default 2>/dev/null | grep -vE "tailscale0|wg[0-9]+|warp|tun[0-9]+" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
PUB_IP="${SERVER_PUB_IP:-}"
if [ -z "$PUB_IP" ] && [ -n "$WAN_IF" ]; then
    PUB_IP=$(ip -4 -o addr show dev "$WAN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)
fi

if [ -n "$PUB_IP" ]; then
    ip rule del from "$PUB_IP" lookup main priority 100 2>/dev/null || true
    ip rule add from "$PUB_IP" lookup main priority 100 2>/dev/null || true
fi

ip link set dev tailscale0 txqueuelen 10000 2>/dev/null || true
iptables -t nat -C POSTROUTING -o tailscale0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE 2>/dev/null || true
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

if [ -n "${EXIT_TS_IP:-}" ] && command -v tailscale &>/dev/null; then
    tailscale set --exit-node="$EXIT_TS_IP" --exit-node-allow-lan-access=true --accept-routes=true 2>/dev/null || true
fi
RU_SH_EOF
    chmod +x /usr/local/bin/bobarev-cascade-ru.sh

    cat << 'RU_SVC_EOF' > /etc/systemd/system/bobarev-cascade-ru.service
[Unit]
Description=Bobarev Cascade RU Routing (NaiveProxy -> Tailscale)
After=network-online.target tailscaled.service caddy.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bobarev-cascade-ru.sh

[Install]
WantedBy=multi-user.target
RU_SVC_EOF

    systemctl daemon-reload
    silent_run systemctl enable --now bobarev-cascade-ru.service
    /usr/local/bin/bobarev-cascade-ru.sh

    if command -v ufw &>/dev/null; then
        silent_run ufw allow 80/tcp comment 'NaiveProxy ACME HTTP'
        silent_run ufw allow 443/tcp comment 'NaiveProxy HTTPS'
        silent_run ufw allow 443/udp comment 'NaiveProxy HTTP3 QUIC'
        echo -e "${C_GREEN}✅ Порты 80/tcp, 443/tcp и 443/udp открыты в UFW.${C_RESET}"
    fi

    echo -e "${C_GREEN}✅ Сервер 1 (Вход в РФ на базе NaiveProxy + Tailscale) успешно настроен и запущен!${C_RESET}"
    print_naive_shadowrocket_links
}

setup_cascade_server2_warp() {
    echo -e "${C_CYAN}🌍 === НАСТРОЙКА СЕРВЕРА 2 (ЗАРУБЕЖНЫЙ ВЫХОД): TAILSCALE -> WARP ===${C_RESET}"
    ensure_tailscale_installed || true
    enable_routing_optimizations || true

    echo -e "${C_BLUE}📦 Установка пакетов wireguard-tools, iptables и curl...${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -yq wireguard-tools iptables curl

    local arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    local wgcf_arch="amd64"
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
        wgcf_arch="arm64"
    fi

    if [ ! -x /usr/local/bin/wgcf ]; then
        echo -e "${C_BLUE}⬇️ Скачивание утилиты wgcf для генерации профиля Cloudflare WARP...${C_RESET}"
        if ! curl -fsSL "https://github.com/ViRb3/wgcf/releases/download/v2.3.1/wgcf_2.3.1_linux_${wgcf_arch}" -o /usr/local/bin/wgcf 2>/dev/null; then
            local latest_url=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null | grep "browser_download_url.*linux_${wgcf_arch}" | head -n 1 | cut -d'"' -f4 || echo "")
            [ -n "$latest_url" ] && curl -fsSL "$latest_url" -o /usr/local/bin/wgcf
        fi
        chmod +x /usr/local/bin/wgcf
    fi

    mkdir -p /etc/wireguard
    if [ ! -f /etc/wireguard/warp.conf ] || prompt_yn "Профиль /etc/wireguard/warp.conf уже существует. Сгенерировать новый профиль WARP?" "false"; then
        echo -e "${C_BLUE}🔑 Регистрация аккаунта Cloudflare WARP и создание конфигурации...${C_RESET}"
        (
            cd /root
            rm -f wgcf-account.toml wgcf-profile.conf 2>/dev/null || true
            /usr/local/bin/wgcf register --accept-tos
            /usr/local/bin/wgcf generate --keepalive
            cp /root/wgcf-profile.conf /etc/wireguard/warp.conf
        )

        # Удаляем DNS и IPv6, добавляем изолированную таблицу 51820 для трафика из Tailscale (100.64.0.0/10)
        sed -i '/^DNS/d' /etc/wireguard/warp.conf
        sed -i 's/, [0-9a-fA-F:\/]*//g' /etc/wireguard/warp.conf

        sed -i '/^\[Interface\]/a Table = 51820\nPostUp = ip rule add from 100.64.0.0/10 lookup 51820 priority 6000 || true\nPostUp = iptables -t nat -I POSTROUTING 1 -o warp -j MASQUERADE\nPostUp = iptables -I FORWARD 1 -i tailscale0 -o warp -j ACCEPT\nPostUp = iptables -I FORWARD 1 -i warp -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT\nPostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nPostDown = ip rule del from 100.64.0.0/10 lookup 51820 priority 6000 || true\nPostDown = iptables -t nat -D POSTROUTING -o warp -j MASQUERADE\nPostDown = iptables -D FORWARD -i tailscale0 -o warp -j ACCEPT\nPostDown = iptables -D FORWARD -i warp -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT\nPostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' /etc/wireguard/warp.conf
        chmod 600 /etc/wireguard/warp.conf
    fi

    ensure_wg_kernel_modules
    systemctl daemon-reload
    systemctl enable --now wg-quick@warp
    systemctl restart wg-quick@warp || true

    silent_run tailscale set --advertise-exit-node=true
    if command -v ufw &>/dev/null; then
        silent_run ufw default allow routed
        silent_run sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        silent_run ufw route allow in on tailscale0 out on warp comment 'Tailscale to WARP'
        silent_run ufw route allow in on warp out on tailscale0 comment 'WARP to Tailscale'
        ensure_ufw_nat_rule "-A POSTROUTING -o warp -j MASQUERADE"
        ensure_ufw_mangle_tcpmss
        silent_run ufw reload
    fi

    cat << EOF > /etc/default/bobarev-cascade
CASCADE_ROLE="foreign_warp_exit"
EOF
    chmod 600 /etc/default/bobarev-cascade

    local my_ts_ip=$(tailscale ip -4 2>/dev/null | head -n 1 || echo "100.x.y.z")
    echo -e "${C_GREEN}✅ Сервер 2 (Зарубежный выход через Cloudflare WARP) успешно запущен!${C_RESET}"
    echo -e "${C_BLUE}📌 Ваш Tailscale IP этого сервера: ${C_BOLD}${my_ts_ip}${C_RESET}"
    echo -e "${C_YELLOW}⚠️ Не забудьте в админ-панели Tailscale (https://login.tailscale.com/admin/machines) включить галочку 'Use as exit node' для этого сервера, а на Сервере 1 (РФ) указать IP ${my_ts_ip}!${C_RESET}"
}

manage_cascade_naive_ts_warp() {
    while true; do
        MODULE_CANCELED=false
        local c_state="Не настроен"
        if is_naive_active; then
            c_state="Активен Сервер 1 (РФ: NaiveProxy -> Tailscale)"
        elif is_warp_active; then
            c_state="Активен Сервер 2 (Зарубеж: Tailscale -> WARP)"
        fi

        local c_choice
        if ! c_choice=$(whiptail --title "Каскад: NaiveProxy + Tailscale + WARP" --menu "\nТекущая роль: $c_state\nВыберите действие:" 17 $WT_WIDTH 6 \
        "1" "🔒 Сервер 1 (Вход РФ): NaiveProxy (Caddy) -> Tailscale" \
        "2" "🌍 Сервер 2 (Выход Зарубеж): Tailscale -> Cloudflare WARP" \
        "3" "👤 Пользователи NaiveProxy (Добавить / Сменить пароль)" \
        "4" "📋 Показать ссылки (Shadowrocket / Streisand / Hiddify)" \
        "5" "🛑 Остановить и удалить компоненты каскада" \
        "0" "🔙 Вернуться назад" 3>&1 1>&2 2>&3) || [ "$c_choice" = "0" ]; then
            break
        fi

        clear
        case "$c_choice" in
            1)
                setup_cascade_server1_ru
                pause_enter
                ;;
            2)
                setup_cascade_server2_warp
                pause_enter
                ;;
            3)
                if [ ! -f "$CADDYFILE" ]; then
                    echo -e "${C_YELLOW}⚠️ Сначала настройте Сервер 1 (Пункт 1).${C_RESET}"
                else
                    local new_u=""
                    prompt_default "Введите имя пользователя NaiveProxy:" "user1" new_u
                    if [ "$MODULE_CANCELED" = false ] && [ -n "$new_u" ]; then
                        new_u=$(echo "$new_u" | tr -dc 'a-zA-Z0-9_-')
                        local def_p=$(openssl rand -base64 18 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16 || echo "NaivePass2026")
                        local new_p=""
                        prompt_default "Введите пароль для $new_u:" "$def_p" new_p
                        if [ "$MODULE_CANCELED" = false ] && [ -n "$new_p" ]; then
                            add_or_update_naive_user "$new_u" "$new_p"
                            render_naive_caddyfile
                            echo -e "${C_GREEN}✅ Пользователь $new_u сохранен, конфигурация Caddy перезагружена!${C_RESET}"
                            print_naive_shadowrocket_links
                        fi
                    fi
                fi
                pause_enter
                ;;
            4)
                print_naive_shadowrocket_links
                pause_enter
                ;;
            5)
                if prompt_yn "Остановить и отключить службы каскада (NaiveProxy Caddy / WARP) на этом сервере?" "false"; then
                    silent_run systemctl stop caddy.service bobarev-cascade-ru.service wg-quick@warp.service
                    silent_run systemctl disable caddy.service bobarev-cascade-ru.service wg-quick@warp.service
                    silent_run tailscale set --exit-node=
                    rm -f /etc/default/bobarev-cascade /etc/systemd/system/bobarev-cascade-ru.service /usr/local/bin/bobarev-cascade-ru.sh
                    systemctl daemon-reload
                    echo -e "${C_GREEN}✅ Службы каскада остановлены и отключены.${C_RESET}"
                fi
                pause_enter
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# ЛИЧНЫЙ РЕТРАНСЛЯТОР DERP
# ------------------------------------------------------------------------------
print_derp_json_snippet() {
    local d_domain="${1:-derp.yourdomain.com}"
    local d_ip="${2:-ВАШ_IP_СЕРВЕРА}"
    local is_real="${3:-false}"

    echo -e "\n${C_CYAN}📋 === БЛОК derpMap ДЛЯ КОНСОЛИ TAILSCALE ===${C_RESET}"
    echo -e "Откройте: ${C_BLUE}https://login.tailscale.com/admin/acls/file${C_RESET} (Access controls -> JSON editor)"
    echo -e "и добавьте этот блок перед последней закрывающей скобкой ${C_BOLD}}${C_RESET}:\n"
    cat << DERP_JSON_EOF
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "900": {
        "RegionID":   900,
        "RegionCode": "custom",
        "RegionName": "My Custom DERP via Cloudflare",
        "Nodes": [
          {
            "Name":     "900a-derp",
            "RegionID": 900,
            "HostName": "$d_domain",
            "DERPPort": 443,
            "STUNPort": -1
          },
          {
            "Name":     "900b-stun",
            "RegionID": 900,
            "HostName": "$d_ip",
            "STUNPort": 3478,
            "STUNOnly": true
          },
          {
            "Name":     "900c-stun-google",
            "RegionID": 900,
            "HostName": "stun.l.google.com",
            "STUNPort": 19302,
            "STUNOnly": true
          }
        ]
      }
    }
  }
DERP_JSON_EOF
    if [ "$is_real" = "true" ]; then
        echo -e "\n${C_GREEN}✅ В код подставлены ваш реальный домен ($d_domain) и IP-адрес ($d_ip) — можно сразу копировать!${C_RESET}"
    else
        echo -e "\n${C_YELLOW}⚠️ Показан обезличенный шаблон. Не забудьте заменить 'derp.yourdomain.com' и 'ВАШ_IP_СЕРВЕРА' на ваши реальные данные!${C_RESET}"
    fi
    echo -e "\n${C_BLUE}💡 Команды проверки на клиентах после сохранения ACL:${C_RESET}"
    echo -e "  • ${C_GREEN}tailscale netcheck${C_RESET}"
    echo -e "  • ${C_GREEN}tailscale debug derp 900${C_RESET}"
}

show_derp_json_interactive() {
    local saved_domain="derp.yourdomain.com"
    local is_installed=false
    if [ -f /etc/default/bobarev-derp ]; then
        # shellcheck disable=SC1091
        source /etc/default/bobarev-derp
        saved_domain="${DERP_DOMAIN:-derp.yourdomain.com}"
        is_installed=true
    elif [ -f /etc/systemd/system/derper.service ]; then
        is_installed=true
    fi

    if [ "$is_installed" = true ] && [ "$saved_domain" != "derp.yourdomain.com" ]; then
        if prompt_yn "Узел DERP уже настроен на этом сервере.\nПодставить ваш реальный домен и IP-адрес сервера в JSON-код?\n\n• Да: готовый код с вашими данными для копирования.\n• Нет: обезличенный шаблон (безопасно для скриншотов и видео)." "false"; then
            local real_ip=""
            real_ip=$(curl -4 -s --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || ip -4 -o addr show dev "${DEFAULT_WAN_IF:-eth0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || echo "ВАШ_IP_СЕРВЕРА")
            [ -z "$real_ip" ] && real_ip="ВАШ_IP_СЕРВЕРА"
            print_derp_json_snippet "$saved_domain" "$real_ip" "true"
            return 0
        fi
    fi
    print_derp_json_snippet "derp.yourdomain.com" "ВАШ_IP_СЕРВЕРА" "false"
}

manage_custom_derp() {
    while true; do
        MODULE_CANCELED=false
        local saved_domain="derp.yourdomain.com"
        if [ -f /etc/default/bobarev-derp ]; then
            # shellcheck disable=SC1091
            source /etc/default/bobarev-derp
            saved_domain="${DERP_DOMAIN:-derp.yourdomain.com}"
        fi

        local derp_state="Не установлен"
        if is_derp_active; then
            derp_state="Активен"
        elif [ -f /etc/systemd/system/derper.service ]; then
            derp_state="Остановлен"
        fi

        local d_choice
        if ! d_choice=$(whiptail --title "Личный ретранслятор (DERP)" --menu "\nСтатус ретранслятора: $derp_state\nВыберите действие:" 16 $WT_WIDTH 5 \
        "1" "🚀 Установить / Обновить узел DERP (Cloudflare + STUN)" \
        "2" "📋 Показать JSON-код (derpMap) для консоли" \
        "3" "🔑 Редактировать сертификаты Cloudflare (.crt / .key)" \
        "4" "🛑 Остановить и удалить службу DERP" \
        "0" "🔙 Вернуться назад" 3>&1 1>&2 2>&3) || [ "$d_choice" = "0" ]; then
            break
        fi

        clear
        case "$d_choice" in
            1)
                echo -e "${C_CYAN}📡 === УСТАНОВКА ЛИЧНОГО РЕТРАНСЛЯТОРА DERP (CLOUDFLARE + STUN) ===${C_RESET}"
                ensure_tailscale_installed || true

                local d_dom=""
                prompt_default "Введите ваш поддомен для DERP (например, derp.yourdomain.com):" "$saved_domain" d_dom
                if [ "$MODULE_CANCELED" = true ] || [ -z "$d_dom" ]; then continue; fi

                echo -e "${C_BLUE}📦 Установка компилятора Go и сборка актуального бинарника derper...${C_RESET}"
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq
                apt-get install -yq golang git nano

                local derp_tmp_dir="/root/.derp-build-tmp"
                mkdir -p "$derp_tmp_dir"
                export GOTOOLCHAIN=auto
                export GOPATH="/root/go"
                export GOTMPDIR="$derp_tmp_dir"
                export TMPDIR="$derp_tmp_dir"

                GOBIN=/usr/local/bin go install tailscale.com/cmd/derper@latest || {
                    go install tailscale.com/cmd/derper@latest
                    if [ -f "/root/go/bin/derper" ]; then
                        cp /root/go/bin/derper /usr/local/bin/derper
                    elif [ -f "$HOME/go/bin/derper" ]; then
                        cp "$HOME/go/bin/derper" /usr/local/bin/derper
                    fi
                }
                rm -rf "$derp_tmp_dir"
                unset GOTMPDIR TMPDIR

                if [ ! -x /usr/local/bin/derper ]; then
                    echo -e "${C_RED}❌ Ошибка: не удалось собрать бинарник /usr/local/bin/derper.${C_RESET}"
                    pause_enter
                    continue
                fi
                echo -e "${C_GREEN}✅ Бинарник /usr/local/bin/derper успешно скомпилирован.${C_RESET}"

                mkdir -p /etc/derp/certs
                local crt_file="/etc/derp/certs/${d_dom}.crt"
                local key_file="/etc/derp/certs/${d_dom}.key"

                local edit_certs=true
                if [ -s "$crt_file" ] && [ -s "$key_file" ]; then
                    if ! prompt_yn "Сертификаты для $d_dom уже существуют. Желаете ввести их заново?" "false"; then
                        edit_certs=false
                    fi
                fi

                if [ "$edit_certs" = true ]; then
                    whiptail --title "Сертификаты Cloudflare Origin CA" --msgbox \
"Сейчас по очереди откроются два окна редактора nano:\n\n1. В первое окно вставьте Origin Certificate (.crt) от Cloudflare.\n2. Во второе окно вставьте Private Key (.key).\n\nДля сохранения в nano нажмите: Ctrl+O -> Enter -> Ctrl+X." 14 $WT_WIDTH
                    nano "$crt_file"
                    nano "$key_file"
                fi

                chmod 600 "$key_file" 2>/dev/null || true

                cat << EOF > /etc/default/bobarev-derp
DERP_DOMAIN="$d_dom"
DERP_HTTPS_PORT="443"
DERP_STUN_PORT="3478"
EOF

                echo -e "${C_BLUE}⚙️ Создание и запуск защищенной системной службы derper.service...${C_RESET}"
                cat << EOF > /etc/systemd/system/derper.service
[Unit]
Description=Tailscale DERP Relay Server ($d_dom)
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/derper --hostname=$d_dom --certmode=manual --certdir=/etc/derp/certs --a=:443 --http-port=-1 --stun-port=3478 --verify-clients
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

                systemctl daemon-reload
                systemctl enable --now derper.service
                systemctl restart derper.service || true

                if command -v ufw &>/dev/null; then
                    silent_run ufw allow 443/tcp comment 'DERP HTTPS Relay'
                    silent_run ufw allow 3478/udp comment 'DERP Local STUN'
                    echo -e "${C_GREEN}✅ Порты 443/tcp (DERP HTTPS) и 3478/udp (STUN) открыты в UFW.${C_RESET}"
                fi

                if is_derp_active; then
                    echo -e "${C_GREEN}✅ Служба личного ретранслятора DERP успешно запущена и защищена флагом --verify-clients!${C_RESET}"
                else
                    echo -e "${C_YELLOW}⚠️ Служба derper не запустилась. Проверьте правильность сертификатов и не занят ли порт 443:${C_RESET}"
                    journalctl -u derper.service -n 10 --no-pager || true
                fi

                show_derp_json_interactive
                pause_enter
                ;;
            2)
                show_derp_json_interactive
                pause_enter
                ;;
            3)
                mkdir -p /etc/derp/certs
                nano "/etc/derp/certs/${saved_domain}.crt"
                nano "/etc/derp/certs/${saved_domain}.key"
                chmod 600 "/etc/derp/certs/${saved_domain}.key" 2>/dev/null || true
                silent_run systemctl restart derper.service
                echo -e "${C_GREEN}✅ Сертификаты обновлены, служба derper перезапущена.${C_RESET}"
                pause_enter
                ;;
            4)
                if prompt_yn "Остановить и полностью удалить службу личного ретранслятора DERP и закрыть порты 443/tcp и 3478/udp в UFW?" "false"; then
                    silent_run systemctl stop derper.service
                    silent_run systemctl disable derper.service
                    rm -f /etc/systemd/system/derper.service /etc/default/bobarev-derp
                    systemctl daemon-reload
                    if command -v ufw &>/dev/null; then
                        silent_run ufw delete allow 443/tcp
                        silent_run ufw delete allow 3478/udp
                    fi
                    echo -e "${C_GREEN}✅ Служба DERP удалена, порты 443/tcp и 3478/udp закрыты в UFW.${C_RESET}"
                fi
                pause_enter
                ;;
        esac
    done
}

print_network_health_summary() {
    local wan_dev=$(get_wan_if)
    local ip_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    local nf_mode=$(get_tailscale_netfilter_mode)
    local nat_count=0
    [ -n "$wan_dev" ] && nat_count=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -cE -- "-o ${wan_dev}[[:space:]].*-j (MASQUERADE|SNAT)" || true)

    echo -e "\n${C_CYAN}--- Сводка сетевого здоровья (Маршрутизация и Туннели) ---${C_RESET}"
    if [ "$ip_fwd" = "1" ]; then
        echo -e "  • Форвардинг пакетов (IPv4): ${C_GREEN}✅ Включен (net.ipv4.ip_forward = 1)${C_RESET}"
    else
        echo -e "  • Форвардинг пакетов (IPv4): ${C_RED}❌ Выключен (маршрутизация пакетов отключена)${C_RESET}"
    fi

    if [ "$nf_mode" = "off" ]; then
        echo -e "  • Приоритет правил фаервола: ${C_GREEN}✅ Брандмауэр UFW (системный режим)${C_RESET}"
    elif [ "$nf_mode" = "on" ]; then
        echo -e "  • Приоритет правил фаервола: ${C_BLUE}ℹ️  Tailscale (встроенный авто-режим)${C_RESET}"
    fi

    if [ "$nat_count" -eq 1 ]; then
        echo -e "  • Трансляция NAT на выходе:  ${C_GREEN}✅ Активна на $wan_dev (1 чистое правило без дубликатов)${C_RESET}"
    elif [ "$nat_count" -gt 1 ]; then
        echo -e "  • Трансляция NAT на выходе:  ${C_YELLOW}⚠️  Активна на $wan_dev, но дубликатов: $nat_count (рекомендуется очистка)${C_RESET}"
    else
        echo -e "  • Трансляция NAT на выходе:  ${C_BLUE}ℹ️  Не используется на $wan_dev (режим обычного узла без шлюза)${C_RESET}"
    fi

    local extra_ifs=$(ip -br link show 2>/dev/null | grep -v "DOWN" | awk '{print $1}' | sed 's/@.*//' | grep -vE "^(lo|${wan_dev}|docker.*|veth.*|br-.*)$" || echo "")
    for eif in $extra_ifs; do
        local e_ip=$(ip -4 -o addr show dev "$eif" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || echo "без IP")
        echo -e "  • Активный интерфейс ($eif): ${C_GREEN}✅ IP: $e_ip (транзит разрешен)${C_RESET}"
    done
    return 0
}

remove_ufw_docker_protection() {
    iptables -F DOCKER-USER 2>/dev/null || true
    ip6tables -F DOCKER-USER 2>/dev/null || true
    if [ -f /etc/ufw/after.rules ]; then
        sed -i '/# BEGIN UFW AND DOCKER/,/# END UFW AND DOCKER/d' /etc/ufw/after.rules 2>/dev/null || true
    fi
}

apply_ufw_docker_protection() {
    local wan_if="$1"
    [ ! -f /etc/ufw/after.rules ] || [ -z "$wan_if" ] && return 0
    remove_ufw_docker_protection
    cat << DOCKER_UFW_EOF >> /etc/ufw/after.rules

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i tailscale0 -j RETURN
-A DOCKER-USER -i tun+ -j RETURN
-A DOCKER-USER -i wg+ -j RETURN
-A DOCKER-USER -i warp -j RETURN
-A DOCKER-USER -i $wan_if -p tcp -m conntrack --ctstate NEW -j DROP
-A DOCKER-USER -i $wan_if -p udp -m conntrack --ctstate NEW -j DROP
-A DOCKER-USER -j RETURN
COMMIT
# END UFW AND DOCKER
DOCKER_UFW_EOF
}

enable_routing_optimizations() {
    ensure_wg_kernel_modules
    cat << 'ETHTOOL_SCRIPT_EOF' > /usr/local/bin/tailscale-gro.sh
#!/bin/bash
tries=0
while ! ip -4 route show table main default 2>/dev/null | grep -vE "tailscale0|wg[0-9]+|warp|tun[0-9]+" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -ge 15 ] && exit 0
    sleep 2
done
NETDEV=$(ip -4 route show table main default 2>/dev/null | grep -vE "tailscale0|wg[0-9]+|warp|tun[0-9]+" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
if [ -n "$NETDEV" ]; then
    ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true
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

    if dpkg -l 2>/dev/null | grep -qw iptables-persistent; then
        silent_run systemctl stop netfilter-persistent 2>/dev/null
        silent_run systemctl disable netfilter-persistent 2>/dev/null
        silent_run apt-get purge -yq iptables-persistent netfilter-persistent
        echo -e "${C_BLUE}ℹ️ Удален конфликтующий пакет iptables-persistent (управление возвращено UFW).${C_RESET}"
    fi

    disable_ufw_strict_rpfilter
    if command -v ufw &>/dev/null && [ -f /etc/ufw/before.rules ]; then
        ensure_ufw_mangle_tcpmss
        flush_and_reload_nat
    fi
    disable_ufw_strict_rpfilter

    iptables -t mangle -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    
    if command -v ip6tables &>/dev/null; then
        ip6tables -t mangle -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        ip6tables -t mangle -A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi

    echo -e "${C_GREEN}✅ Аппаратное ускорение (GRO с защитой от зависаний) и фиксация MTU (MSS Clamping) включены.${C_RESET}"
}

is_port_free() {
    local port="${1//[^0-9]/}"
    { [ -z "$port" ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; } && return 1

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

    if command -v ufw &>/dev/null; then
        silent_run ufw allow 41641/udp comment 'Tailscale Direct P2P'
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

    if is_tailscale_authenticated; then
        silent_run tailscale set --auto-update
        echo -e "${C_GREEN}✅ Узел успешно подключен.${C_RESET}"
        return 0
    else
        echo -e "${C_YELLOW}⚠️ Узел еще не авторизован в сети Tailscale.${C_RESET}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# БЕЗОПАСНЫЕ ФУНКЦИИ ВВОДА WHIPTAIL
# ------------------------------------------------------------------------------
prompt_yn() {
    local prompt="$1"
    local default_yes="$2"
    if [ "$default_yes" = "true" ]; then
        if whiptail --title "Подтверждение" --yesno "$prompt" 12 $WT_WIDTH; then return 0; else return 1; fi
    else
        if whiptail --title "Подтверждение" --yesno "$prompt" 12 $WT_WIDTH --defaultno; then return 0; else return 1; fi
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
    if [ "$MODULE_CANCELED" = true ]; then
        return 0
    fi
    echo ""
    read -r -p "Нажмите Enter для возврата в меню..." < /dev/tty || true
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${C_RED}❌ Ошибка: этот скрипт должен запускаться от имени суперпользователя (root).${C_RESET}" >&2
    exit 1
fi

if ! command -v whiptail &>/dev/null; then
    echo -e "${C_BLUE}📦 Интерфейс whiptail не обнаружен. Автоматическая установка...${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -yq whiptail >/dev/null 2>&1 || {
        echo -e "${C_RED}❌ Не удалось установить whiptail. Выполните вручную: apt update && apt install whiptail${C_RESET}" >&2
        exit 1
    }
fi

# ==============================================================================
# МОДУЛИ НАСТРОЙКИ (1 - 19)
# ==============================================================================

# 1. Часовой пояс и синхронизация времени
mod_timezone() {
    echo -e "${C_CYAN}🌐 === 1/19. НАСТРОЙКА ЧАСОВОГО ПОЯСА ===${C_RESET}"
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Europe/Moscow")
    echo "Текущий часовой пояс: $current_tz"
    local tz=""
    prompt_default "Введите новый часовой пояс:" "$current_tz" tz
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    silent_run timedatectl set-timezone "$tz"
    silent_run timedatectl set-ntp true
    echo -e "${C_GREEN}✅ Часовой пояс установлен в $tz, автоматическая синхронизация точного времени включена.${C_RESET}"
}

# 2. Имя хоста
mod_hostname() {
    echo -e "${C_CYAN}📌 === 2/19. НАСТРОЙКА ИМЕНИ ХОСТА ===${C_RESET}"
    echo "Текущее имя хоста: $(hostname)"
    
    local default_brand_host="Server-VPS"
    case "$SYSTEM_TYPE" in
        SBC_Armbian) default_brand_host="Server-SBC" ;;
        Desktop_PC|Laptop_PC) default_brand_host="Server-PC" ;;
    esac

    local new_host=""
    prompt_default "Введите новое имя сервера:" "$default_brand_host" new_host
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    new_host=$(echo "$new_host" | tr -dc 'a-zA-Z0-9-')
    if [ -z "$new_host" ]; then
        whiptail --msgbox "Ошибка: Имя хоста не может быть пустым." 8 $WT_WIDTH
        return 0
    fi

    hostnamectl set-hostname "$new_host"
    if [ -f /etc/hosts ]; then
        backup_file "/etc/hosts"
        sed -i -E "s/^(127\.0\.0\.1[[:space:]]+localhost).*$/\1 $new_host/" /etc/hosts
        if grep -q "^127\.0\.1\.1" /etc/hosts; then
            sed -i -E "s/^127\.0\.1\.1[[:space:]]+.*$/127.0.1.1\t$new_host/" /etc/hosts
        else
            echo -e "127.0.1.1\t$new_host" >> /etc/hosts
        fi
    fi
    silent_run sed -i 's/preserve_hostname: false/preserve_hostname: true/g' /etc/cloud/cloud.cfg
    echo -e "${C_GREEN}✅ Имя сервера чисто обновлено на $new_host.${C_RESET}"
}

# 3. Обновление пакетов
mod_apt_update() {
    echo -e "${C_CYAN}📦 === 3/19. ОБНОВЛЕНИЕ ПАКЕТОВ И ОЧИСТКА ===${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive

    if [ -f /etc/gai.conf ]; then
        sed -i 's/^#\s*precedence ::ffff:0:0\/96\s\+100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf 2>/dev/null || true
        echo -e "${C_BLUE}ℹ️ Включен приоритет IPv4 над IPv6 (защита от зависаний apt и curl).${C_RESET}"
    fi

    apt-get update && apt-get upgrade -yq

    local zram_pkg="zram-tools"
    if [ -f /etc/default/armbian-zram ] || [ -f /etc/init.d/armbian-zram ]; then
        echo -e "${C_BLUE}ℹ️ Обнаружен встроенный менеджер памяти Armbian. Сторонняя утилита zram-tools пропущена.${C_RESET}"
        zram_pkg=""
    fi

    apt-get install -yq sudo ufw unattended-upgrades ethtool curl wget ca-certificates gnupg whiptail jq $zram_pkg
    silent_run dpkg-reconfigure --priority=low unattended-upgrades

    if [ -d /etc/apt/apt.conf.d ]; then
        cat << 'UNATTENDED_EOF' > /etc/apt/apt.conf.d/51bobarev-unattended-clean
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UNATTENDED_EOF
        echo -e "${C_BLUE}ℹ️ Включена автоочистка старых ядер при фоновых обновлениях безопасности.${C_RESET}"
    fi

    apt-get autoremove -yq && apt-get clean
    systemctl enable unattended-upgrades

    if [ -n "$zram_pkg" ] && [ -f /etc/default/zramswap ]; then
        cat << 'ZRAM_EOF' > /etc/default/zramswap
ALGO=zstd
PERCENT=50
PRIORITY=100
ZRAM_EOF
        silent_run systemctl restart zramswap
        echo -e "${C_GREEN}✅ Сжатие оперативной памяти zRAM (алгоритм zstd, 50% RAM) активировано.${C_RESET}"
    fi

    local current_target=$(systemctl get-default)
    echo "Текущий режим загрузки: $current_target"

    if [ "$current_target" = "graphical.target" ]; then
        if prompt_yn "⚠️ Обнаружена графическая оболочка ($(get_system_type_short)). Переключить систему в консольный режим работы?" "false"; then
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

# 4. Пользователь и Sudo (с гарантированным приоритетом 99-zzz- в /etc/sudoers.d)
mod_user_setup() {
    echo -e "${C_CYAN}👤 === 4/19. СОЗДАНИЕ И НАСТРОЙКА ПОЛЬЗОВАТЕЛЯ ===${C_RESET}"
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
    
    groupadd -f sudo 2>/dev/null || true
    usermod -aG sudo "$username" || true
    echo -e "${C_BLUE}ℹ️ Пользователь $username добавлен в группу администраторов (sudo).${C_RESET}"

    local pass
    if ! pass=$(whiptail --title "Пароль" --passwordbox "Введите новый пароль для $username (пусто - отмена):" 10 $WT_WIDTH 3>&1 1>&2 2>&3); then
        echo -e "${C_YELLOW}ℹ Смена пароля отменена.${C_RESET}"
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

    if [ -f /etc/sudoers ]; then
        backup_file "/etc/sudoers"
        sed -i -E '/^[#@]includedir[[:space:]]+\/etc\/sudoers\.d/d' /etc/sudoers 2>/dev/null || true
        echo "#includedir /etc/sudoers.d" >> /etc/sudoers
    fi

    mkdir -p /etc/sudoers.d
    chmod 750 /etc/sudoers.d 2>/dev/null || true

    rm -f "/etc/sudoers.d/$username" "/etc/sudoers.d/99-zzz-$username" 2>/dev/null || true
    for sfile in /etc/sudoers.d/*; do
        [ ! -f "$sfile" ] && continue
        [[ "$(basename "$sfile")" == "README" || "$sfile" == *.bak ]] && continue
        if grep -qE "^[[:space:]]*${username}[[:space:]]+" "$sfile" 2>/dev/null; then
            sed -i -E "/^[[:space:]]*${username}[[:space:]]+/d" "$sfile" 2>/dev/null || true
            if ! grep -qE "^[[:space:]]*[^#[:space:]]" "$sfile" 2>/dev/null; then
                rm -f "$sfile" 2>/dev/null || true
            fi
        fi
    done

    if prompt_yn "Разрешить этому пользователю выполнять команды от имени администратора без запроса пароля (NOPASSWD)?" "true"; then
        echo "$username ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/99-zzz-$username"
        chmod 0440 "/etc/sudoers.d/99-zzz-$username"
        if command -v visudo &>/dev/null && ! visudo -c -f "/etc/sudoers.d/99-zzz-$username" >/dev/null 2>&1; then
            rm -f "/etc/sudoers.d/99-zzz-$username"
            echo -e "${C_RED}❌ Ошибка проверки синтаксиса sudoers!${C_RESET}"
        else
            echo -e "${C_GREEN}✅ Беспарольный доступ (NOPASSWD) включен с максимальным приоритетом (99-zzz-$username).${C_RESET}"
        fi
    else
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        echo "ℹ️ Система будет запрашивать пароль при каждом повышении прав (через группу %sudo)."
    fi
}

# 5. SSH-ключи
mod_ssh_key() {
    echo -e "${C_CYAN}🔑 === 5/19. НАСТРОЙКА КЛЮЧЕЙ ДОСТУПА ===${C_RESET}"
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
            MODULE_CANCELED=true
            return 0
        fi
    fi

    if [ -n "$pubkey" ]; then
        local mode_choice
        if ! mode_choice=$(whiptail --title "Параметры сохранения" --menu "Выберите действие:" 12 $WT_WIDTH 2 \
        "1" "Добавить ключ в существующий список" \
        "2" "Полностью перезаписать список ключей" 3>&1 1>&2 2>&3); then
            echo -e "${C_YELLOW}↩️ Отмена сохранения.${C_RESET}"
            MODULE_CANCELED=true
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

# 6. Конфигурация SSH (с поддержкой полной Zero-Trust изоляции на tailscale0)
mod_ssh_config() {
    echo -e "${C_CYAN}🔒 === 6/19. БЕЗОПАСНОСТЬ УДАЛЕННОГО ДОСТУПА ===${C_RESET}"
    backup_file "/etc/ssh/sshd_config"

    silent_run sed -i -E 's/^\s*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)\s+/# &/g' /etc/ssh/sshd_config

    local sshd_cmd=$(get_sshd_cmd)
    local active_ssh_port="22"
    if [ -n "$sshd_cmd" ]; then
        active_ssh_port=$($sshd_cmd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")
    fi
    active_ssh_port="${active_ssh_port//[^0-9]/}"

    local port=""
    while true; do
        prompt_default "Введите сетевой порт для удаленного подключения:" "${active_ssh_port:-22}" port
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        port="${port//[^0-9]/}"

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
    local conf_bak_dir="/etc/ssh/.sshd_config.d.bak"
    mkdir -p "$conf_dir" "$conf_bak_dir"
    
    if [ -f /etc/ssh/sshd_config ]; then
        silent_run sed -i '/^\s*Include \/etc\/ssh\/sshd_config\.d\/\*\.conf/d' /etc/ssh/sshd_config
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi

    local ts_restrict_comment=""
    local restrict_choice=false
    if prompt_yn "Скрыть доступ к серверу (разрешить вход по SSH только через закрытую сеть)?" "true"; then
        restrict_choice=true
        ts_restrict_comment="# SSH via Tailscale only"
    else
        ts_restrict_comment="# SSH Public Access"
    fi

    echo -e "${C_BLUE}🧹 Резервное копирование и очистка сторонних конфигураций SSH...${C_RESET}"
    rm -rf "${conf_bak_dir:?}"/* 2>/dev/null || true
    cp -a "$conf_dir"/*.conf "$conf_bak_dir"/ 2>/dev/null || true
    rm -f "$conf_dir"/*.conf 2>/dev/null
    
    local conf_file="$conf_dir/00-bobarev-security.conf"
    
    tee "$conf_file" > /dev/null << SSH_HARDENING_EOF
# Server Security Hardening Configuration
$ts_restrict_comment
AcceptEnv LANG LC_*
Port $port
PermitRootLogin $disable_root
PubkeyAuthentication yes
PasswordAuthentication $pass_auth_val
KbdInteractiveAuthentication $kbd_auth_val
AuthorizedKeysFile .ssh/authorized_keys
StrictModes yes
UsePAM yes
UseDNS no
ClientAliveInterval 60
ClientAliveCountMax 3
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
        rm -rf "$conf_bak_dir" 2>/dev/null || true
        silent_run systemctl disable --now ssh.socket
        silent_run systemctl enable --now ssh.service
        silent_run systemctl restart sshd
        silent_run systemctl restart ssh

        if [ "$restrict_choice" = true ]; then
            if ensure_tailscale_installed && is_tailscale_authenticated; then
                if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
                    if [ -n "$active_ssh_port" ] && [ "$active_ssh_port" != "$port" ]; then
                        silent_run ufw delete allow in on tailscale0 to any port "$active_ssh_port" proto tcp
                        silent_run ufw delete allow "$active_ssh_port"/tcp
                    fi
                    silent_run ufw allow in on tailscale0 to any port "$port" proto tcp comment 'SSH via Tailscale only'
                    silent_run ufw delete allow in on tailscale0
                    silent_run ufw delete allow "$port"/tcp
                    echo -e "${C_GREEN}✅ Полная изоляция (Zero-Trust): на tailscale0 открыт только порт SSH ($port/tcp).${C_RESET}"
                else
                    echo -e "${C_BLUE}ℹ️ Правило изоляции сохранено. Оно вступит в силу при включении брандмауэра (Модуль 8).${C_RESET}"
                fi
            else
                sed -i 's/# SSH via Tailscale only/# SSH Public Access/' "$conf_file"
                echo -e "${C_YELLOW}⚠️ Узел Tailscale не авторизован! Для предотвращения блокировки сервера оставлен публичный доступ к SSH ($port).${C_RESET}"
                silent_run ufw allow "$port"/tcp comment 'SSH Public Port'
            fi
        else
            if [ -n "$active_ssh_port" ] && [ "$active_ssh_port" != "$port" ]; then
                silent_run ufw delete allow "$active_ssh_port"/tcp
                silent_run ufw delete allow in on tailscale0 to any port "$active_ssh_port" proto tcp
            fi
            silent_run ufw allow "$port"/tcp comment 'SSH Public Port'
            if prompt_yn "Установить легковесную защиту от перебора паролей SSH (sshguard)?" "true"; then
                export DEBIAN_FRONTEND=noninteractive
                silent_run apt-get update
                silent_run apt-get install -yq sshguard
                silent_run systemctl enable --now sshguard
                echo -e "${C_GREEN}✅ Защита от перебора паролей (sshguard) активирована.${C_RESET}"
            fi
        fi
        echo -e "${C_GREEN}✅ Служба удаленного доступа успешно перезапущена с абсолютным приоритетом параметров.${C_RESET}"
    else
        echo -e "${C_RED}❌ Ошибка применения параметров безопасности! Выполнен откат изменений...${C_RESET}"
        rm -f "$conf_file"
        cp -a "$conf_bak_dir"/*.conf "$conf_dir"/ 2>/dev/null || true
        rm -rf "$conf_bak_dir" 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi
}

# 7. Защита ядра и сети (с префиксом 99-zzz- и включенным IPv4/IPv6 форвардингом)
mod_hardening() {
    echo -e "${C_CYAN}🔒 === 7/19. ЗАЩИТА ЯДРА И УСКОРЕНИЕ МАРШРУТИЗАЦИИ ===${C_RESET}"
    
    sed -i -E '/^\s*(net\.core\.(rmem|wmem)_(max|default)|net\.core\.netdev_max_backlog|net\.ipv4\.tcp_congestion_control|net\.core\.default_qdisc)\s*=/d' /etc/sysctl.conf 2>/dev/null || true
    backup_file "/etc/sysctl.d/99-zzz-server-hardening.conf"
    rm -f /etc/sysctl.d/99-server-hardening.conf 2>/dev/null || true
    
    local icmp_ignore=0
    if prompt_yn "Скрыть сервер от пингов (отключить ответы на ICMP Echo / ping)?" "false"; then
        icmp_ignore=1
        echo -e "${C_BLUE}ℹ️ Ответы на ICMP-пинги будут отключены.${C_RESET}"
    else
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        icmp_ignore=0
        echo -e "${C_BLUE}ℹ️ Стандартные ответы на ICMP-пинги сохранены (рекомендуется для мониторинга).${C_RESET}"
    fi

    silent_run modprobe tcp_bbr
    silent_run modprobe nf_conntrack
    ensure_wg_kernel_modules
    disable_ufw_strict_rpfilter

    mkdir -p /etc/sysctl.d
    tee /etc/sysctl.d/99-zzz-server-hardening.conf > /dev/null << HARDENING_EOF
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
kernel.unprivileged_bpf_disabled = 1
kernel.perf_event_paranoid = 3
kernel.sysrq = 0
kernel.panic = 10
kernel.panic_on_oops = 1
net.core.bpf_jit_harden = 2
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 10000
net.netfilter.nf_conntrack_max = 131072
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
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
net.ipv4.icmp_echo_ignore_all = $icmp_ignore
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 1
fs.protected_regular = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_timestamps = 1
HARDENING_EOF

    sysctl --system > /dev/null 2>&1 || true
    sysctl -p /etc/sysctl.d/99-zzz-server-hardening.conf > /dev/null 2>&1 || true

    if [ "$SYSTEM_TYPE" = "SBC_Armbian" ] && [ -f /etc/systemd/system.conf ]; then
        sed -i -E 's/^\s*#?\s*RuntimeWatchdogSec=.*/RuntimeWatchdogSec=15s/' /etc/systemd/system.conf
        if ! grep -q "^RuntimeWatchdogSec=" /etc/systemd/system.conf; then
            echo "RuntimeWatchdogSec=15s" >> /etc/systemd/system.conf
        fi
        silent_run systemctl daemon-reexec
        echo -e "${C_GREEN}✅ Аппаратный таймер защиты от зависаний (Watchdog 15s) для мини-ПК активирован.${C_RESET}"
    fi

    echo -e "${C_GREEN}✅ Защита ядра, форвардинг пакетов, расширенные UDP-буферы и TCP BBR применены.${C_RESET}"
}

# 8. Firewall UFW (сохраняет правила личного DERP, Каскада NaiveProxy/WARP и открывает 41641/udp при наличии Tailscale)
mod_ufw() {
    echo -e "${C_CYAN}🧱 === 8/19. НАСТРОЙКА БРАНДМАУЭРА ===${C_RESET}"
    DEFAULT_WAN_IF=$(get_wan_if)
    
    local active_ssh_port="22"
    local sshd_cmd=$(get_sshd_cmd)
    if [ -n "$sshd_cmd" ]; then
        active_ssh_port=$($sshd_cmd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")
    fi
    active_ssh_port="${active_ssh_port//[^0-9]/}"
    local port="${active_ssh_port:-22}"

    echo -e "${C_BLUE}ℹ️ Автоматически определен порт SSH: $port${C_RESET}"

    remove_ufw_docker_protection
    silent_run ufw delete allow in on tailscale0
    silent_run ufw delete allow 41641/udp
    silent_run ufw --force reset
    rm -f /etc/ufw/user.rules.* /etc/ufw/user6.rules.* /etc/ufw/before.rules.* /etc/ufw/after.rules.* /etc/ufw/before6.rules.* /etc/ufw/after6.rules.* 2>/dev/null || true

    disable_ufw_strict_rpfilter
    silent_run ufw default deny incoming
    silent_run ufw default allow outgoing

    local netdev="$DEFAULT_WAN_IF"
    local allow_routed=false
    if prompt_yn "Разрешить сквозную маршрутизацию трафика между интерфейсами?" "true"; then
        allow_routed=true
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        silent_run ufw default allow routed
        silent_run sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        if [ -n "$netdev" ]; then
            select_and_apply_routed_interfaces "$netdev"
            apply_wan_exit_nat "$netdev"
            ensure_ufw_mangle_tcpmss
        fi
    else
        silent_run ufw default deny routed
        silent_run sed -i 's/DEFAULT_FORWARD_POLICY="ACCEPT"/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
    fi

    local is_ts_restricted_in_mod6=false
    local is_public_in_mod6=false
    if grep -q "SSH via Tailscale only" /etc/ssh/sshd_config.d/00-bobarev-security.conf 2>/dev/null; then
        is_ts_restricted_in_mod6=true
    elif grep -q "SSH Public Access" /etc/ssh/sshd_config.d/00-bobarev-security.conf 2>/dev/null; then
        is_public_in_mod6=true
    fi

    local do_restrict=false
    if [ "$is_ts_restricted_in_mod6" = true ]; then
        echo -e "${C_BLUE}ℹ️ Ограничение удаленного доступа применено автоматически.${C_RESET}"
        do_restrict=true
    elif [ "$is_public_in_mod6" = true ]; then
        echo -e "${C_BLUE}ℹ️ Публичный доступ к SSH сохранен автоматически.${C_RESET}"
        do_restrict=false
    elif prompt_yn "Разрешить вход по SSH только через закрытую сеть (с полной изоляцией остальных портов)?" "true"; then
        do_restrict=true
    fi

    local chosen_nf_mode=""
    if command -v tailscale &>/dev/null; then
        silent_run ufw allow 41641/udp comment 'Tailscale Direct P2P'
        ensure_ufw_mangle_tcpmss
        if is_tailscale_web_active; then
            silent_run ufw allow in on tailscale0 to any port 5252 proto tcp comment 'Tailscale Web UI'
            echo -e "${C_BLUE}ℹ️ Обнаружен активный веб-интерфейс: открыт порт 5252/tcp на tailscale0.${C_RESET}"
        fi
        if prompt_yn "Передать приоритет управления сетевыми правилами системе (UFW)?" "true"; then
            chosen_nf_mode="off"
        else
            chosen_nf_mode="on"
        fi
        echo "TS_NETFILTER_MODE=\"$chosen_nf_mode\"" > /etc/default/bobarev-netfilter
    fi

    if [ -f /etc/default/bobarev-derp ] || is_derp_active; then
        silent_run ufw allow 443/tcp comment 'DERP HTTPS Relay'
        silent_run ufw allow 3478/udp comment 'DERP Local STUN'
        echo -e "${C_BLUE}ℹ️ Восстановлены правила UFW для личного ретранслятора DERP (443/tcp и 3478/udp).${C_RESET}"
    fi

    if [ -f /etc/wireguard/warp.conf ] || is_warp_active; then
        silent_run ufw route allow in on tailscale0 out on warp comment 'Tailscale to WARP'
        silent_run ufw route allow in on warp out on tailscale0 comment 'WARP to Tailscale'
        echo -e "${C_BLUE}ℹ️ Восстановлены правила транзита UFW для туннеля Cloudflare WARP.${C_RESET}"
    fi

    if [ -f /etc/default/bobarev-router ]; then
        # shellcheck disable=SC1091
        source /etc/default/bobarev-router
        if [ -n "${ROUTER_LAN_IF:-}" ] && [ -n "${ROUTER_OUT_IF:-}" ]; then
            silent_run ufw allow in on "$ROUTER_LAN_IF" to any port 67 proto udp comment 'LAN DHCP'
            silent_run ufw allow in on "$ROUTER_LAN_IF" to any port 53 comment 'LAN DNS (UDP/TCP)'
            silent_run ufw route allow in on "$ROUTER_LAN_IF" out on "$ROUTER_OUT_IF" comment "LAN to $ROUTER_OUT_IF"
            silent_run ufw route allow in on "$ROUTER_OUT_IF" out on "$ROUTER_LAN_IF" comment "$ROUTER_OUT_IF to LAN"
            ensure_ufw_nat_rule "-A POSTROUTING -o $ROUTER_OUT_IF -j MASQUERADE"
            ensure_ufw_mangle_tcpmss
            local ks_human="выключена"
            if [ "${ROUTER_KILLSWITCH:-false}" = "true" ] && [ -n "$netdev" ] && [ "$netdev" != "$ROUTER_OUT_IF" ] && [ "$netdev" != "$ROUTER_LAN_IF" ]; then
                silent_run ufw route deny in on "$ROUTER_LAN_IF" out on "$netdev" comment 'Kill Switch'
                ks_human="включена"
            fi
            echo -e "${C_BLUE}ℹ️ Восстановлен профиль роутера: сеть $ROUTER_LAN_IF направлена в $ROUTER_OUT_IF (защита от утечки IP: $ks_human).${C_RESET}"
        fi
    fi

    if [ -n "$netdev" ]; then
        if prompt_yn "Запретить контейнерам Docker обходить брандмауэр из внешней сети?" "true"; then
            apply_ufw_docker_protection "$netdev"
            echo -e "${C_GREEN}✅ Защита контейнеров Docker снаружи включена.${C_RESET}"
        fi
    fi

    if [ "$do_restrict" = true ]; then
        if ensure_tailscale_installed && is_tailscale_authenticated; then
            silent_run ufw allow 41641/udp comment 'Tailscale Direct P2P'
            silent_run ufw allow in on tailscale0 to any port "$port" proto tcp comment 'SSH via Tailscale only'
            silent_run ufw delete allow in on tailscale0
            silent_run ufw delete allow "$port"/tcp
            echo -e "${C_GREEN}✅ Полная изоляция (Zero-Trust): открыт только порт SSH ($port/tcp) внутри закрытой сети.${C_RESET}"
        else
            silent_run ufw allow "$port"/tcp comment 'SSH Public Port'
            echo -e "${C_YELLOW}⚠️ Узел Tailscale не авторизован! Во избежание потери доступа порт SSH ($port) оставлен открытым публично.${C_RESET}"
        fi
    else
        silent_run ufw allow "$port"/tcp comment 'SSH Public Port'
        echo -e "${C_GREEN}✅ Брандмауэр настроен: порт SSH ($port) открыт публично.${C_RESET}"
    fi

    if is_naive_active; then
        silent_run ufw allow 80/tcp comment 'NaiveProxy ACME HTTP'
        silent_run ufw allow 443/tcp comment 'NaiveProxy HTTPS'
        silent_run ufw allow 443/udp comment 'NaiveProxy HTTP3 QUIC'
    fi

    iptables -t nat -F 2>/dev/null || true
    silent_run ufw --force enable
    silent_run ufw delete allow in on tailscale0
    if ! command -v tailscale &>/dev/null; then
        silent_run ufw delete allow 41641/udp
    fi
    silent_run ufw reload
    if [ -n "$chosen_nf_mode" ]; then
        set_tailscale_netfilter_priority "$chosen_nf_mode"
    elif [ -n "$netdev" ] && [ "$allow_routed" = true ]; then
        apply_wan_exit_nat "$netdev" "true" || true
    fi
    silent_run ufw logging off
    disable_ufw_strict_rpfilter
    if [ -x /usr/local/bin/bobarev-cascade-ru.sh ]; then
        /usr/local/bin/bobarev-cascade-ru.sh || true
    fi
    if [ -x /usr/local/bin/bobarev-router-up.sh ]; then
        /usr/local/bin/bobarev-router-up.sh || true
    fi
    echo -e "${C_GREEN}✅ Межсетевой экран (UFW) включен и активно защищает систему.${C_RESET}"
    print_network_health_summary
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

    echo -e "${C_CYAN}🔐 === 9/19. УПРАВЛЕНИЕ СИСТЕМНЫМ ДОСТУПОМ ===${C_RESET}"
    
    local root_choice
    if ! root_choice=$(whiptail --title "Системный доступ" --menu "Выберите желаемое действие:" 12 $WT_WIDTH 2 \
    "1" "Заблокировать" \
    "2" "Разблокировать" 3>&1 1>&2 2>&3); then
        MODULE_CANCELED=true
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

# 10. Tailscale (включая пункт 9 DERP и пункт 10 Каскад NaiveProxy + Tailscale + WARP)
mod_tailscale() {
    local mode="${1:-}"
    DEFAULT_WAN_IF=$(get_wan_if)
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
                if command -v ufw &>/dev/null; then
                    silent_run ufw delete allow 41641/udp
                fi
                echo -e "${C_YELLOW}⏭️ Установка Tailscale пропущена пользователем.${C_RESET}"
                return 0
            fi
        fi
        if command -v tailscale &>/dev/null; then
            if [ -f /etc/default/bobarev-netfilter ]; then
                local saved_nf=$(get_tailscale_netfilter_mode)
                set_tailscale_netfilter_priority "$saved_nf" "true"
            else
                if prompt_yn "Передать приоритет управления сетевыми правилами системе (UFW)?" "true"; then
                    set_tailscale_netfilter_priority "off"
                else
                    set_tailscale_netfilter_priority "on"
                fi
            fi
        fi
        return 0
    fi

    while true; do
        MODULE_CANCELED=false
        DEFAULT_WAN_IF=$(get_wan_if)
        local nf_cur=$(get_tailscale_netfilter_mode)

        local ts_choice
        if ! ts_choice=$(whiptail --title "Настройка закрытой сети" --menu "" 19 $WT_WIDTH 12 \
        "1" "🔑 Авторизация" \
        "2" "🌐 Настройка шлюза" \
        "3" "🔀 Трансляция локальных сетей" \
        "4" "📥 Прием маршрутов" \
        "5" "🔒 Стелс-режим" \
        "6" "⚡ Ускорение и MSS Clamping" \
        "7" "💻 Локальный веб-интерфейс" \
        "8" "🔧 Приоритет сетевых правил" \
        "9" "📡 Личный ретранслятор (DERP)" \
        "10" "🔗 Каскад: NaiveProxy + Tailscale + WARP" \
        "11" "🔄 Полный сброс" \
        "0" "🔙 Вернуться назад" 3>&1 1>&2 2>&3); then
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
                if en_choice=$(whiptail --title "Настройка шлюза" --menu "Действие:" 12 $WT_WIDTH 4 \
                "1" "Назначить этот сервер шлюзом" \
                "2" "Отключить трансляцию шлюза" \
                "3" "Подключиться к удаленному шлюзу" \
                "4" "Отключиться от шлюза" 3>&1 1>&2 2>&3); then
                    case "$en_choice" in
                        1) 
                            echo -e "${C_BLUE}⚙️ Настройка сервера в качестве сетевого шлюза...${C_RESET}"
                            sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
                            disable_ufw_strict_rpfilter

                            local active_nf=$(get_tailscale_netfilter_mode)
                            [ "$active_nf" = "none" ] && active_nf="off"

                            silent_run tailscale set --advertise-exit-node=true

                            local wan_dev=$(get_wan_if)
                            if [ -n "$wan_dev" ]; then
                                apply_wan_exit_nat "$wan_dev"
                                ensure_ufw_mangle_tcpmss

                                if command -v ufw &>/dev/null; then
                                    silent_run ufw default allow routed
                                    silent_run sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
                                    for r_if in $(ip -br link show 2>/dev/null | grep -v "DOWN" | awk '{print $1}' | sed 's/@.*//' | grep -vE "^(lo|${wan_dev}|docker.*|veth.*|br-.*)$" || true); do
                                        silent_run ufw route allow in on "$r_if" out on "$wan_dev" comment "Route $r_if to $wan_dev"
                                        silent_run ufw route allow in on "$wan_dev" out on "$r_if" comment "Route $wan_dev to $r_if"
                                    done
                                fi
                            fi
                            set_tailscale_netfilter_priority "$active_nf" "true"
                            disable_ufw_strict_rpfilter

                            echo -e "${C_GREEN}✅ Сервер успешно настроен как шлюз (правила защищены от перезагрузки)!${C_RESET}"
                            print_network_health_summary
                            
                            whiptail --title "⚠️ ВАЖНО: Активация в панели Tailscale" --msgbox \
"Сервер объявлен шлюзом, форвардинг и правила NAT/SNAT закреплены!\n\nОстался финальный шаг в веб-панели:\n1. Откройте: https://login.tailscale.com/admin/machines\n2. Напротив этого сервера нажмите [...] -> Edit route settings...\n3. Включите переключатель 'Use as exit node'!\n\n💡 Если интернет через шлюз не открывается на клиентах,\nпереподключите Tailscale на клиентском устройстве." 16 $WT_WIDTH
                            ;;
                        2) 
                            silent_run tailscale set --advertise-exit-node=false
                            local wan_dev=$(get_wan_if)
                            if [ -n "$wan_dev" ] && ! ip link show tun0 >/dev/null 2>&1; then
                                iptables -t nat -D POSTROUTING -o "$wan_dev" -j MASQUERADE 2>/dev/null || true
                                local pub_ip=$(ip -4 -o addr show dev "$wan_dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || echo "")
                                [ -n "$pub_ip" ] && iptables -t nat -D POSTROUTING -o "$wan_dev" -j SNAT --to-source "$pub_ip" 2>/dev/null || true
                                if [ -f /etc/ufw/before.rules ]; then
                                    sed -i "/-o ${wan_dev} -j MASQUERADE/d" /etc/ufw/before.rules 2>/dev/null || true
                                    sed -i "/-o ${wan_dev} -j SNAT/d" /etc/ufw/before.rules 2>/dev/null || true
                                    silent_run ufw reload
                                fi
                            fi
                            echo -e "${C_GREEN}✅ Функция шлюза Tailscale отключена.${C_RESET}" 
                            ;;
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
                    pause_enter
                fi
                ;;
            3)
                local tr_choice
                if tr_choice=$(whiptail --title "Трансляция локальных сетей" --menu "Действие:" 11 $WT_WIDTH 2 \
                "1" "Включить трансляцию (Задать подсеть)" \
                "2" "Отключить трансляцию" 3>&1 1>&2 2>&3); then
                    case "$tr_choice" in
                        1)
                            local sub=$(get_interface_subnet "$DEFAULT_WAN_IF")
                            local r_input=""
                            MODULE_CANCELED=false
                            prompt_default "Сетевой диапазон для трансляции:" "${sub}.0/24" r_input
                            if [ "$MODULE_CANCELED" = false ] && [ -n "$r_input" ]; then
                                silent_run tailscale set --advertise-routes="$r_input"
                                echo -e "${C_GREEN}✅ Выбранный диапазон ($r_input) транслируется в общую сеть.${C_RESET}"
                            fi
                            ;;
                        2)
                            silent_run tailscale set --advertise-routes=""
                            echo -e "${C_GREEN}✅ Трансляция локальных сетей успешно отключена.${C_RESET}"
                            ;;
                    esac
                    pause_enter
                fi
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
                if prompt_yn "Включить встроенную панель управления в браузере (порт 5252/tcp)?" "true"; then
                    silent_run tailscale set --webclient=true
                    if command -v ufw &>/dev/null; then
                        silent_run ufw allow in on tailscale0 to any port 5252 proto tcp comment 'Tailscale Web UI'
                    fi
                    local ts_ip_now=$(tailscale ip -4 2>/dev/null | head -n 1 || echo "100.x.x.x")
                    echo -e "${C_GREEN}✅ Веб-интерфейс запущен, порт 5252/tcp открыт в UFW.${C_RESET}"
                    echo -e "${C_BLUE}🌐 Адрес панели: http://${ts_ip_now}:5252${C_RESET}"
                else
                    silent_run tailscale set --webclient=false
                    if command -v ufw &>/dev/null; then
                        silent_run ufw delete allow in on tailscale0 to any port 5252 proto tcp
                    fi
                    echo -e "${C_BLUE}✅ Панель управления остановлена, порт 5252/tcp закрыт в UFW.${C_RESET}"
                fi
                pause_enter
                ;;
            8)
                local nf_choice
                if nf_choice=$(whiptail --title "Приоритет сетевых правил" --menu "Действие:" 13 $WT_WIDTH 4 \
                "1" "🔒 Приоритет брандмауэра UFW (системный режим)" \
                "2" "🔗 Приоритет Tailscale (встроенный авто-режим)" \
                "3" "🔀 Выбрать интерфейсы для сквозного транзита" \
                "4" "🧹 Очистить дубликаты NAT и перезагрузить UFW" 3>&1 1>&2 2>&3); then
                    case "$nf_choice" in
                        1) set_tailscale_netfilter_priority "off" ;;
                        2) set_tailscale_netfilter_priority "on" ;;
                        3)
                            local wan_dev=$(get_wan_if)
                            if [ -n "$wan_dev" ]; then
                                select_and_apply_routed_interfaces "$wan_dev"
                                flush_and_reload_nat
                                echo -e "${C_GREEN}✅ Правила сквозного транзита для выбранных интерфейсов обновлены.${C_RESET}"
                            fi
                            ;;
                        4)
                            flush_and_reload_nat
                            [ "$(get_tailscale_netfilter_mode)" = "off" ] && clean_tailscale_iptables_chains
                            echo -e "${C_GREEN}✅ Таблица NAT очищена от дубликатов, правила UFW перезагружены.${C_RESET}"
                            ;;
                    esac
                    print_network_health_summary
                    pause_enter
                fi
                ;;
            9)
                manage_custom_derp
                ;;
            10)
                manage_cascade_naive_ts_warp
                ;;
            11)
                if prompt_yn "Полностью сбросить все сетевые параметры к заводским значениям?" "false"; then
                    tailscale up --reset 2>&1 | grep -v "accept-routes" || true
                    rm -f /etc/default/bobarev-netfilter 2>/dev/null || true
                    if command -v ufw &>/dev/null; then
                        silent_run ufw delete allow in on tailscale0 to any port 5252 proto tcp
                    fi
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
    echo -e "${C_CYAN}📝 === 11/19. УПРАВЛЕНИЕ СИСТЕМНЫМИ ЖУРНАЛАМИ ===${C_RESET}"
    
    local log_choice
    if ! log_choice=$(whiptail --title "Управление логами" --menu "Выберите режим работы системных журналов:" 14 $WT_WIDTH 4 \
    "1" "Безопасное ограничение (100 МБ / 1 месяц)" \
    "2" "Указать свой лимит (Custom)" \
    "3" "Полностью отключить логирование (Stealth)" \
    "0" "Оставить без изменений" 3>&1 1>&2 2>&3); then
        MODULE_CANCELED=true
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
        
        silent_run sed -i -E '/^\s*#?\s*(\[Journal\]|Storage=|ForwardToSyslog=|ForwardToKMsg=|ForwardToConsole=|ForwardToWall=|SystemMaxUse=|MaxRetentionSec=)/d' /etc/systemd/journald.conf
        cat << CONF >> /etc/systemd/journald.conf
[Journal]
SystemMaxUse=$log_size
MaxRetentionSec=1month
CONF
        
        silent_run systemctl restart systemd-journald
        silent_run systemctl disable clean-logs-boot.service 2>/dev/null || true
        rm -f /usr/local/bin/disable-logging.sh
        
        echo -e "${C_GREEN}✅ Системные журналы безопасно ограничены объемом $log_size.${C_RESET}"
    
    elif [ "$log_choice" = "3" ]; then
        cat << 'DISABLE_LOGS_EOF' > /usr/local/bin/disable-logging.sh
#!/bin/bash
set -euo pipefail
sed -i -E '/^\s*#?\s*(\[Journal\]|Storage=|ForwardToSyslog=|ForwardToKMsg=|ForwardToConsole=|ForwardToWall=|SystemMaxUse=|MaxRetentionSec=)/d' /etc/systemd/journald.conf
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
    silent_run sed -i -E '/^\s*#?\s*(\[Journal\]|Storage=|ForwardToSyslog=|ForwardToKMsg=|ForwardToConsole=|ForwardToWall=|SystemMaxUse=|MaxRetentionSec=)/d' /etc/systemd/journald.conf
    cat << 'CONF' >> /etc/systemd/journald.conf
[Journal]
SystemMaxUse=100M
MaxRetentionSec=1month
CONF
    silent_run systemctl restart systemd-journald
}

# 12. Оптимизация RAM / Flash (с префиксом 99-zzz-)
mod_ram_flash_opt() {
    echo -e "${C_CYAN}⚡ === 12/19. ОПТИМИЗАЦИЯ ПАМЯТИ И НАКОПИТЕЛЕЙ ===${C_RESET}"
    backup_file "/etc/fstab"

    local target_swappiness=1
    local target_page_cluster=3
    if swapon --show 2>/dev/null | grep -q "zram"; then
        target_swappiness=100
        target_page_cluster=0
        echo -e "${C_BLUE}ℹ️ Обнаружен активный zRAM: установлен vm.swappiness=100 и page-cluster=0 для сжатия в ОЗУ.${C_RESET}"
    fi

    mkdir -p /etc/sysctl.d
    rm -f /etc/sysctl.d/99-ram-opt.conf 2>/dev/null || true
    cat << EOF > /etc/sysctl.d/99-zzz-ram-opt.conf
vm.swappiness=$target_swappiness
vm.page-cluster=$target_page_cluster
vm.vfs_cache_pressure=50
vm.dirty_writeback_centisecs=1500
vm.dirty_background_ratio=5
vm.dirty_ratio=10
kernel.dmesg_restrict=1
EOF
    sysctl --system > /dev/null 2>&1 || true

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
        awk '
        BEGIN { OFS="\t" }
        !/^#/ && $2 == "/" {
            if ($4 !~ /(^|,)noatime(,|$)/) $4 = $4 ",noatime"
        }
        { print }' /etc/fstab > /tmp/fstab.tmp && cat /tmp/fstab.tmp > /etc/fstab && rm -f /tmp/fstab.tmp
        silent_run mount -o remount,noatime /
        echo -e "${C_YELLOW}⚠️ Файловая система '$root_fs' не поддерживает commit=120. Применен только noatime.${C_RESET}"
    fi

    for dev_sched in /sys/block/sd*/queue/scheduler /sys/block/mmcblk*/queue/scheduler; do
        if [ -f "$dev_sched" ]; then echo "mq-deadline" > "$dev_sched" 2>/dev/null || true; fi
    done
    for nvme_sched in /sys/block/nvme*/queue/scheduler; do
        if [ -f "$nvme_sched" ]; then echo "none" > "$nvme_sched" 2>/dev/null || true; fi
    done

    mkdir -p /etc/udev/rules.d
    cat << 'UDEV_EOF' > /etc/udev/rules.d/60-ioscheduler.rules
ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]*", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
UDEV_EOF
    silent_run udevadm control --reload-rules

    TMPFS_ENTRIES=(
        "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=25% 0 0"
        "tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,size=15% 0 0"
    )

    for entry in "${TMPFS_ENTRIES[@]}"; do
        mount_point=$(echo "$entry" | awk '{print $2}')
        if ! grep -q -E "[[:space:]]${mount_point}[[:space:]]" /etc/fstab; then
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
        MODULE_CANCELED=true
        return 0
    fi

    clear
    case "$swap_choice" in
        1|2)
            local swap_size="2G"
            if [ "$swap_choice" = "2" ]; then
                prompt_default "Желаемый объем памяти (например: 2G, 4G, 1024M):" "4G" swap_size
                [ "$MODULE_CANCELED" = true ] && return 0
            fi
            silent_run swapoff /swap.img
            silent_run swapoff /swapfile
            rm -f /swap.img /swapfile

            local root_fs=$(df -T / 2>/dev/null | awk 'NR==2 {print $2}' || echo "unknown")
            if [ "$root_fs" = "btrfs" ] && command -v btrfs &>/dev/null; then
                btrfs filesystem mkswapfile --size "$swap_size" /swapfile
            else
                if ! fallocate -l "$swap_size" /swapfile 2>/dev/null; then
                    local num="${swap_size%[GgMm]}"
                    local unit="${swap_size: -1}"
                    case "$unit" in
                        [Gg]) num=$((num * 1024)) ;;
                        [Mm]) ;;
                        *) num=2048 ;;
                    esac
                    dd if=/dev/zero of=/swapfile bs=1M count="$num" status=progress
                fi
                chmod 600 /swapfile
                mkswap /swapfile
            fi

            swapon /swapfile
            sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            echo -e "${C_GREEN}✅ Файл подкачки размером $swap_size успешно инициализирован!${C_RESET}"
            ;;
        3)
            silent_run swapoff /swapfile
            silent_run swapoff /swap.img
            sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab
            rm -f /swapfile /swap.img
            echo -e "${C_GREEN}✅ Дисковый файл подкачки отключен.${C_RESET}"
            ;;
    esac
}

# 14. Системные утилиты и режим процессора
mod_desktop_apps() {
    echo -e "${C_CYAN}💻 === 14/19. СИСТЕМНЫЕ УТИЛИТЫ И РЕЖИМ ПРОЦЕССОРА ===${C_RESET}"

    local gov_choice
    if gov_choice=$(whiptail --title "Управление питанием процессора" --menu "\nВыберите желаемый режим работы:\n\nТекущий режим напрямую влияет на скорость\nработы, нагрев и энергопотребление." 17 $WT_WIDTH 4 \
    "1" "⚡ Performance (Максимальный)" \
    "2" "🔄 Ondemand / Schedutil (Сбалансированный)" \
    "3" "🍃 Powersave (Эко-режим)" \
    "0" "🔙 Без изменений" 3>&1 1>&2 2>&3) && [ "$gov_choice" != "0" ]; then
        local selected_gov="ondemand"
        local gov_name="Сбалансированный"
        local avail_govs=""
        [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ] && avail_govs=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")

        case "$gov_choice" in
            1) selected_gov="performance"; gov_name="Максимальный (Performance)" ;;
            2)
                if echo "$avail_govs" | grep -qw "ondemand"; then
                    selected_gov="ondemand"; gov_name="Сбалансированный (Ondemand)"
                elif echo "$avail_govs" | grep -qw "schedutil"; then
                    selected_gov="schedutil"; gov_name="Сбалансированный (Schedutil)"
                else
                    selected_gov="powersave"; gov_name="Динамический P-State (Powersave)"
                fi
                ;;
            3) selected_gov="powersave"; gov_name="Эко-режим (Powersave)" ;;
        esac

        echo -e "${C_BLUE}⚙️ Установка режима процессора: $gov_name...${C_RESET}"
        export DEBIAN_FRONTEND=noninteractive
        silent_run apt-get update
        silent_run apt-get install -yq cpufrequtils
        
        echo "GOVERNOR=$selected_gov" > /etc/default/cpufrequtils
        silent_run systemctl restart cpufrequtils 2>/dev/null || true
        
        for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
            [ -f "$cpu" ] && echo "$selected_gov" > "$cpu" 2>/dev/null || true
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
    echo -e "${C_CYAN}📺 === 15/19. СБРОС ВИДЕОВЫХОДА HDMI ===${C_RESET}"
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
    echo -e "${C_CYAN}⏳ === 16/19. АНАЛИЗ ВРЕМЕНИ ЗАГРУЗКИ СИСТЕМЫ ===${C_RESET}"
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

# 17. Полный аудит сервера (с проверкой ретранслятора DERP и туннелей каскада)
mod_server_audit() {
    clear
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    echo -e "${C_BOLD}       🔍  ПОЛНЫЙ ИНТЕЛЛЕКТУАЛЬНЫЙ АУДИТ И ДИАГНОСТИКА     ${C_RESET}"
    echo -e "${C_CYAN}=================================================================${C_RESET}\n"
    
    local active_user=$(get_active_user)
    local wan_if=$(get_wan_if)

    echo -e "${C_BOLD}--- 1. Базовая система, хост и обновления ---${C_RESET}"
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    current_tz="${current_tz#Etc/}"
    local ntp_sync=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "no")
    local ntp_str="${C_YELLOW}⚠️  Нет синхронизации точного времени${C_RESET}"
    [ "$ntp_sync" = "yes" ] && ntp_str="${C_GREEN}✅ Время синхронизировано${C_RESET}"

    local sys_type_human=$(get_system_type_human)
    local boot_target=$(systemctl get-default 2>/dev/null || echo "multi-user.target")
    local boot_target_human="${C_BLUE}Консольный (без рабочего стола, экономия ОЗУ)${C_RESET}"
    [ "$boot_target" = "graphical.target" ] && boot_target_human="${C_BLUE}Графический рабочий стол${C_RESET}"

    echo -e "  • Часовой пояс и время:      ${C_GREEN}$current_tz${C_RESET} ($ntp_str)"
    echo -e "  • Имя сервера (хост):        ${C_GREEN}$(hostname)${C_RESET}"
    echo -e "  • Тип устройства:            ${C_BLUE}$sys_type_human${C_RESET}"
    echo -e "  • Режим работы системы:      $boot_target_human"
    
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        echo -e "  • Фоновые обновления:        ${C_GREEN}✅ Включены (авто-установка обновлений защиты)${C_RESET}"
    else
        echo -e "  • Фоновые обновления:        ${C_RED}❌ Отключены${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 2. Аппаратная часть и Детектор оверселлинга ---${C_RESET}"
    local cpu_temp="Нет датчика"
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        local raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "")
        if [ -n "$raw_temp" ] && [ "$raw_temp" -gt 0 ]; then
            cpu_temp=$(LC_ALL=C awk "BEGIN {printf \"%.1f°C\", $raw_temp/1000}")
            if [ "$raw_temp" -gt 75000 ]; then
                cpu_temp="${C_RED}🔥 $cpu_temp (Критический перегрев / Снижение частот!)${C_RESET}"
            elif [ "$raw_temp" -gt 60000 ]; then
                cpu_temp="${C_YELLOW}⚠️  $cpu_temp (Повышенный нагрев)${C_RESET}"
            else
                cpu_temp="${C_GREEN}❄️  $cpu_temp (В норме)${C_RESET}"
            fi
        fi
    fi

    local cpu_gov="Неизвестно"
    [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] && cpu_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "Неизвестно")
    local cpu_gov_human="${C_BLUE}$cpu_gov${C_RESET}"
    case "$cpu_gov" in
        performance) cpu_gov_human="${C_BLUE}Максимальная производительность (performance)${C_RESET}" ;;
        ondemand|schedutil) cpu_gov_human="${C_BLUE}Автоматический сбалансированный ($cpu_gov)${C_RESET}" ;;
        powersave)   cpu_gov_human="${C_BLUE}Энергосберегающий (powersave)${C_RESET}" ;;
        *)
            if [ "$SYSTEM_TYPE" = "Cloud_VPS" ]; then
                cpu_gov_human="${C_BLUE}Управляется гипервизором VPS${C_RESET}"
            fi
            ;;
    esac

    local cpu_freq="Неизвестно"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        local raw_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "")
        [ -n "$raw_freq" ] && cpu_freq="$(LC_ALL=C awk "BEGIN {printf \"%d МГц\", $raw_freq/1000}")"
    elif [ -f /proc/cpuinfo ]; then
        local proc_mhz=$(LC_ALL=C awk -F: '/cpu MHz/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%.0f", $2; exit}' /proc/cpuinfo 2>/dev/null || echo "")
        if [ -n "$proc_mhz" ]; then
            cpu_freq="${proc_mhz} МГц"
        fi
    fi
    if [ "$cpu_freq" = "Неизвестно" ] && [ "$SYSTEM_TYPE" = "Cloud_VPS" ]; then
        cpu_freq="Динамическая (VPS)"
    fi
    
    local load_avg=$(uptime | awk -F'load average:' '{ print $2 }' | sed 's/^[ \t]*//')
    local disk_usage=$(df -h / 2>/dev/null | awk 'NR==2 {print $3 " из " $2 " (занято " $5 ")"}' || echo "N/A")

    local steal_status="${C_BLUE}Неприменимо (физическое железо)${C_RESET}"
    local cpu_speed_status="${C_BLUE}Стандартная${C_RESET}"
    local disk_io_status="${C_BLUE}Не проверялся${C_RESET}"
    local psi_status="${C_GREEN}✅ 0.0% (очередей ожидания нет)${C_RESET}"
    local oversell_score=0

    local stat_line1=$(grep '^cpu ' /proc/stat 2>/dev/null || echo "")
    local t_cpu1=$(LC_ALL=C date +%s.%N 2>/dev/null || awk '{print $1}' /proc/uptime)
    LC_ALL=C awk 'BEGIN {for(i=0;i<2000000;i++){x=i*1.5}}' >/dev/null 2>&1 || true
    local t_cpu2=$(LC_ALL=C date +%s.%N 2>/dev/null || awk '{print $1}' /proc/uptime)

    local cpu_bench_ms=$(LC_ALL=C awk -v t1="$t_cpu1" -v t2="$t_cpu2" 'BEGIN {d=(t2-t1)*1000; if(d<1) d=1; printf "%d", d}')
    if [ "$cpu_bench_ms" -lt 150 ]; then
        cpu_speed_status="${C_GREEN}✅ Быстрый (${cpu_bench_ms} мс — без троттлинга)${C_RESET}"
    elif [ "$cpu_bench_ms" -lt 350 ]; then
        cpu_speed_status="${C_GREEN}✅ Нормальный (${cpu_bench_ms} мс — стандартное ядро)${C_RESET}"
    else
        cpu_speed_status="${C_YELLOW}⚠️  Замедлен (${cpu_bench_ms} мс — хостер лимитирует ядро!)${C_RESET}"
        oversell_score=$((oversell_score + 1))
    fi

    local io_test_file="/root/.bobarev_io_test_$$"
    local t_io1=$(LC_ALL=C date +%s.%N 2>/dev/null || awk '{print $1}' /proc/uptime)
    if dd if=/dev/zero of="$io_test_file" bs=4k count=40 oflag=dsync status=none 2>/dev/null; then
        local t_io2=$(LC_ALL=C date +%s.%N 2>/dev/null || awk '{print $1}' /proc/uptime)
        rm -f "$io_test_file" 2>/dev/null || true
        local io_parsed=$(LC_ALL=C awk -v t1="$t_io1" -v t2="$t_io2" 'BEGIN {
            el = t2 - t1;
            if (el <= 0.0001) el = 0.001;
            lat = (el * 1000) / 40;
            iops = int(40 / el);
            printf "%.2f|%d|%d", lat, iops, int(lat);
        }')
        local io_lat=$(echo "$io_parsed" | cut -d'|' -f1)
        local io_iops=$(echo "$io_parsed" | cut -d'|' -f2)
        local io_lat_int=$(echo "$io_parsed" | cut -d'|' -f3)

        if [ "$io_lat_int" -lt 3 ]; then
            disk_io_status="${C_GREEN}✅ Быстрый NVMe/SSD (отклик ${io_lat} мс, ~${io_iops} IOPS)${C_RESET}"
        elif [ "$io_lat_int" -lt 12 ]; then
            disk_io_status="${C_GREEN}✅ Нормальный SSD (отклик ${io_lat} мс, ~${io_iops} IOPS)${C_RESET}"
        else
            disk_io_status="${C_YELLOW}⚠️  Медленный отклик (${io_lat} мс, ~${io_iops} IOPS — диск занят!)${C_RESET}"
            oversell_score=$((oversell_score + 1))
        fi
    else
        rm -f "$io_test_file" 2>/dev/null || true
    fi

    sleep 0.3
    local stat_line2=$(grep '^cpu ' /proc/stat 2>/dev/null || echo "")

    if [ -n "$stat_line1" ] && [ -n "$stat_line2" ]; then
        local parsed_stat=$(LC_ALL=C awk -v s1="$stat_line1" -v s2="$stat_line2" 'BEGIN {
            split(s1, a, " "); split(s2, b, " ");
            t1 = a[2]+a[3]+a[4]+a[5]+a[6]+a[7]+a[8]+a[9];
            t2 = b[2]+b[3]+b[4]+b[5]+b[6]+b[7]+b[8]+b[9];
            td = t2 - t1;
            if (td > 0) {
                st = ((b[9] - a[9]) * 100) / td;
                if (st < 0) st = 0;
                printf "%.1f|%d", st, int(st);
            } else {
                print "0.0|0";
            }
        }')
        local steal_pct="${parsed_stat%|*}"
        local steal_int="${parsed_stat#*|}"

        if [ "$steal_int" -eq 0 ]; then
            steal_status="${C_GREEN}✅ 0.0% под нагрузкой (хостер честно отдает ядро)${C_RESET}"
        elif [ "$steal_int" -lt 5 ]; then
            steal_status="${C_GREEN}✅ Низкий (${steal_pct}% — минимальное влияние соседей)${C_RESET}"
        elif [ "$steal_int" -lt 15 ]; then
            steal_status="${C_YELLOW}⚠️  Умеренный (${steal_pct}% — заметная очередь за процессором)${C_RESET}"
            oversell_score=$((oversell_score + 1))
        else
            steal_status="${C_RED}🚨 ВЫСОКИЙ (${steal_pct}% — жесткий оверселлинг CPU на ноде!)${C_RESET}"
            oversell_score=$((oversell_score + 2))
        fi
    fi

    if [ -f /proc/pressure/cpu ] && [ -f /proc/pressure/io ]; then
        local psi_cpu=$(LC_ALL=C awk '/^some/ {for(i=1;i<=NF;i++) if($i ~ /^avg60=/) {split($i,a,"="); print a[2]}}' /proc/pressure/cpu 2>/dev/null || echo "0.00")
        local psi_io=$(LC_ALL=C awk '/^some/ {for(i=1;i<=NF;i++) if($i ~ /^avg60=/) {split($i,a,"="); print a[2]}}' /proc/pressure/io 2>/dev/null || echo "0.00")
        psi_cpu="${psi_cpu:-0.00}"
        psi_io="${psi_io:-0.00}"
        local psi_bad_flag=$(LC_ALL=C awk -v c="$psi_cpu" -v d="$psi_io" 'BEGIN {if (c+0 > 5.0 || d+0 > 10.0) print 1; else print 0}')
        if [ "${psi_bad_flag:-0}" -eq 1 ]; then
            psi_status="${C_YELLOW}⚠️  Замечены простои в очереди (CPU: ${psi_cpu}%, Диск: ${psi_io}%)${C_RESET}"
            oversell_score=$((oversell_score + 1))
        else
            psi_status="${C_GREEN}✅ В норме (CPU: ${psi_cpu}%, Диск: ${psi_io}% за минуту)${C_RESET}"
        fi
    fi

    local verdict_human="${C_GREEN}🟢 Честные ресурсы (оверселлинг не обнаружен)${C_RESET}"
    if [ "$oversell_score" -eq 1 ]; then
        verdict_human="${C_YELLOW}🟡 Умеренный оверселлинг (ресурсы делятся с соседями)${C_RESET}"
    elif [ "$oversell_score" -ge 2 ]; then
        verdict_human="${C_RED}🔴 Жесткий оверселлинг! (хостер урезает железо)${C_RESET}"
    fi

    echo -e "  • Температура процессора:    $cpu_temp"
    echo -e "  • Режим питания процессора:  $cpu_gov_human"
    echo -e "  • Текущая частота ядер:      ${C_BLUE}$cpu_freq${C_RESET}"
    echo -e "  • Вычислительная нагрузка:   ${C_BLUE}$load_avg${C_RESET}"
    echo -e "  • Занято места на диске:     ${C_BLUE}$disk_usage${C_RESET}"
    echo -e "  • Отклик ядра (Троттлинг):   $cpu_speed_status"
    echo -e "  • Кража CPU под нагрузкой:   $steal_status"
    echo -e "  • Реальный отклик диска:     $disk_io_status"
    echo -e "  • Ожидание ресурсов (PSI):   $psi_status"
    echo -e "  • Вердикт по оверселлингу:   $verdict_human"

    echo -e "\n${C_BOLD}--- 3. Учетные записи, пользователи и Sudo ---${C_RESET}"
    local in_sudo_group="нет"
    if id -nG "$active_user" 2>/dev/null | grep -qw "sudo"; then
        in_sudo_group="в группе sudo"
    fi
    echo -e "  • Основной администратор:    ${C_GREEN}$active_user ($in_sudo_group)${C_RESET}"

    local sudo_effective_line=$(sudo -l -U "$active_user" 2>/dev/null | grep -E "NOPASSWD|ALL" | tail -n 1 || echo "")
    if echo "$sudo_effective_line" | grep -q "NOPASSWD"; then
        echo -e "  • Повышение прав (Sudo):     ${C_GREEN}✅ Без запроса пароля (NOPASSWD активен)${C_RESET}"
    elif [ -f "/etc/sudoers.d/99-zzz-$active_user" ] || [ -f "/etc/sudoers.d/$active_user" ]; then
        echo -e "  • Повышение прав (Sudo):     ${C_YELLOW}⚠️  Файл NOPASSWD есть, но перебит другим правилом (перезапустите п. 4)${C_RESET}"
    else
        echo -e "  • Повышение прав (Sudo):     ${C_BLUE}ℹ️  Стандартный запрос пароля${C_RESET}"
    fi

    local root_locked=$(passwd -S root 2>/dev/null || echo "")
    if echo "$root_locked" | grep -qE " L | LK | NP "; then
        echo -e "  • Пароль суперпользователя:  ${C_GREEN}✅ Заблокирован (защищено)${C_RESET}"
    else
        echo -e "  • Пароль суперпользователя:  ${C_RED}❌ Активен (разрешен прямой вход root)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 4. Безопасность и конфигурация SSH ---${C_RESET}"
    local ssh_port="22" root_ssh="yes" pass_auth="yes"
    local sshd_cmd=$(get_sshd_cmd)

    if [ -n "$sshd_cmd" ]; then
        local conf_port=$($sshd_cmd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "")
        local conf_root=$($sshd_cmd -T 2>/dev/null | grep -i "^permitrootlogin " | awk '{print $2}' | head -n 1 || echo "")
        local conf_pass=$($sshd_cmd -T 2>/dev/null | grep -i "^passwordauthentication " | awk '{print $2}' | head -n 1 || echo "")
        
        [ -n "$conf_port" ] && ssh_port="$conf_port"
        [ -n "$conf_root" ] && root_ssh="$conf_root"
        [ -n "$conf_pass" ] && pass_auth="$conf_pass"
    fi

    local port_status_human
    if [ "$ssh_port" = "22" ]; then
        port_status_human="${C_YELLOW}⚠️  22 (Стандартный порт, рекомендуется сменить)${C_RESET}"
    else
        port_status_human="${C_GREEN}✅ $ssh_port (Нестандартный порт)${C_RESET}"
    fi

    local root_status_human
    case "${root_ssh,,}" in
        no) root_status_human="${C_GREEN}✅ Запрещен${C_RESET}" ;;
        prohibit-password|without-password) root_status_human="${C_GREEN}✅ Только по SSH-ключам${C_RESET}" ;;
        yes|*) root_status_human="${C_RED}❌ Разрешен${C_RESET}" ;;
    esac

    local pass_status_human
    case "${pass_auth,,}" in
        no) pass_status_human="${C_GREEN}✅ Отключен (вход только по SSH-ключам)${C_RESET}" ;;
        yes|*) pass_status_human="${C_YELLOW}⚠️  Разрешен вход по паролю${C_RESET}" ;;
    esac

    echo -e "  • Используемый порт SSH:     $port_status_human"
    echo -e "  • Вход для root по SSH:      $root_status_human"
    echo -e "  • Авторизация по паролю:     $pass_status_human"

    if systemctl is-active --quiet sshguard 2>/dev/null; then
        echo -e "  • Защита от перебора пароля: ${C_GREEN}✅ Работает (легковесный демон sshguard)${C_RESET}"
    elif systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "  • Защита от перебора пароля: ${C_GREEN}✅ Работает (служба fail2ban)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 5. Защита ядра и сетевые оптимизации ---${C_RESET}"
    check_param() {
        local param="$1" expected="$2" label="$3" ok_msg="$4" err_msg="$5"
        local val=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
        if [ "$val" = "$expected" ]; then
            echo -e "  • ${label}${C_GREEN}✅ $ok_msg${C_RESET}"
        else
            echo -e "  • ${label}${C_YELLOW}⚠️  $err_msg (сейчас: $val)${C_RESET}"
        fi
    }
    check_param "kernel.dmesg_restrict"           "1"        "Защита журнала ядра:       " "Включена" "Отключена"
    check_param "net.ipv4.ip_forward"             "1"        "Форвардинг пакетов (IPv4): " "Включен (маршрутизация активна)" "Отключен"
    check_param "net.ipv4.tcp_syncookies"         "1"        "Защита от флуда (SYN):     " "Включена" "Отключена"
    check_param "net.ipv4.tcp_congestion_control" "bbr"      "Ускорение сети TCP BBR:    " "Активно" "Стандартное"
    check_param "net.core.rmem_max"               "26214400" "Расширенные буферы VPN:    " "Активны (25 МБ под высокие скорости)" "Стандартные"

    echo -e "\n${C_BOLD}--- 6. Межсетевой экран (UFW), Изоляция и Режим роутера ---${C_RESET}"
    if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
        local ufw_out=$(LC_ALL=C ufw status 2>/dev/null || echo "")
        echo -e "  • Статус брандмауэра:        ${C_GREEN}✅ Включен и защищает сервер${C_RESET}"
        
        local fwd_policy=$(grep -E "^DEFAULT_FORWARD_POLICY=" /etc/default/ufw 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "DROP")
        if [ "$fwd_policy" = "ACCEPT" ]; then
            echo -e "  • Пересылка трафика (Шлюз):  ${C_GREEN}✅ Разрешена (сервер может раздавать интернет)${C_RESET}"
        else
            echo -e "  • Пересылка трафика (Шлюз):  ${C_YELLOW}⚠️  Запрещена (только локальные подключения)${C_RESET}"
        fi

        if echo "$ufw_out" | grep -qE "${ssh_port}/tcp[[:space:]]+on[[:space:]]+tailscale0|SSH via Tailscale only"; then
            echo -e "  • Доступ к порту SSH:        ${C_GREEN}🔒 Скрыт снаружи (вход только через Tailscale)${C_RESET}"
        else
            echo -e "  • Доступ к порту SSH:        ${C_YELLOW}🌍 Публичный (открыт для всех сетей)${C_RESET}"
        fi

        if command -v tailscale &>/dev/null; then
            if echo "$ufw_out" | awk '!/ALLOW FWD/ && /^Anywhere[[:space:]]+on[[:space:]]+tailscale0[[:space:]]+ALLOW/' | grep -q .; then
                echo -e "  • Изоляция сети Tailscale:   ${C_YELLOW}⚠️  Отключена (открыты все порты на tailscale0)${C_RESET}"
            else
                local open_ts_ports="только SSH $ssh_port/tcp"
                if echo "$ufw_out" | awk '!/ALLOW FWD/ && /^5252\/tcp[[:space:]]+on[[:space:]]+tailscale0[[:space:]]+ALLOW/' | grep -q .; then
                    open_ts_ports="SSH $ssh_port/tcp и Веб-панель 5252/tcp"
                fi
                echo -e "  • Изоляция сети Tailscale:   ${C_GREEN}🔒 Полная (Zero-Trust: $open_ts_ports — безопасно для Share)${C_RESET}"
            fi
        fi

        if [ -n "$wan_if" ]; then
            local nat_cnt=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -cE -- "-o ${wan_if}[[:space:]].*-j (MASQUERADE|SNAT)" || true)
            if [ "$nat_cnt" -eq 1 ]; then
                echo -e "  • Трансляция NAT на выходе:  ${C_GREEN}✅ Активна на $wan_if (1 чистое правило без дубликатов)${C_RESET}"
            elif [ "$nat_cnt" -gt 1 ]; then
                echo -e "  • Трансляция NAT на выходе:  ${C_YELLOW}⚠️  Найдено дубликатов на $wan_if: $nat_cnt (очистите в п. 10 -> 8 -> 4)${C_RESET}"
            else
                echo -e "  • Трансляция NAT на выходе:  ${C_BLUE}ℹ️  Не используется на $wan_if (режим обычного узла без шлюза)${C_RESET}"
            fi
        fi

        if [ -f /etc/default/bobarev-router ]; then
            # shellcheck disable=SC1091
            source /etc/default/bobarev-router
            local r_lan="${ROUTER_LAN_IF:-не задан}"
            local r_ip="${ROUTER_LAN_IP:-192.168.199.1}"
            local r_out="${ROUTER_OUT_IF:-не задан}"

            local r_out_human="${C_GREEN}Через сетевой канал $r_out${C_RESET}"
            case "$r_out" in
                wg*)        r_out_human="${C_GREEN}🔒 Через защищенный туннель WireGuard ($r_out)${C_RESET}" ;;
                tailscale0) r_out_human="${C_GREEN}🔗 Через закрытую сеть Tailscale${C_RESET}" ;;
                tun*|utun*) r_out_human="${C_GREEN}🚀 Через прокси-туннель ($r_out)${C_RESET}" ;;
                "$wan_if")  r_out_human="${C_BLUE}🌍 Напрямую через провайдера ($r_out, без VPN)${C_RESET}" ;;
            esac

            local r_host_human="${C_BLUE}Идет напрямую через провайдера (мимо VPN)${C_RESET}"
            if [ "${ROUTER_ROUTE_HOST:-false}" = "true" ]; then
                r_host_human="${C_GREEN}✅ Тоже защищен и идет через $r_out${C_RESET}"
            fi

            local r_ks_human="${C_YELLOW}⚠️  Выключена (при сбое VPN трафик пойдет напрямую)${C_RESET}"
            if [ "${ROUTER_KILLSWITCH:-false}" = "true" ]; then
                r_ks_human="${C_GREEN}🔒 Включена (блокирует утечку IP в обход VPN)${C_RESET}"
            elif [ "$r_out" = "$wan_if" ]; then
                r_ks_human="${C_BLUE}Не требуется (выбран прямой выход без VPN)${C_RESET}"
            fi

            echo -e "  • Режим локального роутера:  ${C_GREEN}✅ Активен (раздает сеть в порт $r_lan, шлюз $r_ip)${C_RESET}"
            echo -e "  • Интернет для клиентов LAN: $r_out_human"
            echo -e "  • Трафик самого сервера:     $r_host_human"
            echo -e "  • Защита от утечки IP:       $r_ks_human"
        fi

        if [ -f /etc/ufw/after.rules ] && grep -q "BEGIN UFW AND DOCKER" /etc/ufw/after.rules; then
            echo -e "  • Защита контейнеров Docker: ${C_GREEN}✅ Включена (доступ к портам Docker извне закрыт)${C_RESET}"
        fi
    else
        echo -e "  • Статус брандмауэра:        ${C_RED}❌ Выключен (сервер не защищен)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 7. Закрытая меш-сеть Tailscale ---${C_RESET}"
    if command -v tailscale &>/dev/null; then
        echo -e "  • Служба Tailscale:          ${C_GREEN}✅ Установлена и работает${C_RESET}"
        local ts_name ts_ip ts_exit ts_adv_exit ts_accept ts_stealth
        IFS="|" read -r ts_name _ <<< "$(get_tailscale_whoami)"
        ts_ip=$(tailscale ip -4 2>/dev/null | head -n 1 || echo "Не авторизован")
        
        ts_exit=$(tailscale get exit-node 2>/dev/null || echo "")
        local ts_exit_human
        if [ -z "$ts_exit" ] || [ "$ts_exit" = "none" ] || [ "$ts_exit" = "false" ]; then
            if [ -f /etc/default/bobarev-router ]; then
                # shellcheck disable=SC1091
                source /etc/default/bobarev-router
                if [ "${ROUTER_ROUTE_HOST:-false}" = "true" ] && [ -n "${ROUTER_OUT_IF:-}" ] && [ "${ROUTER_OUT_IF:-}" != "tailscale0" ]; then
                    ts_exit_human="Отключен (интернет идет через туннель ${ROUTER_OUT_IF})"
                else
                    ts_exit_human="Отключен (используется собственный маршрут)"
                fi
            else
                ts_exit_human="Отключен (используется собственный интернет)"
            fi
        else
            ts_exit_human="Активен (трафик идет через узел $ts_exit)"
        fi
        
        ts_adv_exit=$(tailscale get advertise-exit-node 2>/dev/null || echo "false")
        local ts_adv_exit_human
        [ "$ts_adv_exit" = "true" ] && ts_adv_exit_human="${C_GREEN}Да (раздает свой интернет другим устройствам)${C_RESET}" || ts_adv_exit_human="${C_BLUE}Нет${C_RESET}"
        
        ts_accept=$(tailscale get accept-routes 2>/dev/null || echo "false")
        local ts_accept_human
        [ "$ts_accept" = "true" ] && ts_accept_human="${C_GREEN}Включен (видит подсети других устройств)${C_RESET}" || ts_accept_human="${C_BLUE}Выключен${C_RESET}"
        
        ts_stealth=$(tailscale get stateful-filtering 2>/dev/null || echo "false")
        local ts_stealth_human
        [ "$ts_stealth" = "true" ] && ts_stealth_human="${C_GREEN}Включен (отбрасывает входящие из сети)${C_RESET}" || ts_stealth_human="${C_BLUE}Выключен (открыт для своих устройств)${C_RESET}"

        local ts_nf_mode=$(get_tailscale_netfilter_mode)
        local ts_nf_human="${C_BLUE}Tailscale (встроенный авто-режим)${C_RESET}"
        [ "$ts_nf_mode" = "off" ] && ts_nf_human="${C_GREEN}✅ Брандмауэр UFW (системный режим)${C_RESET}"

        local ts_web_human="${C_BLUE}Отключена (порт 5252 закрыт)${C_RESET}"
        if is_tailscale_web_active; then
            if LC_ALL=C ufw status 2>/dev/null | awk '!/ALLOW FWD/ && (/^5252\/tcp[[:space:]]+on[[:space:]]+tailscale0[[:space:]]+ALLOW/ || /^Anywhere[[:space:]]+on[[:space:]]+tailscale0[[:space:]]+ALLOW/)' | grep -q .; then
                ts_web_human="${C_GREEN}✅ Активна (http://${ts_ip}:5252 — порт 5252/tcp открыт в UFW)${C_RESET}"
            else
                ts_web_human="${C_YELLOW}⚠️  Включена, но порт 5252/tcp закрыт в UFW (перевключите п. 10 -> 7)${C_RESET}"
            fi
        fi

        local ts_derp_human="${C_BLUE}Не настроен${C_RESET}"
        if is_derp_active; then
            ts_derp_human="${C_GREEN}✅ Работает (443/tcp и STUN 3478/udp открыты)${C_RESET}"
        elif [ -f /etc/systemd/system/derper.service ]; then
            ts_derp_human="${C_YELLOW}⚠️  Установлен, но служба derper остановлена${C_RESET}"
        fi

        local cascade_status="${C_BLUE}Не настроен${C_RESET}"
        if is_naive_active; then
            cascade_status="${C_GREEN}🔒 Сервер 1 (NaiveProxy -> Tailscale активен)${C_RESET}"
        elif is_warp_active; then
            cascade_status="${C_GREEN}🌍 Сервер 2 (Tailscale -> WARP активен)${C_RESET}"
        fi

        echo -e "  • Имя устройства в сети:     ${C_BLUE}$ts_name${C_RESET}"
        echo -e "  • Внутренний IP-адрес:       ${C_BLUE}$ts_ip${C_RESET}"
        echo -e "  • Внешний шлюз Tailscale:    ${C_BLUE}$ts_exit_human${C_RESET}"
        echo -e "  • Раздает свой интернет:     $ts_adv_exit_human"
        echo -e "  • Доступ к чужим подсетям:   $ts_accept_human"
        echo -e "  • Скрытый режим (Stealth):   $ts_stealth_human"
        echo -e "  • Приоритет правил фаервола: $ts_nf_human"
        echo -e "  • Личный ретранслятор DERP:  $ts_derp_human"
        echo -e "  • Каскад (Naive/Tailscale):  $cascade_status"
        echo -e "  • Веб-панель (порт 5252):    $ts_web_human"

        if systemctl is-active --quiet tailscale-gro.service 2>/dev/null; then
            echo -e "  • Аппаратное ускорение GRO:  ${C_GREEN}✅ Включено${C_RESET}"
        else
            echo -e "  • Аппаратное ускорение GRO:  ${C_YELLOW}⚠️  Отключено${C_RESET}"
        fi
    else
        echo -e "  • Служба Tailscale:          ${C_YELLOW}⚠️  Не установлена${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 8. Сетевые интерфейсы и Открытые порты ---${C_RESET}"
    local active_ifs=$(ip -br link show | grep -v "DOWN" | awk '{print $1}' | sed 's/@.*//' || echo "")
    for iface in $active_ifs; do
        local mtu=$(cat /sys/class/net/"$iface"/mtu 2>/dev/null || echo "N/A")
        local speed=$(cat /sys/class/net/"$iface"/speed 2>/dev/null || echo "N/A")
        
        if [ "$speed" != "N/A" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
            speed="${speed} Мбит/с"
        elif [ "$iface" = "tailscale0" ] || [[ "$iface" == *"wg"* ]] || [[ "$iface" == *"warp"* ]] || [[ "$iface" == *"tun"* ]] || [[ "$iface" == *"lo"* ]]; then
            speed="Виртуальный канал"
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

        echo -e "  • Интерфейс ${C_BLUE}$iface${C_RESET} (MTU: ${C_GREEN}$mtu${C_RESET}, Скорость: ${C_GREEN}$speed${C_RESET})"
        echo -e "    └─ Пакеты: Ошибки = $err_str | Пропущено (Dropped) = $drop_str"
    done

    echo -e ""
    local mss_active=false
    if command -v ufw &>/dev/null && [ -f /etc/ufw/before.rules ] && grep -q "TCPMSS" /etc/ufw/before.rules; then mss_active=true; fi
    if command -v iptables &>/dev/null && iptables -t mangle -L FORWARD -n 2>/dev/null | grep -q "TCPMSS"; then mss_active=true; fi
    
    if [ "$mss_active" = true ]; then
        echo -e "  • Выравнивание пакетов (MSS): ${C_GREEN}✅ Включено (сайты открываются без зависаний в VPN)${C_RESET}"
    else
        echo -e "  • Выравнивание пакетов (MSS): ${C_YELLOW}⚠️  Выключено (возможны зависания сайтов в VPN)${C_RESET}"
    fi

    if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
        local ufw_ports_list=$(LC_ALL=C ufw status 2>/dev/null || echo "")
        [ -z "$ufw_ports_list" ] && ufw_ports_list="Все входящие порты закрыты"
        echo -e "  • Открытые порты (по UFW):    ${C_BLUE}активны${C_RESET}"
    elif command -v ss &>/dev/null; then
        local listen_ports=$(ss -tlnH 2>/dev/null | awk '$4 !~ /^127\./ && $4 !~ /^\[::1\]/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -nu | tr '\n' ' ' || echo "")
        [ -n "$listen_ports" ] && echo -e "  • Открытые порты (без UFW):   ${C_YELLOW}$listen_ports${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 9. Оптимизация памяти, накопителей и подкачки ---${C_RESET}"
    
    local vm_swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "N/A")
    local swappiness_human
    if [ "$vm_swappiness" = "1" ]; then
        swappiness_human="${C_GREEN}✅ 1 (Максимальная защита флеш-памяти от износа)${C_RESET}"
    elif [ "$vm_swappiness" = "100" ] && swapon --show 2>/dev/null | grep -q "zram"; then
        swappiness_human="${C_GREEN}✅ 100 (Активное сжатие данных в быстрой ОЗУ zRAM)${C_RESET}"
    elif [ "$vm_swappiness" = "60" ]; then
        swappiness_human="${C_YELLOW}⚠️  60 (Заводское значение, частая запись на диск)${C_RESET}"
    elif [ "$vm_swappiness" = "N/A" ]; then
        swappiness_human="${C_RED}❌ Ошибка чтения${C_RESET}"
    else
        swappiness_human="${C_BLUE}$vm_swappiness (Пользовательское значение)${C_RESET}"
    fi
    echo -e "  • Режим подкачки памяти:     $swappiness_human"

    if mount | grep " / " | grep -q "noatime"; then
        echo -e "  • Запись времени чтения:     ${C_GREEN}✅ Отключена (noatime — снижен износ накопителя)${C_RESET}"
    else
        echo -e "  • Запись времени чтения:     ${C_YELLOW}⚠️  Включена (лишняя нагрузка на диск)${C_RESET}"
    fi

    if mount | grep " / " | grep -q "commit=120"; then
        echo -e "  • Буферизация записи диска:  ${C_GREEN}✅ 120 сек. (бережет флеш-память от частых записей)${C_RESET}"
    else
        echo -e "  • Буферизация записи диска:  ${C_YELLOW}⚠️  Стандартная (5 сек.)${C_RESET}"
    fi

    local swap_human_list=()
    while read -r sw_dev sw_size; do
        [ -z "$sw_dev" ] && continue
        if [[ "$sw_dev" == *"zram"* ]]; then
            swap_human_list+=("zRAM ($sw_size)")
        else
            swap_human_list+=("Диск ($sw_size)")
        fi
    done < <(swapon --show=NAME,SIZE --noheadings 2>/dev/null | awk '{print $1, $2}')

    if [ "${#swap_human_list[@]}" -gt 0 ]; then
        local joined_swap=$(printf "%s, " "${swap_human_list[@]}")
        joined_swap="${joined_swap%, }"
        echo -e "  • Виртуальная память:        ${C_GREEN}✅ $joined_swap${C_RESET}"
    else
        echo -e "  • Виртуальная память:        ${C_YELLOW}Отключена${C_RESET}"
    fi

    echo -e "\n${C_CYAN}=================================================================${C_RESET}"
}

# 18. Универсальный режим локального маршрутизатора (с поддержкой SBC-клиента WireGuard/WARP)
mod_router_sbc() {
    echo -e "${C_CYAN}📡 === 18/19. УНИВЕРСАЛЬНЫЙ РЕЖИМ ЛОКАЛЬНОГО МАРШРУТИЗАТОРА ===${C_RESET}"
    DEFAULT_WAN_IF=$(get_wan_if)
    local wan_if="$DEFAULT_WAN_IF"
    
    if ! whiptail --title "Универсальный Маршрутизатор" --yesno "Превратить этот сервер в локальный LAN-шлюз (Роутер)?\n\nВы сможете выбрать внутренний интерфейс для клиентов (например, порт роутера Google Wi-Fi) и внешний VPN-канал (WireGuard wg0, WARP, Tailscale или WAN)." 14 $WT_WIDTH; then
        echo -e "${C_YELLOW}⏭️ Настройка маршрутизатора отменена.${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi

    local available_lan_ifs=$(ip -br link show | grep -vE "tailscale0|lo|wg[0-9]*|warp|tun[0-9]*|utun[0-9]*|docker|veth|br-" | awk '{print $1}' | sed 's/@.*//' || echo "")
    if [ -z "$available_lan_ifs" ]; then
        whiptail --msgbox "Ошибка: Не найдено подходящих физических интерфейсов для локальной сети!" 8 $WT_WIDTH
        return 0
    fi

    local lan_menu_items=()
    for iface in $available_lan_ifs; do
        local st_tag=$(get_iface_status_tag "$iface")
        lan_menu_items+=("$iface" "Порт LAN для клиентов $st_tag")
    done

    local lan_if=""
    if ! lan_if=$(whiptail --title "1/3. Внутренний LAN-интерфейс" --menu "Выберите сетевой порт для подключения роутера (например, Google Wi-Fi):" 14 $WT_WIDTH 5 "${lan_menu_items[@]}" 3>&1 1>&2 2>&3) || [ -z "$lan_if" ]; then
        echo -e "${C_YELLOW}↩️ Отмена. Возврат в меню...${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi

    local out_menu_items=()
    ip link show wg0 >/dev/null 2>&1 && out_menu_items+=("wg0" "🔒 WireGuard туннель (wg0)")
    ip link show warp >/dev/null 2>&1 && out_menu_items+=("warp" "🚀 Cloudflare WARP туннель (warp)")
    ip link show tailscale0 >/dev/null 2>&1 && out_menu_items+=("tailscale0" "🔗 Tailscale меш-сеть (tailscale0)")
    [ -n "$wan_if" ] && out_menu_items+=("$wan_if" "🌍 Прямой WAN провайдера ($wan_if)")
    out_menu_items+=("CUSTOM" "📝 Ввести имя интерфейса вручную")

    local out_if=""
    if ! out_if=$(whiptail --title "2/3. Выходной VPN-канал" --menu "Через какой интерфейс отправлять трафик клиентов из локальной сети ($lan_if)?" 16 $WT_WIDTH 6 "${out_menu_items[@]}" 3>&1 1>&2 2>&3) || [ -z "$out_if" ]; then
        echo -e "${C_YELLOW}↩️ Отмена. Возврат в меню...${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi

    if [ "$out_if" = "CUSTOM" ]; then
        prompt_default "Введите точное имя интерфейса (например: wg0, warp):" "wg0" out_if
        if [ "$MODULE_CANCELED" = true ] || [ -z "$out_if" ]; then return 0; fi
    fi

    local lan_ip="192.168.199.1"
    prompt_default "3/3. Введите статический IP для шлюза на порту $lan_if:" "$lan_ip" lan_ip
    [ "$MODULE_CANCELED" = true ] && return 0

    # Автоматически добавляем правила перенаправления и маскарадинга для SBC / роутера
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    ensure_wg_kernel_modules

    silent_run iptables -A FORWARD -i "$lan_if" -o "$out_if" -j ACCEPT
    silent_run iptables -A FORWARD -i "$out_if" -o "$lan_if" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    silent_run iptables -t nat -A POSTROUTING -s "${lan_ip%.*}.0/24" -o "$out_if" -j MASQUERADE

    echo -e "${C_GREEN}✅ Одноплатный компьютер успешно настроен как шлюз! Клиенты из сети $lan_if маршрутизируются через интерфейс $out_if.${C_RESET}"
    pause_enter
}

# 19. Экспорт и импорт резервной копии конфигураций (включая NaiveProxy, WARP и сертификаты)
mod_backup_manager() {
    echo -e "${C_CYAN}📦 === 19/19. ЭКСПОРТ И ИМПОРТ НАСТРОЕК ===${C_RESET}"
    local target_user=$(get_active_user)
    local target_home=$(getent passwd "$target_user" | cut -d: -f6)
    [ -z "$target_home" ] && target_home="/root"

    local b_choice
    if ! b_choice=$(whiptail --title "Экспорт и импорт настроек" --menu "Выберите действие:" 13 $WT_WIDTH 3 \
    "1" "📤 Сохранить настройки в архив (Экспорт)" \
    "2" "📥 Восстановить настройки из архива (Импорт)" \
    "0" "🔙 Отмена" 3>&1 1>&2 2>&3) || [ "$b_choice" = "0" ]; then
        MODULE_CANCELED=true
        return 0
    fi

    if [ "$b_choice" = "1" ]; then
        local archive_path="${target_home}/bobarev_backup_$(hostname)_$(date +%Y%m%d_%H%M%S).tar.gz"
        local files_to_pack=()
        for item in /etc/sudoers /etc/sudoers.d /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/sysctl.d /etc/ufw /etc/default/ufw /etc/default/bobarev-router /etc/default/bobarev-netfilter /etc/default/bobarev-derp /etc/default/bobarev-cascade /etc/derp /etc/wireguard /etc/caddy /etc/naiveproxy /etc/systemd/system/derper.service /etc/systemd/system/caddy.service /etc/systemd/system/bobarev-cascade-ru.service /usr/local/bin/bobarev-cascade-ru.sh /usr/local/bin/bobarev-router-up.sh /etc/systemd/system/bobarev-router.service /etc/dnsmasq.conf /etc/default/zramswap /etc/systemd/journald.conf /etc/udev/rules.d/60-ioscheduler.rules; do
            [ -e "$item" ] && files_to_pack+=("$item")
        done

        tar -czf "$archive_path" "${files_to_pack[@]}" 2>/dev/null || true
        silent_run chown "$target_user:$target_user" "$archive_path"
        echo -e "${C_GREEN}✅ Архив настроек успешно сохранен:${C_RESET} ${C_BLUE}$archive_path${C_RESET}"
    elif [ "$b_choice" = "2" ]; then
        local import_path=""
        prompt_default "Введите полный путь к архиву .tar.gz для восстановления:" "${target_home}/" import_path
        [ "$MODULE_CANCELED" = true ] && return 0

        if [ ! -f "$import_path" ]; then
            echo -e "${C_RED}❌ Файл не найден: $import_path${C_RESET}"
            return 0
        fi

        if prompt_yn "Восстановить системные настройки из архива $import_path и перезапустить службы?" "false"; then
            tar -xzf "$import_path" -C / 2>/dev/null
            systemctl daemon-reload 2>/dev/null || true
            sysctl --system >/dev/null 2>&1 || true
            [ -x /usr/local/bin/bobarev-router-up.sh ] && /usr/local/bin/bobarev-router-up.sh
            [ -x /usr/local/bin/bobarev-cascade-ru.sh ] && /usr/local/bin/bobarev-cascade-ru.sh
            [ -f /etc/systemd/system/derper.service ] && [ -x /usr/local/bin/derper ] && silent_run systemctl restart derper.service
            is_naive_active && silent_run systemctl restart caddy.service
            is_warp_active && silent_run systemctl restart wg-quick@warp
            silent_run systemctl restart systemd-journald
            silent_run systemctl restart sshd || silent_run systemctl restart ssh
            command -v ufw &>/dev/null && flush_and_reload_nat
            disable_ufw_strict_rpfilter
            echo -e "${C_GREEN}✅ Настройки успешно восстановлены и применены!${C_RESET}"
        fi
    fi
}

run_full_auto_setup() {
    echo "🚀 ЗАПУСК ПОСЛЕДОВАТЕЛЬНОЙ НАСТРОЙКИ ВСЕХ КОМПОНЕНТОВ..."
    local local_aborted=false
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
    MODULE_CANCELED=false
}

# ------------------------------------------------------------------------------
# ОБРАБОТКА CLI-АРГУМЕНТОВ БЫСТРОГО ЗАПУСКА
# ------------------------------------------------------------------------------
if [ "${1:-}" != "" ]; then
    case "${1:-}" in
        --audit|-a)
            mod_server_audit
            exit 0
            ;;
        --update|-u)
            mod_apt_update
            exit 0
            ;;
        --backup|-b)
            mod_backup_manager
            exit 0
            ;;
        --auto)
            run_full_auto_setup
            exit 0
            ;;
        --help|-h)
            echo -e "${C_BOLD}BOBAREV SHELL v3.2.4 (Gold Master)${C_RESET}"
            echo "Использование: $0 [опция]"
            echo "  (без опций)   Запуск интерактивного меню"
            echo "  --audit, -a   Мгновенный вывод интеллектуального аудита (Модуль 17)"
            echo "  --update, -u  Обновление пакетов, приоритет IPv4 и настройка zRAM (Модуль 3)"
            echo "  --backup, -b  Экспорт или импорт настроек сервера (Модуль 19)"
            echo "  --auto        Последовательная настройка сервера целиком (Шаги 1-12)"
            echo "  --help, -h    Показать эту справку"
            exit 0
            ;;
        *)
            echo -e "${C_RED}Неизвестный параметр: $1${C_RESET} (используйте --help для справки)" >&2
            exit 1
            ;;
    esac
fi

# ==============================================================================
# === 🚀 ЗАПУСК ГЛАВНОГО МЕНЮ (ВСЕГДА В САМОМ КОНЦЕ ФАЙЛА) ===
# ==============================================================================
while true; do
    ts_main_status="Отсутствует"
    if command -v tailscale &>/dev/null; then
        if is_derp_active; then
            ts_main_status="Активна + Личный DERP"
        elif is_tailscale_web_active; then
            ts_main_status="Активна (веб-панель)"
        else
            ts_main_status="Активна"
        fi
    fi
    
    if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
        ufw_status="Активен"
    else
        ufw_status="Не активен"
    fi
    
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    tz="${tz#Etc/}"

    export TERM_COLS=$(tput cols 2>/dev/null || echo 85)
    export TERM_LINES=$(tput lines 2>/dev/null || echo 27)
    export WT_WIDTH=$((TERM_COLS < 85 ? TERM_COLS : 85))
    export WT_HEIGHT=$((TERM_LINES < 27 ? TERM_LINES : 27))
    WT_MENU=$((WT_HEIGHT - 14))
    if [ "$WT_MENU" -lt 6 ]; then WT_MENU=6; fi

    choice=""
    if ! choice=$(whiptail --title "🔧 ГЛАВНОЕ МЕНЮ" \
    --menu "\n  💻 Системные данные:
  • Хост: $(hostname) ($(get_system_type_short))
  • Часовой пояс: $tz
  • Статус UFW: $ufw_status
  • Сеть Tailscale: $ts_main_status

  📌 Выберите желаемый этап настройки:" $WT_HEIGHT $WT_WIDTH $WT_MENU \
    "1" "🌐 Часовой пояс" \
    "2" "📌 Имя сервера" \
    "3" "📦 Обновление компонентов" \
    "4" "👤 Создание и настройка пользователя" \
    "5" "🔑 Привязка ключа безопасности" \
    "6" "🔒 Конфигурация удаленного доступа" \
    "7" "🔒 Настройка системной защиты" \
    "8" "🔥 Управление брандмауэром" \
    "9" "🔐 Блокировка доступа суперпользователя" \
    "10" "🔗 Настройка закрытой сети Tailscale" \
    "11" "📝 Управление системными журналами" \
    "12" "⚡ Оптимизация памяти" \
    "13" "💾 Управление файлом подкачки" \
    "14" "💻 Утилиты ПК и режим процессора" \
    "15" "📺 Сброс видеовыхода HDMI" \
    "16" "⏳ Анализ времени загрузки" \
    "17" "🔍 Интеллектуальный аудит системы" \
    "18" "📡 Режим локального маршрутизатора" \
    "19" "📦 Экспорт / Импорт настроек" \
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
        19) mod_backup_manager; pause_enter ;;
        A) run_full_auto_setup; pause_enter ;;
    esac
done
