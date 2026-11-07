#!/bin/bash
set -euo pipefail

# ==============================================================================
# СКРИПТ КОМПЛЕКСНОЙ НАСТРОЙКИ СЕРВЕРА (BOBAREV SHELL)
# Версия: 3.14.55 (Dual-Stack Mullvad VPS Gateway + VLESS-REALITY + Clean Router-v2 Edition)
# ==============================================================================

# Menu headers use the exact selected main-menu label.
BOBAREV_SECTION_TITLE=''
whiptail() {
 local -a forwarded=()
 while (($#)); do
  if [[ "$1" == --title && -n "${BOBAREV_SECTION_TITLE:-}" ]]; then
   shift
   if (($#)); then shift; fi
   continue
  fi
  forwarded+=("$1")
  shift
 done
 if [[ -n "${BOBAREV_SECTION_TITLE:-}" ]]; then
  command whiptail --title "$BOBAREV_SECTION_TITLE" "${forwarded[@]}"
 else
  command whiptail "${forwarded[@]}"
 fi
}
export BOBAREV_SECTION_TITLE
export -f whiptail
declare -A BOBAREV_MENU_TITLES=()

C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_WHITE='\033[1;37m'
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
UDP2RAW_BIN="/usr/local/bin/udp2raw"
UDP2RAW_SERVICE="/etc/systemd/system/bobarev-udp2raw.service"


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
    ip -4 route show table main default 2>/dev/null | grep -vE "tailscale0|wg[0-9]*|wgcf|wg-cascade|warp|tun[0-9]*|tap[0-9]*|utun[0-9]*|awg[0-9]*|zt[a-z0-9]*|nebula[0-9]*|easytier[0-9]*" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || echo ""
}

DEFAULT_WAN_IF=$(get_wan_if)

get_cpu_rps_mask() {
    local ncpu
    ncpu=$(nproc 2>/dev/null || echo 1)
    [[ "$ncpu" =~ ^[0-9]+$ ]] || ncpu=1
    (( ncpu < 1 )) && ncpu=1
    (( ncpu > 64 )) && ncpu=64
    python3 -c "print(hex((1 << $ncpu) - 1)[2:])" 2>/dev/null || printf '%x' $(( (1 << (ncpu > 16 ? 16 : ncpu)) - 1 ))
}

silent_run() { "$@" >/dev/null 2>&1 || true; }

verify_sha256() {
    local file="$1"
    local expected="$2"
    [ -z "$expected" ] && return 0
    local act_sha=$(sha256sum "$file" | awk '{print $1}')
    if [ "$act_sha" != "$expected" ]; then
        echo -e "${C_RED} Ошибка: контрольная сумма SHA256 файла $file не совпала!${C_RESET}"
        return 1
    fi
    return 0
}

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


is_udp2raw_active() {
    systemctl is-active --quiet bobarev-udp2raw.service 2>/dev/null && return 0
    return 1
}

is_wg_cascade_active() {
    systemctl is-active --quiet wg-quick@wg-cascade.service 2>/dev/null && return 0
    ip link show wg-cascade >/dev/null 2>&1 && return 0
    return 1
}

is_wg0_active() {
    systemctl is-active --quiet wg-quick@wg0.service 2>/dev/null && return 0
    ip link show wg0 >/dev/null 2>&1 && return 0
    return 1
}

ensure_wg_kernel_modules() {
    silent_run modprobe wireguard
    silent_run modprobe nf_conntrack
    silent_run modprobe tcp_bbr
    silent_run modprobe ip6table_mangle
    silent_run modprobe xt_TCPMSS
    mkdir -p /etc/modules-load.d
    cat << 'MOD_EOF' > /etc/modules-load.d/bobarev-network-modules.conf
wireguard
nf_conntrack
tcp_bbr
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
    if [ -f /etc/ufw/before.rules ]; then
        if ! grep -q "TCPMSS" /etc/ufw/before.rules; then
            sed -i '1s/^/*mangle\n:FORWARD ACCEPT [0:0]\n-F FORWARD\n-A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n\n/' /etc/ufw/before.rules
        elif ! grep -q "^-F FORWARD" /etc/ufw/before.rules; then
            sed -i '/^:FORWARD ACCEPT/a -F FORWARD' /etc/ufw/before.rules 2>/dev/null || true
        fi
    fi
    if [ -f /etc/ufw/before6.rules ]; then
        sed -i '/^\*mangle/,/^COMMIT/d' /etc/ufw/before6.rules 2>/dev/null || true
    fi
    if command -v ip6tables &>/dev/null; then
        ip6tables -t mangle -F FORWARD 2>/dev/null || true
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
            echo -e "${C_BLUE} Обнаружена маска /32 на интерфейсе $wan_dev: закреплена постоянная привязка SNAT ($pub_ip).${C_RESET}"
        fi
    else
        iptables -t nat -A POSTROUTING -o "$wan_dev" -j MASQUERADE
        ensure_ufw_nat_rule "-A POSTROUTING -o $wan_dev -j MASQUERADE"
        if [ "$quiet" != "true" ]; then
            echo -e "${C_BLUE} Закреплено правило маскарадинга (MASQUERADE) для $wan_dev в /etc/ufw/before.rules.${C_RESET}"
        fi
    fi
    return 0
}

select_and_apply_routed_interfaces() {
    local wan_dev="$1"
    [ -z "$wan_dev" ] && return 0

    local candidate_ifs=$(ip -br link show 2>/dev/null | grep -v "DOWN" | awk '{print $1}' | sed 's/@.*//' | grep -vE "^(lo|${wan_dev}|docker.*|veth.*|br-.*)$" || echo "")
    if [ -z "$candidate_ifs" ]; then
        echo -e "${C_BLUE} Дополнительные интерфейсы не обнаружены (базовая маршрутизация для $wan_dev включена).${C_RESET}"
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
            echo -e "${C_BLUE} Разрешена сквозная маршрутизация: $sif <-> $wan_dev.${C_RESET}"
        done
    fi
    return 0
}

flush_and_reload_nat() {
    local wan_dev=$(get_wan_if)
    # Preserve foreign NAT chains.
    :
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
    if is_wg_cascade_active; then
        iptables -t nat -C POSTROUTING -o wg-cascade -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o wg-cascade -j MASQUERADE 2>/dev/null || true
    fi
    if is_wg0_active; then
        iptables -t nat -C POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o wg0 -j MASQUERADE 2>/dev/null || true
    fi
    if [ -x /usr/local/bin/bobarev-cascade-ru.sh ]; then
        /usr/local/bin/bobarev-cascade-ru.sh >/dev/null 2>&1 || true
    fi
    if [ -x /usr/local/sbin/bobarev-router-v2 ] && [ -f /etc/bobarev-router-v2/config ]; then
        /usr/local/sbin/bobarev-router-v2 start >/dev/null 2>&1 || true
    elif [ -x /usr/local/bin/bobarev-router-up.sh ]; then
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
            echo -e "${C_GREEN} Приоритет сетевых правил передан брандмауэру UFW (системный режим).${C_RESET}"
        fi
    else
        silent_run tailscale set --netfilter-mode=on
        flush_and_reload_nat
        if [ "$quiet" != "true" ]; then
            echo -e "${C_BLUE} Приоритет сетевых правил оставлен Tailscale (встроенный авто-режим).${C_RESET}"
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# СТЕК КАСКАДА: NAIVEPROXY (CADDY 2), ТЮНИНГ TCP И ПОЛЬЗОВАТЕЛИ
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
    local caddy_cache="/var/lib/bobarev-shell-mullvad/caddy/caddy"
    if [ -x "$CADDY_BIN" ] && { "$CADDY_BIN" list-modules 2>/dev/null || true; } | grep -q "http.handlers.forward_proxy"; then
        echo -e "${C_GREEN} Бинарник Caddy с модулем NaiveProxy (forward_proxy) уже скомпилирован.${C_RESET}"
        return 0
    fi
    if [ -x "$caddy_cache" ] && { "$caddy_cache" list-modules 2>/dev/null || true; } | grep -q "http.handlers.forward_proxy"; then
        install -m 755 "$caddy_cache" "$CADDY_BIN"
        echo -e "${C_GREEN} Восстановлен ранее собранный Caddy с NaiveProxy из локального кэша.${C_RESET}"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    if ! command -v curl &>/dev/null || ! command -v wget &>/dev/null || ! command -v git &>/dev/null || ! command -v htpasswd &>/dev/null; then
        echo -e "${C_BLUE} Доустановка утилит сборки Caddy (git, openssl, apache2-utils)...${C_RESET}"
        apt-get update -qq
        apt-get install -yq curl wget git tar unzip openssl ca-certificates apache2-utils >/dev/null 2>&1
    fi

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

    # Используем динамическую временную папку, чтобы сборка не падала с "no space left on device"
    local build_tmp_dir=$(mktemp -d /root/.caddy-build-XXXXXX)

    if [ "$need_go" = true ]; then
        echo -e "${C_BLUE} Установка компилятора Go ${GO_VERSION_PIN} с проверкой SHA256...${C_RESET}"
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
            echo -e "${C_RED} Ошибка: контрольная сумма SHA256 архива Go не совпала!${C_RESET}"
            return 1
        fi
        rm -rf /usr/local/go
        tar -C /usr/local -xzf "$go_tmp"
        rm -f "$go_tmp"
        echo 'export PATH="/usr/local/go/bin:$PATH"' > /etc/profile.d/go.sh
        export PATH="/usr/local/go/bin:$PATH"
        echo -e "${C_GREEN} Компилятор Go ${GO_VERSION_PIN} успешно установлен.${C_RESET}"
    fi

    echo -e "${C_BLUE} Сборка Caddy ${CADDY_VERSION_PIN} с модулем klzgrad/forwardproxy@naive (занимает 3-10 минут)...${C_RESET}"
    export GOPATH="/root/go"
    export GOCACHE="/root/.cache/go-build"
    export GOTMPDIR="$build_tmp_dir"
    export TMPDIR="$build_tmp_dir"

    go install "github.com/caddyserver/xcaddy/cmd/xcaddy@${XCADDY_VERSION_PIN}"

    local tmp_caddy_bin="${build_tmp_dir}/caddy_built"
    "$GOPATH/bin/xcaddy" build "$CADDY_VERSION_PIN" \
        --with "github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${FORWARDPROXY_REF_PIN}" \
        --output "$tmp_caddy_bin" || true

    if [ -f "$tmp_caddy_bin" ]; then
        install -m 755 "$tmp_caddy_bin" "$CADDY_BIN"
        mkdir -p "$(dirname "$caddy_cache")"
        install -m 755 "$tmp_caddy_bin" "$caddy_cache" 2>/dev/null || true
    fi

    rm -rf "$build_tmp_dir"
    unset GOTMPDIR TMPDIR

    if [ ! -x "$CADDY_BIN" ] || ! { "$CADDY_BIN" list-modules 2>/dev/null || true; } | grep -q "http.handlers.forward_proxy"; then
        echo -e "${C_RED} Ошибка сборки: модуль http.handlers.forward_proxy не найден в Caddy.${C_RESET}"
        return 1
    fi
    echo -e "${C_GREEN} Caddy ${CADDY_VERSION_PIN} + NaiveProxy успешно собран!${C_RESET}"
    return 0
}

render_naive_caddyfile() {
    if [[ -f /etc/naiveproxy/mesh-paused ]]; then echo "Каскад на паузе. Сначала возобновите его или переключите выход в меню управления каскадом."; return 1; fi
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
    email ${email}
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
$( [ "${CASCADE_ROLE:-}" = "ru_hysteria_entry" ] && echo "            upstream socks5://127.0.0.1:1080" )
$( [ "${CASCADE_ROLE:-}" = "ru_xray_entry" ] && echo "            upstream socks5://127.0.0.1:10808" )
$( if [ -f /etc/naiveproxy/mesh-upstream.port ] && [ "${CASCADE_ROLE:-}" = standalone_naive ]; then read -r nm_port < /etc/naiveproxy/mesh-upstream.port; if [[ "$nm_port" =~ ^[0-9]{4,5}$ ]] && ((10#$nm_port >= 1024 && 10#$nm_port <= 65535)); then echo "            upstream socks5://127.0.0.1:$nm_port"; else echo "            upstream socks5://127.0.0.1:1"; fi; fi )
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
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVC_EOF

    "$CADDY_BIN" fmt --overwrite "$CADDYFILE" >/dev/null 2>&1 || true
    if ! "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >"$CADDYFILE.validate.log" 2>&1;then
        echo -e "${C_RED} Caddyfile не прошёл валидацию:${C_RESET}" >&2
        tail -n 40 "$CADDYFILE.validate.log" >&2
        rm -f "$CADDYFILE.validate.log"
        return 1
    fi
    rm -f "$CADDYFILE.validate.log"
    systemctl daemon-reload || return 1
    systemctl enable caddy.service || return 1
    if systemctl is-active --quiet caddy.service; then
        systemctl reload caddy.service || systemctl restart caddy.service || return 1
    else
        systemctl restart caddy.service || return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet caddy.service; then
        echo -e "${C_RED} Ошибка запуска caddy.service! Проверка синтаксиса Caddyfile:${C_RESET}"
        /usr/local/bin/caddy validate --config "$CADDYFILE" 2>&1 || true
        journalctl -u caddy.service -n 10 --no-pager 2>/dev/null || true
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
        echo -e "${C_RED} Не удалось создать bcrypt-хеш пароля.${C_RESET}"
        return 1
    fi

    sed -i "/^${u_name}:/d" "$NAIVE_USERS_FILE" 2>/dev/null || true
    echo "${u_name}:${b_hash}" >> "$NAIVE_USERS_FILE"

    sed -i "/^${u_name}:/d" "$NAIVE_PASS_FILE" 2>/dev/null || true
    echo "${u_name}:${u_pass}" >> "$NAIVE_PASS_FILE"
    chmod 600 "$NAIVE_USERS_FILE" "$NAIVE_PASS_FILE"
    return 0
}

delete_naive_user_interactive() {
    if [ ! -s "$NAIVE_PASS_FILE" ]; then
        echo -e "${C_YELLOW} Список пользователей NaiveProxy пуст.${C_RESET}"
        return 0
    fi

    local menu_items=()
    local count=0
    while IFS=: read -r u _; do
        [ -z "$u" ] && continue
        menu_items+=("$u" "Удалить доступ и ссылку для $u")
        count=$((count + 1))
    done < "$NAIVE_PASS_FILE"

    if [ "$count" -eq 0 ]; then
        echo -e "${C_YELLOW} Пользователи не найдены.${C_RESET}"
        return 0
    fi

    local list_h=$((count < 7 ? count : 7))
    local box_h=$((list_h + 8))
    local del_u=""
    if ! smart_menu "Удаление пользователя NaiveProxy" "Выберите пользователя для удаления:" $box_h $WT_WIDTH $list_h "del_u" "${menu_items[@]}" || [ -z "$del_u" ]; then
        echo -e "${C_YELLOW} Удаление отменено.${C_RESET}"
        return 0
    fi

    if prompt_yn "Вы действительно хотите удалить пользователя '$del_u' и отозвать его ссылку?" "false"; then
        sed -i "/^${del_u}:/d" "$NAIVE_USERS_FILE" 2>/dev/null || true
        sed -i "/^${del_u}:/d" "$NAIVE_PASS_FILE" 2>/dev/null || true
        render_naive_caddyfile
        echo -e "${C_GREEN} Пользователь '$del_u' успешно удален, конфигурация Caddy перезагружена без обрыва связи!${C_RESET}"
    fi
}

manage_naive_users_menu() {
    if [ ! -f "$CADDYFILE" ]; then
        echo -e "${C_YELLOW} Сначала настройте Сервер 1 (Вход в РФ).${C_RESET}"
        return 0
    fi

    while true; do
        MODULE_CANCELED=false
        local u_cnt=0
        [ -f "$NAIVE_PASS_FILE" ] && u_cnt=$(grep -c ":" "$NAIVE_PASS_FILE" 2>/dev/null || true); u_cnt="${u_cnt:-0}"

        local u_choice
        if ! smart_menu "Управление пользователями NaiveProxy" "\nАктивных пользователей: $u_cnt\nВыберите действие:" 15 $WT_WIDTH 4 "u_choice" \
        "1" " Добавить или изменить пользователя" \
        "2" " Удалить пользователя из списка" \
        "3" " Показать ссылки всех пользователей" \
        "0" " Вернуться назад" || [ "$u_choice" = "0" ]; then
            break
        fi

        clear
        case "$u_choice" in
            1)
                local new_u=""
                prompt_default "Введите имя пользователя NaiveProxy:" "user1" new_u
                if [ "$MODULE_CANCELED" = false ] && [ -n "$new_u" ]; then
                    new_u=$(echo "$new_u" | tr -dc 'a-zA-Z0-9_-')
                    local def_p=$(openssl rand -base64 18 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16 || { echo -e "${C_RED} Ошибка генератора паролей.${C_RESET}" >&2; return 1; })
                    local new_p=""
                    prompt_default "Введите пароль для $new_u:" "$def_p" new_p
                    if [ "$MODULE_CANCELED" = false ] && [ -n "$new_p" ]; then
                        add_or_update_naive_user "$new_u" "$new_p"
                        render_naive_caddyfile
                        echo -e "${C_GREEN} Пользователь $new_u сохранен, конфигурация Caddy обновлена!${C_RESET}"
                        print_naive_shadowrocket_links
                    fi
                fi
                pause_enter
                ;;
            2)
                delete_naive_user_interactive
                pause_enter
                ;;
            3)
                print_naive_shadowrocket_links
                pause_enter
                ;;
        esac
    done
}

tune_fq_qdisc_interfaces() {
    command -v tc &>/dev/null || return 0
    local wan_if=$(get_wan_if)
    for dev in $wan_if tailscale0 wg0 wg-cascade warp; do
        [ -z "$dev" ] && continue
        if ip link show "$dev" >/dev/null 2>&1; then
            tc qdisc replace dev "$dev" root fq limit 30000 flow_limit 10000 2>/dev/null || true
        fi
    done
}

apply_naive_tcp_tuning_profile() {
    local profile="${1:-balanced}"
    silent_run modprobe nf_conntrack
    mkdir -p /etc/sysctl.d

    if [ "$profile" = "aggressive" ]; then
        cat << 'TUNE_EOF' > /etc/sysctl.d/99-zzz-bobarev-naive-tuning.conf
# Bobarev Shell v3.14.55: Aggressive Anti-HoL Blocking & Low-Latency Profile
net.ipv4.tcp_notsent_lowat = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_reordering = 30
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.optmem_max = 2097152
net.core.netdev_max_backlog = 30000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_mem = 131072 262144 524288
net.ipv4.udp_mem = 131072 262144 524288
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 14400
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
TUNE_EOF
    else
        cat << 'TUNE_EOF' > /etc/sysctl.d/99-zzz-bobarev-naive-tuning.conf
# Bobarev Shell v3.14.55: Zero-Bufferbloat High-Throughput Balanced Profile
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_thin_linear_timeouts = 0
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_reordering = 30
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.optmem_max = 2097152
net.core.netdev_max_backlog = 30000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_mem = 131072 262144 524288
net.ipv4.udp_mem = 131072 262144 524288
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 14400
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
TUNE_EOF
    fi

    sysctl -p /etc/sysctl.d/99-zzz-bobarev-naive-tuning.conf >/dev/null 2>&1 || true
    tune_fq_qdisc_interfaces
    ip tcp_metrics flush all >/dev/null 2>&1 || true

    if systemctl is-active --quiet caddy.service 2>/dev/null; then
        systemctl restart caddy.service 2>/dev/null || true
    fi

    if [ -f /etc/default/bobarev-cascade ]; then
        sed -i '/^TCP_TUNE_PROFILE=/d' /etc/default/bobarev-cascade 2>/dev/null || true
        echo "TCP_TUNE_PROFILE=\"$profile\"" >> /etc/default/bobarev-cascade
    fi
}

print_naive_shadowrocket_links() {
    if [ ! -f /etc/default/bobarev-cascade ] || [ ! -s "$NAIVE_PASS_FILE" ]; then
        echo -e "${C_YELLOW} Пользователи NaiveProxy еще не созданы или Сервер 1 не настроен.${C_RESET}"
        return 0
    fi
    # shellcheck disable=SC1091
    source /etc/default/bobarev-cascade
    local dom="${NAIVE_DOMAIN:-$(hostname)}"

    local show_real=false
    if prompt_yn "Показать реальные пароли в ссылках для копирования в Shadowrocket?\n\n Да: готовые рабочие ссылки.\n Нет: скрыть пароли звездочками (безопасно для скриншотов)." "true"; then
        show_real=true
    fi

    echo -e "\n${C_CYAN} === ГОТОВЫЕ ССЫЛКИ ДЛЯ SHADOWROCKET ===${C_RESET}"
    while IFS=: read -r u p; do
        [ -z "$u" ] || [ -z "$p" ] && continue
        local disp_p="********"
        local b64_str="Скрыто_для_скриншота"
        if [ "$show_real" = true ]; then
            disp_p="$p"
            b64_str=$(printf '%s' "${u}:${p}@${dom}:443" | base64 -w0 2>/dev/null || printf '%s' "${u}:${p}@${dom}:443" | base64)
        fi
        echo -e "\n Пользователь: ${C_BOLD}${u}${C_RESET} (Сервер: ${C_GREEN}${dom}${C_RESET}, Порт: ${C_GREEN}443${C_RESET})"
        echo -e "   ${C_GREEN} ОСНОВНАЯ ССЫЛКА HTTP/2 (Мультиплексирование в 1 клик, рекомендуется для YouTube и стриминга):${C_RESET}"
        echo -e "    ${C_BOLD}${C_GREEN}http2://${b64_str}?obfs=none#${dom}-HTTP2-${u}${C_RESET}"
        echo -e "   ${C_BLUE}Резервная ссылка HTTPS + Padding (классический формат, требует ручного включения HTTP2 в TLS):${C_RESET}"
        echo -e "    ${C_BLUE}https://${u}:${disp_p}@${dom}:443?padding=true#${dom}-${u}${C_RESET}"
    done < "$NAIVE_PASS_FILE"

    echo -e "\n${C_BLUE} Почему основная ссылка http2:// работает быстрее и стабильнее чем https://:${C_RESET}"
    echo -e "   Схема ${C_BOLD}http2://${C_RESET} выбирает HTTP/2 в ссылке. Фактический протокол и стабильность зависят от клиента, сети и сайта."
    echo -e "   HTTP/2 может мультиплексировать несколько запросов в одном TLS-соединении, но не гарантирует отсутствие пауз или лучшую скорость."
}

write_bobarev_cascade_ru_script() {
    cat << 'RU_SH_EOF' > /usr/local/bin/bobarev-cascade-ru.sh
#!/bin/bash
[ ! -f /etc/default/bobarev-cascade ] && exit 0
source /etc/default/bobarev-cascade

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [ -f "$rp" ] && echo 0 > "$rp" 2>/dev/null || true
done
if [ -f /etc/sysctl.d/99-zzz-bobarev-naive-tuning.conf ]; then
    sysctl -p /etc/sysctl.d/99-zzz-bobarev-naive-tuning.conf >/dev/null 2>&1 || true
else
    sysctl -w net.ipv4.tcp_notsent_lowat=16384 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_base_mss=1024 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_no_metrics_save=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_autocorking=0 >/dev/null 2>&1 || true
fi
WAN_IF=$(ip -4 route show table main default 2>/dev/null | grep -vE "tailscale0|wg[0-9]*|wgcf|wg-cascade|warp|tun[0-9]*|tap[0-9]*|utun[0-9]*|awg[0-9]*|zt[a-z0-9]*|nebula[0-9]*|easytier[0-9]*" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || true)
if [ -n "$WAN_IF" ] && command -v tc &>/dev/null; then
    tc qdisc replace dev "$WAN_IF" root fq limit 30000 flow_limit 10000 2>/dev/null || true
fi
PUB_IP="${SERVER_PUB_IP:-}"
if [ -z "$PUB_IP" ] && [ -n "$WAN_IF" ]; then
    PUB_IP=$(ip -4 -o addr show dev "$WAN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)
fi

while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
while iptables -t mangle -D OUTPUT -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done

for m_val in 1360 1300 1260 1240 1220 1200 1160 1140 1120 1080; do
    while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$m_val" 2>/dev/null; do :; done
    while iptables -t mangle -D FORWARD -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$m_val" 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$m_val" 2>/dev/null; do :; done
    while iptables -t mangle -D POSTROUTING -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$m_val" 2>/dev/null; do :; done
    while iptables -t mangle -D FORWARD -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$m_val" 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$m_val" 2>/dev/null; do :; done
    while iptables -t mangle -D POSTROUTING -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$m_val" 2>/dev/null; do :; done
done

if [ "${CASCADE_ROLE:-}" = "ru_entry" ]; then
    if [ -n "$PUB_IP" ]; then
        while ip rule del from "$PUB_IP" lookup main priority 100 2>/dev/null; do :; done
        ip rule add from "$PUB_IP" lookup main priority 100 2>/dev/null || true
    fi
    ip link set dev tailscale0 mtu 1280 txqueuelen 10000 2>/dev/null || true
    while iptables -t nat -D POSTROUTING -o tailscale0 -j MASQUERADE 2>/dev/null; do :; done
    iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE 2>/dev/null || true
    # Для связки NaiveProxy -> Tailscale (MTU 1280 + Disco) -> WARP (MTU 1280) фиксируем MSS 1140
    iptables -t mangle -I FORWARD 1 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140 2>/dev/null || true
    iptables -t mangle -I OUTPUT 1 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140 2>/dev/null || true
    iptables -t mangle -I POSTROUTING 1 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140 2>/dev/null || true
    if [ -n "${EXIT_TS_IP:-}" ] && command -v tailscale &>/dev/null; then
        tailscale set --exit-node="$EXIT_TS_IP" --exit-node-allow-lan-access=true --accept-routes=true 2>/dev/null || true
    fi
elif [ "${CASCADE_ROLE:-}" = "ru_wg_entry" ]; then
    if command -v tailscale &>/dev/null; then
        tailscale set --exit-node= 2>/dev/null || true
    fi
    while ip rule del priority 100 2>/dev/null; do :; done
    [ -n "$PUB_IP" ] && while ip rule del from "$PUB_IP" lookup main 2>/dev/null; do :; done
    ip route replace default dev wg-cascade table 51888 2>/dev/null || true
    ip link set dev wg-cascade mtu 1280 txqueuelen 10000 2>/dev/null || true
    while iptables -t nat -D POSTROUTING -o wg-cascade -j MASQUERADE 2>/dev/null; do :; done
    iptables -t nat -I POSTROUTING 1 -o wg-cascade -j MASQUERADE 2>/dev/null || true
    iptables -t mangle -I FORWARD 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
    iptables -t mangle -I OUTPUT 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
    iptables -t mangle -I POSTROUTING 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
fi
RU_SH_EOF
    chmod +x /usr/local/bin/bobarev-cascade-ru.sh

    cat << 'RU_SVC_EOF' > /etc/systemd/system/bobarev-cascade-ru.service
[Unit]
Description=Bobarev Cascade RU Routing (NaiveProxy -> Tunnel)
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bobarev-cascade-ru.sh

[Install]
WantedBy=multi-user.target
RU_SVC_EOF
    silent_run systemctl daemon-reload
    silent_run systemctl enable --now bobarev-cascade-ru.service
}



setup_hybrid_wg_routing() {
    echo -e "${C_CYAN} === НАСТРОЙКА ГИБРИДНОГО ШЛЮЗА: NAIVEPROXY + TAILSCALE EXIT NODE -> WG0 ===${C_RESET}"
    ensure_wg_kernel_modules
    
    local ssh_p="22"
    local sshd_c=$(get_sshd_cmd)
    if [ -n "$sshd_c" ]; then
        ssh_p=$($sshd_c -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")
    fi
    ssh_p="${ssh_p//[^0-9]/}"
    [ -z "$ssh_p" ] && ssh_p="22"

    local use_existing=false
    if [ -f /etc/wireguard/wg0.conf ]; then
        if prompt_yn "Конфигурация /etc/wireguard/wg0.conf уже существует.
Использовать существующий профиль WireGuard (применив надежные правила FwMark 51820 и PBR)?" "true"; then
            use_existing=true
        fi
    fi

    local tmp_wg
    tmp_wg=$(mktemp /root/.wg0_input.XXXXXX)
    chmod 600 "$tmp_wg"

    if [ "$use_existing" = false ]; then
        whiptail --title "Конфигурация WireGuard" --msgbox "Сейчас откроется редактор nano.
Вставьте ваш конфиг от провайдера или зарубежного сервера (секции [Interface] и [Peer]).

Для сохранения нажмите: Ctrl+O -> Enter -> Ctrl+X." 14 $WT_WIDTH
        nano "$tmp_wg"
    else
        cp /etc/wireguard/wg0.conf "$tmp_wg"
    fi

    local priv=$(awk -F'=' '/^[[:space:]]*PrivateKey[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' "$tmp_wg" 2>/dev/null | tr -d '[:space:]')
    local addr=$(awk -F'=' '/^[[:space:]]*Address[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' "$tmp_wg" 2>/dev/null | tr -d '[:space:]')
    local pub=$(awk -F'=' '/^[[:space:]]*PublicKey[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' "$tmp_wg" 2>/dev/null | tr -d '[:space:]')
    local psk=$(awk -F'=' '/^[[:space:]]*PresharedKey[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' "$tmp_wg" 2>/dev/null | tr -d '[:space:]')
    local ep=$(awk -F'=' '/^[[:space:]]*Endpoint[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' "$tmp_wg" 2>/dev/null | tr -d '[:space:]')
    local keepalive=$(awk -F'=' '/^[[:space:]]*PersistentKeepalive[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' "$tmp_wg" 2>/dev/null | tr -dc '0-9')
    [ -z "$keepalive" ] && keepalive="25"
    rm -f "$tmp_wg"

    if [ -z "$priv" ] || [ -z "$addr" ] || [ -z "$pub" ] || [ -z "$ep" ]; then
        echo -e "${C_RED} Ошибка: В введенной конфигурации отсутствуют обязательные поля (PrivateKey, Address, PublicKey или Endpoint)!${C_RESET}"
        return 1
    fi

    local psk_line=""
    [ -n "$psk" ] && psk_line="PresharedKey = $psk"

    echo -e "${C_BLUE} Формирование безопасного профиля /etc/wireguard/wg0.conf с FwMark = 51820...${C_RESET}"
    mkdir -p /etc/wireguard
    cat << EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $priv
Address = $addr
FwMark = 51820
Table = off

# 1. Форвардинг ядра и отключение строгого rp_filter
PostUp = sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
PostUp = for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do [ -f "\$rp" ] && echo 0 > "\$rp"; done

# 2. Маршруты в изолированную таблицу 150
PostUp = ip route replace 100.64.0.0/10 dev tailscale0 table 150 2>/dev/null || true
PostUp = ip route replace default dev wg0 table 150
PostUp = ip route replace 100.64.0.0/10 dev tailscale0 table main 2>/dev/null || true

# 3. ЗАЩИТА СИСТЕМНОГО ДОСТУПА (ВЫСОКИЙ ПРИОРИТЕТ 95-100 -> в таблицу main / ens3):
# А) Пакеты самого WireGuard (FwMark 51820) — защита от зацикливания туннеля!
PostUp = ip rule del fwmark 51820 lookup main priority 95 2>/dev/null || true
PostUp = ip rule add fwmark 51820 lookup main priority 95

# Б) Подсеть Tailscale (100.64.0.0/10) — трафик между узлами идет строго через tailscale0
PostUp = ip rule del to 100.64.0.0/10 lookup main priority 96 2>/dev/null || true
PostUp = ip rule add to 100.64.0.0/10 lookup main priority 96

# В) Связь демона Tailscale с пирами и серверами координации (порт 41641/udp)
PostUp = ip rule del sport 41641 lookup main priority 97 2>/dev/null || true
PostUp = ip rule add sport 41641 lookup main priority 97

# Г) Ответы SSH (порт $ssh_p) — сессия SSH никогда не упадет
PostUp = ip rule del sport $ssh_p lookup main priority 98 2>/dev/null || true
PostUp = ip rule add sport $ssh_p lookup main priority 98

# Д) Ответы на входящие соединения с физического интерфейса (CONNMARK + порты 443/80)
PostUp = ip rule del fwmark 0x80000000/0x80000000 lookup main priority 94 2>/dev/null || true
PostUp = ip rule add fwmark 0x80000000/0x80000000 lookup main priority 94
PostUp = iptables -t mangle -C PREROUTING -i ${DEFAULT_WAN_IF:-ens3} -m addrtype --dst-type LOCAL -m conntrack --ctdir ORIGINAL -j CONNMARK --set-xmark 0x80000000/0x80000000 2>/dev/null || iptables -t mangle -I PREROUTING 1 -i ${DEFAULT_WAN_IF:-ens3} -m addrtype --dst-type LOCAL -m conntrack --ctdir ORIGINAL -j CONNMARK --set-xmark 0x80000000/0x80000000 2>/dev/null || true
PostUp = iptables -t mangle -C OUTPUT -m connmark --mark 0x80000000/0x80000000 -j CONNMARK --restore-mark --nfmask 0x80000000 --ctmask 0x80000000 2>/dev/null || iptables -t mangle -A OUTPUT -m connmark --mark 0x80000000/0x80000000 -j CONNMARK --restore-mark --nfmask 0x80000000 --ctmask 0x80000000 2>/dev/null || true
PostUp = ip rule del sport 443 lookup main priority 99 2>/dev/null || true
PostUp = ip rule add sport 443 lookup main priority 99
PostUp = ip rule del sport 80 lookup main priority 100 2>/dev/null || true
PostUp = ip rule add sport 80 lookup main priority 100

# 4. НАПРАВЛЕНИЕ ТРАФИКА В WG0:
# А) Клиенты Tailscale Exit Node (входящие с интерфейса tailscale0)
PostUp = ip rule del iif tailscale0 lookup 150 priority 1000 2>/dev/null || true
PostUp = ip rule add iif tailscale0 lookup 150 priority 1000

# Б) Запросы NaiveProxy/Caddy и весь исходящий трафик сервера в интернет
PostUp = ip rule del lookup 150 priority 30000 2>/dev/null || true
PostUp = ip rule add lookup 150 priority 30000

# 5. ФОРВАРДИНГ, MSS CLAMPING И NAT
PostUp = iptables -C FORWARD -i tailscale0 -o wg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i tailscale0 -o wg0 -j ACCEPT 2>/dev/null || true
PostUp = iptables -C FORWARD -i wg0 -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostUp = iptables -t nat -C POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t mangle -C FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -C OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# --- ПРАВИЛА ОЧИСТКИ ПРИ ОСТАНОВКЕ (PostDown) ---
PostDown = ip rule del lookup 150 priority 30000 2>/dev/null || true
PostDown = ip rule del iif tailscale0 lookup 150 priority 1000 2>/dev/null || true
PostDown = ip rule del sport 80 lookup main priority 100 2>/dev/null || true
PostDown = ip rule del sport 443 lookup main priority 99 2>/dev/null || true
PostDown = ip rule del sport $ssh_p lookup main priority 98 2>/dev/null || true
PostDown = ip rule del sport 41641 lookup main priority 97 2>/dev/null || true
PostDown = ip rule del to 100.64.0.0/10 lookup main priority 96 2>/dev/null || true
PostDown = ip rule del fwmark 51820 lookup main priority 95 2>/dev/null || true
PostDown = ip rule del fwmark 0x80000000/0x80000000 lookup main priority 94 2>/dev/null || true
PostDown = iptables -t mangle -D OUTPUT -m connmark --mark 0x80000000/0x80000000 -j CONNMARK --restore-mark --nfmask 0x80000000 --ctmask 0x80000000 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -i ${DEFAULT_WAN_IF:-ens3} -m addrtype --dst-type LOCAL -m conntrack --ctdir ORIGINAL -j CONNMARK --set-xmark 0x80000000/0x80000000 2>/dev/null || true
PostDown = iptables -t mangle -D OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg0 -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i tailscale0 -o wg0 -j ACCEPT 2>/dev/null || true
PostDown = ip route flush table 150 2>/dev/null || true

[Peer]
PublicKey = $pub
$psk_line
Endpoint = $ep
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = $keepalive
EOF
    chmod 600 /etc/wireguard/wg0.conf

    echo -e "${C_BLUE} Запуск и включение автозагрузки WireGuard (wg0)...${C_RESET}"
    silent_run systemctl daemon-reload
    systemctl reset-failed wg-quick@wg0 2>/dev/null || true
    systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
    if ! systemctl restart wg-quick@wg0; then
        echo -e "${C_YELLOW} Повторная инициализация интерфейса wg0...${C_RESET}"
        ip link del dev wg0 2>/dev/null || true
        systemctl restart wg-quick@wg0
    fi

    if command -v tailscale &>/dev/null; then
        silent_run tailscale set --advertise-exit-node=true
    fi

    ensure_ufw_nat_rule "-A POSTROUTING -o wg0 -j MASQUERADE"
    if command -v ufw &>/dev/null; then
        silent_run ufw route allow in on tailscale0 out on wg0 comment 'Tailscale to wg0 exit'
        silent_run ufw route allow in on wg0 out on tailscale0 comment 'wg0 to Tailscale return'
        silent_run ufw reload
    fi
    iptables -t nat -C POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o wg0 -j MASQUERADE 2>/dev/null || true

    if [ -f /etc/default/bobarev-cascade ]; then
        sed -i '/^NAIVE_OUT_MODE=/d' /etc/default/bobarev-cascade 2>/dev/null || true
        echo 'NAIVE_OUT_MODE="wg0"' >> /etc/default/bobarev-cascade
    fi

    if systemctl is-active --quiet caddy.service 2>/dev/null; then
        systemctl restart caddy.service || true
    fi

    echo -e "${C_BLUE} Проверка подключения и внешнего IP...${C_RESET}"
    local test_ip=""
    for i in {1..5}; do
        test_ip=$(curl -4 -s --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || echo "")
        [ -n "$test_ip" ] && break
        sleep 1
    done
    [ -z "$test_ip" ] && test_ip=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || echo "Проверьте пир WireGuard")

    echo -e "
${C_GREEN} Гибридный шлюз успешно активирован!${C_RESET}"
    echo -e "   Исходящий IP туннеля (WireGuard wg0): ${C_BOLD}${C_GREEN}${test_ip}${C_RESET}"
    echo -e "   Клиенты NaiveProxy (Shadowrocket) и Tailscale Exit Node выходят в интернет через: ${C_BOLD}wg0${C_RESET}"
    echo -e "   Входящие подключения к серверу и SSH защищены и работают напрямую через физический интерфейс: ${C_BOLD}${DEFAULT_WAN_IF:-ens3}${C_RESET}"
    return 0
}

disable_hybrid_wg_routing() {
    local cleanup_ssh_port=''
    if [[ -r /etc/wireguard/wg0.conf ]]; then
        cleanup_ssh_port=$(sed -nE 's/^[[:space:]]*PostUp[[:space:]]*=[[:space:]]*ip rule add sport ([0-9]+) lookup main priority 98[[:space:]]*$/\1/p' /etc/wireguard/wg0.conf | awk 'NR==1 {print}')
    fi
    echo -e "${C_YELLOW} Отключение туннеля wg0 и возврат к прямому выходу в интернет...${C_RESET}"
    silent_run systemctl stop wg-quick@wg0
    silent_run systemctl disable wg-quick@wg0
    silent_run wg-quick down wg0 2>/dev/null || true
    ip link del dev wg0 2>/dev/null || true
    ip route flush table 150 2>/dev/null || true
    while ip rule del priority 30000 2>/dev/null; do :; done
    while ip rule del priority 1000 2>/dev/null; do :; done
    while ip rule del fwmark 0x80000000/0x80000000 lookup main priority 94 2>/dev/null; do :; done
    while ip rule del fwmark 51820 lookup main priority 95 2>/dev/null; do :; done
    while ip rule del to 100.64.0.0/10 lookup main priority 96 2>/dev/null; do :; done
    while ip rule del sport 41641 lookup main priority 97 2>/dev/null; do :; done
    if [[ "$cleanup_ssh_port" =~ ^[0-9]+$ ]]; then
        while ip rule del sport "$cleanup_ssh_port" lookup main priority 98 2>/dev/null; do :; done
    else echo 'Сохранённый SSH-порт правила 98 не найден; неизвестное правило не удаляется.'; fi
    while ip rule del sport 443 lookup main priority 99 2>/dev/null; do :; done
    while ip rule del sport 80 lookup main priority 100 2>/dev/null; do :; done

    if [ -f /etc/ufw/before.rules ]; then
        sed -i '/-o wg0 -j MASQUERADE/d' /etc/ufw/before.rules 2>/dev/null || true
    fi
    if command -v ufw &>/dev/null; then
        silent_run ufw route delete allow in on tailscale0 out on wg0 2>/dev/null || true
        silent_run ufw route delete allow in on wg0 out on tailscale0 2>/dev/null || true
        silent_run ufw reload >/dev/null 2>&1 || true
    fi

    if [ -f /etc/default/bobarev-cascade ]; then
        sed -i '/^NAIVE_OUT_MODE=/d' /etc/default/bobarev-cascade 2>/dev/null || true
        echo 'NAIVE_OUT_MODE="direct"' >> /etc/default/bobarev-cascade
    fi

    if systemctl is-active --quiet caddy.service 2>/dev/null; then
        systemctl restart caddy.service || true
    fi
    echo -e "${C_GREEN} Туннель wg0 отключен. NaiveProxy переведен на прямой выход в интернет.${C_RESET}"
}

setup_standalone_naive() {
    if nm_bound; then
        echo "NaiveProxy сейчас связан с mesh-каскадом или приостановлен."
        echo "Для автономной настройки сначала нужно переключить выход на этот сервер."
        nm_direct || { pause_enter; return 0; }
    fi
    while true; do
        MODULE_CANCELED=false
        local is_configured=false
        local c_state="Не настроен"
        local cur_out="direct"

        if [ -f "$CADDYFILE" ] && [ -f /etc/default/bobarev-cascade ]; then
            # shellcheck disable=SC1091
            source /etc/default/bobarev-cascade
            if [ "${CASCADE_ROLE:-}" = "standalone_naive" ]; then
                is_configured=true
                cur_out="${NAIVE_OUT_MODE:-direct}"
                local out_human="Прямой выход"
                if [ "$cur_out" = "wg0" ] || systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
                    out_human="Гибридный шлюз (wg0 + Tailscale Exit Node)"
                fi
                c_state="Активен (Домен: ${NAIVE_DOMAIN:-N/A} | ${out_human})"
            fi
        fi

        local u_cnt=0
        [ -f "$NAIVE_PASS_FILE" ] && u_cnt=$(grep -c ":" "$NAIVE_PASS_FILE" 2>/dev/null || true); u_cnt="${u_cnt:-0}"

        local sc_choice=""
        if [ "$is_configured" = true ]; then
            if ! smart_menu " Автономный NaiveProxy (+ WG Dual-Gateway)" "
Статус: $c_state
Активных пользователей: $u_cnt
Выберите действие:" 18 $WT_WIDTH 6 "sc_choice"             "1" " Показать ссылки Shadowrocket"             "2" " Управление пользователями"             "3" " Подключить / Обновить туннель WireGuard (wg0 -> Выход)"             "4" " Переключить на прямой выход в интернет (отключить wg0)"             "5" " Перенастроить домен и NaiveProxy (без изменения выхода)"             "6" " Остановить и удалить NaiveProxy"             "0" " Вернуться в главное меню" || [ "$sc_choice" = "0" ]; then
                break
            fi
        else
            if ! smart_menu " Автономный NaiveProxy (+ WG Dual-Gateway)" "
Статус: $c_state

Поддерживает 2 режима выхода:
  Прямой выход в интернет с этого VPS.
  WireGuard wg0 — отдельное дополнение после настройки NaiveProxy.

Выберите действие:" 16 $WT_WIDTH 2 "sc_choice"             "1" " Настроить автономный NaiveProxy (прямой выход)"             "0" " Вернуться в главное меню" || [ "$sc_choice" = "0" ]; then
                break
            fi
            [ "$sc_choice" = "1" ] && sc_choice="5"
        fi

        clear
        case "$sc_choice" in
            1)
                print_naive_shadowrocket_links
                pause_enter
                ;;
            2)
                manage_naive_users_menu
                ;;
            3)
                setup_hybrid_wg_routing || true
                pause_enter
                ;;
            4)
                disable_hybrid_wg_routing
                pause_enter
                ;;
            5)
                echo -e "${C_CYAN} === НАСТРОЙКА АВТОНОМНОГО NAIVEPROXY ===${C_RESET}"

                if systemctl is-active --quiet hysteria-server.service || systemctl is-active --quiet hysteria-client.service || systemctl is-active --quiet bobarev-xray.service || is_derp_active; then
                    echo -e "${C_YELLOW} Освобождение портов 80/443 от предыдущих каскадных служб (Hysteria/Xray/DERP)...${C_RESET}"
                    silent_run systemctl stop hysteria-server.service hysteria-client.service bobarev-xray.service derper.service
                    silent_run systemctl disable hysteria-server.service hysteria-client.service bobarev-xray.service derper.service
                fi

                if ! check_required_ports_free "ru" "80" "443"; then
                    pause_enter
                    if [ "$is_configured" = false ]; then break; else continue; fi
                fi
                enable_routing_optimizations || true

                local saved_dom=""
                local saved_email=""
                if [ -f /etc/default/bobarev-cascade ]; then
                    # shellcheck disable=SC1091
                    source /etc/default/bobarev-cascade
                    saved_dom="${NAIVE_DOMAIN:-}"
                    saved_email="${NAIVE_EMAIL:-}"
                fi

                local n_dom=""
                prompt_default "1/3. Введите ваш домен, направленный по DNS (A-запись без Cloudflare proxy) на этот сервер:" "${saved_dom:-yourdomain.com}" n_dom
                if [ "$MODULE_CANCELED" = true ] || [ -z "$n_dom" ]; then
                    if [ "$is_configured" = false ]; then break; else continue; fi
                fi

                local n_email=""
                prompt_default "2/3. Введите ваш Email для автоматического выпуска SSL-сертификата Let's Encrypt:" "${saved_email:-admin@${n_dom}}" n_email
                if [ "$MODULE_CANCELED" = true ] || [ -z "$n_email" ]; then
                    if [ "$is_configured" = false ]; then break; else continue; fi
                fi

                local n_user=""
                prompt_default "3/3. Введите имя пользователя для подключения в Shadowrocket:" "user1" n_user
                if [ "$MODULE_CANCELED" = true ] || [ -z "$n_user" ]; then
                    if [ "$is_configured" = false ]; then break; else continue; fi
                fi
                n_user=$(echo "$n_user" | tr -dc 'a-zA-Z0-9_-')

                local rand_pass=$(openssl rand -base64 18 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16 || { echo -e "${C_RED} Ошибка генератора паролей.${C_RESET}" >&2; return 1; })
                local n_pass=""
                prompt_default "Пароль для пользователя $n_user (минимум 8 символов):" "$rand_pass" n_pass
                if [ "$MODULE_CANCELED" = true ] || [ -z "$n_pass" ]; then
                    if [ "$is_configured" = false ]; then break; else continue; fi
                fi

                # Повторная настройка NaiveProxy не должна менять маршрутизацию дополнений.
                if [ "$is_configured" = false ]; then
                    silent_run systemctl stop wg-quick@wg-cascade.service bobarev-udp2raw.service hysteria-server.service hysteria-client.service bobarev-xray.service derper.service
                    silent_run systemctl disable wg-quick@wg-cascade.service bobarev-udp2raw.service hysteria-server.service hysteria-client.service bobarev-xray.service derper.service
                    silent_run wg-quick down wg-cascade 2>/dev/null || true
                    ip link del dev wg-cascade 2>/dev/null || true
                    ip route flush table 51888 2>/dev/null || true
                    while ip rule del priority 100 2>/dev/null; do :; done
                    clean_duplicate_cascade_iptables
                fi

                ensure_go_and_build_caddy_naive || { pause_enter; if [ "$is_configured" = false ]; then break; else continue; fi; }

                local wan_dev=$(get_wan_if)
                local pub_ip=$(ip -4 -o addr show dev "${wan_dev:-eth0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || echo "")

                cat << EOF > /etc/default/bobarev-cascade
CASCADE_ROLE="standalone_naive"
NAIVE_DOMAIN="$n_dom"
NAIVE_EMAIL="$n_email"
SERVER_PUB_IP="$pub_ip"
TCP_TUNE_PROFILE="balanced"
NAIVE_OUT_MODE="$cur_out"
EOF
                chmod 600 /etc/default/bobarev-cascade

                apply_naive_tcp_tuning_profile "balanced"
                add_or_update_naive_user "$n_user" "$n_pass"
                if ! render_naive_caddyfile; then
                    echo -e "${C_RED} Caddy не применил конфигурацию. Установка не подтверждена.${C_RESET}"
                    pause_enter
                    continue
                fi

                if command -v ufw &>/dev/null; then
                    silent_run ufw allow 80/tcp comment 'NaiveProxy ACME HTTP'
                    silent_run ufw allow 443/tcp comment 'NaiveProxy HTTPS'
                    silent_run ufw allow 443/udp comment 'NaiveProxy HTTP3 QUIC'
                    echo -e "${C_GREEN} Порты 80/tcp, 443/tcp и 443/udp открыты в UFW.${C_RESET}"
                fi

                echo -e "${C_BLUE} Режим выхода сохранён: ${cur_out}. WireGuard wg0 настраивается отдельно через пункт 3.${C_RESET}"

                echo -e "${C_GREEN} Конфигурация NaiveProxy применена. Работу CONNECT нужно проверить отдельно.${C_RESET}"
                print_naive_shadowrocket_links
                pause_enter
                ;;
            6)
                if prompt_yn "Остановить и удалить службы NaiveProxy (Caddy) и туннель wg0 на этом сервере?" "false"; then
                    disable_hybrid_wg_routing
                    silent_run systemctl stop caddy.service
                    silent_run systemctl disable caddy.service
                    rm -f /etc/caddy/Caddyfile /etc/default/bobarev-cascade
                    rm -rf "$NAIVE_DIR" "$WEBROOT" "$LOG_DIR"
                    silent_run systemctl daemon-reload
                    echo -e "${C_GREEN} Служба NaiveProxy полностью остановлена и удалена.${C_RESET}"
                fi
                pause_enter
                ;;
        esac
    done
}


setup_cascade_server1_ru() {
    echo -e "${C_CYAN} === НАСТРОЙКА СЕРВЕРА 1 (ВХОД РФ): NAIVEPROXY -> TAILSCALE ===${C_RESET}"
    if ! is_derp_active && ! check_required_ports_free "ru" "80" "443"; then
        return 0
    fi
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

    local rand_pass=$(openssl rand -base64 18 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16 || { echo -e "${C_RED} Ошибка генератора паролей.${C_RESET}" >&2; return 1; })
    local n_pass=""
    prompt_default "Пароль для пользователя $n_user (минимум 8 символов):" "$rand_pass" n_pass
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_pass" ]; then return 0; fi

    local ts_peers=$(tailscale status 2>/dev/null | awk 'NR>1 {print $1 " (" $2 ")"}' | tr '\n' ' ' || echo "")
    [ -n "$ts_peers" ] && echo -e "${C_BLUE} Доступные узлы в вашей сети Tailscale: $ts_peers${C_RESET}"

    local exit_ts_ip=""
    prompt_default "4/4. Введите Tailscale IP вашего Зарубежного Сервера 2 (например, 100.x.y.z):" "${saved_exit:-}" exit_ts_ip
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    if is_derp_active; then
        echo -e "${C_YELLOW} Внимание: служба личного DERP на порту 443 остановлена, так как порт 443 передается NaiveProxy (Caddy).${C_RESET}"
        silent_run systemctl stop derper.service
        silent_run systemctl disable derper.service
    fi

    if is_wg_cascade_active; then
        echo -e "${C_BLUE} Отключение прямого моста wg-cascade (переход на Tailscale-маршрут)...${C_RESET}"
        silent_run systemctl stop wg-quick@wg-cascade.service
        silent_run systemctl disable wg-quick@wg-cascade.service
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
TCP_TUNE_PROFILE="balanced"
EOF
    chmod 600 /etc/default/bobarev-cascade

    apply_naive_tcp_tuning_profile "balanced"
    add_or_update_naive_user "$n_user" "$n_pass"
    render_naive_caddyfile
    write_bobarev_cascade_ru_script
    /usr/local/bin/bobarev-cascade-ru.sh

    if command -v ufw &>/dev/null; then
        silent_run ufw allow 80/tcp comment 'NaiveProxy ACME HTTP'
        silent_run ufw allow 443/tcp comment 'NaiveProxy HTTPS'
        silent_run ufw allow 443/udp comment 'NaiveProxy HTTP3 QUIC'
        echo -e "${C_GREEN} Порты 80/tcp, 443/tcp и 443/udp открыты в UFW.${C_RESET}"
    fi

    echo -e "${C_GREEN} Сервер 1 (Вход в РФ на базе NaiveProxy + Tailscale [MTU 1280, MSS 1140]) успешно настроен и запущен!${C_RESET}"
    print_naive_shadowrocket_links
}

ensure_warp_installed_and_configured() {
    if ! command -v wg &>/dev/null || ! command -v iptables &>/dev/null || ! command -v curl &>/dev/null; then
        echo -e "${C_BLUE} Установка пакетов wireguard-tools, iptables и curl...${C_RESET}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -yq wireguard-tools iptables curl >/dev/null 2>&1
    fi

    local arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    local wgcf_arch="amd64"
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
        wgcf_arch="arm64"
    fi

    if [ ! -x /usr/local/bin/wgcf ]; then
        echo -e "${C_BLUE} Скачивание утилиты wgcf для генерации профиля Cloudflare WARP...${C_RESET}"

        local wgcf_sha=""
        case "$wgcf_arch" in
            amd64) wgcf_sha="4fb7a136aa470ece11d17949c7db07b040ec9c604742dc8680bcf1889f85d0c8" ;;
            arm64) wgcf_sha="710ab2d8ac145d81a4cf0c11bdb0e05914f77ae2a45f67b87e718d84b4cb7301" ;;
            *)     wgcf_sha="" ;;
        esac

        if ! curl -fsSL "https://github.com/ViRb3/wgcf/releases/download/v2.3.1/wgcf_2.3.1_linux_${wgcf_arch}" -o /usr/local/bin/wgcf 2>/dev/null; then
            local latest_url=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null | grep "browser_download_url.*linux_${wgcf_arch}" | head -n 1 | cut -d'"' -f4 || echo "")
            [ -n "$latest_url" ] && curl -fsSL "$latest_url" -o /usr/local/bin/wgcf
        fi

        if [ -n "$wgcf_sha" ]; then
            if ! verify_sha256 "/usr/local/bin/wgcf" "$wgcf_sha"; then
                echo -e "${C_RED} Ошибка: SHA256 для wgcf не совпал! Файл удален.${C_RESET}"
                rm -f /usr/local/bin/wgcf
                return 1
            fi
        fi
        chmod +x /usr/local/bin/wgcf
    fi

    mkdir -p /etc/wireguard
    local need_patch=false
    if [ ! -f /etc/wireguard/warp.conf ] || prompt_yn "Профиль /etc/wireguard/warp.conf уже существует. Сгенерировать новый профиль WARP?" "false"; then
        echo -e "${C_BLUE} Регистрация аккаунта Cloudflare WARP и создание конфигурации...${C_RESET}"
        (
            cd /root
            rm -f wgcf-account.toml wgcf-profile.conf 2>/dev/null || true
            /usr/local/bin/wgcf register --accept-tos
            /usr/local/bin/wgcf generate --keepalive
            cp /root/wgcf-profile.conf /etc/wireguard/warp.conf
        )
        need_patch=true
    elif ! grep -q "MTU = 1280" /etc/wireguard/warp.conf 2>/dev/null; then
        need_patch=true
    fi

    if [ "$need_patch" = true ]; then
        # Безопасная генерация /etc/wireguard/warp.conf без многострочных sed
        local w_priv=$(awk -F'=' '/^[[:space:]]*PrivateKey[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' /etc/wireguard/warp.conf 2>/dev/null | tr -d '[:space:]')
        local w_addr=$(awk -F'=' '/^[[:space:]]*Address[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' /etc/wireguard/warp.conf 2>/dev/null | head -n 1 | cut -d',' -f1 | tr -d '[:space:]')
        local w_pub=$(awk -F'=' '/^[[:space:]]*PublicKey[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' /etc/wireguard/warp.conf 2>/dev/null | tr -d '[:space:]')
        local w_end=$(awk -F'=' '/^[[:space:]]*Endpoint[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' /etc/wireguard/warp.conf 2>/dev/null | tr -d '[:space:]')
        [ -z "$w_addr" ] && w_addr="172.16.0.2/32"
        [ -z "$w_end" ] && w_end="engage.cloudflareclient.com:2408"

        cat << EOF > /etc/wireguard/warp.conf
[Interface]
PrivateKey = $w_priv
Address = $w_addr
MTU = 1280
Table = 51820
PostUp = ip rule del from 172.16.0.2 lookup 51820 priority 5998 2>/dev/null || true
PostUp = ip rule add from 172.16.0.2 lookup 51820 priority 5998 || true
PostUp = ip rule del oif warp lookup 51820 priority 5999 2>/dev/null || true
PostUp = ip rule add oif warp lookup 51820 priority 5999 || true
PostUp = ip rule del from 100.64.0.0/10 lookup 51820 priority 6000 2>/dev/null || true
PostUp = ip rule add from 100.64.0.0/10 lookup 51820 priority 6000 || true
PostUp = ip rule del from 10.200.200.0/24 lookup 51820 priority 6001 2>/dev/null || true
PostUp = ip rule add from 10.200.200.0/24 lookup 51820 priority 6001 || true
PostUp = ip link set dev warp mtu 1280 txqueuelen 10000 || true
PostUp = tc qdisc replace dev warp root fq limit 30000 flow_limit 10000 2>/dev/null || true
PostUp = iptables -t nat -C POSTROUTING -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o warp -j MASQUERADE
PostUp = iptables -C FORWARD -i tailscale0 -o warp -j ACCEPT 2>/dev/null || iptables -A FORWARD -i tailscale0 -o warp -j ACCEPT
PostUp = iptables -C FORWARD -i warp -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i warp -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -C FORWARD -i wg-cascade -o warp -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg-cascade -o warp -j ACCEPT
PostUp = iptables -C FORWARD -i warp -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i warp -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t mangle -C FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || iptables -t mangle -I FORWARD 1 -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
PostDown = ip rule del from 100.64.0.0/10 lookup 51820 priority 6000 2>/dev/null || true
PostDown = ip rule del from 10.200.200.0/24 lookup 51820 priority 6001 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o warp -j MASQUERADE 2>/dev/null || true
PostDown = iptables -D FORWARD -i tailscale0 -o warp -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i warp -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg-cascade -o warp -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i warp -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

[Peer]
PublicKey = $w_pub
AllowedIPs = 0.0.0.0/0
Endpoint = $w_end
PersistentKeepalive = 25
EOF
        chmod 600 /etc/wireguard/warp.conf
    fi

    ensure_wg_kernel_modules
    silent_run systemctl daemon-reload
    silent_run systemctl enable --now wg-quick@warp
    systemctl restart wg-quick@warp || true
}

setup_cascade_server2_warp() {
    echo -e "${C_CYAN} === НАСТРОЙКА СЕРВЕРА 2 (ЗАРУБЕЖНЫЙ ВЫХОД): TAILSCALE -> WARP / ЧИСТЫЙ IP ===${C_RESET}"
    ensure_tailscale_installed || true
    enable_routing_optimizations || true

    local exit_choice=""
    if ! smart_menu "Выход в интернет на Зарубежном Сервере 2 (Tailscale)" "\nКак выпускать трафик из Tailscale в интернет с этого зарубежного сервера?\n(Вы сможете переключать этот режим за 2 секунды в Пункте 5 меню):" 16 $WT_WIDTH 2 "exit_choice" \
    "1" " Чистый зарубежный IP (Напрямую с этого сервера — БЕЗ WARP, макс. скорость!)" \
    "2" " Через Cloudflare WARP (Маскирует выходной IP под Cloudflare)"; then
        return 0
    fi

    local exit_mode="direct"
    if [ "$exit_choice" = "2" ]; then
        exit_mode="warp"
    fi

    silent_run tailscale set --advertise-exit-node=true
    cat << EOF > /etc/default/bobarev-cascade
CASCADE_ROLE="foreign_warp_exit"
FOREIGN_EXIT_MODE="$exit_mode"
EOF
    chmod 600 /etc/default/bobarev-cascade

    apply_foreign_exit_mode "$exit_mode"

    local my_ts_ip=$(tailscale ip -4 2>/dev/null | head -n 1 || echo "100.x.y.z")
    echo -e "${C_GREEN} Сервер 2 (Зарубежный выход Tailscale, режим: $exit_mode) успешно запущен!${C_RESET}"
    echo -e "${C_BLUE} Ваш Tailscale IP этого сервера: ${C_BOLD}${my_ts_ip}${C_RESET}"
    echo -e "${C_YELLOW} Не забудьте в админ-панели Tailscale (https://login.tailscale.com/admin/machines) включить галочку 'Use as exit node' для этого сервера, а на Сервере 1 (РФ) указать IP ${my_ts_ip}!${C_RESET}"
}

manage_cascade_naive_ts_warp() {
    while true; do
        MODULE_CANCELED=false
        local c_state="Не активен"
        if is_naive_active; then
            # shellcheck disable=SC1091
            [ -f /etc/default/bobarev-cascade ] && source /etc/default/bobarev-cascade
            if [ "${CASCADE_ROLE:-}" = "ru_wg_entry" ]; then
                c_state="Сервер 1 (РФ: NaiveProxy -> Прямой WG мост)"
            else
                c_state="Сервер 1 (РФ: NaiveProxy -> Tailscale)"
            fi
        elif [ -f /etc/default/bobarev-cascade ]; then
            # shellcheck disable=SC1091
            source /etc/default/bobarev-cascade
            if is_warp_active; then
                c_state="Сервер 2 (Зарубеж: Tailscale -> Cloudflare WARP)"
            else
                c_state="Сервер 2 (Зарубеж: Tailscale -> Чистый IP сервера)"
            fi
        fi

        local c_choice
        if ! smart_menu "Каскад: NaiveProxy + Tailscale + WARP" "\nСтатус моста: $c_state\nВыберите действие:" 18 $WT_WIDTH 6 "c_choice" \
        "1" " Сервер 1 (РФ): NaiveProxy -> Tailscale" \
        "2" " Сервер 2 (Зарубеж): Tailscale -> Выход" \
        "3" " Управление пользователями NaiveProxy" \
        "4" " Показать ссылки Shadowrocket" \
        "5" " Переключить выход: Чистый IP <-> WARP" \
        "6" " Остановить компоненты каскада" \
        "0" " Вернуться в главное меню" || [ "$c_choice" = "0" ]; then
            break
        fi

        clear
        case "$c_choice" in
            1)
                setup_cascade_server1_ru || true
                pause_enter
                ;;
            2)
                setup_cascade_server2_warp || true
                pause_enter
                ;;
            3)
                manage_naive_users_menu
                ;;
            4)
                print_naive_shadowrocket_links
                pause_enter
                ;;
            5)
                toggle_foreign_warp_menu
                pause_enter
                ;;
            6)
                if prompt_yn "Остановить и отключить службы каскада (NaiveProxy Caddy / WARP) на этом сервере?" "false"; then
                    silent_run systemctl stop caddy.service bobarev-cascade-ru.service wg-quick@warp.service wg-quick@wg-cascade.service
                    silent_run tailscale set --exit-node=
                    rm -f /etc/default/bobarev-cascade /etc/systemd/system/bobarev-cascade-ru.service /etc/systemd/system/bobarev-udp2raw.service /usr/local/bin/udp2raw /usr/local/bin/bobarev-cascade-ru.sh /etc/wireguard/wg-cascade.conf
                    silent_run systemctl daemon-reload
                    echo -e "${C_GREEN} Службы каскада остановлены и отключены.${C_RESET}"
                fi
                pause_enter
                ;;
        esac
    done
}

# ==============================================================================
# МОДУЛЬ 20: ПРЯМОЙ СКОРОСТНОЙ КАСКАД (NAIVEPROXY -> WG + UDP2RAW -> WARP)
# ==============================================================================
check_required_ports_free() {
    # Проверяет, не заняты ли целевые порты СТОРОННИМИ процессами (игнорируя наши собственные caddy, udp2raw и ядерный интерфейс wg-cascade)
    local role="$1" # ru | foreign
    shift
    local ports=("$@")
    local conflict_found=false

    # Определяем текущий порт нашего собственного интерфейса wg-cascade (если он уже запущен в ядре),
    # так как ядерный модуль WireGuard в ss -tulpn не имеет поля users:(...)
    local own_wg_port=""
    if ip link show wg-cascade >/dev/null 2>&1; then
        own_wg_port=$(wg show wg-cascade listen-port 2>/dev/null | tr -d '[:space:]' || echo "")
    fi

    for p in "${ports[@]}"; do
        [ -z "$p" ] && continue
        # Если этот порт занят нашим же ядерным интерфейсом wg-cascade — пропускаем (он будет штатно перезапущен)
        if [ -n "$own_wg_port" ] && [ "$p" = "$own_wg_port" ]; then
            continue
        fi
        local line=""
        line=$({ ss -tulpnH "sport = :$p" 2>/dev/null || true; } | grep -vE '"(caddy|udp2raw|hysteria|xray|derper)"' | head -n 1 || echo "")
        if [ -n "$line" ]; then
            # Если на порту 51889 или порту из /etc/wireguard/wg-cascade.conf висит ядерный сокет без users:(...), это наш wg-cascade
            if ! echo "$line" | grep -q "users:(" && { [ "$p" = "51889" ] || grep -qE "^ListenPort[[:space:]]*=[[:space:]]*${p}\b" /etc/wireguard/wg-cascade.conf 2>/dev/null; }; then
                continue
            fi
            local proto=$(echo "$line" | awk '{print $1}')
            local proc_info=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo "ядерный модуль / неизвестный процесс")
            local pid_info=$(echo "$line" | grep -oP 'pid=\K[0-9]+' || echo "-")
            echo -e "${C_RED} Внимание: Порт ${p}/${proto} уже занят сторонним процессом '${proc_info}' (PID: ${pid_info})!${C_RESET}"
            conflict_found=true
        fi
    done

    if [ "$conflict_found" = true ]; then
        echo -e "${C_YELLOW} Пожалуйста, освободите указанные порты (остановите/удалите конфликтующий процесс) и запустите настройку заново.${C_RESET}"
        return 1
    fi
    return 0
}

ensure_udp2raw_installed() {
    if [ -x "$UDP2RAW_BIN" ]; then
        return 0
    fi
    echo -e "${C_BLUE} Скачивание и установка движка обфускации заголовков udp2raw...${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -yq curl wget tar iptables

    local tmp_u2r=$(mktemp -d /root/.udp2raw-XXXXXX)
    local u2r_url="https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz"

    if ! wget -q --tries=3 --timeout=30 "$u2r_url" -O "${tmp_u2r}/udp2raw.tar.gz"; then
        rm -rf "$tmp_u2r"
        echo -e "${C_RED} Ошибка скачивания архива udp2raw с GitHub.${C_RESET}"
        return 1
    fi

    # Хеш для версии 20230206.0 (рекомендуется уточнить актуальный SHA256)
    local u2r_sha="PLACEHOLDER_SHA256_FOR_UDP2RAW_BINARIES_TAR_GZ"
    if [ "$u2r_sha" != "PLACEHOLDER_SHA256_FOR_UDP2RAW_BINARIES_TAR_GZ" ]; then
        if ! verify_sha256 "${tmp_u2r}/udp2raw.tar.gz" "$u2r_sha"; then
            rm -rf "$tmp_u2r"
            return 1
        fi
    fi

    if ! tar -xzf "${tmp_u2r}/udp2raw.tar.gz" -C "$tmp_u2r" 2>/dev/null; then
        rm -rf "$tmp_u2r"
        echo -e "${C_RED} Ошибка распаковки архива udp2raw!${C_RESET}"
        return 1
    fi
    local arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    local bin_name="udp2raw_amd64"
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
        if [ -f "${tmp_u2r}/udp2raw_arm64" ]; then
            bin_name="udp2raw_arm64"
        else
            bin_name="udp2raw_arm"
        fi
    fi

    if [ -f "${tmp_u2r}/${bin_name}" ]; then
        install -m 755 "${tmp_u2r}/${bin_name}" "$UDP2RAW_BIN"
    else
        rm -rf "$tmp_u2r"
        echo -e "${C_RED} Не найден подходящий бинарник udp2raw (${bin_name}) для архитектуры ${arch}!${C_RESET}"
        return 1
    fi
    rm -rf "$tmp_u2r"
    echo -e "${C_GREEN} Движок побитовой маскировки udp2raw успешно установлен.${C_RESET}"
    return 0
}

ensure_hysteria_installed() {
    if [ -x "/usr/local/bin/hysteria" ]; then
        return 0
    fi
    echo -e "${C_BLUE} Скачивание и установка Hysteria 2...${C_RESET}"
    local arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    local h_arch="amd64"
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
        h_arch="arm64"
    fi

    local h_url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${h_arch}"
    if ! curl -fsSL "$h_url" -o /usr/local/bin/hysteria; then
        echo -e "${C_RED} Ошибка скачивания Hysteria!${C_RESET}"
        return 1
    fi
    chmod +x /usr/local/bin/hysteria
    echo -e "${C_GREEN} Hysteria 2 успешно установлена.${C_RESET}"
    return 0
}

clean_udp2raw_iptables() {
    local rline=""
    local -a rule_args=()
    while read -r rline; do
        [ -z "$rline" ] && continue
        read -r -a rule_args <<< "${rline/-A /-D }"
        iptables -w 5 "${rule_args[@]}" 2>/dev/null || true
    done < <(iptables -S INPUT 2>/dev/null | grep "udp2rawDwrW_" || true)

    local cname=""
    while read -r cname; do
        [ -z "$cname" ] && continue
        iptables -w 5 -F "$cname" 2>/dev/null || true
        iptables -w 5 -X "$cname" 2>/dev/null || true
    done < <(iptables -S 2>/dev/null | awk '/^-N udp2rawDwrW_/{print $2}' || true)
}

clean_duplicate_cascade_iptables() {
    clean_udp2raw_iptables
    if command -v ip6tables &>/dev/null; then
        ip6tables -t mangle -F FORWARD 2>/dev/null || true
    fi
    local wan_dev=$(get_wan_if)
    while iptables -D FORWARD -i wg-cascade -o warp -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i warp -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    if [ -n "$wan_dev" ]; then
        while iptables -D FORWARD -i wg-cascade -o "$wan_dev" -j ACCEPT 2>/dev/null; do :; done
        while iptables -D FORWARD -i "$wan_dev" -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    fi
    for mss_val in 1360 1300 1260 1240 1220 1200 1160 1140 1120 1080; do
        while iptables -t mangle -D FORWARD -i wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D OUTPUT -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D POSTROUTING -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D POSTROUTING -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -i warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -i tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D POSTROUTING -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
    done
    while iptables -t mangle -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -o wg-cascade -j MASQUERADE 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -o warp -j MASQUERADE 2>/dev/null; do :; done
    [ -n "$wan_dev" ] && while iptables -t nat -D POSTROUTING -o "$wan_dev" -j MASQUERADE 2>/dev/null; do :; done
}

apply_foreign_exit_mode() {
    local exit_mode="${1:-warp}" # warp | direct
    local wan_dev=$(get_wan_if)
    [ -z "$wan_dev" ] && wan_dev="ens3"

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    disable_ufw_strict_rpfilter

    # Очищаем старые правила маршрутизации в таблицу 51820 (WARP), дубликаты FORWARD и старые правила TCPMSS
    while ip rule del from 100.64.0.0/10 lookup 51820 priority 6000 2>/dev/null; do :; done
    while ip rule del from 100.64.0.0/10 lookup 51820 2>/dev/null; do :; done
    while ip rule del from 10.200.200.0/30 lookup 51820 priority 6001 2>/dev/null; do :; done
    while ip rule del from 10.200.200.0/30 lookup 51820 2>/dev/null; do :; done
    while ip rule del from 10.200.200.0/24 lookup 51820 priority 6001 2>/dev/null; do :; done
    while ip rule del from 10.200.200.0/24 lookup 51820 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -o warp -j MASQUERADE 2>/dev/null; do :; done
    tune_fq_qdisc_interfaces
    while iptables -D FORWARD -i wg-cascade -o warp -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i warp -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i wg-cascade -o "$wan_dev" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$wan_dev" -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i tailscale0 -o warp -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i warp -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i tailscale0 -o "$wan_dev" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$wan_dev" -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    for mss_val in 1360 1300 1260 1240 1220 1200 1160 1140 1120 1080; do
        while iptables -t mangle -D FORWARD -i wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D POSTROUTING -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D POSTROUTING -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -i tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
        while iptables -t mangle -D POSTROUTING -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_val" 2>/dev/null; do :; done
    done

    if [ "$exit_mode" = "direct" ]; then
        echo -e "${C_BLUE} Включение режима ПРЯМОГО ВЫХОДА (Чистый IP зарубежного сервера без WARP)...${C_RESET}"
        silent_run systemctl stop wg-quick@warp.service
        silent_run systemctl disable wg-quick@warp.service
        ip link set dev wg-cascade mtu 1280 txqueuelen 10000 2>/dev/null || true
        ip link set dev tailscale0 mtu 1280 txqueuelen 10000 2>/dev/null || true

        iptables -C FORWARD -i wg-cascade -o "$wan_dev" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg-cascade -o "$wan_dev" -j ACCEPT
        iptables -C FORWARD -i "$wan_dev" -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$wan_dev" -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        iptables -C FORWARD -i tailscale0 -o "$wan_dev" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i tailscale0 -o "$wan_dev" -j ACCEPT
        iptables -C FORWARD -i "$wan_dev" -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$wan_dev" -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        apply_wan_exit_nat "$wan_dev" "true"

        # Для прямого WG-моста: MSS 1200; для Tailscale (с учетом заголовка Disco): MSS 1140
        iptables -t mangle -I FORWARD 1 -i wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        iptables -t mangle -I FORWARD 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        iptables -t mangle -I POSTROUTING 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        iptables -t mangle -I FORWARD 1 -i tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140 2>/dev/null || true
        iptables -t mangle -I FORWARD 1 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140 2>/dev/null || true
        iptables -t mangle -I POSTROUTING 1 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140 2>/dev/null || true

        if command -v ufw &>/dev/null; then
            silent_run ufw route allow in on wg-cascade out on "$wan_dev" comment 'WG Cascade to WAN Direct'
            silent_run ufw route allow in on "$wan_dev" out on wg-cascade comment 'WAN Direct to WG Cascade'
            silent_run ufw route allow in on tailscale0 out on "$wan_dev" comment 'Tailscale to WAN Direct'
            silent_run ufw route allow in on "$wan_dev" out on tailscale0 comment 'WAN Direct to Tailscale'
        fi
    else
        echo -e "${C_BLUE} Включение режима CLOUDFLARE WARP на выходе Зарубежного сервера...${C_RESET}"
        ensure_warp_installed_and_configured
        ip link set dev wg-cascade mtu 1280 txqueuelen 10000 2>/dev/null || true
        ip link set dev tailscale0 mtu 1280 txqueuelen 10000 2>/dev/null || true
        ip rule add from 100.64.0.0/10 lookup 51820 priority 6000 2>/dev/null || true
        ip rule add from 10.200.200.0/24 lookup 51820 priority 6001 2>/dev/null || true

        iptables -C FORWARD -i wg-cascade -o warp -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg-cascade -o warp -j ACCEPT
        iptables -C FORWARD -i warp -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i warp -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        iptables -C FORWARD -i tailscale0 -o warp -j ACCEPT 2>/dev/null || iptables -A FORWARD -i tailscale0 -o warp -j ACCEPT
        iptables -C FORWARD -i warp -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i warp -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        iptables -t nat -C POSTROUTING -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o warp -j MASQUERADE

        iptables -t mangle -I FORWARD 1 -i wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        iptables -t mangle -I FORWARD 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        iptables -t mangle -I POSTROUTING 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        iptables -t mangle -I FORWARD 1 -i tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140 2>/dev/null || true
        iptables -t mangle -I FORWARD 1 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140 2>/dev/null || true
        iptables -t mangle -I POSTROUTING 1 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140 2>/dev/null || true

        if command -v ufw &>/dev/null; then
            silent_run ufw route allow in on wg-cascade out on warp comment 'WG Cascade to WARP'
            silent_run ufw route allow in on warp out on wg-cascade comment 'WARP to WG Cascade'
            silent_run ufw route allow in on tailscale0 out on warp comment 'Tailscale to WARP'
            silent_run ufw route allow in on warp out on tailscale0 comment 'WARP to Tailscale'
            ensure_ufw_nat_rule "-A POSTROUTING -o warp -j MASQUERADE"
        fi
    fi

    if [ -f /etc/default/bobarev-cascade ]; then
        sed -i '/^FOREIGN_EXIT_MODE=/d' /etc/default/bobarev-cascade 2>/dev/null || true
        echo "FOREIGN_EXIT_MODE=\"$exit_mode\"" >> /etc/default/bobarev-cascade
    fi
    if [ -f /etc/default/bobarev-cascade ]; then
        # shellcheck disable=SC1091
        source /etc/default/bobarev-cascade
        if [ "${CASCADE_ROLE:-}" = "foreign_xray_exit" ] && [ -n "${XRAY_PORT:-}" ]; then
            render_xray_server_config "$XRAY_PORT" "$XRAY_UUID" "$XRAY_PRIV" "$XRAY_SHORT_ID" "$XRAY_SNI" "$exit_mode"
            silent_run systemctl restart bobarev-xray.service
        fi
        if [ "${CASCADE_ROLE:-}" = "foreign_hysteria_exit" ] && [ -n "${HYSTERIA_PORT:-}" ]; then
            render_hysteria_server_config "$HYSTERIA_PORT" "${HYSTERIA_PASS:-SecretPass2026}" "$exit_mode"
            silent_run systemctl restart hysteria-server.service
        fi
    fi

}

toggle_foreign_warp_menu() {
    local cur_mode="warp"
    if [ -f /etc/default/bobarev-cascade ]; then
        # shellcheck disable=SC1091
        source /etc/default/bobarev-cascade
        cur_mode="${FOREIGN_EXIT_MODE:-warp}"
    fi
    if ! is_warp_active && [ "$cur_mode" = "warp" ]; then
        cur_mode="direct"
    fi

    local cur_human="Cloudflare WARP (защищенный IP Cloudflare)"
    [ "$cur_mode" = "direct" ] && cur_human="Прямой выход (Чистый собственный IP зарубежного сервера)"

    local m_choice=""
    local def_item="1"
    [ "$cur_mode" = "warp" ] && def_item="2"

    if ! smart_menu "Переключение выхода на Сервере 2 (WARP <-> Чистый IP)" "\nТекущий режим выхода: $cur_human\n\nРаботает для всех каскадов (WG-мост, Hysteria 2, Xray REALITY и Tailscale)!\nВыберите, как выпускать трафик в интернет с этого зарубежного сервера (переключение за 2 секунды, менять настройки на РФ-сервере НЕ нужно):" 18 $WT_WIDTH 2 "m_choice" \
    "1" " Чистый зарубежный IP (Напрямую с этого сервера — БЕЗ WARP, макс. скорость!)" \
    "2" " Cloudflare WARP (Маскировка выходного IP под Cloudflare)"; then
        return 0
    fi

    local target_mode="direct"
    [ "$m_choice" = "2" ] && target_mode="warp"

    apply_foreign_exit_mode "$target_mode"

    local wan_dev=$(get_wan_if)
    [ -z "$wan_dev" ] && wan_dev="ens3"
    if [ "$target_mode" = "direct" ]; then
        local my_ip=$(curl -4 -s --interface "$wan_dev" --max-time 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || echo "")
        echo -e "\n${C_GREEN} WARP отключен! Теперь трафик (и из WG-моста, и из Tailscale) выходит напрямую с чистого зарубежного IP: ${C_BOLD}${my_ip:-Прямой IP сервера}${C_RESET}"
        echo -e "${C_BLUE} Подсказка: Без двойного шифрования WARP сайт speed.cloudflare.com и Speedtest работают на полной скорости канала!${C_RESET}"
    else
        local w_ip=$(curl -4 -s --interface warp --max-time 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || echo "")
        echo -e "\n${C_GREEN} Cloudflare WARP включен! Выходной IP каскада: ${C_BOLD}${w_ip:-Cloudflare WARP}${C_RESET}"
    fi
}

configure_udp2raw_service() {
    local role="$1"       # server | client
    local r_addr="$2"     # remote/target addr:port (-r)
    local l_addr="$3"     # local listen addr:port (-l)
    local obfs_mode="$4"  # udp | faketcp | none
    local obfs_key="$5"

    if [ "$obfs_mode" = "none" ]; then
        silent_run systemctl stop bobarev-udp2raw.service
        silent_run systemctl disable bobarev-udp2raw.service
        clean_udp2raw_iptables
        rm -f "$UDP2RAW_SERVICE"
        silent_run systemctl daemon-reload
        return 0
    fi

    ensure_udp2raw_installed || return 1
    silent_run systemctl stop bobarev-udp2raw.service
    clean_udp2raw_iptables

    local mode_flag="-s"
    if [ "$role" = "client" ]; then
        mode_flag="-c"
    fi
    local addr_flags="-l ${l_addr} -r ${r_addr}"

    # Флаг -a отключает переполнение буфера ядра (Recv-Q 2MB) на сокете-заглушке,
    # а --fix-gro предотвращает отбрасывание склеенных GRO-пакетов (>1500 байт) при высоких скоростях!
    local extra_flags="-a --sock-buf 10240 --seq-mode 4"

    cat << EOF > "$UDP2RAW_SERVICE"
[Unit]
Description=Bobarev Shell udp2raw Anti-DPI Obfuscator ($obfs_mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Nice=-15
CPUSchedulingPolicy=rr
CPUSchedulingPriority=50
LimitNOFILE=1048576
LimitMEMLOCK=infinity
ExecStart=${UDP2RAW_BIN} ${mode_flag} ${addr_flags} -k "${obfs_key}" --raw-mode ${obfs_mode} --cipher-mode none --auth-mode none ${extra_flags}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    local wan_if=$(get_wan_if)
    if [ -n "$wan_if" ] && command -v ethtool &>/dev/null; then
        ethtool -K "$wan_if" tso off gso off gro off rx-udp-gro-forwarding off rx-gro-list off 2>/dev/null || true
    fi

    silent_run systemctl daemon-reload
    systemctl reset-failed bobarev-udp2raw.service 2>/dev/null || true
    systemctl enable --now bobarev-udp2raw.service >/dev/null 2>&1 || true
    systemctl restart bobarev-udp2raw.service || true
    sleep 3
    if ! systemctl is-active --quiet bobarev-udp2raw.service; then
        echo -e "${C_RED} Служба udp2raw НЕ запустилась! Последние строки журнала:${C_RESET}"
        journalctl -u bobarev-udp2raw.service -n 15 --no-pager 2>/dev/null | sed "s/\x1b\[[0-9;]*m//g" || true
        return 1
    fi
    echo -e "${C_GREEN} Служба udp2raw запущена (режим: $obfs_mode).${C_RESET}"
}

setup_direct_wg_server2_foreign() {
    echo -e "${C_CYAN} === ШАГ 1: НАСТРОЙКА ЗАРУБЕЖНОГО СЕРВЕРА 2 (WG-BRIDGE + ANTI-DPI) ===${C_RESET}"
    enable_routing_optimizations || true
    apply_naive_tcp_tuning_profile "balanced"

    local ext_port="51888"
    prompt_default "1/3. Введите внешний порт на этом сервере для приема каскадного моста:" "51888" ext_port
    if [ "$MODULE_CANCELED" = true ] || [ -z "$ext_port" ]; then return 0; fi
    ext_port="${ext_port//[^0-9]/}"
    if ! check_required_ports_free "foreign" "$ext_port" "51889"; then
        return 0
    fi

    local obfs_choice=""
    if ! smart_menu "2/3. Защита заголовков WireGuard от ТСПУ" "\nВыберите режим обхода шейпинга ТСПУ между серверами (автоматически передастся на Сервер 1 внутри токена):" 16 $WT_WIDTH 3 "obfs_choice" \
    "1" " FakeTCP Маскировка (Рекомендуется — полностью мимикрирует под TCP-поток)" \
    "2" " UDP-XOR Маскировка (Резервный вариант)" \
    "3" " Чистый WireGuard без маскировки (Только если ТСПУ не режет WG)"; then
        return 0
    fi

    local obfs_mode="faketcp"
    case "$obfs_choice" in
        1) obfs_mode="faketcp" ;;
        2) obfs_mode="udp" ;;
        3) obfs_mode="none" ;;
    esac

    local exit_choice=""
    if ! smart_menu "3/3. Выход в интернет на Зарубежном Сервере 2" "\nКак выпускать трафик в интернет с этого зарубежного сервера?\n(Вы сможете переключать этот режим в любой момент в Пункте 5 меню каскада):" 16 $WT_WIDTH 2 "exit_choice" \
    "1" " Чистый зарубежный IP (Напрямую с этого сервера — БЕЗ WARP, макс. скорость!)" \
    "2" " Через Cloudflare WARP (Скрывает IP сервера за IP Cloudflare)"; then
        return 0
    fi

    local exit_mode="direct"
    if [ "$exit_choice" = "2" ]; then
        exit_mode="warp"
    else
        silent_run systemctl stop wg-quick@warp.service
        silent_run systemctl disable wg-quick@warp.service
    fi

    echo -e "${C_BLUE} Очистка предыдущих настроек моста wg-cascade и старых правил...${C_RESET}"
    silent_run systemctl stop wg-quick@wg-cascade.service bobarev-udp2raw.service hysteria-server.service hysteria-client.service bobarev-xray.service
    silent_run wg-quick down wg-cascade
    ip link del dev wg-cascade 2>/dev/null || true
    while ip rule del from 10.200.200.0/24 lookup 51820 priority 6001 2>/dev/null; do :; done
    clean_duplicate_cascade_iptables
    disable_ufw_strict_rpfilter

    mkdir -p /etc/wireguard
    local s2_priv=$(wg genkey)
    local s2_pub=$(echo "$s2_priv" | wg pubkey)

    # Генерируем 3 независимых слота (пира) для одновременного подключения до 3 российских серверов без конфликта ключей и IP!
    local s1_priv_1=$(wg genkey); local s1_pub_1=$(echo "$s1_priv_1" | wg pubkey); local psk_1=$(wg genpsk)
    local s1_priv_2=$(wg genkey); local s1_pub_2=$(echo "$s1_priv_2" | wg pubkey); local psk_2=$(wg genpsk)
    local s1_priv_3=$(wg genkey); local s1_pub_3=$(echo "$s1_priv_3" | wg pubkey); local psk_3=$(wg genpsk)
    local obfs_key=$(openssl rand -hex 8 2>/dev/null || echo "mysecretkey2026")

    local wg_listen_port="$ext_port"
    if [ "$obfs_mode" != "none" ]; then
        wg_listen_port="51889"
    fi

    local wan_dev=$(get_wan_if)
    [ -z "$wan_dev" ] && wan_dev="ens3"

    local warp_rule_postup=""
    if [ "$exit_mode" = "warp" ]; then
        warp_rule_postup="PostUp = ip rule del from 10.200.200.0/24 lookup 51820 priority 6001 2>/dev/null || true
PostUp = ip rule add from 10.200.200.0/24 lookup 51820 priority 6001 || true"
    fi

    cat << EOF > /etc/wireguard/wg-cascade.conf
[Interface]
Address = 10.200.200.1/24
ListenPort = $wg_listen_port
PrivateKey = $s2_priv
MTU = 1280
Table = off
PostUp = ip link set dev wg-cascade mtu 1280 txqueuelen 10000 || true
PostUp = tc qdisc replace dev wg-cascade root fq limit 30000 flow_limit 10000 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
${warp_rule_postup}
PostUp = iptables -t mangle -C FORWARD -i wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || iptables -t mangle -I FORWARD 1 -i wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 || true
PostUp = iptables -t mangle -C FORWARD -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || iptables -t mangle -I FORWARD 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 || true
PostUp = iptables -t mangle -C POSTROUTING -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || iptables -t mangle -I POSTROUTING 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 || true
PostDown = ip rule del from 10.200.200.0/24 lookup 51820 priority 6001 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg-cascade -o warp -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i warp -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg-cascade -o $wan_dev -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i $wan_dev -o wg-cascade -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -i wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true

[Peer]
# RU Entry Server #1 (10.200.200.2)
PublicKey = $s1_pub_1
PresharedKey = $psk_1
AllowedIPs = 10.200.200.2/32

[Peer]
# RU Entry Server #2 (10.200.200.3)
PublicKey = $s1_pub_2
PresharedKey = $psk_2
AllowedIPs = 10.200.200.3/32

[Peer]
# RU Entry Server #3 (10.200.200.4)
PublicKey = $s1_pub_3
PresharedKey = $psk_3
AllowedIPs = 10.200.200.4/32
EOF
    chmod 600 /etc/wireguard/wg-cascade.conf

    ensure_wg_kernel_modules
    silent_run systemctl daemon-reload
    systemctl reset-failed wg-quick@wg-cascade.service 2>/dev/null || true
    systemctl enable wg-quick@wg-cascade.service >/dev/null 2>&1 || true
    if ! systemctl restart wg-quick@wg-cascade.service; then
        echo -e "${C_YELLOW} Повторная инициализация интерфейса wg-cascade после принудительной зачистки...${C_RESET}"
        ip link del dev wg-cascade 2>/dev/null || true
        systemctl reset-failed wg-quick@wg-cascade.service 2>/dev/null || true
        systemctl start wg-quick@wg-cascade.service
    fi

    if command -v ufw &>/dev/null; then
        silent_run ufw allow "${ext_port}/udp" comment 'WG Direct Cascade UDP'
        silent_run ufw allow "${ext_port}/tcp" comment 'WG Direct Cascade FakeTCP'
        silent_run ufw route allow in on wg-cascade out on "$wan_dev" comment 'WG Cascade to WAN Direct'
        silent_run ufw route allow in on "$wan_dev" out on wg-cascade comment 'WAN Direct to WG Cascade'
        silent_run ufw route allow in on wg-cascade out on warp comment 'WG Cascade to WARP'
        silent_run ufw route allow in on warp out on wg-cascade comment 'WARP to WG Cascade'
        ensure_ufw_nat_rule "-A POSTROUTING -o warp -j MASQUERADE"
        silent_run ufw reload
        while iptables -t mangle -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    fi

    apply_foreign_exit_mode "$exit_mode"

    if [ "$obfs_mode" != "none" ]; then
        configure_udp2raw_service "server" "127.0.0.1:${wg_listen_port}" "0.0.0.0:${ext_port}" "$obfs_mode" "$obfs_key"
    else
        configure_udp2raw_service "server" "" "" "none" ""
    fi
    disable_ufw_strict_rpfilter

    local ext_ip=""
    ext_ip=$(ip -4 -o addr show dev "${wan_dev:-eth0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 | tr -d '[:space:]' || true)
    if [ -z "$ext_ip" ]; then
        ext_ip=$(curl -4 -s --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || echo "IP_СЕРВЕРА_2")
    fi

    local raw_1="${ext_ip}|${ext_port}|${s2_pub}|${s1_priv_1}|${psk_1}|${obfs_mode}|${obfs_key}|10.200.200.2"
    local raw_2="${ext_ip}|${ext_port}|${s2_pub}|${s1_priv_2}|${psk_2}|${obfs_mode}|${obfs_key}|10.200.200.3"
    local raw_3="${ext_ip}|${ext_port}|${s2_pub}|${s1_priv_3}|${psk_3}|${obfs_mode}|${obfs_key}|10.200.200.4"

    local bridge_token_1=$(printf '%s' "$raw_1" | base64 -w0 2>/dev/null || printf '%s' "$raw_1" | base64 | tr -d '\n\r ')
    local bridge_token_2=$(printf '%s' "$raw_2" | base64 -w0 2>/dev/null || printf '%s' "$raw_2" | base64 | tr -d '\n\r ')
    local bridge_token_3=$(printf '%s' "$raw_3" | base64 -w0 2>/dev/null || printf '%s' "$raw_3" | base64 | tr -d '\n\r ')

    cat << EOF > /etc/default/bobarev-cascade
CASCADE_ROLE="foreign_wg_warp_exit"
FOREIGN_EXIT_MODE="$exit_mode"
WG_CASCADE_PORT="$ext_port"
WG_OBFS_MODE="$obfs_mode"
WG_OBFS_KEY="$obfs_key"
WG_BRIDGE_TOKEN="$bridge_token_1"
WG_BRIDGE_TOKEN_2="$bridge_token_2"
WG_BRIDGE_TOKEN_3="$bridge_token_3"
EOF
    chmod 600 /etc/default/bobarev-cascade

    echo -e "\n${C_GREEN} Зарубежный Сервер 2 (Мост wg-cascade [MTU 1280, MSS 1240, обфускация: $obfs_mode, выход: $exit_mode]) успешно запущен!${C_RESET}"
    echo -e "\n${C_CYAN} === ИНДИВИДУАЛЬНЫЕ ТОКЕНЫ ДЛЯ ПОДКЛЮЧЕНИЯ РОССИЙСКИХ СЕРВЕРОВ ===${C_RESET}"
    echo -e "${C_YELLOW} Используйте свой отдельный токен для каждого РФ-сервера, чтобы они работали одновременно без конфликта IP!${C_RESET}"
    echo -e "\n   ${C_BOLD}Токен #1 (для 1-го РФ-сервера, IP 10.200.200.2):${C_RESET}"
    echo -e "    ${C_BOLD}${C_GREEN}${bridge_token_1}${C_RESET}"
    echo -e "\n   ${C_BOLD}Токен #2 (для 2-го РФ-сервера, IP 10.200.200.3):${C_RESET}"
    echo -e "    ${C_BOLD}${C_GREEN}${bridge_token_2}${C_RESET}"
    echo -e "\n   ${C_BOLD}Токен #3 (резервный для 3-го РФ-сервера, IP 10.200.200.4):${C_RESET}"
    echo -e "    ${C_BOLD}${C_GREEN}${bridge_token_3}${C_RESET}\n"
    echo -e "${C_BLUE} Как подключить РФ-серверы:${C_RESET}"
    echo -e "  1. На первом РФ-сервере -> Пункт 19 -> Пункт 2 -> вставьте Токен #1."
    echo -e "  2. На втором РФ-сервере -> Пункт 19 -> Пункт 2 -> вставьте Токен #2."
}

setup_direct_wg_server1_ru() {
    echo -e "${C_CYAN} === ШАГ 2: НАСТРОЙКА РОССИЙСКОГО СЕРВЕРА 1 (NAIVEPROXY -> WG + ANTI-DPI) ===${C_RESET}"
    if ! check_required_ports_free "ru" "80" "443" "51889"; then
        return 0
    fi
    enable_routing_optimizations || true

    if ! command -v wg &>/dev/null || ! command -v iptables &>/dev/null || ! command -v curl &>/dev/null || ! command -v python3 &>/dev/null; then
        echo -e "${C_BLUE} Установка пакетов wireguard-tools, iptables, curl и python3...${C_RESET}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -yq wireguard-tools iptables curl python3 >/dev/null 2>&1
    fi

    local saved_dom=""
    local saved_email=""
    if [ -f /etc/default/bobarev-cascade ]; then
        # shellcheck disable=SC1091
        source /etc/default/bobarev-cascade
        saved_dom="${NAIVE_DOMAIN:-}"
        saved_email="${NAIVE_EMAIL:-}"
    fi

    local token_in=""
    prompt_clean "1/4. Вставьте Токен соединения, полученный на Зарубежном Сервере 2:" token_in
    if [ "$MODULE_CANCELED" = true ] || [ -z "$token_in" ]; then return 0; fi

    local decoded=""
    decoded=$(python3 -c '
import sys, base64, re
try:
    raw = "".join(sys.argv[1].split())
    pad = len(raw) % 4
    if pad:
        raw += "=" * (4 - pad)
    txt = base64.b64decode(raw.encode("utf-8")).decode("utf-8", errors="ignore")
    if "ip=" in txt and "\n" in txt:
        m = re.search(r"ip=([0-9.]+)", txt)
        ip = m.group(1) if m else ""
        parts = txt.splitlines()[-1].split("|")
        parts[0] = ip
        txt = "|".join(parts)
    print(txt.strip())
except Exception:
    print("")
' "$token_in" 2>/dev/null || echo "")

    if [ -z "$decoded" ]; then
        local clean_b64=$(printf '%s' "$token_in" | tr -d '[:space:]')
        decoded=$(printf '%s' "$clean_b64" | base64 -d 2>/dev/null | tr -d '\n\r' || echo "")
    fi

    local s2_ip="" s2_port="" s2_pub="" s1_priv="" psk="" obfs_mode="none" obfs_key="mysecretkey2026" s1_tun_ip="10.200.200.2"
    IFS="|" read -r s2_ip s2_port s2_pub s1_priv psk obfs_mode obfs_key s1_tun_ip <<< "$decoded"
    s2_ip=$(printf '%s' "$s2_ip" | tr -d '[:space:]')
    s2_port=$(printf '%s' "$s2_port" | tr -dc '0-9')
    s2_pub=$(printf '%s' "$s2_pub" | tr -d '[:space:]')
    s1_priv=$(printf '%s' "$s1_priv" | tr -d '[:space:]')
    psk=$(printf '%s' "$psk" | tr -d '[:space:]')
    obfs_mode=$(printf '%s' "${obfs_mode:-none}" | tr -d '[:space:]')
    obfs_key=$(printf '%s' "${obfs_key:-bobarev2026key}" | tr -d '[:space:]')
    s1_tun_ip=$(printf '%s' "${s1_tun_ip:-10.200.200.2}" | tr -d '[:space:]')
    [ -z "$s1_tun_ip" ] && s1_tun_ip="10.200.200.2"

    if [ -z "${s2_ip:-}" ] || [ -z "${s2_port:-}" ] || [ -z "${s2_pub:-}" ] || [ -z "${s1_priv:-}" ] || [ -z "${psk:-}" ]; then
        echo -e "${C_RED} Ошибка: Неверный формат Токена соединения! Скопируйте свежий токен с Сервера 2 целиком.${C_RESET}"
        return 1
    fi

    # Режим маскировки берется строго из токена Сервера 2: у обоих концов моста он обязан совпадать,
    # иначе рукопожатие WireGuard никогда не состоится.
    case "$obfs_mode" in
        udp|faketcp|none) ;;
        *) obfs_mode="udp" ;;
    esac
    local obfs_human="UDP-XOR"
    [ "$obfs_mode" = "faketcp" ] && obfs_human="FakeTCP"
    [ "$obfs_mode" = "none" ] && obfs_human="Чистый WireGuard (без udp2raw)"
    echo -e "${C_BLUE} Режим маскировки взят из токена Сервера 2: ${obfs_human} (${obfs_mode}).${C_RESET}"
    local n_dom=""
    prompt_default "2/4. Введите ваш домен на этом РФ-сервере (A-запись DNS):" "${saved_dom:-ru.yourdomain.com}" n_dom
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_dom" ]; then return 0; fi

    local n_email=""
    prompt_default "3/4. Введите ваш Email для SSL-сертификата Let's Encrypt:" "${saved_email:-admin@${n_dom}}" n_email
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_email" ]; then return 0; fi

    if [ ! -s "$NAIVE_PASS_FILE" ]; then
        local n_user=""
        prompt_default "4/4. Введите имя пользователя для Shadowrocket:" "user1" n_user
        if [ "$MODULE_CANCELED" = true ] || [ -z "$n_user" ]; then return 0; fi
        n_user=$(echo "$n_user" | tr -dc 'a-zA-Z0-9_-')

        local rand_pass=$(openssl rand -base64 18 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16 || { echo -e "${C_RED} Ошибка генератора паролей.${C_RESET}" >&2; return 1; })
        local n_pass=""
        prompt_default "Пароль для пользователя $n_user:" "$rand_pass" n_pass
        if [ "$MODULE_CANCELED" = true ] || [ -z "$n_pass" ]; then return 0; fi
        add_or_update_naive_user "$n_user" "$n_pass"
    else
        echo -e "${C_GREEN} Существующие пользователи NaiveProxy сохранены!${C_RESET}"
    fi

    ensure_go_and_build_caddy_naive || return 1

    echo -e "${C_BLUE} Очистка предыдущих настроек моста wg-cascade и старых маршрутов...${C_RESET}"
    silent_run systemctl stop wg-quick@wg-cascade.service bobarev-udp2raw.service hysteria-server.service hysteria-client.service bobarev-xray.service
    silent_run wg-quick down wg-cascade
    ip link del dev wg-cascade 2>/dev/null || true
    ip route flush table 51888 2>/dev/null || true
    while ip rule del priority 100 2>/dev/null; do :; done
    while ip rule del priority 101 2>/dev/null; do :; done
    while ip rule del priority 30000 2>/dev/null; do :; done
    while ip rule del lookup 51888 2>/dev/null; do :; done
    clean_duplicate_cascade_iptables
    disable_ufw_strict_rpfilter

    local wan_dev=$(get_wan_if)
    local pub_ip=""
    if [ -n "$wan_dev" ]; then
        pub_ip=$(ip -4 -o addr show dev "$wan_dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 | tr -d '[:space:]' || echo "")
    fi
    if [ -z "$pub_ip" ]; then
        pub_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d '[:space:]' || echo "")
    fi
    if [ -z "$pub_ip" ]; then
        pub_ip=$(curl -4 -s --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || echo "")
    fi

    if command -v tailscale &>/dev/null; then
        silent_run tailscale set --exit-node=
    fi

    local wg_endpoint="${s2_ip}:${s2_port}"
    if [ "$obfs_mode" != "none" ]; then
        configure_udp2raw_service "client" "${s2_ip}:${s2_port}" "127.0.0.1:51889" "$obfs_mode" "$obfs_key"
        wg_endpoint="127.0.0.1:51889"
    else
        configure_udp2raw_service "client" "" "" "none" ""
    fi

    local ssh_p="22"
    local sshd_c=$(get_sshd_cmd)
    if [ -n "$sshd_c" ]; then
        ssh_p=$($sshd_c -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")
    fi
    ssh_p="${ssh_p//[^0-9]/}"
    [ -z "$ssh_p" ] && ssh_p="22"

    mkdir -p /etc/wireguard
    cat << EOF > /etc/wireguard/wg-cascade.conf
[Interface]
Address = ${s1_tun_ip}/24
PrivateKey = $s1_priv
MTU = 1280
Table = 51888
PostUp = ip link set dev wg-cascade mtu 1280 txqueuelen 10000 || true
PostUp = tc qdisc replace dev wg-cascade root fq limit 30000 flow_limit 10000 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
PostUp = ip route flush table 51888 2>/dev/null || true
PostUp = ip route replace default dev wg-cascade table 51888 || true
PostUp = ip rule del to $s2_ip lookup main priority 101 2>/dev/null || true
PostUp = ip rule add to $s2_ip lookup main priority 101 || true
PostUp = ip rule del sport 443 lookup main priority 102 2>/dev/null || true
PostUp = ip rule add sport 443 lookup main priority 102 || true
PostUp = ip rule del sport 80 lookup main priority 103 2>/dev/null || true
PostUp = ip rule add sport 80 lookup main priority 103 || true
PostUp = ip rule del sport $ssh_p lookup main priority 104 2>/dev/null || true
PostUp = ip rule add sport $ssh_p lookup main priority 104 || true
PostUp = ip rule del lookup 51888 priority 30000 2>/dev/null || true
PostUp = ip rule add lookup 51888 priority 30000 || true
PostUp = iptables -t nat -C POSTROUTING -o wg-cascade -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o wg-cascade -j MASQUERADE || true
PostUp = iptables -t mangle -C FORWARD -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || iptables -t mangle -I FORWARD 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 || true
PostUp = iptables -t mangle -C OUTPUT -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || iptables -t mangle -I OUTPUT 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 || true
PostUp = iptables -t mangle -C POSTROUTING -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || iptables -t mangle -I POSTROUTING 1 -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 || true
PostDown = ip rule del lookup 51888 priority 30000 2>/dev/null || true
PostDown = ip rule del to $s2_ip lookup main priority 101 2>/dev/null || true
PostDown = ip rule del sport 443 lookup main priority 102 2>/dev/null || true
PostDown = ip rule del sport 80 lookup main priority 103 2>/dev/null || true
PostDown = ip rule del sport $ssh_p lookup main priority 104 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o wg-cascade -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
PostDown = iptables -t mangle -D OUTPUT -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -o wg-cascade -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true

[Peer]
# Foreign Server 2 (WG -> Exit)
PublicKey = $s2_pub
PresharedKey = $psk
Endpoint = $wg_endpoint
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 /etc/wireguard/wg-cascade.conf

    ensure_wg_kernel_modules
    silent_run systemctl daemon-reload
    systemctl reset-failed wg-quick@wg-cascade.service 2>/dev/null || true
    systemctl enable wg-quick@wg-cascade.service >/dev/null 2>&1 || true
    if ! systemctl restart wg-quick@wg-cascade.service; then
        echo -e "${C_YELLOW} Повторная инициализация интерфейса wg-cascade после глубокой зачистки...${C_RESET}"
        ip link del dev wg-cascade 2>/dev/null || true
        systemctl reset-failed wg-quick@wg-cascade.service 2>/dev/null || true
        systemctl start wg-quick@wg-cascade.service
    fi

    cat << EOF > /etc/default/bobarev-cascade
CASCADE_ROLE="ru_wg_entry"
NAIVE_DOMAIN="$n_dom"
NAIVE_EMAIL="$n_email"
SERVER_PUB_IP="$pub_ip"
FOREIGN_WG_ENDPOINT="${s2_ip}:${s2_port}"
WG_OBFS_MODE="$obfs_mode"
WG_OBFS_KEY="$obfs_key"
TCP_TUNE_PROFILE="balanced"
EOF
    chmod 600 /etc/default/bobarev-cascade

    apply_naive_tcp_tuning_profile "balanced"
    render_naive_caddyfile
    write_bobarev_cascade_ru_script
    /usr/local/bin/bobarev-cascade-ru.sh

    if command -v ufw &>/dev/null; then
        silent_run ufw allow 80/tcp comment 'NaiveProxy ACME HTTP'
        silent_run ufw allow 443/tcp comment 'NaiveProxy HTTPS'
        silent_run ufw allow 443/udp comment 'NaiveProxy HTTP3 QUIC'
    fi
    disable_ufw_strict_rpfilter

    echo -e "\n${C_GREEN} Каскад 1: Naiveproxy - Wireguard - Warp (NaiveProxy -> WG [MTU 1280, MSS 1240 + Anti-DPI: $obfs_mode]) запущен!${C_RESET}"
    echo -e "${C_BLUE} Проверка рукопожатия WireGuard и внешнего IP через мост...${C_RESET}"
    for i in {1..10}; do
        ping -c 1 -W 1 10.200.200.1 >/dev/null 2>&1 || true
        if wg show wg-cascade latest-handshakes 2>/dev/null | grep -qE "[1-9][0-9]{2,}"; then
            break
        fi
        sleep 1
    done
    local test_ip=$(curl -4 -s --interface wg-cascade --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || echo "")
    if [ -z "$test_ip" ]; then
        test_ip=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || echo "Установка рукопожатия...")
    fi
    [ -z "$test_ip" ] && test_ip="Установка рукопожатия..."
    echo -e "   Выходной IP каскада: ${C_GREEN}${test_ip}${C_RESET}"
    print_naive_shadowrocket_links
}

render_hysteria_server_config() {
    local h_port="$1"
    local h_pass="$2"
    local exit_mode="${3:-direct}"

    mkdir -p /etc/hysteria
    if [ ! -s /etc/hysteria/server.crt ] || [ ! -s /etc/hysteria/server.key ]; then
        openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=www.bing.com" 2>/dev/null
    fi
    chmod 600 /etc/hysteria/server.key

    local outbound_block=""
    if [ "$exit_mode" = "warp" ]; then
        ip rule del from 172.16.0.2 lookup 51820 priority 5998 2>/dev/null || true
        ip rule add from 172.16.0.2 lookup 51820 priority 5998 2>/dev/null || true
        ip rule del oif warp lookup 51820 priority 5999 2>/dev/null || true
        ip rule add oif warp lookup 51820 priority 5999 2>/dev/null || true
        outbound_block="outbounds:
  - name: warp_out
    type: direct
    direct:
      mode: 4
      bindDevice: warp"
    else
        outbound_block="outbounds:
  - name: direct_out
    type: direct
    direct:
      mode: 4"
    fi

    cat << EOF > /etc/hysteria/config.yaml
listen: :${h_port}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: "${h_pass}"

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
  maxIdleTimeout: 60s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

${outbound_block}
EOF
    chmod 600 /etc/hysteria/config.yaml
}

setup_cascade_hysteria_server2_foreign() {
    echo -e "${C_CYAN} === НАСТРОЙКА СЕРВЕРА 2 (ЗАРУБЕЖНЫЙ ВЫХОД): HYSTERIA 2 -> WARP / ЧИСТЫЙ IP ===${C_RESET}"
    ensure_hysteria_installed || return 1
    enable_routing_optimizations || true
    apply_naive_tcp_tuning_profile "balanced"

    local h_port="36533"
    prompt_default "1/3. Введите UDP-порт для сервера Hysteria 2 (рекомендуется 36533 или 443):" "$h_port" h_port
    if [ "$MODULE_CANCELED" = true ] || [ -z "$h_port" ]; then return 0; fi
    h_port="${h_port//[^0-9]/}"

    local h_pass=$(openssl rand -base64 18 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16 || echo "SecretPass2026")
    local h_pass_input=""
    prompt_default "2/3. Пароль для моста Hysteria 2:" "$h_pass" h_pass_input
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi
    [ -n "$h_pass_input" ] && h_pass="$h_pass_input"

    local exit_choice=""
    if ! smart_menu "3/3. Выход в интернет на Зарубежном Сервере 2 (Hysteria 2)" "\nКак выпускать трафик из Hysteria 2 в интернет?" 16 $WT_WIDTH 2 "exit_choice" \
    "1" " Через Cloudflare WARP (Маскирует выходной IP под Cloudflare)" \
    "2" " Чистый зарубежный IP (Напрямую с этого сервера — БЕЗ WARP, макс. скорость!)"; then
        return 0
    fi

    local exit_mode="warp"
    [ "$exit_choice" = "2" ] && exit_mode="direct"

    silent_run systemctl stop hysteria-server.service hysteria-client.service
    pkill -f "/usr/local/bin/hysteria" 2>/dev/null || true

    apply_foreign_exit_mode "$exit_mode"

    render_hysteria_server_config "$h_port" "$h_pass" "$exit_mode"

    cat << 'SVC_EOF' > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Bobarev Shell Hysteria 2 Server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Nice=-10
LimitNOFILE=1048576
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC_EOF

    silent_run systemctl daemon-reload
    silent_run systemctl enable --now hysteria-server.service
    systemctl restart hysteria-server.service || true
    sleep 2

    if ! systemctl is-active --quiet hysteria-server.service; then
        echo -e "${C_RED} Служба hysteria-server НЕ запустилась! Журнал ошибок:${C_RESET}"
        journalctl -u hysteria-server.service -n 15 --no-pager || true
        return 1
    fi

    if command -v ufw &>/dev/null; then
        silent_run ufw allow "${h_port}/tcp" comment 'Hysteria 2 TCP'
        silent_run ufw allow "${h_port}/udp" comment 'Hysteria 2 QUIC UDP'
    fi

    local wan_dev=$(get_wan_if)
    local pub_ip=$(ip -4 -o addr show dev "${wan_dev:-ens3}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 | tr -d '[:space:]' || true)
    if [ -z "$pub_ip" ]; then
        pub_ip=$(curl -4 -s --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || echo "IP_СЕРВЕРА_2")
    fi
    local pub_ipv6=""
    pub_ipv6=$(ip -6 -o addr show dev "${wan_dev:-ens3}" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 | tr -d '[:space:]' || true)
    if [ -z "$pub_ipv6" ]; then
        pub_ipv6=$(curl -6 -s --max-time 4 https://[2606:4700:4700::1111]/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || true)
    fi

    local cert_pin=""
    if [ -s /etc/hysteria/server.crt ]; then
        cert_pin=$(openssl x509 -noout -fingerprint -sha256 -in /etc/hysteria/server.crt 2>/dev/null | awk -F= '{print $2}' | tr -d '[:space:]' || true)
    fi

    local bridge_token=$(printf '%s|%s|%s|%s' "$pub_ip" "$h_port" "$h_pass" "$cert_pin" | base64 -w0 2>/dev/null || printf '%s|%s|%s|%s' "$pub_ip" "$h_port" "$h_pass" "$cert_pin" | base64 | tr -d '\n\r ')
    local bridge_token_v6=""
    if [ -n "$pub_ipv6" ]; then
        bridge_token_v6=$(printf '%s|%s|%s|%s' "$pub_ipv6" "$h_port" "$h_pass" "$cert_pin" | base64 -w0 2>/dev/null || printf '%s|%s|%s|%s' "$pub_ipv6" "$h_port" "$h_pass" "$cert_pin" | base64 | tr -d '\n\r ')
    fi

    cat << EOF > /etc/default/bobarev-cascade
CASCADE_ROLE="foreign_hysteria_exit"
FOREIGN_EXIT_MODE="$exit_mode"
HYSTERIA_PORT="$h_port"
HYSTERIA_PASS="$h_pass"
HYSTERIA_CERT_PIN="$cert_pin"
HYSTERIA_TOKEN="$bridge_token"
HYSTERIA_TOKEN_V6="$bridge_token_v6"
SERVER_PUB_IP="$pub_ip"
SERVER_PUB_IPV6="$pub_ipv6"
EOF
    chmod 600 /etc/default/bobarev-cascade

    echo -e "\n${C_GREEN} Сервер 2 (Hysteria 2 [порт: $h_port/udp, выход: $exit_mode]) успешно запущен!${C_RESET}"
    echo -e "\n${C_CYAN} ТОКЕНЫ ДЛЯ СЕРВЕРА 1 (РФ):${C_RESET}"
    echo -e "   ${C_BOLD}Основной токен (IPv4):${C_RESET}"
    echo -e "    ${C_BOLD}${C_GREEN}${bridge_token}${C_RESET}"
    if [ -n "$bridge_token_v6" ]; then
        echo -e "\n   ${C_BOLD}Резервный токен (IPv6 — обход блокировки IPv4):${C_RESET}"
        echo -e "    ${C_BOLD}${C_CYAN}${bridge_token_v6}${C_RESET}"
    fi
    echo ""
}

setup_cascade_hysteria_server1_ru() {
    echo -e "${C_CYAN} === НАСТРОЙКА СЕРВЕРА 1 (ВХОД РФ): NAIVEPROXY -> HYSTERIA 2 ===${C_RESET}"
    ensure_hysteria_installed || return 1
    enable_routing_optimizations || true

    local saved_dom=""
    local saved_email=""
    if [ -f /etc/default/bobarev-cascade ]; then
        # shellcheck disable=SC1091
        source /etc/default/bobarev-cascade
        saved_dom="${NAIVE_DOMAIN:-}"
        saved_email="${NAIVE_EMAIL:-}"
    fi

    local token_in=""
    prompt_clean "1/4. Вставьте Токен соединения Hysteria 2 с Зарубежного Сервера 2:" token_in
    if [ "$MODULE_CANCELED" = true ] || [ -z "$token_in" ]; then return 0; fi

    local clean_b64=$(printf '%s' "$token_in" | tr -d '[:space:]')
    local decoded=$(printf '%s' "$clean_b64" | base64 -d 2>/dev/null | tr -d '\n\r' || echo "")
    local s2_ip="" s2_port="" s2_pass="" s2_pin=""
    IFS='|' read -r s2_ip s2_port s2_pass s2_pin <<< "$decoded"

    if [ -z "$s2_ip" ] || [ -z "$s2_port" ] || [ -z "$s2_pass" ]; then
        echo -e "${C_RED} Ошибка: Неверный формат Токена Hysteria 2!${C_RESET}"
        return 1
    fi

    local n_dom=""
    prompt_default "2/4. Введите ваш домен на этом РФ-сервере (A-запись DNS):" "${saved_dom:-ru.yourdomain.com}" n_dom
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_dom" ]; then return 0; fi

    local n_email=""
    prompt_default "3/4. Введите Email для выпуска SSL-сертификата Let's Encrypt:" "${saved_email:-admin@${n_dom}}" n_email
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_email" ]; then return 0; fi

    if [ ! -s "$NAIVE_PASS_FILE" ]; then
        local n_user=""
        prompt_default "4/4. Введите имя пользователя для Shadowrocket:" "user1" n_user
        if [ "$MODULE_CANCELED" = true ] || [ -z "$n_user" ]; then return 0; fi
        n_user=$(echo "$n_user" | tr -dc 'a-zA-Z0-9_-')

        local rand_pass=$(openssl rand -base64 18 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16 || { echo -e "${C_RED} Ошибка генератора паролей.${C_RESET}" >&2; return 1; })
        local n_pass=""
        prompt_default "Пароль для пользователя $n_user:" "$rand_pass" n_pass
        if [ "$MODULE_CANCELED" = true ] || [ -z "$n_pass" ]; then return 0; fi
        add_or_update_naive_user "$n_user" "$n_pass"
    else
        echo -e "${C_GREEN} Существующие пользователи NaiveProxy сохранены!${C_RESET}"
    fi

    ensure_go_and_build_caddy_naive || return 1

    # Отключаем перехват маршрутов от Каскада 1 (wg-cascade / udp2raw) и Tailscale Exit Node,
    # чтобы трафик шел строго по цепочке: Caddy (NaiveProxy) -> socks5://127.0.0.1:1080 (Hysteria 2 Client) -> Сервер 2
    echo -e "${C_BLUE} Очистка конфликтующих маршрутов wg-cascade и старых экземпляров Hysteria...${C_RESET}"
    silent_run systemctl stop wg-quick@wg-cascade.service bobarev-udp2raw.service hysteria-server.service hysteria-client.service bobarev-xray.service
    silent_run systemctl disable wg-quick@wg-cascade.service bobarev-udp2raw.service hysteria-server.service hysteria-client.service bobarev-xray.service
    silent_run wg-quick down wg-cascade
    ip link del dev wg-cascade 2>/dev/null || true
    ip route flush table 51888 2>/dev/null || true
    while ip rule del priority 30000 2>/dev/null; do :; done
    while ip rule del lookup 51888 2>/dev/null; do :; done
    clean_duplicate_cascade_iptables
    if command -v tailscale &>/dev/null; then
        silent_run tailscale set --exit-node=
    fi

    mkdir -p /etc/hysteria
    local h_server_target="${s2_ip}:${s2_port}"
    if [[ "$s2_ip" =~ : ]]; then
        h_server_target="[${s2_ip}]:${s2_port}"
    fi
    local tls_block="tls:
  sni: www.bing.com
  insecure: true"
    if [ -n "${s2_pin:-}" ]; then
        tls_block="tls:
  sni: www.bing.com
  insecure: false
  pinSHA256: \"${s2_pin}\""
        echo -e "${C_GREEN} Включена защита от MITM: привязка сертификата Сервера 2 (pinSHA256: ${s2_pin}).${C_RESET}"
    fi
    cat << EOF > /etc/hysteria/client.yaml
server: ${h_server_target}
auth: "${s2_pass}"

${tls_block}

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
  maxIdleTimeout: 60s
  keepAlivePeriod: 15s
  disablePathMTUDiscovery: false

socks5:
  listen: 127.0.0.1:1080
EOF
    chmod 600 /etc/hysteria/client.yaml

    cat << 'SVC_EOF' > /etc/systemd/system/hysteria-client.service
[Unit]
Description=Bobarev Shell Hysteria 2 Client (SOCKS5 127.0.0.1:1080)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Nice=-10
LimitNOFILE=1048576
ExecStart=/usr/local/bin/hysteria client --config /etc/hysteria/client.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC_EOF

    silent_run systemctl daemon-reload
    silent_run systemctl enable --now hysteria-client.service
    systemctl restart hysteria-client.service || true
    sleep 2

    if ! systemctl is-active --quiet hysteria-client.service; then
        echo -e "${C_RED} Служба hysteria-client НЕ запустилась! Журнал:${C_RESET}"
        journalctl -u hysteria-client.service -n 15 --no-pager || true
        return 1
    fi

    # Сначала записываем CASCADE_ROLE="ru_hysteria_entry", чтобы render_naive_caddyfile()
    # гарантированно добавил директиву `upstream socks5://127.0.0.1:1080` в блок forward_proxy!
    cat << EOF > /etc/default/bobarev-cascade
CASCADE_ROLE="ru_hysteria_entry"
NAIVE_DOMAIN="$n_dom"
NAIVE_EMAIL="$n_email"
HYSTERIA_SERVER="$s2_ip"
HYSTERIA_PORT="$s2_port"
TCP_TUNE_PROFILE="balanced"
EOF
    chmod 600 /etc/default/bobarev-cascade

    apply_naive_tcp_tuning_profile "balanced"
    render_naive_caddyfile

    if command -v ufw &>/dev/null; then
        silent_run ufw allow 80/tcp comment 'NaiveProxy ACME HTTP'
        silent_run ufw allow 443/tcp comment 'NaiveProxy HTTPS'
        silent_run ufw allow 443/udp comment 'NaiveProxy HTTP3 QUIC'
    fi

    echo -e "${C_BLUE} Проверка выходного IP через локальный SOCKS5-мост Hysteria 2 (127.0.0.1:1080)...${C_RESET}"
    local test_ip=$(curl -4 -s --socks5-hostname 127.0.0.1:1080 --max-time 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || echo "")
    if [ -z "$test_ip" ]; then
        test_ip=$(curl -4 -s --socks5-hostname 127.0.0.1:1080 --max-time 6 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || echo "Проверьте доступность UDP-порта ${s2_port} на Сервере 2")
    fi
    echo -e "\n${C_GREEN} Каскад 2 (NaiveProxy -> Hysteria 2 SOCKS5 -> Выход Зарубеж) успешно запущен!${C_RESET}"
    echo -e "   Выходной IP каскада: ${C_BOLD}${C_GREEN}${test_ip}${C_RESET}"
    print_naive_shadowrocket_links
}

manage_cascade_hysteria_menu() {
    while true; do
        MODULE_CANCELED=false
        local c_state="Не активен"
        if systemctl is-active --quiet hysteria-server.service 2>/dev/null; then
            if is_warp_active; then
                c_state="Активен Сервер 2 (Зарубеж: Hysteria 2 -> Cloudflare WARP)"
            else
                c_state="Активен Сервер 2 (Зарубеж: Hysteria 2 -> Чистый IP сервера)"
            fi
        elif systemctl is-active --quiet hysteria-client.service 2>/dev/null; then
            c_state="Активен Сервер 1 (РФ: NaiveProxy -> Hysteria 2 Client)"
        fi

        local c_choice
        if ! smart_menu " Каскад 2: NaiveProxy + Hysteria 2 + WARP" "\nСтатус моста: $c_state\nВыберите действие:" 19 $WT_WIDTH 7 "c_choice" \
        "1" " Сервер 2 (Зарубеж): Hysteria 2 -> Выход" \
        "2" " Сервер 1 (РФ): NaiveProxy -> Hysteria 2" \
        "3" " Управление пользователями NaiveProxy" \
        "4" " Показать ссылки Shadowrocket" \
        "5" " Переключить выход: Чистый IP <-> WARP" \
        "6" " Показать токен подключения" \
        "7" " Остановить службу Hysteria 2" \
        "0" " Вернуться в главное меню" || [ "$c_choice" = "0" ]; then
            break
        fi

        clear
        case "$c_choice" in
            1) setup_cascade_hysteria_server2_foreign || true; pause_enter ;;
            2) setup_cascade_hysteria_server1_ru || true; pause_enter ;;
            3) manage_naive_users_menu ;;
            4) print_naive_shadowrocket_links; pause_enter ;;
            5) toggle_foreign_warp_menu; pause_enter ;;
            6)
                if [ -f /etc/default/bobarev-cascade ]; then
                    # shellcheck disable=SC1091
                    source /etc/default/bobarev-cascade
                    if [ -n "${HYSTERIA_TOKEN:-}" ]; then
                        echo -e "${C_CYAN} Токены Hysteria 2 для подключения Сервера 1 (РФ):${C_RESET}\n"
                        echo -e "   ${C_BOLD}Основной токен (IPv4):${C_RESET}"
                        echo -e "    ${C_BOLD}${C_GREEN}${HYSTERIA_TOKEN}${C_RESET}\n"
                        if [ -n "${HYSTERIA_TOKEN_V6:-}" ]; then
                            echo -e "   ${C_BOLD}Резервный токен (IPv6):${C_RESET}"
                            echo -e "    ${C_BOLD}${C_CYAN}${HYSTERIA_TOKEN_V6}${C_RESET}\n"
                        fi
                    else
                        echo -e "${C_YELLOW} Токен Hysteria 2 еще не создан на этом сервере.${C_RESET}"
                    fi
                fi
                pause_enter
                ;;
            7)
                if prompt_yn "Остановить и отключить службы Hysteria 2 на этом сервере?" "false"; then
                    silent_run systemctl stop hysteria-server.service hysteria-client.service
                    silent_run systemctl disable hysteria-server.service hysteria-client.service
                    rm -f /etc/hysteria/client.yaml /etc/hysteria/config.yaml
                    if [ -f /etc/default/bobarev-cascade ]; then
                        sed -i 's/CASCADE_ROLE="ru_hysteria_entry"/CASCADE_ROLE="none"/' /etc/default/bobarev-cascade 2>/dev/null || true
                        render_naive_caddyfile 2>/dev/null || true
                    fi
                    echo -e "${C_GREEN} Службы Hysteria 2 остановлены и отключены.${C_RESET}"
                fi
                pause_enter
                ;;
        esac
    done
}


# ==============================================================================
# МОДУЛЬ 21: КАСКАД 3 (NAIVEPROXY -> XRAY REALITY VLESS -> WARP / ЧИСТЫЙ IP)
# ==============================================================================
ensure_xray_installed() {
    if [ -x "/usr/local/bin/xray" ]; then
        return 0
    fi
    echo -e "${C_BLUE} Скачивание и установка Xray-core с официального репозитория XTLS...${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -yq curl wget unzip ca-certificates >/dev/null 2>&1

    local arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    local x_zip="Xray-linux-64.zip"
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
        x_zip="Xray-linux-arm64-v8a.zip"
    fi

    local tmp_xray=$(mktemp -d /root/.xray-XXXXXX)
    local x_url="https://github.com/XTLS/Xray-core/releases/latest/download/${x_zip}"

    if ! curl -fsSL "$x_url" -o "${tmp_xray}/xray.zip"; then
        rm -rf "$tmp_xray"
        echo -e "${C_RED} Ошибка скачивания архива Xray-core с GitHub.${C_RESET}"
        return 1
    fi
    if curl -fsSL "${x_url}.dgst" -o "${tmp_xray}/xray.zip.dgst" 2>/dev/null; then
        local exp_xray_sha=$(awk -F'= ' '/^SHA2-256=/{print $2; exit}' "${tmp_xray}/xray.zip.dgst" | tr -d '[:space:]' || true)
        if [ -n "$exp_xray_sha" ] && ! verify_sha256 "${tmp_xray}/xray.zip" "$exp_xray_sha"; then
            rm -rf "$tmp_xray"
            return 1
        fi
    fi

    unzip -qo "${tmp_xray}/xray.zip" -d "$tmp_xray"
    if [ -f "${tmp_xray}/xray" ]; then
        cp -f "${tmp_xray}/xray" /usr/local/bin/xray
        chmod +x /usr/local/bin/xray
    else
        rm -rf "$tmp_xray"
        echo -e "${C_RED} Бинарник xray не найден в распакованном архиве!${C_RESET}"
        return 1
    fi
    rm -rf "$tmp_xray"
    echo -e "${C_GREEN} Xray-core успешно установлен: $(/usr/local/bin/xray version 2>/dev/null | head -n 1 || echo "готов")${C_RESET}"
    return 0
}

write_xray_service() {
    cat << 'SVC_EOF' > /etc/systemd/system/bobarev-xray.service
[Unit]
Description=Bobarev Shell Xray-core Cascade Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Nice=-10
LimitNOFILE=1048576
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC_EOF
    silent_run systemctl daemon-reload
}

render_xray_server_config() {
    local x_port="$1"
    local x_uuid="$2"
    local x_priv="$3"
    local x_short_id="$4"
    local x_sni="$5"
    local exit_mode="${6:-direct}"

    mkdir -p /etc/xray
    local outbound_sockopt=""
    if [ "$exit_mode" = "warp" ]; then
        outbound_sockopt=',
      "streamSettings": {
        "sockopt": {
          "interface": "warp"
        }
      }'
    fi

    cat << EOF > /etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${x_port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${x_uuid}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${x_sni}:443",
          "xver": 0,
          "serverNames": [
            "${x_sni}"
          ],
          "privateKey": "${x_priv}",
          "shortIds": [
            "${x_short_id}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }${outbound_sockopt}
    }
  ]
}
EOF
    chmod 600 /etc/xray/config.json
}

render_xray_client_config() {
    local s2_ip="$1"
    local s2_port="$2"
    local s2_uuid="$3"
    local s2_pub="$4"
    local s2_short_id="$5"
    local s2_sni="$6"

    mkdir -p /etc/xray
    cat << EOF > /etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${s2_ip}",
            "port": ${s2_port},
            "users": [
              {
                "id": "${s2_uuid}",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "${s2_sni}",
          "publicKey": "${s2_pub}",
          "shortId": "${s2_short_id}",
          "spiderX": ""
        },
        "sockopt": {
          "dialerProxy": "fragment",
          "tcpNoDelay": true
        }
      }
    },
    {
      "tag": "fragment",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "AsIs",
        "fragment": {
          "packets": "1-3",
          "length": "100-200",
          "interval": "10-20"
        }
      },
      "streamSettings": {
        "sockopt": {
          "tcpNoDelay": true
        }
      }
    }
  ]
}
EOF
    chmod 600 /etc/xray/config.json
}

setup_cascade_xray_server2_foreign() {
    echo -e "${C_CYAN} === НАСТРОЙКА СЕРВЕРА 2 (ЗАРУБЕЖНЫЙ ВЫХОД): XRAY REALITY -> WARP / ЧИСТЫЙ IP ===${C_RESET}"
    ensure_xray_installed || return 1
    enable_routing_optimizations || true
    apply_naive_tcp_tuning_profile "balanced"

    local x_port="8443"
    prompt_default "1/3. Введите TCP-порт для приема VLESS-REALITY (рекомендуется 8443 или 443):" "$x_port" x_port
    if [ "$MODULE_CANCELED" = true ] || [ -z "$x_port" ]; then return 0; fi
    x_port="${x_port//[^0-9]/}"

    local x_sni="gateway.icloud.com"
    prompt_default "2/3. Введите целевой SNI-домен для маскировки REALITY (TLS 1.3):" "$x_sni" x_sni
    if [ "$MODULE_CANCELED" = true ] || [ -z "$x_sni" ]; then return 0; fi

    local exit_choice=""
    if ! smart_menu "3/3. Выход в интернет на Зарубежном Сервере 2 (Xray REALITY)" "
Как выпускать трафик из Xray в интернет?" 16 $WT_WIDTH 2 "exit_choice"     "1" " Чистый зарубежный IP (Напрямую с этого сервера — БЕЗ WARP, макс. скорость!)"     "2" " Через Cloudflare WARP (Маскирует выходной IP под Cloudflare)"; then
        return 0
    fi

    local exit_mode="direct"
    [ "$exit_choice" = "2" ] && exit_mode="warp"

    # Генерация ключей x25519, UUID и ShortId (совместимо со старым Public key и новым Password в Xray v25/v26+)
    local keys=$(/usr/local/bin/xray x25519 2>/dev/null || true)
    local x_priv=$(echo "$keys" | awk -F':' 'tolower($1) ~ /private/ {print $2; exit}' | tr -d '[:space:]')
    local x_pub=$(echo "$keys" | awk -F':' 'tolower($1) ~ /public|password/ {print $2; exit}' | tr -d '[:space:]')
    local x_uuid=$(/usr/local/bin/xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
    local x_short_id=$(openssl rand -hex 8)

    if [ -z "$x_priv" ] || [ -z "$x_pub" ]; then
        echo -e "${C_RED} Ошибка генерации ключей x25519 через бинарник xray!${C_RESET}"
        return 1
    fi

    silent_run systemctl stop bobarev-xray.service
    apply_foreign_exit_mode "$exit_mode"
    render_xray_server_config "$x_port" "$x_uuid" "$x_priv" "$x_short_id" "$x_sni" "$exit_mode"
    write_xray_service

    silent_run systemctl enable --now bobarev-xray.service
    systemctl restart bobarev-xray.service || true
    sleep 2

    if ! systemctl is-active --quiet bobarev-xray.service; then
        echo -e "${C_RED} Служба bobarev-xray НЕ запустилась! Журнал ошибок:${C_RESET}"
        journalctl -u bobarev-xray.service -n 15 --no-pager || true
        return 1
    fi

    if command -v ufw &>/dev/null; then
        silent_run ufw allow "${x_port}/tcp" comment 'Xray REALITY TCP'
        silent_run ufw reload
    fi

    local wan_dev=$(get_wan_if)
    local pub_ip=$(ip -4 -o addr show dev "${wan_dev:-ens3}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 | tr -d '[:space:]' || true)
    if [ -z "$pub_ip" ]; then
        pub_ip=$(curl -4 -s --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || echo "IP_СЕРВЕРА_2")
    fi
    local pub_ipv6=""
    pub_ipv6=$(ip -6 -o addr show dev "${wan_dev:-ens3}" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 | tr -d '[:space:]' || true)
    if [ -z "$pub_ipv6" ]; then
        pub_ipv6=$(curl -6 -s --max-time 4 https://[2606:4700:4700::1111]/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]' || true)
    fi

    local bridge_token=$(printf '%s|%s|%s|%s|%s|%s' "$pub_ip" "$x_port" "$x_uuid" "$x_pub" "$x_short_id" "$x_sni" | base64 -w0 2>/dev/null || printf '%s|%s|%s|%s|%s|%s' "$pub_ip" "$x_port" "$x_uuid" "$x_pub" "$x_short_id" "$x_sni" | base64 | tr -d '\n\r ')
    local bridge_token_v6=""
    if [ -n "$pub_ipv6" ]; then
        bridge_token_v6=$(printf '%s|%s|%s|%s|%s|%s' "$pub_ipv6" "$x_port" "$x_uuid" "$x_pub" "$x_short_id" "$x_sni" | base64 -w0 2>/dev/null || printf '%s|%s|%s|%s|%s|%s' "$pub_ipv6" "$x_port" "$x_uuid" "$x_pub" "$x_short_id" "$x_sni" | base64 | tr -d '\n\r ')
    fi

    cat << EOF > /etc/default/bobarev-cascade
CASCADE_ROLE="foreign_xray_exit"
FOREIGN_EXIT_MODE="$exit_mode"
XRAY_PORT="$x_port"
XRAY_UUID="$x_uuid"
XRAY_PRIV="$x_priv"
XRAY_PUB="$x_pub"
XRAY_SHORT_ID="$x_short_id"
XRAY_SNI="$x_sni"
XRAY_TOKEN="$bridge_token"
XRAY_TOKEN_V6="$bridge_token_v6"
SERVER_PUB_IP="$pub_ip"
SERVER_PUB_IPV6="$pub_ipv6"
EOF
    chmod 600 /etc/default/bobarev-cascade

    echo -e "\n${C_GREEN} Сервер 2 (Xray VLESS-REALITY [порт: $x_port/tcp, SNI: $x_sni, выход: $exit_mode]) успешно запущен!${C_RESET}"
    echo -e "\n${C_CYAN} ТОКЕНЫ ДЛЯ СЕРВЕРА 1 (РФ):${C_RESET}"
    echo -e "   ${C_BOLD}Основной токен (IPv4):${C_RESET}"
    echo -e "    ${C_BOLD}${C_GREEN}${bridge_token}${C_RESET}"
    if [ -n "$bridge_token_v6" ]; then
        echo -e "\n   ${C_BOLD}Резервный токен (IPv6 — обход блокировки IPv4):${C_RESET}"
        echo -e "    ${C_BOLD}${C_CYAN}${bridge_token_v6}${C_RESET}"
    fi
    echo ""
}

setup_cascade_xray_server1_ru() {
    echo -e "${C_CYAN} === НАСТРОЙКА СЕРВЕРА 1 (ВХОД РФ): NAIVEPROXY -> XRAY REALITY ===${C_RESET}"
    ensure_xray_installed || return 1
    enable_routing_optimizations || true

    local saved_dom=""
    local saved_email=""
    if [ -f /etc/default/bobarev-cascade ]; then
        # shellcheck disable=SC1091
        source /etc/default/bobarev-cascade
        saved_dom="${NAIVE_DOMAIN:-}"
        saved_email="${NAIVE_EMAIL:-}"
    fi

    local token_in=""
    prompt_clean "1/4. Вставьте Токен соединения Xray REALITY с Зарубежного Сервера 2:" token_in
    if [ "$MODULE_CANCELED" = true ] || [ -z "$token_in" ]; then return 0; fi

    local clean_b64=$(printf '%s' "$token_in" | tr -d '[:space:]')
    local decoded=$(printf '%s' "$clean_b64" | base64 -d 2>/dev/null | tr -d '\r\n' || echo "")
    local s2_ip="" s2_port="" s2_uuid="" s2_pub="" s2_short_id="" s2_sni=""
    IFS='|' read -r s2_ip s2_port s2_uuid s2_pub s2_short_id s2_sni <<< "$decoded"

    if [ -z "$s2_ip" ] || [ -z "$s2_port" ] || [ -z "$s2_uuid" ] || [ -z "$s2_pub" ]; then
        echo -e "${C_RED} Ошибка: Неверный формат Токена Xray REALITY! Скопируйте свежий токен с Сервера 2.${C_RESET}"
        return 1
    fi

    local n_dom=""
    prompt_default "2/4. Введите ваш домен на этом РФ-сервере (A-запись DNS):" "${saved_dom:-ru.yourdomain.com}" n_dom
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_dom" ]; then return 0; fi

    local n_email=""
    prompt_default "3/4. Введите Email для выпуска SSL-сертификата Let's Encrypt:" "${saved_email:-admin@${n_dom}}" n_email
    if [ "$MODULE_CANCELED" = true ] || [ -z "$n_email" ]; then return 0; fi

    if [ ! -s "$NAIVE_PASS_FILE" ]; then
        local n_user=""
        prompt_default "4/4. Введите имя пользователя для Shadowrocket:" "user1" n_user
        if [ "$MODULE_CANCELED" = true ] || [ -z "$n_user" ]; then return 0; fi
        n_user=$(echo "$n_user" | tr -dc 'a-zA-Z0-9_-')

        local rand_pass=$(openssl rand -base64 18 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16 || { echo -e "${C_RED} Ошибка генератора паролей.${C_RESET}" >&2; return 1; })
        local n_pass=""
        prompt_default "Пароль для пользователя $n_user:" "$rand_pass" n_pass
        if [ "$MODULE_CANCELED" = true ] || [ -z "$n_pass" ]; then return 0; fi
        add_or_update_naive_user "$n_user" "$n_pass"
    else
        echo -e "${C_GREEN} Существующие пользователи NaiveProxy сохранены!${C_RESET}"
    fi

    ensure_go_and_build_caddy_naive || return 1

    echo -e "${C_BLUE} Очистка маршрутов и служб этого каскада...${C_RESET}"
    silent_run systemctl stop wg-quick@wg-cascade.service bobarev-udp2raw.service hysteria-server.service hysteria-client.service bobarev-xray.service
    silent_run systemctl disable wg-quick@wg-cascade.service bobarev-udp2raw.service hysteria-server.service hysteria-client.service bobarev-xray.service
    silent_run wg-quick down wg-cascade 2>/dev/null || true
    ip link del dev wg-cascade 2>/dev/null || true
    ip route flush table 51888 2>/dev/null || true
    while ip rule del lookup 51888 2>/dev/null; do :; done
    clean_duplicate_cascade_iptables
    if command -v tailscale &>/dev/null; then
        local ts_exit_now=""
        ts_exit_now=$(tailscale get exit-node 2>/dev/null || echo "")
        if [ -n "$ts_exit_now" ] && [ "$ts_exit_now" != "none" ] && [ "$ts_exit_now" != "false" ]; then
            echo -e "${C_YELLOW} Сохраняю текущий Tailscale exit node: $ts_exit_now.${C_RESET}"
        fi
    fi

    render_xray_client_config "$s2_ip" "$s2_port" "$s2_uuid" "$s2_pub" "$s2_short_id" "$s2_sni"
    write_xray_service

    silent_run systemctl enable --now bobarev-xray.service
    systemctl restart bobarev-xray.service || true
    sleep 2

    if ! systemctl is-active --quiet bobarev-xray.service; then
        echo -e "${C_RED} Служба bobarev-xray (клиент) НЕ запустилась! Журнал:${C_RESET}"
        journalctl -u bobarev-xray.service -n 15 --no-pager || true
        return 1
    fi

    cat << EOF > /etc/default/bobarev-cascade
CASCADE_ROLE="ru_xray_entry"
NAIVE_DOMAIN="$n_dom"
NAIVE_EMAIL="$n_email"
XRAY_SERVER="$s2_ip"
XRAY_PORT="$s2_port"
TCP_TUNE_PROFILE="balanced"
EOF
    chmod 600 /etc/default/bobarev-cascade

    apply_naive_tcp_tuning_profile "balanced"
    render_naive_caddyfile

    if command -v ufw &>/dev/null; then
        silent_run ufw allow 80/tcp comment 'NaiveProxy ACME HTTP'
        silent_run ufw allow 443/tcp comment 'NaiveProxy HTTPS'
        silent_run ufw allow 443/udp comment 'NaiveProxy HTTP3 QUIC'
    fi

    echo -e "${C_BLUE} Проверка выходного IP через локальный SOCKS5-мост Xray REALITY (127.0.0.1:10808)...${C_RESET}"
    local test_ip="" probe_url="" direct_ip=""
    for probe_url in "https://1.1.1.1/cdn-cgi/trace" "https://www.cloudflare.com/cdn-cgi/trace" "https://api.ipify.org"; do
        test_ip=$(curl -q -4 --noproxy '*' --socks5-hostname 127.0.0.1:10808 --connect-timeout 5 --max-time 12 "$probe_url" 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]')
        if [ -z "$test_ip" ]; then
            test_ip=$(curl -q -4 --noproxy '*' --socks5-hostname 127.0.0.1:10808 --connect-timeout 5 --max-time 12 "$probe_url" 2>/dev/null | tr -d '[:space:]')
        fi
        if [ -n "$test_ip" ]; then break; fi
    done
    if [ -z "$test_ip" ]; then
        echo -e "${C_RED} SOCKS5-мост Xray REALITY не вернул внешний IPv4.${C_RESET}"
        echo -e "${C_YELLOW} Проверьте доступность TCP-порта ${s2_port} на Сервере 2, его firewall и журнал:${C_RESET}"
        echo "journalctl -u bobarev-xray.service -n 100 --no-pager"
        return 1
    fi
    direct_ip=$(curl -q -4 --noproxy '*' --connect-timeout 5 --max-time 12 https://api.ipify.org 2>/dev/null || echo "")
    echo -e "\\n${C_GREEN} Каскад 3 (NaiveProxy -> Xray REALITY SOCKS5 -> Выход Зарубеж) успешно запущен!${C_RESET}"
    echo -e "   Выходной IP каскада: ${C_BOLD}${C_GREEN}${test_ip}${C_RESET}"
    if [ -n "$direct_ip" ] && [ "$test_ip" = "$direct_ip" ]; then
        echo -e "${C_YELLOW} Внимание: IP через SOCKS5 совпадает с прямым WAN. Проверьте маршрут Xray на Сервере 2.${C_RESET}"
    fi
    print_naive_shadowrocket_links
}

manage_cascade_xray_menu() {
    while true; do
        MODULE_CANCELED=false
        local c_state="Не активен"
        if systemctl is-active --quiet bobarev-xray.service 2>/dev/null; then
            if [ -f /etc/default/bobarev-cascade ]; then
                # shellcheck disable=SC1091
                source /etc/default/bobarev-cascade
                if [ "${CASCADE_ROLE:-}" = "foreign_xray_exit" ]; then
                    if is_warp_active; then
                        c_state="Активен Сервер 2 (Зарубеж: Xray REALITY -> Cloudflare WARP)"
                    else
                        c_state="Активен Сервер 2 (Зарубеж: Xray REALITY -> Чистый IP сервера)"
                    fi
                elif [ "${CASCADE_ROLE:-}" = "ru_xray_entry" ]; then
                    c_state="Активен Сервер 1 (РФ: NaiveProxy -> Xray REALITY Client)"
                fi
            fi
        fi

        local c_choice
        if ! smart_menu " Каскад 3: NaiveProxy + Xray REALITY + WARP" "\nСтатус моста: $c_state\nВыберите действие:" 19 $WT_WIDTH 7 "c_choice" \
        "1" " Сервер 2 (Зарубеж): Xray REALITY -> Выход" \
        "2" " Сервер 1 (РФ): NaiveProxy -> Xray REALITY" \
        "3" " Управление пользователями NaiveProxy" \
        "4" " Показать ссылки Shadowrocket" \
        "5" " Переключить выход: Чистый IP <-> WARP" \
        "6" " Показать токен подключения" \
        "7" " Остановить службы Xray" \
        "0" " Вернуться в главное меню" || [ "$c_choice" = "0" ]; then
            break
        fi

        clear
        case "$c_choice" in
            1) setup_cascade_xray_server2_foreign || true; pause_enter ;;
            2) setup_cascade_xray_server1_ru || true; pause_enter ;;
            3) manage_naive_users_menu ;;
            4) print_naive_shadowrocket_links; pause_enter ;;
            5) toggle_foreign_warp_menu; pause_enter ;;
            6)
                if [ -f /etc/default/bobarev-cascade ]; then
                    # shellcheck disable=SC1091
                    source /etc/default/bobarev-cascade
                    if [ -n "${XRAY_TOKEN:-}" ]; then
                        echo -e "${C_CYAN} Токены Xray REALITY для подключения Сервера 1 (РФ):${C_RESET}\n"
                        echo -e "   ${C_BOLD}Основной токен (IPv4):${C_RESET}"
                        echo -e "    ${C_BOLD}${C_GREEN}${XRAY_TOKEN}${C_RESET}\n"
                        if [ -n "${XRAY_TOKEN_V6:-}" ]; then
                            echo -e "   ${C_BOLD}Резервный токен (IPv6):${C_RESET}"
                            echo -e "    ${C_BOLD}${C_CYAN}${XRAY_TOKEN_V6}${C_RESET}\n"
                        fi
                    else
                        echo -e "${C_YELLOW} Токен Xray REALITY еще не создан на этом сервере.${C_RESET}"
                    fi
                fi
                pause_enter
                ;;
            7)
                if prompt_yn "Остановить и отключить службы Xray на этом сервере?" "false"; then
                    silent_run systemctl stop bobarev-xray.service
                    silent_run systemctl disable bobarev-xray.service
                    rm -f /etc/xray/config.json
                    if [ -f /etc/default/bobarev-cascade ]; then
                        sed -i 's/CASCADE_ROLE="ru_xray_entry"/CASCADE_ROLE="none"/' /etc/default/bobarev-cascade 2>/dev/null || true
                        render_naive_caddyfile 2>/dev/null || true
                    fi
                    echo -e "${C_GREEN} Службы Xray остановлены и отключены.${C_RESET}"
                fi
                pause_enter
                ;;
        esac
    done
}

mod_direct_wg_cascade() {
    while true; do
        MODULE_CANCELED=false
        local d_status="Не активен"
        if is_wg_cascade_active; then
            local ob_str="прямой"
            if is_udp2raw_active; then
                ob_str="Anti-DPI udp2raw активен"
            fi
            # shellcheck disable=SC1091
            [ -f /etc/default/bobarev-cascade ] && source /etc/default/bobarev-cascade
            if [ "${CASCADE_ROLE:-}" = "foreign_wg_warp_exit" ]; then
                if is_warp_active; then
                    d_status="Активен Сервер 2 (Зарубеж: WG-Мост [$ob_str] -> Cloudflare WARP)"
                else
                    d_status="Активен Сервер 2 (Зарубеж: WG-Мост [$ob_str] -> Чистый IP сервера)"
                fi
            else
                d_status="Активен Сервер 1 (РФ: NaiveProxy -> WG-Мост [$ob_str])"
            fi
        fi

        local dc_choice
        if ! smart_menu " Каскад 1: NaiveProxy + WireGuard + WARP" "\nСтатус моста: $d_status\nВыберите действие:" 18 $WT_WIDTH 7 "dc_choice" \
        "1" " Сервер 2 (Зарубеж): WG-мост + Anti-DPI" \
        "2" " Сервер 1 (РФ): NaiveProxy -> WG-мост" \
        "3" " Управление пользователями NaiveProxy" \
        "4" " Показать ссылки Shadowrocket" \
        "5" " Переключить выход: Чистый IP <-> WARP" \
        "6" " Показать токен подключения" \
        "7" " Остановить каскад и мост" \
        "0" " Вернуться в главное меню" || [ "$dc_choice" = "0" ]; then
            break
        fi

        clear
        case "$dc_choice" in
            1)
                setup_direct_wg_server2_foreign || true
                pause_enter
                ;;
            2)
                setup_direct_wg_server1_ru || true
                pause_enter
                ;;
            3)
                manage_naive_users_menu
                ;;
            4)
                print_naive_shadowrocket_links
                pause_enter
                ;;
            5)
                toggle_foreign_warp_menu
                pause_enter
                ;;
            6)
                if [ -f /etc/default/bobarev-cascade ]; then
                    # shellcheck disable=SC1091
                    source /etc/default/bobarev-cascade
                    if [ -n "${WG_BRIDGE_TOKEN:-}" ]; then
                        echo -e "${C_CYAN} Токены соединения Зарубежного Сервера 2 (Режим обфускации: ${WG_OBFS_MODE:-udp}):${C_RESET}"
                        echo -e "${C_YELLOW} Используйте отдельный токен для каждого РФ-сервера:${C_RESET}"
                        echo -e "\n   ${C_BOLD}Токен #1 (для 1-го РФ-сервера, IP 10.200.200.2):${C_RESET}"
                        echo -e "    ${C_BOLD}${C_GREEN}${WG_BRIDGE_TOKEN}${C_RESET}"
                        if [ -n "${WG_BRIDGE_TOKEN_2:-}" ]; then
                            echo -e "\n   ${C_BOLD}Токен #2 (для 2-го РФ-сервера, IP 10.200.200.3):${C_RESET}"
                            echo -e "    ${C_BOLD}${C_GREEN}${WG_BRIDGE_TOKEN_2}${C_RESET}"
                        fi
                        if [ -n "${WG_BRIDGE_TOKEN_3:-}" ]; then
                            echo -e "\n   ${C_BOLD}Токен #3 (резервный для 3-го РФ-сервера, IP 10.200.200.4):${C_RESET}"
                            echo -e "    ${C_BOLD}${C_GREEN}${WG_BRIDGE_TOKEN_3}${C_RESET}"
                        fi
                        echo ""
                    else
                        echo -e "${C_YELLOW} На этом сервере еще не генерировался токен Сервера 2 (выполните Шаг 1).${C_RESET}"
                    fi
                else
                    echo -e "${C_YELLOW} Каскад еще не настроен.${C_RESET}"
                fi
                pause_enter
                ;;
            7)
                if prompt_yn "Остановить и отключить прямой ядерный мост wg-cascade и службу маскировки udp2raw?" "false"; then
                    silent_run systemctl stop wg-quick@wg-cascade.service bobarev-udp2raw.service hysteria-server.service hysteria-client.service bobarev-xray.service
                    silent_run systemctl disable wg-quick@wg-cascade.service bobarev-udp2raw.service hysteria-server.service hysteria-client.service bobarev-xray.service
                    silent_run wg-quick down wg-cascade
                    ip link del dev wg-cascade 2>/dev/null || true
                    ip route flush table 51888 2>/dev/null || true
                    while ip rule del priority 100 2>/dev/null; do :; done
                    while ip rule del priority 101 2>/dev/null; do :; done
                    while ip rule del priority 102 2>/dev/null; do :; done
                    while ip rule del priority 103 2>/dev/null; do :; done
                    while ip rule del priority 104 2>/dev/null; do :; done
                    while ip rule del priority 30000 2>/dev/null; do :; done
                    while ip rule del from 10.200.200.0/24 lookup 51820 priority 6001 2>/dev/null; do :; done
                    clean_duplicate_cascade_iptables
                    rm -f /etc/wireguard/wg-cascade.conf "$UDP2RAW_SERVICE"
                    silent_run systemctl daemon-reload
                    echo -e "${C_GREEN} Прямой мост wg-cascade, хвосты интерфейса и служба udp2raw полностью зачищены.${C_RESET}"
                fi
                pause_enter
                ;;
        esac
    done
}

# ЛИЧНЫЙ РЕТРАНСЛЯТОР DERP
# ------------------------------------------------------------------------------
print_derp_json_snippet() {
    local d_domain="${1:-derp.yourdomain.com}"
    local d_ip="${2:-ВАШ_IP_СЕРВЕРА}"
    local is_real="${3:-false}"

    echo -e "\n${C_CYAN} === БЛОК derpMap ДЛЯ КОНСОЛИ TAILSCALE ===${C_RESET}"
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
        echo -e "\n${C_GREEN} В код подставлены ваш реальный домен ($d_domain) и IP-адрес ($d_ip) — можно сразу копировать!${C_RESET}"
    else
        echo -e "\n${C_YELLOW} Показан обезличенный шаблон. Не забудьте заменить 'derp.yourdomain.com' и 'ВАШ_IP_СЕРВЕРА' на ваши реальные данные!${C_RESET}"
    fi
    echo -e "\n${C_BLUE} Команды проверки на клиентах после сохранения ACL:${C_RESET}"
    echo -e "   ${C_GREEN}tailscale netcheck${C_RESET}"
    echo -e "   ${C_GREEN}tailscale debug derp 900${C_RESET}"
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
        if prompt_yn "Узел DERP уже настроен на этом сервере.\nПодставить ваш реальный домен и IP-адрес сервера в JSON-код?\n\n Да: готовый код с вашими данными для копирования.\n Нет: обезличенный шаблон (безопасно для скриншотов и видео)." "false"; then
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
        if ! smart_menu "Личный ретранслятор (DERP)" "\nСтатус: $derp_state\nВыберите действие:" 16 $WT_WIDTH 5 "d_choice" \
        "1" " Установить / Обновить DERP (Cloudflare + STUN)" \
        "2" " Показать JSON-код (derpMap) для консоли" \
        "3" " Редактировать сертификаты Cloudflare" \
        "4" " Остановить и удалить службу DERP" \
        "0" " Вернуться назад" || [ "$d_choice" = "0" ]; then
            break
        fi

        clear
        case "$d_choice" in
            1)
                echo -e "${C_CYAN} === УСТАНОВКА ЛИЧНОГО РЕТРАНСЛЯТОРА DERP (CLOUDFLARE + STUN) ===${C_RESET}"
                ensure_tailscale_installed || true

                local d_dom=""
                prompt_default "Введите ваш поддомен для DERP (например, derp.yourdomain.com):" "$saved_domain" d_dom
                if [ "$MODULE_CANCELED" = true ] || [ -z "$d_dom" ]; then continue; fi

                echo -e "${C_BLUE} Установка компилятора Go и сборка актуального бинарника derper...${C_RESET}"
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
                    echo -e "${C_RED} Ошибка: не удалось собрать бинарник /usr/local/bin/derper.${C_RESET}"
                    pause_enter
                    continue
                fi
                echo -e "${C_GREEN} Бинарник /usr/local/bin/derper успешно скомпилирован.${C_RESET}"

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

                echo -e "${C_BLUE} Создание и запуск защищенной системной службы derper.service...${C_RESET}"
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

                silent_run systemctl daemon-reload
                silent_run systemctl enable --now derper.service
                systemctl restart derper.service || true

                if command -v ufw &>/dev/null; then
                    silent_run ufw allow 443/tcp comment 'DERP HTTPS Relay'
                    silent_run ufw allow 3478/udp comment 'DERP Local STUN'
                    echo -e "${C_GREEN} Порты 443/tcp (DERP HTTPS) и 3478/udp (STUN) открыты в UFW.${C_RESET}"
                fi

                if is_derp_active; then
                    echo -e "${C_GREEN} Служба личного ретранслятора DERP успешно запущена и защищена флагом --verify-clients!${C_RESET}"
                else
                    echo -e "${C_YELLOW} Служба derper не запустилась. Проверьте правильность сертификатов и не занят ли порт 443:${C_RESET}"
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
                echo -e "${C_GREEN} Сертификаты обновлены, служба derper перезапущена.${C_RESET}"
                pause_enter
                ;;
            4)
                if prompt_yn "Остановить и полностью удалить службу личного ретранслятора DERP и закрыть порты 443/tcp и 3478/udp в UFW?" "false"; then
                    silent_run systemctl stop derper.service
                    silent_run systemctl disable derper.service
                    rm -f /etc/systemd/system/derper.service /etc/default/bobarev-derp
                    silent_run systemctl daemon-reload
                    if command -v ufw &>/dev/null; then
                        silent_run ufw delete allow 443/tcp
                        silent_run ufw delete allow 3478/udp
                    fi
                    echo -e "${C_GREEN} Служба DERP удалена, порты 443/tcp и 3478/udp закрыты в UFW.${C_RESET}"
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
        echo -e "   Форвардинг пакетов (IPv4): ${C_GREEN} Включен (net.ipv4.ip_forward = 1)${C_RESET}"
    else
        echo -e "   Форвардинг пакетов (IPv4): ${C_RED} Выключен (маршрутизация пакетов отключена)${C_RESET}"
    fi

    if [ "$nf_mode" = "off" ]; then
        echo -e "   Приоритет правил фаервола: ${C_GREEN} Брандмауэр UFW (системный режим)${C_RESET}"
    elif [ "$nf_mode" = "on" ]; then
        echo -e "   Приоритет правил фаервола: ${C_BLUE}  Tailscale (встроенный авто-режим)${C_RESET}"
    fi

    if [ "$nat_count" -eq 1 ]; then
        echo -e "   Трансляция NAT на выходе:  ${C_GREEN} Активна на $wan_dev (1 чистое правило без дубликатов)${C_RESET}"
    elif [ "$nat_count" -gt 1 ]; then
        echo -e "   Трансляция NAT на выходе:  ${C_YELLOW}  Активна на $wan_dev, но дубликатов: $nat_count (рекомендуется очистка)${C_RESET}"
    else
        echo -e "   Трансляция NAT на выходе:  ${C_BLUE}  Не используется на $wan_dev (режим обычного узла без шлюза)${C_RESET}"
    fi

    local extra_ifs=$(ip -br link show 2>/dev/null | grep -v "DOWN" | awk '{print $1}' | sed 's/@.*//' | grep -vE "^(lo|${wan_dev}|docker.*|veth.*|br-.*)$" || echo "")
    for eif in $extra_ifs; do
        local e_ip=$(ip -4 -o addr show dev "$eif" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || echo "без IP")
        echo -e "   Активный интерфейс ($eif): ${C_GREEN} IP: $e_ip (транзит разрешен)${C_RESET}"
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


configure_rps_for_interfaces() {
    local wan_if=$(get_wan_if)
    local cpu_mask=$(get_cpu_rps_mask)
    [ -n "$wan_if" ] && ip link set dev "$wan_if" txqueuelen 10000 2>/dev/null || true
    for iface in wg-cascade warp tailscale0 $wan_if; do
        [ -z "$iface" ] && continue
        for qdir in /sys/class/net/"$iface"/queues/rx-*; do
            [ -d "$qdir" ] && echo "$cpu_mask" > "$qdir/rps_cpus" 2>/dev/null || true
        done
        for tdir in /sys/class/net/"$iface"/queues/tx-*; do
            [ -d "$tdir" ] && echo "$cpu_mask" > "$tdir/xps_cpus" 2>/dev/null || true
        done
    done
}

enable_routing_optimizations() {
    configure_rps_for_interfaces || true
    ensure_wg_kernel_modules
    cat << 'ETHTOOL_SCRIPT_EOF' > /usr/local/bin/tailscale-gro.sh
#!/bin/bash
tries=0
while ! ip -4 route show table main default 2>/dev/null | grep -vE "tailscale0|wg[0-9]*|wgcf|wg-cascade|warp|tun[0-9]*|tap[0-9]*|utun[0-9]*|awg[0-9]*|zt[a-z0-9]*|nebula[0-9]*|easytier[0-9]*" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -ge 15 ] && exit 0
    sleep 2
done
NETDEV=$(ip -4 route show table main default 2>/dev/null | grep -vE "tailscale0|wg[0-9]*|wgcf|wg-cascade|warp|tun[0-9]*|tap[0-9]*|utun[0-9]*|awg[0-9]*|zt[a-z0-9]*|nebula[0-9]*|easytier[0-9]*" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || true)
if [ -n "$NETDEV" ]; then
    if systemctl is-active --quiet bobarev-udp2raw.service 2>/dev/null || [ -f /etc/systemd/system/bobarev-udp2raw.service ]; then
        # Для сырых сокетов udp2raw (PF_PACKET) склейка UDP GRO и аппаратный оффлоад TCP вызывают сбои инкапсуляции и дропы пакетов > MTU на virtio_net
        ethtool -K "$NETDEV" tso off gso off gro off rx-udp-gro-forwarding off rx-gro-list off 2>/dev/null || true
    else
        ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off tso on gso on gro on 2>/dev/null || true
        ethtool -G "$NETDEV" rx 1024 tx 1024 2>/dev/null || true
    fi
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
    silent_run systemctl daemon-reload
    silent_run systemctl enable --now tailscale-gro.service

    if dpkg -l 2>/dev/null | grep -qw iptables-persistent; then
        silent_run systemctl stop netfilter-persistent 2>/dev/null
        silent_run systemctl disable netfilter-persistent 2>/dev/null
        silent_run apt-get purge -yq iptables-persistent netfilter-persistent
        echo -e "${C_BLUE} Удален конфликтующий пакет iptables-persistent (управление возвращено UFW).${C_RESET}"
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
        ip6tables -t mangle -F FORWARD 2>/dev/null || true
    fi
    tune_fq_qdisc_interfaces

    echo -e "${C_GREEN} Аппаратное ускорение (GRO с защитой от зависаний) и фиксация MTU (MSS Clamping) включены.${C_RESET}"
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
        echo -e "${C_BLUE} Установка пакета Tailscale в систему...${C_RESET}"
        curl -fsSL https://tailscale.com/install.sh | sh

        mkdir -p /etc/systemd/system/tailscaled.service.d
        cat << 'TS_OVERRIDE' > /etc/systemd/system/tailscaled.service.d/override.conf
[Unit]
After=network-online.target NetworkManager-wait-online.service systemd-networkd-wait-online.service
Wants=network-online.target
TS_OVERRIDE
        silent_run systemctl daemon-reload

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
        echo -e "${C_GREEN} Узел уже подключен к сети (IP: $current_ip).${C_RESET}"
        return 0
    fi

    echo -e "${C_CYAN} Первичное подключение узла...${C_RESET}"
    local authkey=""
    prompt_clean "Ключ авторизации (Оставьте пустым для входа по ссылке)" authkey
    if [ "$MODULE_CANCELED" = true ]; then
        MODULE_CANCELED=false
        return 1
    fi

    if [ -n "$authkey" ]; then
        silent_run tailscale up --authkey="$authkey" --force-reauth
    else
        echo -e "${C_BLUE} Запрос ссылки авторизации... Скопируйте ссылку, которая появится ниже:${C_RESET}"
        tailscale up --force-reauth || true
        echo ""
        whiptail --title "Авторизация" --msgbox "Если вы перешли по ссылке выше и подтвердили авторизацию в браузере, нажмите ОК для продолжения настройки." 10 $WT_WIDTH
    fi

    if is_tailscale_authenticated; then
        silent_run tailscale set --auto-update
        echo -e "${C_GREEN} Узел успешно подключен.${C_RESET}"
        return 0
    else
        echo -e "${C_YELLOW} Узел еще не авторизован в сети Tailscale.${C_RESET}"
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
        echo -e "${C_YELLOW} Отмена. Возврат в меню...${C_RESET}"
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
        echo -e "${C_YELLOW} Отмена. Возврат в меню...${C_RESET}"
        MODULE_CANCELED=true
        return 0
    fi
}

smart_menu() {
    local title="$1"
    local msg="$2"
    local height="$3"
    local width="$4"
    local menu_h="$5"
    local var_name="$6"
    shift 6
    local options=("$@")
    if [[ "$title" == *'ГЛАВНОЕ МЕНЮ'* ]]; then
        local n key label
        for ((n=0;n<${#options[@]};n+=2)); do
            key=${options[n]}; label=${options[n+1]}
            label="${label#"${label%%[![:space:]]*}"}"
            BOBAREV_MENU_TITLES["$key"]="$label"
        done
    fi

    local wt_choice
    if wt_choice=$(whiptail --title "$title" --menu "$msg" "$height" "$width" "$menu_h" "${options[@]}" 3>&1 1>&2 2>&3); then
        printf -v "$var_name" "%s" "$wt_choice"
        return 0
    else
        return 1
    fi
}

backup_file() {
    local file="$1"
    if [ -f "$file" ] && [ ! -f "${file}.bak" ]; then
        cp "$file" "${file}.bak"
        echo -e "${C_BLUE} Создана резервная копия: ${file}.bak${C_RESET}"
    fi
}



check_system_resources() {
    echo -e "${C_CYAN} Проверка системных ресурсов...${C_RESET}"
    local free_disk=$(df / --output=avail | tail -1 | tr -d ' ')
    local free_mem=$(free -m 2>/dev/null | awk '/^Mem:/ {print $4}' || echo "0")
    local total_swap=$(free -m 2>/dev/null | awk '/^Swap:/ {print $2}' || echo "0")
    local all_ok=true

    if [ "$free_disk" -lt 1048576 ]; then
        echo -e "${C_RED} Ошибка: Недостаточно места на диске (минимум 1ГБ требуется для сборки Caddy).${C_RESET}"
        return 1
    fi

    # Если уже активен Swap (например, >= 512MB) или свободной ОЗУ >= 512МБ, то все в норме и не нужно спрашивать повторно
    if [ "$free_mem" -lt 512 ] && [ "${total_swap:-0}" -lt 512 ] && ! swapon --show 2>/dev/null | grep -qE "swapfile|swap"; then
        echo -e "${C_YELLOW} Внимание: Малый объем свободной ОЗУ ($free_mem МБ) и отсутствует Swap.${C_RESET}"
        echo -e "${C_BLUE} Для стабильной сборки Caddy рекомендуется создать Swap-файл (2 ГБ).${C_RESET}"

        if prompt_yn "Создать постоянный Swap-файл (2 ГБ) для обеспечения стабильной работы и сборки?" "true"; then
            echo -e "${C_BLUE} Создание Swap-файла...${C_RESET}"
            silent_run swapoff /swapfile 2>/dev/null || true
            rm -f /swapfile
            silent_run fallocate -l 2G /swapfile || silent_run dd if=/dev/zero of=/swapfile bs=1M count=2048
            silent_run chmod 600 /swapfile
            silent_run mkswap /swapfile
            silent_run swapon /swapfile
            if ! grep -q "/swapfile" /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab 2>/dev/null || true
            fi
            echo -e "${C_GREEN} Swap-файл (2 ГБ) успешно создан и активирован.${C_RESET}"
        else
            echo -e "${C_RED} Сборка может завершиться ошибкой Out of Memory!${C_RESET}"
            all_ok=false
        fi
    else
        echo -e "${C_GREEN} Ресурсы в норме (ОЗУ / Swap активен).${C_RESET}"
    fi
    return 0
}

pause_enter() {
    if [ "$MODULE_CANCELED" = true ]; then
        return 0
    fi
    echo ""
    read -r -p "Нажмите Enter для возврата в меню..." < /dev/tty || true
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${C_RED} Ошибка: этот скрипт должен запускаться от имени суперпользователя (root).${C_RESET}" >&2
    exit 1
fi

if ! check_system_resources; then
    echo -e "${C_RED} Критическая ошибка ресурсов. Запуск невозможен.${C_RESET}"
    exit 1
fi

if ! command -v whiptail &>/dev/null; then
    echo -e "${C_BLUE} Интерфейс whiptail не обнаружен. Автоматическая установка...${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -yq whiptail >/dev/null 2>&1 || {
        echo -e "${C_RED} Не удалось установить whiptail. Выполните вручную: apt update && apt install whiptail${C_RESET}" >&2
        exit 1
    }
fi

# ==============================================================================
# МОДУЛИ НАСТРОЙКИ (1 - 20)
# ==============================================================================

# 1. Часовой пояс и синхронизация времени
mod_timezone() {
    echo -e "${C_CYAN} === 1/27. НАСТРОЙКА ЧАСОВОГО ПОЯСА ===${C_RESET}"
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Europe/Moscow")
    echo "Текущий часовой пояс: $current_tz"
    local tz=""
    prompt_default "Введите новый часовой пояс:" "$current_tz" tz
    if [ "$MODULE_CANCELED" = true ]; then return 0; fi

    silent_run timedatectl set-timezone "$tz"
    silent_run timedatectl set-ntp true
    echo -e "${C_GREEN} Часовой пояс установлен в $tz, автоматическая синхронизация точного времени включена.${C_RESET}"
}

# 2. Имя хоста
mod_hostname() {
    echo -e "${C_CYAN} === 2/27. НАСТРОЙКА ИМЕНИ ХОСТА ===${C_RESET}"
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
    echo -e "${C_GREEN} Имя сервера чисто обновлено на $new_host.${C_RESET}"
}

# 3. Обновление пакетов
mod_apt_update() {
    echo -e "${C_CYAN} === 3/27. ОБНОВЛЕНИЕ ПАКЕТОВ И ОЧИСТКА ===${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive

    if [ -f /etc/gai.conf ]; then
        sed -i 's/^#\s*precedence ::ffff:0:0\/96\s\+100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf 2>/dev/null || true
        echo -e "${C_BLUE} Включен приоритет IPv4 над IPv6 (защита от зависаний apt и curl).${C_RESET}"
    fi

    apt-get update && apt-get upgrade -yq

    local zram_pkg="zram-tools"
    if [ -f /etc/default/armbian-zram ] || [ -f /etc/init.d/armbian-zram ]; then
        echo -e "${C_BLUE} Обнаружен встроенный менеджер памяти Armbian. Сторонняя утилита zram-tools пропущена.${C_RESET}"
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
        echo -e "${C_BLUE} Включена автоочистка старых ядер при фоновых обновлениях безопасности.${C_RESET}"
    fi

    apt-get autoremove -yq && apt-get clean
    silent_run systemctl enable unattended-upgrades

    if [ -n "$zram_pkg" ] && [ -f /etc/default/zramswap ]; then
        cat << 'ZRAM_EOF' > /etc/default/zramswap
ALGO=zstd
PERCENT=50
PRIORITY=100
ZRAM_EOF
        silent_run systemctl restart zramswap
        echo -e "${C_GREEN} Сжатие оперативной памяти zRAM (алгоритм zstd, 50% RAM) активировано.${C_RESET}"
    fi

    local current_target=$(systemctl get-default)
    echo "Текущий режим загрузки: $current_target"

    if [ "$current_target" = "graphical.target" ]; then
        if prompt_yn " Обнаружена графическая оболочка ($(get_system_type_short)). Переключить систему в консольный режим работы?" "false"; then
            systemctl set-default multi-user.target
            echo -e "${C_BLUE} Режим загрузки изменен на консольный.${C_RESET}"
        else
            if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        fi
    else
        systemctl set-default multi-user.target
    fi
    echo -e "${C_GREEN} Система успешно обновлена, базовые утилиты установлены.${C_RESET}"
}

# 4. Пользователь и Sudo (с гарантированным приоритетом 99-zzz- в /etc/sudoers.d)
mod_user_setup() {
    echo -e "${C_CYAN} === 4/27. СОЗДАНИЕ И НАСТРОЙКА ПОЛЬЗОВАТЕЛЯ ===${C_RESET}"
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
        echo -e "${C_GREEN} Учетная запись $username создана.${C_RESET}"
    fi
    
    groupadd -f sudo 2>/dev/null || true
    usermod -aG sudo "$username" || true
    echo -e "${C_BLUE} Пользователь $username добавлен в группу администраторов (sudo).${C_RESET}"

    local pass
    if ! pass=$(whiptail --title "Пароль" --passwordbox "Введите новый пароль для $username (пусто - отмена):" 10 $WT_WIDTH 3>&1 1>&2 2>&3); then
        echo -e "${C_YELLOW} Смена пароля отменена.${C_RESET}"
    elif [ -z "$pass" ]; then
        echo -e "${C_YELLOW} Смена пароля пропущена.${C_RESET}"
    else
        local pass_confirm
        if ! pass_confirm=$(whiptail --title "Подтверждение" --passwordbox "Повторите пароль:" 10 $WT_WIDTH 3>&1 1>&2 2>&3); then
            echo -e "${C_RED} Отмена. Пароль не изменен.${C_RESET}"
        elif [ "$pass" != "$pass_confirm" ]; then
            echo -e "${C_RED} Введенные пароли не совпадают. Попробуйте снова.${C_RESET}"
        else
            echo "$username:$pass" | chpasswd
            echo -e "${C_GREEN} Пароль успешно установлен.${C_RESET}"
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
        local sudo_tmp=$(mktemp)
        echo "$username ALL=(ALL:ALL) NOPASSWD: ALL" > "$sudo_tmp"
        if command -v visudo &>/dev/null && visudo -c -f "$sudo_tmp" >/dev/null 2>&1; then
            mv "$sudo_tmp" "/etc/sudoers.d/99-zzz-$username"
            chmod 0440 "/etc/sudoers.d/99-zzz-$username"
            echo -e "${C_GREEN} Беспарольный доступ (NOPASSWD) включен с максимальным приоритетом (99-zzz-$username).${C_RESET}"
        else
            rm -f "$sudo_tmp"
            echo -e "${C_RED} Ошибка синтаксиса sudoers! Файл не был создан.${C_RESET}"
            return 1
        fi
    else
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        echo " Система будет запрашивать пароль при каждом повышении прав (через группу %sudo)."
    fi
}

# 5. SSH-ключи
mod_ssh_key() {
    echo -e "${C_CYAN} === 5/27. НАСТРОЙКА КЛЮЧЕЙ ДОСТУПА ===${C_RESET}"
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
            echo -e "${C_YELLOW} Отмена. Возврат в главное меню...${C_RESET}"
            MODULE_CANCELED=true
            return 0
        fi
    fi

    if [ -n "$pubkey" ]; then
        local mode_choice
        if ! smart_menu "Параметры сохранения" "Выберите действие:" 12 $WT_WIDTH 2 "mode_choice" \
        "1" " Добавить ключ в существующий список" \
        "2" " Полностью перезаписать список ключей"; then
            echo -e "${C_YELLOW} Отмена сохранения.${C_RESET}"
            MODULE_CANCELED=true
            return 0
        fi

        if [ "$mode_choice" = "2" ]; then
            echo "$pubkey" > "$target_home/.ssh/authorized_keys"
            echo -e "${C_GREEN} Файл с ключами перезаписан.${C_RESET}"
        else
            if ! grep -qF "$pubkey" "$target_home/.ssh/authorized_keys" 2>/dev/null; then
                echo "$pubkey" >> "$target_home/.ssh/authorized_keys"
                echo -e "${C_GREEN} Ключ успешно добавлен.${C_RESET}"
            else
                echo -e "${C_BLUE} Этот ключ уже привязан к профилю.${C_RESET}"
            fi
        fi
    fi

    silent_run chmod 755 "$target_home"
    chmod 700 "$target_home/.ssh"
    silent_run chmod 600 "$target_home/.ssh/authorized_keys"
    chown -R "$target_user:$target_user" "$target_home/.ssh"
    echo -e "${C_GREEN} Права доступа к директории ключей проверены и настроены.${C_RESET}"
}

# 6. Конфигурация SSH (с поддержкой полной Zero-Trust изоляции на tailscale0)
mod_ssh_config() {
    echo -e "${C_CYAN} === 6/27. БЕЗОПАСНОСТЬ УДАЛЕННОГО ДОСТУПА ===${C_RESET}"
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
            echo -e "${C_GREEN} Выбрано: Вход по паролю будет отключен.${C_RESET}"
        else
            echo -e "${C_YELLOW} Выбрано: Вход по паролю оставлен включенным.${C_RESET}"
        fi
    else
        whiptail --msgbox "Внимание: На сервере не найдено ни одного привязанного ключа безопасности!\nВход по паролю ОСТАЕТСЯ ВКЛЮЧЕННЫМ для предотвращения полной потери доступа." 11 $WT_WIDTH
        echo -e "${C_YELLOW} Вход по паролю сохранен.${C_RESET}"
    fi

    local disable_root="no"
    if whiptail --title "Подтверждение" --yesno "Запретить прямой вход для пользователя root по SSH?" 11 $WT_WIDTH; then
        disable_root="no"
        echo -e "${C_GREEN} Выбрано: Вход для root запрещен.${C_RESET}"
    else
        disable_root="yes"
        echo -e "${C_YELLOW} Выбрано: Вход для root разрешен.${C_RESET}"
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

    echo -e "${C_BLUE} Резервное копирование и очистка сторонних конфигураций SSH...${C_RESET}"
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
                    echo -e "${C_GREEN} Полная изоляция (Zero-Trust): на tailscale0 открыт только порт SSH ($port/tcp).${C_RESET}"
                else
                    echo -e "${C_BLUE} Правило изоляции сохранено. Оно вступит в силу при включении брандмауэра (Модуль 8).${C_RESET}"
                fi
            else
                sed -i 's/# SSH via Tailscale only/# SSH Public Access/' "$conf_file"
                echo -e "${C_YELLOW} Узел Tailscale не авторизован! Для предотвращения блокировки сервера оставлен публичный доступ к SSH ($port).${C_RESET}"
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
                echo -e "${C_GREEN} Защита от перебора паролей (sshguard) активирована.${C_RESET}"
            fi
        fi
        echo -e "${C_GREEN} Служба удаленного доступа успешно перезапущена с абсолютным приоритетом параметров.${C_RESET}"
    else
        echo -e "${C_RED} Ошибка применения параметров безопасности! Выполнен откат изменений...${C_RESET}"
        rm -f "$conf_file"
        cp -a "$conf_bak_dir"/*.conf "$conf_dir"/ 2>/dev/null || true
        rm -rf "$conf_bak_dir" 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi
}

# 7. Защита ядра и сети (с префиксом 99-zzz- и включенным IPv4/IPv6 форвардингом)
mod_hardening() {
    echo -e "${C_CYAN} === 7/27. ЗАЩИТА ЯДРА И УСКОРЕНИЕ МАРШРУТИЗАЦИИ ===${C_RESET}"
    
    sed -i -E '/^\s*(net\.core\.(rmem|wmem)_(max|default)|net\.core\.netdev_max_backlog|net\.ipv4\.tcp_congestion_control|net\.core\.default_qdisc)\s*=/d' /etc/sysctl.conf 2>/dev/null || true
    backup_file "/etc/sysctl.d/99-zzz-server-hardening.conf"
    rm -f /etc/sysctl.d/99-server-hardening.conf 2>/dev/null || true
    
    local icmp_ignore=0
    if prompt_yn "Скрыть сервер от пингов (отключить ответы на ICMP Echo / ping)?" "false"; then
        icmp_ignore=1
        echo -e "${C_BLUE} Ответы на ICMP-пинги будут отключены.${C_RESET}"
    else
        if [ "$MODULE_CANCELED" = true ]; then return 0; fi
        icmp_ignore=0
        echo -e "${C_BLUE} Стандартные ответы на ICMP-пинги сохранены (рекомендуется для мониторинга).${C_RESET}"
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
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 10000
net.netfilter.nf_conntrack_max = 262144
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
        echo -e "${C_GREEN} Аппаратный таймер защиты от зависаний (Watchdog 15s) для мини-ПК активирован.${C_RESET}"
    fi

    echo -e "${C_GREEN} Защита ядра, форвардинг пакетов, расширенные UDP-буферы и TCP BBR применены.${C_RESET}"
}

# 8. Firewall UFW (сохраняет правила личного DERP, Каскада NaiveProxy/WARP/WG-Cascade и открывает 41641/udp при наличии Tailscale)
mod_ufw() {
    echo -e "${C_CYAN} === 8/27. НАСТРОЙКА БРАНДМАУЭРА ===${C_RESET}"
    DEFAULT_WAN_IF=$(get_wan_if)
    
    local active_ssh_port="22"
    local sshd_cmd=$(get_sshd_cmd)
    if [ -n "$sshd_cmd" ]; then
        active_ssh_port=$($sshd_cmd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")
    fi
    active_ssh_port="${active_ssh_port//[^0-9]/}"
    local port="${active_ssh_port:-22}"

    echo -e "${C_BLUE} Автоматически определен порт SSH: $port${C_RESET}"

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
        echo -e "${C_BLUE} Ограничение удаленного доступа применено автоматически.${C_RESET}"
        do_restrict=true
    elif [ "$is_public_in_mod6" = true ]; then
        echo -e "${C_BLUE} Публичный доступ к SSH сохранен автоматически.${C_RESET}"
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
            echo -e "${C_BLUE} Обнаружен активный веб-интерфейс: открыт порт 5252/tcp на tailscale0.${C_RESET}"
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
        echo -e "${C_BLUE} Восстановлены правила UFW для личного ретранслятора DERP (443/tcp и 3478/udp).${C_RESET}"
    fi

    if [ -f /etc/wireguard/warp.conf ] || is_warp_active; then
        silent_run ufw route allow in on tailscale0 out on warp comment 'Tailscale to WARP'
        silent_run ufw route allow in on warp out on tailscale0 comment 'WARP to Tailscale'
        silent_run ufw route allow in on wg-cascade out on warp comment 'WG Cascade to WARP'
        silent_run ufw route allow in on warp out on wg-cascade comment 'WARP to WG Cascade'
        ensure_ufw_nat_rule "-A POSTROUTING -o warp -j MASQUERADE"
        echo -e "${C_BLUE} Восстановлены правила транзита UFW для туннеля Cloudflare WARP.${C_RESET}"
    fi

    if [ -f /etc/wireguard/wg0.conf ] || is_wg0_active; then
        silent_run ufw route allow in on tailscale0 out on wg0 comment 'Tailscale to wg0 exit'
        silent_run ufw route allow in on wg0 out on tailscale0 comment 'wg0 to Tailscale return'
        ensure_ufw_nat_rule "-A POSTROUTING -o wg0 -j MASQUERADE"
        echo -e "${C_BLUE} Восстановлены правила транзита UFW и NAT для шлюза WireGuard (wg0).${C_RESET}"
    fi

    if [ -f /etc/default/bobarev-cascade ]; then
        # shellcheck disable=SC1091
        source /etc/default/bobarev-cascade
        if [ -n "${WG_CASCADE_PORT:-}" ]; then
            silent_run ufw allow "${WG_CASCADE_PORT}/udp" comment 'WG Direct Cascade UDP'
            silent_run ufw allow "${WG_CASCADE_PORT}/tcp" comment 'WG Direct Cascade FakeTCP'
        fi
        if [ -n "${HYSTERIA_PORT:-}" ] && { [ "${CASCADE_ROLE:-}" = "foreign_hysteria_exit" ] || systemctl is-active --quiet hysteria-server.service 2>/dev/null; }; then
            silent_run ufw allow "${HYSTERIA_PORT}/udp" comment 'Hysteria 2 QUIC UDP'
            silent_run ufw allow "${HYSTERIA_PORT}/tcp" comment 'Hysteria 2 TCP'
        fi
        if [ -n "${XRAY_PORT:-}" ] && [ "${CASCADE_ROLE:-}" = "foreign_xray_exit" ]; then
            silent_run ufw allow "${XRAY_PORT}/tcp" comment 'Xray REALITY TCP'
        fi
    fi

    if [ -r /etc/bobarev-router-v2/config ]; then
        (
            # shellcheck disable=SC1091
            source /etc/bobarev-router-v2/config
            for r_lan in "${LANS[@]}"; do
                [ -z "$r_lan" ] && continue
                [ "${DHCP:-true}" = "true" ] && silent_run ufw allow in on "$r_lan" to any port 67 proto udp comment 'LAN DHCP'
                silent_run ufw allow in on "$r_lan" to any port 53 proto udp comment 'LAN DNS UDP'
                silent_run ufw allow in on "$r_lan" to any port 53 proto tcp comment 'LAN DNS TCP'
                if [ -n "${OUT:-}" ]; then
                    silent_run ufw route allow in on "$r_lan" out on "$OUT" comment "LAN $r_lan to $OUT"
                    silent_run ufw route allow in on "$OUT" out on "$r_lan" comment "$OUT to LAN $r_lan"
                fi
            done
            echo -e "${C_BLUE} Восстановлены правила UFW для локального маршрутизатора v2 (LAN: ${LANS[*]} -> ${OUT:-N/A}).${C_RESET}"
        )
    elif [ -f /etc/default/bobarev-router ]; then
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
            echo -e "${C_BLUE} Восстановлен профиль роутера: сеть $ROUTER_LAN_IF направлена в $ROUTER_OUT_IF (защита от утечки IP: $ks_human).${C_RESET}"
        fi
    fi

    if [ -n "$netdev" ]; then
        if prompt_yn "Запретить контейнерам Docker обходить брандмауэр из внешней сети?" "true"; then
            apply_ufw_docker_protection "$netdev"
            echo -e "${C_GREEN} Защита контейнеров Docker снаружи включена.${C_RESET}"
        fi
    fi

    if [ "$do_restrict" = true ]; then
        if ensure_tailscale_installed && is_tailscale_authenticated; then
            silent_run ufw allow 41641/udp comment 'Tailscale Direct P2P'
            silent_run ufw allow in on tailscale0 to any port "$port" proto tcp comment 'SSH via Tailscale only'
            silent_run ufw delete allow in on tailscale0
            silent_run ufw delete allow "$port"/tcp
            echo -e "${C_GREEN} Полная изоляция (Zero-Trust): открыт только порт SSH ($port/tcp) внутри закрытой сети.${C_RESET}"
        else
            silent_run ufw allow "$port"/tcp comment 'SSH Public Port'
            echo -e "${C_YELLOW} Узел Tailscale не авторизован! Во избежание потери доступа порт SSH ($port) оставлен открытым публично.${C_RESET}"
        fi
    else
        silent_run ufw allow "$port"/tcp comment 'SSH Public Port'
        echo -e "${C_GREEN} Брандмауэр настроен: порт SSH ($port) открыт публично.${C_RESET}"
    fi

    if is_naive_active; then
        silent_run ufw allow 80/tcp comment 'NaiveProxy ACME HTTP'
        silent_run ufw allow 443/tcp comment 'NaiveProxy HTTPS'
        silent_run ufw allow 443/udp comment 'NaiveProxy HTTP3 QUIC'
    fi

    # Preserve foreign NAT chains.
    :
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
    if [ -x /usr/local/sbin/bobarev-router-v2 ] && [ -f /etc/bobarev-router-v2/config ]; then
        /usr/local/sbin/bobarev-router-v2 start || true
    elif [ -x /usr/local/bin/bobarev-router-up.sh ]; then
        /usr/local/bin/bobarev-router-up.sh || true
    fi
    echo -e "${C_GREEN} Межсетевой экран (UFW) включен и активно защищает систему.${C_RESET}"
    print_network_health_summary
}

# 9. Блокировка Root
mod_lock_root() {
    local mode="${1:-}"
    if [ "$mode" = "auto" ]; then
        if prompt_yn "Заблокировать прямой доступ для суперпользователя (root)?" "true"; then
            if [ $(getent group sudo | cut -d: -f4 | tr ',' ' ' | wc -w) -gt 0 ]; then
                silent_run passwd -l root
                echo -e "${C_GREEN} Доступ для суперпользователя заблокирован.${C_RESET}"
            fi
        fi
        return 0
    fi

    echo -e "${C_CYAN} === 9/27. УПРАВЛЕНИЕ СИСТЕМНЫМ ДОСТУПОМ ===${C_RESET}"
    
    local root_choice
    if ! smart_menu "Системный доступ" "Выберите желаемое действие:" 12 $WT_WIDTH 2 "root_choice" \
    "1" " Заблокировать" \
    "2" " Разблокировать"; then
        MODULE_CANCELED=true
        return 0
    fi

    case "$root_choice" in
        1)
            if [ $(getent group sudo | cut -d: -f4 | tr ',' ' ' | wc -w) -gt 0 ]; then
                silent_run passwd -l root
                echo -e "${C_GREEN} Доступ для суперпользователя заблокирован.${C_RESET}"
            else
                echo -e "${C_YELLOW} В системе нет других администраторов! Блокировка отменена для сохранения контроля.${C_RESET}"
            fi
            ;;
        2) silent_run passwd -u root; echo -e "${C_GREEN} Доступ для суперпользователя разблокирован.${C_RESET}" ;;
    esac
}
mod_lock_root_auto() { mod_lock_root "auto"; }

# 10. Tailscale (включая пункт 9 DERP и пункт 10 Каскад NaiveProxy + Tailscale + WARP)
ts42_wait_running() {
 local i state
 for i in {1..60}; do
  state=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null) || state=''
  [[ "$state" == Running ]] && return 0
  sleep 2
 done
 echo 'Нет Running за 120 секунд.' >&2
 return 1
}
ts42_current_exit() {
 tailscale status --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((ip for p in (d.get("Peer") or {}).values() if p.get("ExitNode") for ip in p.get("TailscaleIPs",[]) if ":" not in ip),""))'
}
ts42_ipv4() {
 local v url
 for url in https://1.1.1.1/cdn-cgi/trace https://api.ipify.org; do
  v=$(curl -q --noproxy '*' -4 -fsS --connect-timeout 5 --max-time 12 "$url" 2>/dev/null) || continue
  if python3 - "$v" <<'TS42_IP'
import sys,ipaddress
s=sys.argv[1].strip();s=next((x[3:] for x in s.splitlines() if x.startswith('ip=')),s)
try:
 a=ipaddress.ip_address(s);assert a.version==4 and a.is_global
except (ValueError,AssertionError):sys.exit(1)
print('IPv4: '+str(a))
TS42_IP
  then return 0; fi
 done
 echo 'IPv4 не работает; автоматического переключения на WAN нет.' >&2
 return 1
}
ts42_wait_default() {
 local i
 for i in {1..30}; do
  ip -4 route show table 52 default 2>/dev/null | grep -Eq '^default dev tailscale0([[:space:]]|$)' && return 0
  sleep 2
 done
 echo 'Нет default через tailscale0 за 60 секунд.' >&2
 return 1
}
ts42_control() {
 local answer env file=/etc/systemd/system/tailscaled.service.d/90-control-443.conf backup=''
 env=$(systemctl show tailscaled --property=Environment --value)
 smart_menu 'Tailscale: управление TCP 443' "Окружение: $env
Внутренний TS_FORCE_NOISE_443=true. Требует проверки после обновлений." 17 "${WT_WIDTH:-85}" 2 answer KEEP 'Сохранить настройки' ENABLE 'Включить TCP 443' || return 1
 [[ "$answer" == ENABLE ]] || return 0
 [[ " $env " != *' TS_FORCE_NOISE_443=true '* ]] || { echo 'Уже включено; restart не нужен.'; return 0; }
 nm_yes 'Применить и перезапустить tailscaled? Используйте локальную консоль/SSH, не Tailscale.' || return 1
 mkdir -p /etc/systemd/system/tailscaled.service.d || return 1
 if [[ -e "$file" ]]; then
  [[ -f "$file" && ! -L "$file" ]] || return 1
  backup=$(mktemp /root/bobarev-443.XXXXXX) || return 1
  cp -a "$file" "$backup" || return 1
 fi
 printf '[Service]\nEnvironment="TS_FORCE_NOISE_443=true"\n' > "$file" || return 1
 if systemctl daemon-reload && systemctl restart tailscaled && ts42_wait_running; then return 0; fi
 if [[ -n "$backup" ]]; then cp -a "$backup" "$file" || return 1; else rm -f "$file"; fi
 systemctl daemon-reload || true;systemctl restart tailscaled || true
 return 1
}
ts43_router_set_exit() {
 local mode=$1 node=${2:-} wan='' gw='' tmp
 [[ -r /etc/bobarev-router-v2/config ]] || { echo 'Локальный маршрутизатор не настроен.'; return 1; }
 if [[ "$mode" == wan ]]; then
  wan=$(ip -4 route show default 2>/dev/null | awk '$1=="default"{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1);exit}}')
  [[ -n "$wan" && "$wan" != tailscale0 ]] || { echo 'Не найден WAN помимо tailscale0.'; return 1; }
  gw=$(ip -4 route show default dev "$wan" 2>/dev/null | awk '/via/{print $3;exit}')
 fi
 tmp=$(mktemp /root/bobarev-router-exit.XXXXXX) || return 1
 (
 source /etc/bobarev-router-v2/config
 if [[ "$mode" == wan ]]; then
  OUT=$wan; GATEWAY=$gw; EXIT_NODE=''
 else
  [[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || exit 1
  OUT=tailscale0; GATEWAY=''; EXIT_NODE=$node
 fi
 printf 'LANS=('; printf ' %q' "${LANS[@]}"; printf ' )\n'
 printf 'ADDRS=('; printf ' %q' "${ADDRS[@]}"; printf ' )\n'
 printf 'STARTS=('; printf ' %q' "${STARTS[@]}"; printf ' )\n'
 printf 'ENDS=('; printf ' %q' "${ENDS[@]}"; printf ' )\n'
 printf 'OUT=%q\nGATEWAY=%q\nDHCP=%q\nEXIT_NODE=%q\nDHCP_OWNER=%q\n' "$OUT" "$GATEWAY" "${DHCP:-false}" "$EXIT_NODE" "${DHCP_OWNER:-managed}"
 ) > "$tmp" || { rm -f "$tmp"; return 1; }
 install -m 600 "$tmp" /etc/bobarev-router-v2/config || { rm -f "$tmp"; return 1; }
 rm -f "$tmp"
 systemctl restart bobarev-router-v2.service || return 1
}
ts43_install_exit_restore() {
 local node=$1
 [[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || { echo 'Нужен явный IP/hostname, не пустая строка.'; return 1; }
 install -d -m 700 /etc/bobarev-tailscale || return 1
 printf '%s\n' "$node" > /etc/bobarev-tailscale/exit-node || return 1
 chmod 600 /etc/bobarev-tailscale/exit-node
 cat > /usr/local/sbin/bobarev-tailscale-exit-restore <<'TS42_RESTORE'
#!/bin/bash
set -euo pipefail
[[ -r /etc/bobarev-tailscale/exit-node ]] || exit 0
read -r node < /etc/bobarev-tailscale/exit-node
[[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || exit 1
for i in {1..60}; do
 state=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null) || state=''
 [[ "$state" == Running ]] && break
 sleep 2
done
[[ "${state:-}" == Running ]] || { echo 'Control plane не готов; exit node не сбрасываем.'; exit 1; }
current=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((ip for p in (d.get("Peer") or {}).values() if p.get("ExitNode") for ip in p.get("TailscaleIPs",[]) if ":" not in ip),""))') || current=''
if [[ "$current" != "$node" ]]; then
 tailscale set --exit-node="$node" --exit-node-allow-lan-access=true
fi
for i in {1..30}; do
 if ip -4 route show table 52 default 2>/dev/null | grep -Eq '^default dev tailscale0([[:space:]]|$)'; then
  actual=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((p.get("HostName", "?") for p in (d.get("Peer") or {}).values() if p.get("ExitNode")),"не определён"))') || actual='не определён'
  echo "Настройка выхода применена: $node; peer=$actual. Доступность интернета проверяется отдельно."
  exit 0
 fi
 sleep 2
done
echo 'Нет default после выбора выхода. WAN fallback не выполнялся.' >&2
exit 1
TS42_RESTORE
 chmod 700 /usr/local/sbin/bobarev-tailscale-exit-restore || return 1
 cat > /etc/systemd/system/bobarev-tailscale-exit-restore.service <<'TS42_UNIT'
[Unit]
Description=Restore explicitly selected Tailscale exit node
Wants=network-online.target tailscaled.service
After=network-online.target tailscaled.service
Before=bobarev-router-v2.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bobarev-tailscale-exit-restore
TimeoutStartSec=195
[Install]
WantedBy=multi-user.target
TS42_UNIT
 systemctl daemon-reload || return 1
 systemctl enable bobarev-tailscale-exit-restore.service || return 1
}
ts43_direct_mode() {
 local node saved='' answer
 [[ -r /etc/bobarev-tailscale/exit-node ]] && saved=$(cat /etc/bobarev-tailscale/exit-node) || saved=''
 smart_menu 'Прямой интернет (WAN без exit node)' "Отключить exit node и переключить LAN маршрутизатора на WAN этого устройства.
Клиенты LAN получат внешний IP домашнего роутера/провайдера.
Сохранённый VPN-выход: ${saved:-нет}.
Порядок: сначала маршрутизатор на WAN, затем отключение exit node." 22 "${WT_WIDTH:-85}" 2 answer NO 'Отмена' YES 'Переключить на прямой интернет' || return 1
 [[ "$answer" == YES ]] || return 0
 ts43_router_set_exit wan || return 1
 systemctl disable --now bobarev-tailscale-exit-restore.service 2>/dev/null || true
 tailscale set --exit-node= || true
 echo 'Exit node отключён. LAN направлен через WAN.'
 ts42_ipv4
}
ts43_vpn_mode() {
 local node saved='' current
 [[ -r /etc/bobarev-tailscale/exit-node ]] && saved=$(cat /etc/bobarev-tailscale/exit-node) || saved=''
 tailscale exit-node list || true
 br26_input 'Явный IP или hostname VPN-выхода из списка выше. Пустое значение не используется.' "$saved" node || return 1
 [[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || return 1
 nm_yes "Вернуть VPN: выход $node для этого устройства и его LAN? Изменится внешний IP." || return 1
 ts42_wait_running || return 1
 current=$(ts42_current_exit) || current=''
 if [[ "$current" != "$node" ]]; then
  tailscale set --exit-node="$node" --exit-node-allow-lan-access=true || return 1
 fi
 ts42_wait_default || { echo 'VPN выход не готов; маршрутизатор оставлен в текущем режиме.'; return 1; }
 ts42_ipv4 || { echo 'IPv4 через VPN не работает; маршрутизатор оставлен в текущем режиме. Проверьте exit node.'; return 1; }
 ts43_install_exit_restore "$node" || return 1
 ts43_router_set_exit tailscale0 "$node" || return 1
 systemctl start bobarev-tailscale-exit-restore.service || return 1
 ts42_ipv4
}
ts42_exit_select() {
 local node current router_out=''
 tailscale exit-node list || return 1
 current=$(ts42_current_exit) || current=''
 br26_input 'Явный IP/hostname выхода. Пустое значение не используется для сброса.' "$current" node || return 1
 [[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || return 1
 nm_yes "Выбрать $node сейчас и восстанавливать его при загрузке? Изменится интернет этого устройства. При отказе WAN fallback не будет." || return 1
 if [[ -r /etc/bobarev-router-v2/config ]]; then
  router_out=$(grep -E '^OUT=' /etc/bobarev-router-v2/config 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  echo 'Если локальный маршрутизатор имеет собственный EXIT_NODE, выберите тот же узел в его мастере: иначе при старте его настройка имеет приоритет.'
 fi
 ts43_install_exit_restore "$node" || return 1
 systemctl start bobarev-tailscale-exit-restore.service || return 1
 if ts42_ipv4; then
  if [[ "$router_out" == tailscale0 ]]; then
   echo 'Маршрутизатор использует tailscale0: LAN-клиенты также направлены через этот выход.'
  else
   echo 'Маршрутизатор использует WAN: LAN-клиенты не идут через этот exit node. Для перевода LAN в VPN используйте «Вернуть VPN exit node».'
  fi
 else
  echo 'ВНИМАНИЕ: IPv4 через выбранный выход не работает. Если маршрутизатор в tailscale0, клиенты могут остаться без интернета; используйте «Прямой интернет: WAN без exit node» или восстановите exit node.' >&2
  return 1
 fi
}
ts42_exit_apply_now() {
 [[ -x /usr/local/sbin/bobarev-tailscale-exit-restore ]] || { echo 'Сначала выберите и сохраните явный выход.'; return 1; }
 nm_yes 'Применить сохранённый выход сейчас? Изменится интернет этого устройства.' || return 1
 systemctl start bobarev-tailscale-exit-restore.service || return 1
 ts42_ipv4
}
ts42_exit_disable_restore() {
 nm_yes 'Отключить ТОЛЬКО отдельную службу восстановления? Текущий exit node не отключается. Маршрутизатор со своим EXIT_NODE всё ещё применит его при старте.' || return 1
 systemctl disable --now bobarev-tailscale-exit-restore.service || return 1
 echo 'Автоприменение выключено. Для смены текущего выхода используйте настройки шлюза Tailscale.'
}
ts43_consistency() {
 local exit_now router_out='' router_exit='' route
 exit_now=$(ts42_current_exit) || exit_now=''
 if [[ -r /etc/bobarev-router-v2/config ]]; then
  router_out=$(grep -E '^OUT=' /etc/bobarev-router-v2/config 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  router_exit=$(grep -E '^EXIT_NODE=' /etc/bobarev-router-v2/config 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
 fi
 route=$(ip route get 1.1.1.1 2>/dev/null || true)
 echo "Текущий exit node Tailscale: ${exit_now:-нет}"
 echo "Маршрутизатор OUT: ${router_out:-не настроен}"
 echo "Маршрутизатор EXIT_NODE: ${router_exit:-пусто}"
 echo "Фактический маршрут до 1.1.1.1:"
 echo "$route"
 if [[ "$router_out" == tailscale0 && -z "$exit_now" ]]; then
  echo 'ВНИМАНИЕ: маршрутизатор в tailscale0, но exit node не выбран. LAN-клиенты могут остаться без интернета.'
 elif [[ "$router_out" == tailscale0 && "$exit_now" != "$router_exit" ]]; then
  echo 'ВНИМАНИЕ: выход Tailscale и EXIT_NODE маршрутизатора различаются. При старте маршрутизатора применится его EXIT_NODE.'
 elif [[ "$router_out" != tailscale0 && -n "$exit_now" ]]; then
  echo 'Режим: LAN через WAN, exit node выбран только для этого устройства. Клиенты используют чистый IP.'
 else
  echo 'Согласованность: ошибок не обнаружено.'
 fi
 echo 'Правило 5270 направляет собственный трафик устройства в таблицу 52 при активном exit node.'
}
ts42_audit() {
 hostname;sysctl net.ipv4.ip_forward
 iptables -S FORWARD;iptables -S ts-forward || true
 iptables -t nat -S POSTROUTING;iptables -t nat -S ts-postrouting || true
 echo 'Локальная проверка iptables не определяет роль устройства. nftables требует отдельного анализа.'
}
br48_dnsmasq_range() {
 local f
 for f in /etc/dnsmasq.d/*.conf /etc/dnsmasq.conf; do
  [[ -r "$f" ]] || continue
  awk '/^[[:space:]]*dhcp-range=/ {print; exit}' "$f" | head -n1 | awk -F'[=,]' '{print $2, $3}'
 done | head -n1
}
ts42_tools() {
 local c target='' port='' endpoints='' val=''
 while true; do
  smart_menu 'Tailscale: диагностика и дополнительные настройки' 'Изменения только с подтверждением. Ping/netcheck не меняют конфигурацию.' 28 "${WT_WIDTH:-85}" 14 c 1 'Путь до peer: direct / DERP / relay' 2 'Netcheck: NAT и UDP' 3 'IPv4 / IPv6 выхода' 4 'Рекомендованный exit node (без выбора)' 5 'Управление через TCP 443' 6 'Выбрать выход + восстановление при загрузке' 7 'Применить сохранённый выход сейчас' 8 'Прямой интернет: WAN без exit node' 9 'Вернуть VPN exit node' 10 'Отключить автоприменение выхода' 11 'Согласованность выхода и маршрутизатора' 12 'Peer Relay (расширенно)' 13 'Автообновления клиента' 14 'Локальные правила Tailscale/NAT' 0 'Назад' || return 0
  case "$c" in
   0) return 0 ;;
   1) br26_input 'IP/hostname peer' "$target" target || continue
      [[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] && tailscale ping --c=5 "$target" || true ;;
   2) tailscale netcheck || true ;;
   3) ts42_ipv4 || true; curl -q --noproxy '*' -6 -fsS --connect-timeout 5 --max-time 12 https://api6.ipify.org || true; echo ;;
   4) tailscale exit-node suggest || true;echo 'Рекомендация не применялась.' ;;
   5) ts42_control || true ;;
   6) ts42_exit_select || true ;;
   7) ts42_exit_apply_now || true ;;
   8) ts43_direct_mode || true ;;
   9) ts43_vpn_mode || true ;;
   10) ts42_exit_disable_restore || true ;;
   11) ts43_consistency || true ;;
   12) echo 'Нужны разрешения relay в tailnet grants и доступный UDP-порт. Политики/проброс NAT автоматически не меняются.'
      if ! tailscale set --help 2>&1 | grep -q -- --relay-server-port; then echo 'Клиент не поддерживает Peer Relay.';pause_enter;continue;fi
      br26_input 'UDP-порт Peer Relay (1024..65535)' '40000' port || continue
      [[ "$port" =~ ^[0-9]{4,5}$ ]] && ((10#$port>=1024 && 10#$port<=65535)) || continue
      nm_yes "Включить Peer Relay UDP $port? ACL/доступность нужно настроить отдельно." || continue
      tailscale set --relay-server-port="$port" || { pause_enter;continue; }
      if nm_yes 'Открыть этот UDP-порт в UFW?'; then ufw allow "$port/udp" || true;fi
      if nm_yes 'Задать static endpoints (расширенно)?'; then
       br26_input 'Список IP:порт через запятую; пример публичного IPv4: 203.0.113.1:40000' '' endpoints || continue
       if python3 - "$endpoints" <<'TS42_ENDPOINT'
import sys,ipaddress
for s in sys.argv[1].split(','):
 host,port=s.rsplit(':',1);ipaddress.ip_address(host.strip('[]'));assert port.isdecimal() and 1<=int(port)<=65535
TS42_ENDPOINT
       then
        nm_yes "Применить static endpoints: $endpoints?" && tailscale set --relay-server-static-endpoints="$endpoints" || true
       fi
      fi ;;
   13) smart_menu 'Автообновления Tailscale' 'Может перезапускать VPN. На маршрутизаторе это влияет на клиентов.' 15 "${WT_WIDTH:-85}" 2 val true 'Включить' false 'Выключить' || continue
      if nm_yes "Установить auto-update=$val?"; then tailscale set --auto-update="$val" || true;fi ;;
   14) ts42_audit || true ;;
  esac
  pause_enter
 done
}

mod_tailscale() {
    local mode="${1:-}"
    DEFAULT_WAN_IF=$(get_wan_if)
    if [ "$mode" = "auto" ]; then
        if command -v tailscale &>/dev/null; then
            echo -e "${C_BLUE} Пакет Tailscale уже установлен. Применение дополнительных настроек...${C_RESET}"
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
                echo -e "${C_YELLOW} Установка Tailscale пропущена пользователем.${C_RESET}"
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
        if ! smart_menu "Настройка закрытой сети" "" 21 $WT_WIDTH 13 "ts_choice" \
        "1" " Авторизация" \
        "2" " Настройка шлюза" \
        "3" " Трансляция локальных сетей" \
        "4" " Прием маршрутов" \
        "5" " Стелс-режим" \
        "6" " Ускорение и MSS Clamping" \
        "7" " Локальный веб-интерфейс" \
        "8" " Приоритет сетевых правил" \
        "9" " Личный ретранслятор (DERP)" \
        "10" " Каскад: NaiveProxy + Tailscale + WARP" \
        "11" " Полный сброс" \
        "12" " Диагностика и дополнительные настройки Tailscale" \
        "0" " Вернуться назад"; then
            break
        fi

        if [ "$ts_choice" = "0" ]; then break; fi
        clear

        case "$ts_choice" in
            12) ts42_tools ;;
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
                if smart_menu "Настройка шлюза" "Действие:" 12 $WT_WIDTH 4 "en_choice" \
                "1" " Назначить этот сервер шлюзом" \
                "2" " Отключить трансляцию шлюза" \
                "3" " Подключиться к удаленному шлюзу" \
                "4" " Отключиться от шлюза"; then
                    case "$en_choice" in
                        1) 
                            echo -e "${C_BLUE} Настройка сервера в качестве сетевого шлюза...${C_RESET}"
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

                            echo -e "${C_GREEN} Сервер успешно настроен как шлюз (правила защищены от перезагрузки)!${C_RESET}"
                            print_network_health_summary
                            
                            whiptail --title " ВАЖНО: Активация в панели Tailscale" --msgbox \
"Сервер объявлен шлюзом, форвардинг и правила NAT/SNAT закреплены!\n\nОстался финальный шаг в веб-панели:\n1. Откройте: https://login.tailscale.com/admin/machines\n2. Напротив этого сервера нажмите [...] -> Edit route settings...\n3. Включите переключатель 'Use as exit node'!\n\n Если интернет через шлюз не открывается на клиентах,\nпереподключите Tailscale на клиентском устройстве." 16 $WT_WIDTH
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
                            echo -e "${C_GREEN} Функция шлюза Tailscale отключена.${C_RESET}" 
                            ;;
                        3)
                            local target_ip=""
                            prompt_clean "IP-адрес или имя удаленного шлюза:" target_ip
                            if [ -n "$target_ip" ]; then
                                silent_run tailscale set --exit-node="$target_ip" --exit-node-allow-lan-access
                                echo -e "${C_GREEN} Весь трафик перенаправлен через выбранный узел.${C_RESET}"
                            fi
                            ;;
                        4) silent_run tailscale set --exit-node=; echo -e "${C_GREEN} Перенаправление трафика отключено.${C_RESET}" ;;
                    esac
                    pause_enter
                fi
                ;;
            3)
                local tr_choice
                if smart_menu "Трансляция локальных сетей" "Действие:" 11 $WT_WIDTH 2 "tr_choice" \
                "1" " Включить трансляцию (Задать подсеть)" \
                "2" " Отключить трансляцию"; then
                    case "$tr_choice" in
                        1)
                            local sub=$(get_interface_subnet "$DEFAULT_WAN_IF")
                            local r_input=""
                            MODULE_CANCELED=false
                            prompt_default "Сетевой диапазон для трансляции:" "${sub}.0/24" r_input
                            if [ "$MODULE_CANCELED" = false ] && [ -n "$r_input" ]; then
                                silent_run tailscale set --advertise-routes="$r_input"
                                echo -e "${C_GREEN} Выбранный диапазон ($r_input) транслируется в общую сеть.${C_RESET}"
                            fi
                            ;;
                        2)
                            silent_run tailscale set --advertise-routes=""
                            echo -e "${C_GREEN} Трансляция локальных сетей успешно отключена.${C_RESET}"
                            ;;
                    esac
                    pause_enter
                fi
                ;;
            4)
                if prompt_yn "Разрешить принятие внешних сетевых маршрутов от других устройств в вашей сети?" "true"; then
                    silent_run tailscale set --accept-routes=true; echo -e "${C_GREEN} Принятие маршрутов включено.${C_RESET}"
                else
                    silent_run tailscale set --accept-routes=false; echo -e "${C_BLUE} Принятие маршрутов отключено.${C_RESET}"
                fi
                pause_enter
                ;;
            5)
                if prompt_yn "Включить скрытый режим работы (отбрасывание нежелательного входящего трафика)?" "true"; then
                    silent_run tailscale set --stateful-filtering=true; echo -e "${C_GREEN} Скрытый режим работы активирован.${C_RESET}"
                else
                    silent_run tailscale set --stateful-filtering=false; echo -e "${C_BLUE} Скрытый режим отключен.${C_RESET}"
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
                    echo -e "${C_GREEN} Веб-интерфейс запущен, порт 5252/tcp открыт в UFW.${C_RESET}"
                    echo -e "${C_BLUE} Адрес панели: http://${ts_ip_now}:5252${C_RESET}"
                else
                    silent_run tailscale set --webclient=false
                    if command -v ufw &>/dev/null; then
                        silent_run ufw delete allow in on tailscale0 to any port 5252 proto tcp
                    fi
                    echo -e "${C_BLUE} Панель управления остановлена, порт 5252/tcp закрыт в UFW.${C_RESET}"
                fi
                pause_enter
                ;;
            8)
                local nf_choice
                if smart_menu "Приоритет сетевых правил" "Действие:" 13 $WT_WIDTH 4 "nf_choice" \
                "1" " Приоритет брандмауэра UFW (системный режим)" \
                "2" " Приоритет Tailscale (встроенный авто-режим)" \
                "3" " Выбрать интерфейсы для сквозного транзита" \
                "4" " Очистить дубликаты NAT и перезагрузить UFW"; then
                    case "$nf_choice" in
                        1) set_tailscale_netfilter_priority "off" ;;
                        2) set_tailscale_netfilter_priority "on" ;;
                        3)
                            local wan_dev=$(get_wan_if)
                            if [ -n "$wan_dev" ]; then
                                select_and_apply_routed_interfaces "$wan_dev"
                                flush_and_reload_nat
                                echo -e "${C_GREEN} Правила сквозного транзита для выбранных интерфейсов обновлены.${C_RESET}"
                            fi
                            ;;
                        4)
                            flush_and_reload_nat
                            [ "$(get_tailscale_netfilter_mode)" = "off" ] && clean_tailscale_iptables_chains
                            echo -e "${C_GREEN} Таблица NAT очищена от дубликатов, правила UFW перезагружены.${C_RESET}"
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
                    systemctl disable --now bobarev-tailscale-exit-restore.service 2>/dev/null || true
                    tailscale up --reset 2>&1 | grep -v "accept-routes" || true
                    rm -f /etc/default/bobarev-netfilter 2>/dev/null || true
                    if command -v ufw &>/dev/null; then
                        silent_run ufw delete allow in on tailscale0 to any port 5252 proto tcp
                    fi
                    echo -e "${C_GREEN} Сетевые параметры очищены.${C_RESET}"
                fi
                pause_enter
                ;;
        esac
    done
}
mod_tailscale_auto() { mod_tailscale "auto"; }

# 11. Управление логированием (Интерактивный менеджер)
mod_logging_manager() {
    echo -e "${C_CYAN} === 11/27. УПРАВЛЕНИЕ СИСТЕМНЫМИ ЖУРНАЛАМИ ===${C_RESET}"
    
    local cur_usage="N/A"
    if command -v journalctl &>/dev/null; then
        cur_usage=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[[:space:]]*[KMGTBkmgtb]+' | head -n 1 || echo "N/A")
        [ -z "$cur_usage" ] && cur_usage="N/A"
    fi
    
    local cur_mode="Стандартный"
    if [ -f /etc/systemd/system/clean-logs-boot.service ] || [ -f /usr/local/bin/disable-logging.sh ]; then
        cur_mode=" Отключены (Stealth)"
    elif grep -qE "^\s*SystemMaxUse=" /etc/systemd/journald.conf 2>/dev/null; then
        local cur_lim=$(grep -E "^\s*SystemMaxUse=" /etc/systemd/journald.conf 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
        cur_mode=" Ограничены (${cur_lim})"
    fi
    
    local msg="\nТекущее состояние журналов:
   Занято на диске: $cur_usage
   Текущий режим:   $cur_mode

Выберите желаемое действие:"
    
    local log_choice=""
    if ! smart_menu "Управление системными журналами" "$msg" 16 $WT_WIDTH 4 "log_choice" \
    "1" " Ограничить размер (100 МБ, 1 месяц)" \
    "2" " Задать собственный лимит размера" \
    "3" " Отключить ведение логов (Stealth)" \
    "0" " Вернуться назад" || [ "$log_choice" = "0" ] || [ -z "$log_choice" ]; then
        MODULE_CANCELED=true
        return 0
    fi
    
    backup_file "/etc/systemd/journald.conf"
    
    if [ "$log_choice" = "1" ] || [ "$log_choice" = "2" ]; then
        local log_size="100M"
        if [ "$log_choice" = "2" ]; then
            prompt_default "Введите максимальный размер логов (например: 50M, 200M, 1G):" "100M" log_size
            [ "$MODULE_CANCELED" = true ] && return 0
        fi
        
        echo -e "${C_BLUE} Применение лимита журналов ($log_size)...${C_RESET}"
        silent_run sed -i -E '/^\s*#?\s*(\[Journal\]|Storage=|ForwardToSyslog=|ForwardToKMsg=|ForwardToConsole=|ForwardToWall=|SystemMaxUse=|MaxRetentionSec=)/d' /etc/systemd/journald.conf
        cat << CONF >> /etc/systemd/journald.conf
[Journal]
SystemMaxUse=$log_size
MaxRetentionSec=1month
CONF
        
        silent_run systemctl restart systemd-journald
        silent_run systemctl disable clean-logs-boot.service 2>/dev/null || true
        rm -f /usr/local/bin/disable-logging.sh /etc/systemd/system/clean-logs-boot.service
        silent_run systemctl daemon-reload
        
        journalctl --vacuum-size="$log_size" >/dev/null 2>&1 || true
        local new_usage=$(journalctl --disk-usage 2>/dev/null || echo "")
        
        echo -e "${C_GREEN} Системные журналы успешно ограничены объемом $log_size (хранение до 1 месяца).${C_RESET}"
        [ -n "$new_usage" ] && echo -e "   ${C_BLUE}$new_usage${C_RESET}"
    
    elif [ "$log_choice" = "3" ]; then
        echo -e "${C_BLUE} Включение режима Stealth и отключение системных журналов...${C_RESET}"
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

        silent_run systemctl daemon-reload
        silent_run systemctl enable clean-logs-boot.service
        /usr/local/bin/disable-logging.sh
        echo -e "${C_GREEN} Полное отключение системного журналирования успешно активировано (режим Stealth).${C_RESET}"
        echo -e "   ${C_BLUE}Служба journald переведена в режим Storage=none${C_RESET}"
        echo -e "   ${C_BLUE}Службы rsyslog/auditd отключены, логи очищены${C_RESET}"
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
    echo -e "${C_CYAN} === 12/27. ОПТИМИЗАЦИЯ ПАМЯТИ И НАКОПИТЕЛЕЙ ===${C_RESET}"
    backup_file "/etc/fstab"

    local target_swappiness=1
    local target_page_cluster=3
    if swapon --show 2>/dev/null | grep -q "zram"; then
        target_swappiness=100
        target_page_cluster=0
        echo -e "${C_BLUE} Обнаружен активный zRAM: установлен vm.swappiness=100 и page-cluster=0 для сжатия в ОЗУ.${C_RESET}"
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
        echo -e "${C_GREEN} Настройки noatime и commit=120 успешно применены (ФС: $root_fs).${C_RESET}"
    else
        awk '
        BEGIN { OFS="\t" }
        !/^#/ && $2 == "/" {
            if ($4 !~ /(^|,)noatime(,|$)/) $4 = $4 ",noatime"
        }
        { print }' /etc/fstab > /tmp/fstab.tmp && cat /tmp/fstab.tmp > /etc/fstab && rm -f /tmp/fstab.tmp
        silent_run mount -o remount,noatime /
        echo -e "${C_YELLOW} Файловая система '$root_fs' не поддерживает commit=120. Применен только noatime.${C_RESET}"
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

    silent_run systemctl daemon-reload
    silent_run mount -a
}

# 13. Менеджер Swap
mod_swap_manager() {
    local swap_choice
    if ! smart_menu "Файл подкачки (Swap)" "Управление виртуальной памятью:" 12 $WT_WIDTH 3 "swap_choice" \
    "1" " Создать базовый объем (2 ГБ)" \
    "2" " Указать собственный объем" \
    "3" " Полностью отключить файл подкачки" || [ "$swap_choice" = "0" ]; then
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
                if [[ ! "$swap_size" =~ ^[0-9]+[GgMm]$ ]]; then
                    echo -e "${C_RED} Ошибка: Неверный формат объема. Используйте G или M (например, 2G или 2048M).${C_RESET}"
                    pause_enter
                    return 1
                fi
            fi
            silent_run swapoff /swap.img 2>/dev/null
            silent_run swapoff /swapfile 2>/dev/null
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
            echo -e "${C_GREEN} Файл подкачки размером $swap_size успешно инициализирован!${C_RESET}"
            ;;
        3)
            silent_run swapoff /swapfile 2>/dev/null
            silent_run swapoff /swap.img 2>/dev/null
            sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab
            rm -f /swapfile /swap.img
            echo -e "${C_GREEN} Дисковый файл подкачки отключен.${C_RESET}"
            ;;
    esac
}

# 14. Системные утилиты и режим процессора
mod_desktop_apps() {
    echo -e "${C_CYAN} === 14/27. СИСТЕМНЫЕ УТИЛИТЫ И РЕЖИМ ПРОЦЕССОРА ===${C_RESET}"

    local gov_choice
    if smart_menu "Управление питанием процессора" "\nВыберите желаемый режим работы:\n\nТекущий режим напрямую влияет на скорость\nработы, нагрев и энергопотребление." 17 $WT_WIDTH 4 "gov_choice" \
    "1" " Performance (Максимальный)" \
    "2" " Ondemand / Schedutil (Сбалансированный)" \
    "3" " Powersave (Эко-режим)" \
    "0" " Без изменений" && [ "$gov_choice" != "0" ]; then
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

        echo -e "${C_BLUE} Установка режима процессора: $gov_name...${C_RESET}"
        export DEBIAN_FRONTEND=noninteractive
        silent_run apt-get update
        silent_run apt-get install -yq cpufrequtils
        
        echo "GOVERNOR=$selected_gov" > /etc/default/cpufrequtils
        silent_run systemctl restart cpufrequtils 2>/dev/null || true
        
        for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
            [ -f "$cpu" ] && echo "$selected_gov" > "$cpu" 2>/dev/null || true
        done
        echo -e "${C_GREEN} Режим процессора успешно изменен на $gov_name.${C_RESET}"
    else
        echo -e "${C_YELLOW} Настройка режима процессора пропущена.${C_RESET}"
    fi

    if whiptail --title "Графическое окружение" --yesno "\nУстановить трей-апплеты (сеть, звук, bluetooth, батарея) и добавить их в автозапуск?\n\n(Имеет смысл только для систем с графическим рабочим столом)." 13 $WT_WIDTH; then
        echo -e "${C_BLUE} Установка утилит для графического интерфейса...${C_RESET}"
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
        echo -e "${C_GREEN} Инструменты графического окружения добавлены в автозапуск для $target_user.${C_RESET}"
    else
        echo -e "${C_YELLOW} Установка графических утилит пропущена.${C_RESET}"
    fi
}

# 15. Программный сброс HDMI
mod_hdmi_reset() {
    echo -e "${C_CYAN} === 15/27. СБРОС ВИДЕОВЫХОДА HDMI ===${C_RESET}"
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
        echo -e "${C_GREEN} Скрипт автоматического сброса HDMI подключен к дисплейному менеджеру LightDM.${C_RESET}"
    else
        echo -e "${C_GREEN} Скрипт /usr/local/bin/reset-hdmi.sh создан. Конфигурация LightDM не найдена.${C_RESET}"
    fi
}

# 16. Диагностика времени загрузки
mod_boot_diag() {
    echo -e "${C_CYAN} === 16/27. АНАЛИЗ ВРЕМЕНИ ЗАГРУЗКИ СИСТЕМЫ ===${C_RESET}"
    if [ "$(cat /proc/1/comm 2>/dev/null)" != "systemd" ]; then
        echo -e "${C_RED} Ошибка: система запущена без systemd. Диагностика невозможна.${C_RESET}"
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

    echo " Сбор данных о загрузке системы..."
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
    
    echo -e "${C_GREEN} Диагностика успешно завершена.${C_RESET}"
    echo " Текстовый отчёт сохранен: $report_file"
    echo " SVG-график сохранен:      $svg_file"
}

# 17. Полный аудит сервера (с проверкой ретранслятора DERP и обоих типов каскада)

# Audit-only: inspect direct POSTROUTING rules; never alter firewall.
audit_nat_output() {
    local iface="$1" rules stats total unique repeated groups
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "   Трансляция NAT на выходе:  ${C_BLUE}  Проверка недоступна: не найден компонент iptables${C_RESET}"
        return 0
    fi
    if ! rules=$(iptables -t nat -S POSTROUTING 2>/dev/null); then
        echo -e "   Трансляция NAT на выходе:  ${C_BLUE}  Не удалось прочитать правила; состояние NAT не определено${C_RESET}"
        return 0
    fi
    stats=$(printf '%s\n' "$rules" | awk -v iface="$iface" '
        $1 == "-A" && $2 == "POSTROUTING" {
            out=""; jump=""
            for (i=3; i<=NF; i++) {
                if ($i == "-o" && i<NF) out=$(i+1)
                if ($i == "-j" && i<NF) jump=$(i+1)
            }
            if (out==iface && (jump=="MASQUERADE" || jump=="SNAT")) {
                key=$0
                total++
                if (++seen[key]==1) unique++
            }
        }
        END {
            for (key in seen) if (seen[key]>1) groups++
            printf "%d %d %d %d", total+0, unique+0, total-unique, groups+0
        }')
    read -r total unique repeated groups <<< "$stats"
    if [[ "$total" == 0 ]]; then
        echo -e "   Трансляция NAT на выходе:  ${C_BLUE}  Прямых правил для $iface не найдено; другие цепочки и сетевые механизмы не проверялись${C_RESET}"
    elif [[ "$repeated" == 0 ]]; then
        echo -e "   Трансляция NAT на выходе:  ${C_BLUE}  На $iface настроено правил: $total; точных повторов нет${C_RESET}"
        if ((total>1)); then
            echo -e "                              ${C_BLUE}Несколько разных правил — само по себе не ошибка. Очистка по этому признаку не требуется.${C_RESET}"
        fi
    else
        echo -e "   Трансляция NAT на выходе:  ${C_BLUE}  На $iface правил: $total; различных: $unique; лишних точных повторов: $repeated${C_RESET}"
        echo -e "                              ${C_BLUE}Замечание к конфигурации, не доказательство сбоя. Автоматическая очистка не выполняется.${C_RESET}"
    fi
}

mod_server_audit() {
    clear
    echo -e "${C_CYAN}=================================================================${C_RESET}"
    echo -e "${C_BOLD}         АУДИТ СИСТЕМЫ 1 (ПОЛНЫЙ ИНТЕЛЛЕКТУАЛЬНЫЙ)     ${C_RESET}"
    echo -e "${C_CYAN}=================================================================${C_RESET}\n"
    
    local active_user=$(get_active_user)
    local wan_if=$(get_wan_if)

    echo -e "${C_BOLD}--- 1. Базовая система, хост и обновления ---${C_RESET}"
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    current_tz="${current_tz#Etc/}"
    local ntp_sync=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "no")
    local ntp_str="${C_YELLOW}  Нет синхронизации точного времени${C_RESET}"
    [ "$ntp_sync" = "yes" ] && ntp_str="${C_GREEN} Время синхронизировано${C_RESET}"

    local sys_type_human=$(get_system_type_human)
    local boot_target=$(systemctl get-default 2>/dev/null || echo "multi-user.target")
    local boot_target_human="${C_BLUE}Консольный (без рабочего стола, экономия ОЗУ)${C_RESET}"
    [ "$boot_target" = "graphical.target" ] && boot_target_human="${C_BLUE}Графический рабочий стол${C_RESET}"

    echo -e "   Часовой пояс и время:      ${C_GREEN}$current_tz${C_RESET} ($ntp_str)"
    echo -e "   Имя сервера (хост):        ${C_GREEN}$(hostname)${C_RESET}"
    echo -e "   Тип устройства:            ${C_BLUE}$sys_type_human${C_RESET}"
    echo -e "   Режим работы системы:      $boot_target_human"
    
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        echo -e "   Фоновые обновления:        ${C_GREEN} Включены (авто-установка обновлений защиты)${C_RESET}"
    else
        echo -e "   Фоновые обновления:        ${C_RED} Отключены${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 2. Аппаратная часть и Детектор оверселлинга ---${C_RESET}"
    local cpu_temp="Нет датчика"
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        local raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "")
        if [ -n "$raw_temp" ] && [ "$raw_temp" -gt 0 ]; then
            cpu_temp=$(LC_ALL=C awk "BEGIN {printf \"%.1f°C\", $raw_temp/1000}")
            if [ "$raw_temp" -gt 75000 ]; then
                cpu_temp="${C_RED} $cpu_temp (Критический перегрев / Снижение частот!)${C_RESET}"
            elif [ "$raw_temp" -gt 60000 ]; then
                cpu_temp="${C_YELLOW}  $cpu_temp (Повышенный нагрев)${C_RESET}"
            else
                cpu_temp="${C_GREEN}  $cpu_temp (В норме)${C_RESET}"
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
    local psi_status="${C_GREEN} 0.0% (очередей ожидания нет)${C_RESET}"
    local oversell_score=0

    local stat_line1=$(grep '^cpu ' /proc/stat 2>/dev/null || echo "")
    local t_cpu1=$(LC_ALL=C date +%s.%N 2>/dev/null || awk '{print $1}' /proc/uptime)
    LC_ALL=C awk 'BEGIN {for(i=0;i<2000000;i++){x=i*1.5}}' >/dev/null 2>&1 || true
    local t_cpu2=$(LC_ALL=C date +%s.%N 2>/dev/null || awk '{print $1}' /proc/uptime)

    local cpu_bench_ms=$(LC_ALL=C awk -v t1="$t_cpu1" -v t2="$t_cpu2" 'BEGIN {d=(t2-t1)*1000; if(d<1) d=1; printf "%d", d}')
    if [ "$cpu_bench_ms" -lt 150 ]; then
        cpu_speed_status="${C_GREEN} Быстрый (${cpu_bench_ms} мс — без троттлинга)${C_RESET}"
    elif [ "$cpu_bench_ms" -lt 350 ]; then
        cpu_speed_status="${C_GREEN} Нормальный (${cpu_bench_ms} мс — стандартное ядро)${C_RESET}"
    else
        cpu_speed_status="${C_YELLOW}  Замедлен (${cpu_bench_ms} мс — хостер лимитирует ядро!)${C_RESET}"
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
            disk_io_status="${C_GREEN} Быстрый NVMe/SSD (отклик ${io_lat} мс, ~${io_iops} IOPS)${C_RESET}"
        elif [ "$io_lat_int" -lt 12 ]; then
            disk_io_status="${C_GREEN} Нормальный SSD (отклик ${io_lat} мс, ~${io_iops} IOPS)${C_RESET}"
        else
            disk_io_status="${C_YELLOW}  Медленный отклик (${io_lat} мс, ~${io_iops} IOPS — диск занят!)${C_RESET}"
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
            steal_status="${C_GREEN} 0.0% под нагрузкой (хостер честно отдает ядро)${C_RESET}"
        elif [ "$steal_int" -lt 5 ]; then
            steal_status="${C_GREEN} Низкий (${steal_pct}% — минимальное влияние соседей)${C_RESET}"
        elif [ "$steal_int" -lt 15 ]; then
            steal_status="${C_YELLOW}  Умеренный (${steal_pct}% — заметная очередь за процессором)${C_RESET}"
            oversell_score=$((oversell_score + 1))
        else
            steal_status="${C_RED} ВЫСОКИЙ (${steal_pct}% — жесткий оверселлинг CPU на ноде!)${C_RESET}"
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
            psi_status="${C_YELLOW}  Замечены простои в очереди (CPU: ${psi_cpu}%, Диск: ${psi_io}%)${C_RESET}"
            oversell_score=$((oversell_score + 1))
        else
            psi_status="${C_GREEN} В норме (CPU: ${psi_cpu}%, Диск: ${psi_io}% за минуту)${C_RESET}"
        fi
    fi

    local verdict_human="${C_GREEN} Честные ресурсы (оверселлинг не обнаружен)${C_RESET}"
    if [ "$oversell_score" -eq 1 ]; then
        verdict_human="${C_YELLOW} Умеренный оверселлинг (ресурсы делятся с соседями)${C_RESET}"
    elif [ "$oversell_score" -ge 2 ]; then
        verdict_human="${C_RED} Жесткий оверселлинг! (хостер урезает железо)${C_RESET}"
    fi

    echo -e "   Температура процессора:    $cpu_temp"
    echo -e "   Режим питания процессора:  $cpu_gov_human"
    echo -e "   Текущая частота ядер:      ${C_BLUE}$cpu_freq${C_RESET}"
    echo -e "   Вычислительная нагрузка:   ${C_BLUE}$load_avg${C_RESET}"
    echo -e "   Занято места на диске:     ${C_BLUE}$disk_usage${C_RESET}"
    echo -e "   Отклик ядра (Троттлинг):   $cpu_speed_status"
    echo -e "   Кража CPU под нагрузкой:   $steal_status"
    echo -e "   Реальный отклик диска:     $disk_io_status"
    echo -e "   Ожидание ресурсов (PSI):   $psi_status"
    echo -e "   Вердикт по оверселлингу:   $verdict_human"

    echo -e "\n${C_BOLD}--- 3. Учетные записи, пользователи и Sudo ---${C_RESET}"
    local in_sudo_group="нет"
    if id -nG "$active_user" 2>/dev/null | grep -qw "sudo"; then
        in_sudo_group="в группе sudo"
    fi
    echo -e "   Основной администратор:    ${C_GREEN}$active_user ($in_sudo_group)${C_RESET}"

    local sudo_effective_line=$(sudo -l -U "$active_user" 2>/dev/null | grep -E "NOPASSWD|ALL" | tail -n 1 || echo "")
    if echo "$sudo_effective_line" | grep -q "NOPASSWD"; then
        echo -e "   Повышение прав (Sudo):     ${C_GREEN} Без запроса пароля (NOPASSWD активен)${C_RESET}"
    elif [ -f "/etc/sudoers.d/99-zzz-$active_user" ] || [ -f "/etc/sudoers.d/$active_user" ]; then
        echo -e "   Повышение прав (Sudo):     ${C_YELLOW}  Файл NOPASSWD есть, но перебит другим правилом (перезапустите п. 4)${C_RESET}"
    else
        echo -e "   Повышение прав (Sudo):     ${C_BLUE}  Стандартный запрос пароля${C_RESET}"
    fi

    local root_locked=$(passwd -S root 2>/dev/null || echo "")
    if echo "$root_locked" | grep -qE " L | LK | NP "; then
        echo -e "   Пароль суперпользователя:  ${C_GREEN} Заблокирован (защищено)${C_RESET}"
    else
        echo -e "   Пароль суперпользователя:  ${C_RED} Активен (разрешен прямой вход root)${C_RESET}"
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
        port_status_human="${C_YELLOW}  22 (Стандартный порт, рекомендуется сменить)${C_RESET}"
    else
        port_status_human="${C_GREEN} $ssh_port (Нестандартный порт)${C_RESET}"
    fi

    local root_status_human
    case "${root_ssh,,}" in
        no) root_status_human="${C_GREEN} Запрещен${C_RESET}" ;;
        prohibit-password|without-password) root_status_human="${C_GREEN} Только по SSH-ключам${C_RESET}" ;;
        yes|*) root_status_human="${C_RED} Разрешен${C_RESET}" ;;
    esac

    local pass_status_human
    case "${pass_auth,,}" in
        no) pass_status_human="${C_GREEN} Отключен (вход только по SSH-ключам)${C_RESET}" ;;
        yes|*) pass_status_human="${C_YELLOW}  Разрешен вход по паролю${C_RESET}" ;;
    esac

    echo -e "   Используемый порт SSH:     $port_status_human"
    echo -e "   Вход для root по SSH:      $root_status_human"
    echo -e "   Авторизация по паролю:     $pass_status_human"

    if systemctl is-active --quiet sshguard 2>/dev/null; then
        echo -e "   Защита от перебора пароля: ${C_GREEN} Работает (легковесный демон sshguard)${C_RESET}"
    elif systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "   Защита от перебора пароля: ${C_GREEN} Работает (служба fail2ban)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 5. Защита ядра и сетевые оптимизации ---${C_RESET}"
    check_param() {
        local param="$1" expected="$2" label="$3" ok_msg="$4" err_msg="$5"
        local val=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
        if [ "$param" = "net.core.rmem_max" ]; then
            if [ "$val" != "N/A" ] && [ "$val" -ge 26214400 ] 2>/dev/null; then
                echo -e "   ${label}${C_GREEN} Активны (расширенные буферы под высокие скорости, сейчас: $val)${C_RESET}"
                return
            fi
        fi
        if [ "$val" = "$expected" ]; then
            echo -e "   ${label}${C_GREEN} $ok_msg${C_RESET}"
        else
            echo -e "   ${label}${C_YELLOW}  $err_msg (сейчас: $val)${C_RESET}"
        fi
    }
    check_param "kernel.dmesg_restrict"           "1"        "Защита журнала ядра:       " "Включена" "Отключена"
    check_param "net.ipv4.ip_forward"             "1"        "Форвардинг пакетов (IPv4): " "Включен (маршрутизация активна)" "Отключен"
    check_param "net.ipv4.tcp_syncookies"         "1"        "Защита от флуда (SYN):     " "Включена" "Отключена"
    check_param "net.ipv4.tcp_congestion_control" "bbr"      "Ускорение сети TCP BBR:    " "Активно" "Стандартное"
    check_param "net.core.rmem_max"               "67108864" "Расширенные буферы VPN:    " "Активны (расширенные буферы под высокие скорости)" "Стандартные"

    echo -e "\n${C_BOLD}--- 6. Межсетевой экран (UFW), Изоляция и Режим роутера ---${C_RESET}"
    if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
        local ufw_out=$(LC_ALL=C ufw status 2>/dev/null || echo "")
        echo -e "   Статус брандмауэра:        ${C_GREEN} Включен и защищает сервер${C_RESET}"
        
        local fwd_policy=$(grep -E "^DEFAULT_FORWARD_POLICY=" /etc/default/ufw 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "DROP")
        if [ "$fwd_policy" = "ACCEPT" ]; then
            echo -e "   Пересылка трафика (Шлюз):  ${C_GREEN} Разрешена (сервер может раздавать интернет)${C_RESET}"
        else
            echo -e "   Пересылка трафика (Шлюз):  ${C_YELLOW}  Запрещена (только локальные подключения)${C_RESET}"
        fi

        if echo "$ufw_out" | grep -qE "${ssh_port}/tcp[[:space:]]+on[[:space:]]+tailscale0|SSH via Tailscale only"; then
            echo -e "   Доступ к порту SSH:        ${C_GREEN} Скрыт снаружи (вход только через Tailscale)${C_RESET}"
        else
            echo -e "   Доступ к порту SSH:        ${C_YELLOW} Публичный (открыт для всех сетей)${C_RESET}"
        fi

        if command -v tailscale &>/dev/null; then
            if echo "$ufw_out" | awk '!/ALLOW FWD/ && /^Anywhere[[:space:]]+on[[:space:]]+tailscale0[[:space:]]+ALLOW/' | grep -q .; then
                echo -e "   Изоляция сети Tailscale:   ${C_YELLOW}  Отключена (открыты все порты на tailscale0)${C_RESET}"
            else
                local open_ts_ports="только SSH $ssh_port/tcp"
                if echo "$ufw_out" | awk '!/ALLOW FWD/ && /^5252\/tcp[[:space:]]+on[[:space:]]+tailscale0[[:space:]]+ALLOW/' | grep -q .; then
                    open_ts_ports="SSH $ssh_port/tcp и Веб-панель 5252/tcp"
                fi
                echo -e "   Изоляция сети Tailscale:   ${C_GREEN} Полная (Zero-Trust: $open_ts_ports — безопасно для Share)${C_RESET}"
            fi
        fi

        if [ -n "$wan_if" ]; then
            audit_nat_output "$wan_if"
        else
            echo -e "   Трансляция NAT на выходе:  ${C_BLUE}  Выходной интерфейс не определён; проверка не выполнена${C_RESET}"
        fi

        if [ -r /etc/bobarev-router-v2/config ]; then
            (
                # shellcheck disable=SC1091
                source /etc/bobarev-router-v2/config
                local r_lan="${LANS[*]:-не задан}"
                local r_ip="${ADDRS[*]:-не задан}"
                local r_out="${OUT:-не задан}"
                local r_out_human="${C_GREEN}Через сетевой канал $r_out${C_RESET}"
                case "$r_out" in
                    wg*)        r_out_human="${C_GREEN} Через защищенный туннель WireGuard ($r_out)${C_RESET}" ;;
                    tailscale0) r_out_human="${C_GREEN} Через закрытую сеть Tailscale (Exit Node: ${EXIT_NODE:-авто})${C_RESET}" ;;
                    tun*|utun*) r_out_human="${C_GREEN} Через прокси-туннель ($r_out)${C_RESET}" ;;
                    "$wan_if")  r_out_human="${C_BLUE} Напрямую через провайдера ($r_out, без VPN)${C_RESET}" ;;
                esac
                echo -e "   Режим локального роутера:  ${C_GREEN} Активен v2 (LAN: $r_lan, шлюз: $r_ip)${C_RESET}"
                echo -e "   Интернет для клиентов LAN: $r_out_human"
                echo -e "   Защита от утечки IP:       ${C_GREEN} Включена (изолированная таблица + BR42_WAIT + unreachable metric)${C_RESET}"
            )
        elif [ -f /etc/default/bobarev-router ]; then
            # shellcheck disable=SC1091
            source /etc/default/bobarev-router
            local r_lan="${ROUTER_LAN_IF:-не задан}"
            local r_ip="${ROUTER_LAN_IP:-192.168.199.1}"
            local r_out="${ROUTER_OUT_IF:-не задан}"

            local r_out_human="${C_GREEN}Через сетевой канал $r_out${C_RESET}"
            case "$r_out" in
                wg*)        r_out_human="${C_GREEN} Через защищенный туннель WireGuard ($r_out)${C_RESET}" ;;
                tailscale0) r_out_human="${C_GREEN} Через закрытую сеть Tailscale${C_RESET}" ;;
                tun*|utun*) r_out_human="${C_GREEN} Через прокси-туннель ($r_out)${C_RESET}" ;;
                "$wan_if")  r_out_human="${C_BLUE} Напрямую через провайдера ($r_out, без VPN)${C_RESET}" ;;
            esac

            local r_host_human="${C_BLUE}Идет напрямую через провайдера (мимо VPN)${C_RESET}"
            if [ "${ROUTER_ROUTE_HOST:-false}" = "true" ]; then
                r_host_human="${C_GREEN} Тоже защищен и идет через $r_out${C_RESET}"
            fi

            local r_ks_human="${C_YELLOW}  Выключена (при сбое VPN трафик пойдет напрямую)${C_RESET}"
            if [ "${ROUTER_KILLSWITCH:-false}" = "true" ]; then
                r_ks_human="${C_GREEN} Включена (блокирует утечку IP в обход VPN)${C_RESET}"
            elif [ "$r_out" = "$wan_if" ]; then
                r_ks_human="${C_BLUE}Не требуется (выбран прямой выход без VPN)${C_RESET}"
            fi

            echo -e "   Режим локального роутера:  ${C_GREEN} Активен (раздает сеть в порт $r_lan, шлюз $r_ip)${C_RESET}"
            echo -e "   Интернет для клиентов LAN: $r_out_human"
            echo -e "   Трафик самого сервера:     $r_host_human"
            echo -e "   Защита от утечки IP:       $r_ks_human"
        fi

        if [ -f /etc/ufw/after.rules ] && grep -q "BEGIN UFW AND DOCKER" /etc/ufw/after.rules; then
            echo -e "   Защита контейнеров Docker: ${C_GREEN} Включена (доступ к портам Docker извне закрыт)${C_RESET}"
        fi
    else
        echo -e "   Статус брандмауэра:        ${C_RED} Выключен (сервер не защищен)${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 7. Закрытая меш-сеть Tailscale и Каскадные туннели ---${C_RESET}"
    local cascade_status="${C_BLUE}Не настроен${C_RESET}"
    if [[ -f /etc/naiveproxy/mesh-paused ]]; then
        cascade_status="${C_BLUE}NaiveProxy + XRayMesh: сохранена отметка паузы${C_RESET}"
    elif is_naive_active && nm_bound; then
        if systemctl is-active --quiet xraymesh.service && { systemctl is-active --quiet naive-mesh-bridge.service || systemctl is-active --quiet gost-mesh.service; }; then
            cascade_status="${C_GREEN}Сервер 1: NaiveProxy + XRayMesh — локальные службы запущены; полный путь отдельно не проверен${C_RESET}"
        else
            cascade_status="${C_BLUE}NaiveProxy привязан к mesh-каскаду; часть ожидаемых локальных служб не запущена${C_RESET}"
        fi
    elif systemctl is-active --quiet xraymesh.service; then
        cascade_status="${C_GREEN}Сервер 2: XRayMesh — локальные службы запущены${C_RESET}"
    elif is_naive_active && { systemctl is-active --quiet wg-quick@wg0 2>/dev/null || ip link show wg0 >/dev/null 2>&1; }; then
        cascade_status="${C_GREEN} Гибридный шлюз (NaiveProxy + Tailscale Exit Node -> WireGuard wg0 активен)${C_RESET}"
    elif is_naive_active && is_wg_cascade_active; then
        cascade_status="${C_GREEN} Сервер 1 (Каскад 1: Naiveproxy - Wireguard - Warp: NaiveProxy -> WG-Мост активен)${C_RESET}"
    elif is_naive_active; then
        local audit_saved_role=""
        if [[ -r /etc/default/bobarev-cascade ]]; then
            audit_saved_role=$(sed -n 's/^CASCADE_ROLE="\([a-zA-Z0-9_]*\)"$/\1/p' /etc/default/bobarev-cascade | head -n 1)
        fi
        case "$audit_saved_role" in
            ru_hysteria_entry) cascade_status="${C_BLUE}NaiveProxy запущен; сохранена настройка каскада Hysteria 2${C_RESET}" ;;
            ru_xray_entry) cascade_status="${C_BLUE}NaiveProxy запущен; сохранена настройка каскада Xray REALITY${C_RESET}" ;;
            standalone_naive) cascade_status="${C_BLUE}NaiveProxy запущен в автономной конфигурации; фактический внешний IP не проверен${C_RESET}" ;;
            *) cascade_status="${C_BLUE}NaiveProxy запущен; направление выхода по этой проверке не определено${C_RESET}" ;;
        esac
    elif is_wg_cascade_active && is_warp_active; then
        cascade_status="${C_GREEN} Сервер 2 (Прямой скоростной выход: WG-Мост -> WARP активен)${C_RESET}"
    elif is_warp_active; then
        cascade_status="${C_GREEN} Сервер 2 (Tailscale-выход: Tailscale -> WARP активен)${C_RESET}"
    elif systemctl is-active --quiet wg-quick@wg0 2>/dev/null || ip link show wg0 >/dev/null 2>&1; then
        cascade_status="${C_GREEN} Шлюз WireGuard wg0 активен (таблица 150)${C_RESET}"
    fi
    echo -e "   Активный режим каскада:    $cascade_status"

    if command -v tailscale &>/dev/null; then
        echo -e "   Служба Tailscale:          ${C_GREEN} Установлена и работает${C_RESET}"
        local ts_name ts_ip ts_exit ts_adv_exit ts_accept ts_stealth
        IFS="|" read -r ts_name _ <<< "$(get_tailscale_whoami)"
        ts_ip=$(tailscale ip -4 2>/dev/null | head -n 1 || echo "Не авторизован")
        
        ts_exit=$(tailscale get exit-node 2>/dev/null || echo "")
        local ts_exit_human
        if [ -z "$ts_exit" ] || [ "$ts_exit" = "none" ] || [ "$ts_exit" = "false" ]; then
            if is_wg_cascade_active; then
                ts_exit_human="Отключен (трафик идет через скоростной ядерный мост wg-cascade)"
            elif [ -f /etc/default/bobarev-router ]; then
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
        [ "$ts_nf_mode" = "off" ] && ts_nf_human="${C_GREEN} Брандмауэр UFW (системный режим)${C_RESET}"

        local ts_web_human="${C_BLUE}Отключена (порт 5252 закрыт)${C_RESET}"
        if is_tailscale_web_active; then
            if LC_ALL=C ufw status 2>/dev/null | awk '!/ALLOW FWD/ && (/^5252\/tcp[[:space:]]+on[[:space:]]+tailscale0[[:space:]]+ALLOW/ || /^Anywhere[[:space:]]+on[[:space:]]+tailscale0[[:space:]]+ALLOW/)' | grep -q .; then
                ts_web_human="${C_GREEN} Активна (http://${ts_ip}:5252 — порт 5252/tcp открыт в UFW)${C_RESET}"
            else
                ts_web_human="${C_YELLOW}  Включена, но порт 5252/tcp закрыт в UFW (перевключите п. 10 -> 7)${C_RESET}"
            fi
        fi

        local ts_derp_human="${C_BLUE}Не настроен${C_RESET}"
        if is_derp_active; then
            ts_derp_human="${C_GREEN} Работает (443/tcp и STUN 3478/udp открыты)${C_RESET}"
        elif [ -f /etc/systemd/system/derper.service ]; then
            ts_derp_human="${C_YELLOW}  Установлен, но служба derper остановлена${C_RESET}"
        fi

        echo -e "   Имя устройства в сети:     ${C_BLUE}$ts_name${C_RESET}"
        echo -e "   Внутренний IP-адрес:       ${C_BLUE}$ts_ip${C_RESET}"
        echo -e "   Внешний шлюз Tailscale:    ${C_BLUE}$ts_exit_human${C_RESET}"
        echo -e "   Раздает свой интернет:     $ts_adv_exit_human"
        echo -e "   Доступ к чужим подсетям:   $ts_accept_human"
        echo -e "   Скрытый режим (Stealth):   $ts_stealth_human"
        echo -e "   Приоритет правил фаервола: $ts_nf_human"
        echo -e "   Личный ретранслятор DERP:  $ts_derp_human"
        echo -e "   Веб-панель (порт 5252):    $ts_web_human"

        if systemctl is-active --quiet tailscale-gro.service 2>/dev/null; then
            echo -e "   Аппаратное ускорение GRO:  ${C_GREEN} Включено${C_RESET}"
        else
            echo -e "   Аппаратное ускорение GRO:  ${C_YELLOW}  Отключено${C_RESET}"
        fi
    else
        echo -e "   Служба Tailscale:          ${C_YELLOW}  Не установлена${C_RESET}"
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
        
        local err_str="${C_GREEN}0 ${C_RESET}"
        [ "$total_err" -gt 0 ] && err_str="${C_RED}$total_err ${C_RESET}"
        
        local drop_str="${C_GREEN}0 ${C_RESET}"
        [ "$total_drop" -gt 0 ] && drop_str="${C_YELLOW}$total_drop ${C_RESET}"

        echo -e "   Интерфейс ${C_BLUE}$iface${C_RESET} (MTU: ${C_GREEN}$mtu${C_RESET}, Скорость: ${C_GREEN}$speed${C_RESET})"
        echo -e "     Пакеты: Ошибки = $err_str | Пропущено (Dropped) = $drop_str"
    done

    echo -e ""
    local mss_active=false
    if command -v ufw &>/dev/null && [ -f /etc/ufw/before.rules ] && grep -q "TCPMSS" /etc/ufw/before.rules; then mss_active=true; fi
    if command -v iptables &>/dev/null && iptables -t mangle -L FORWARD -n 2>/dev/null | grep -q "TCPMSS"; then mss_active=true; fi
    
    if [ "$mss_active" = true ]; then
        echo -e "   Выравнивание пакетов (MSS): ${C_GREEN} Включено (сайты открываются без зависаний в VPN)${C_RESET}"
    else
        echo -e "   Выравнивание пакетов (MSS): ${C_YELLOW}  Выключено (возможны зависания сайтов в VPN)${C_RESET}"
    fi

    if command -v ufw &>/dev/null && LC_ALL=C ufw status | grep -qw "active"; then
        local ufw_ports_list=$(LC_ALL=C ufw status 2>/dev/null || echo "")
        [ -z "$ufw_ports_list" ] && ufw_ports_list="Все входящие порты закрыты"
        echo -e "   Открытые порты (по UFW):    ${C_BLUE}активны${C_RESET}"
    elif command -v ss &>/dev/null; then
        local listen_ports=$(ss -tlnH 2>/dev/null | awk '$4 !~ /^127\./ && $4 !~ /^\[::1\]/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -nu | tr '\n' ' ' || echo "")
        [ -n "$listen_ports" ] && echo -e "   Открытые порты (без UFW):   ${C_YELLOW}$listen_ports${C_RESET}"
    fi

    echo -e "\n${C_BOLD}--- 9. Оптимизация памяти, накопителей и подкачки ---${C_RESET}"
    
    local vm_swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "N/A")
    local swappiness_human
    if [ "$vm_swappiness" = "1" ]; then
        swappiness_human="${C_GREEN} 1 (Максимальная защита флеш-памяти от износа)${C_RESET}"
    elif [ "$vm_swappiness" = "100" ] && swapon --show 2>/dev/null | grep -q "zram"; then
        swappiness_human="${C_GREEN} 100 (Активное сжатие данных в быстрой ОЗУ zRAM)${C_RESET}"
    elif [ "$vm_swappiness" = "60" ]; then
        swappiness_human="${C_YELLOW}  60 (Заводское значение, частая запись на диск)${C_RESET}"
    elif [ "$vm_swappiness" = "N/A" ]; then
        swappiness_human="${C_RED} Ошибка чтения${C_RESET}"
    else
        swappiness_human="${C_BLUE}$vm_swappiness (Пользовательское значение)${C_RESET}"
    fi
    echo -e "   Режим подкачки памяти:     $swappiness_human"

    if mount | grep " / " | grep -q "noatime"; then
        echo -e "   Запись времени чтения:     ${C_GREEN} Отключена (noatime — снижен износ накопителя)${C_RESET}"
    else
        echo -e "   Запись времени чтения:     ${C_YELLOW}  Включена (лишняя нагрузка на диск)${C_RESET}"
    fi

    if mount | grep " / " | grep -q "commit=120"; then
        echo -e "   Буферизация записи диска:  ${C_GREEN} 120 сек. (бережет флеш-память от частых записей)${C_RESET}"
    else
        echo -e "   Буферизация записи диска:  ${C_YELLOW}  Стандартная (5 сек.)${C_RESET}"
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
        echo -e "   Виртуальная память:        ${C_GREEN} $joined_swap${C_RESET}"
    else
        echo -e "   Виртуальная память:        ${C_YELLOW}Отключена${C_RESET}"
    fi

    echo -e "\n${C_CYAN}=================================================================${C_RESET}"
}

# 18. Универсальный режим локального маршрутизатора (с поддержкой SBC-клиента WireGuard/WARP)
br26_input() {
 local _v
 _v=$(whiptail --inputbox "$1" 12 "${WT_WIDTH:-85}" "$2" 3>&1 1>&2 2>&3) || return 1
 printf -v "$3" '%s' "$_v"
}
br26_apply() {
 local p=/etc/bobarev-router-v2/pending dev i lan table pref occupied
 [[ -f "$p/config" ]] || { echo 'Нет отложенной конфигурации'; return 1; }
 # Use a subshell so staged configuration cannot overwrite wizard variables.
 (
 source "$p/config"
 DHCP_OWNER=${DHCP_OWNER:-managed}
 MSS_CLAMP=${MSS_CLAMP:-true}
 DNS_REDIRECT=${DNS_REDIRECT:-false}
 [[ "$DHCP_OWNER" == existing || "$DHCP_OWNER" == managed ]] || exit 1
 if [[ "$DHCP_OWNER" == existing ]]; then
  systemctl is-active --quiet dnsmasq.service || exit 1
  [[ $(systemctl is-enabled dnsmasq.service 2>/dev/null) == enabled ]] || { echo 'Сохраняемый dnsmasq должен быть enabled'; exit 1; }
 fi
 local old_dns_active=false old_dns_enabled=false committed=false
 systemctl is-active --quiet dnsmasq.service && old_dns_active=true
 [[ $(systemctl is-enabled dnsmasq.service 2>/dev/null) == enabled ]] && old_dns_enabled=true
 restore_dhcp_on_failure() {
  local rc=$?
  if [[ "$rc" != 0 && "$DHCP_OWNER" == managed && "$old_dns_active" == true && "$committed" == false ]]; then
   systemctl disable --now bobarev-router-dhcp.service 2>/dev/null || true
   [[ "$old_dns_enabled" != true ]] || systemctl enable dnsmasq.service || true
   systemctl start dnsmasq.service || true
   echo 'Старый DHCP возвращён; полного сетевого отката нет.' >&2
  fi
 }
 trap restore_dhcp_on_failure EXIT
 for dev in "${LANS[@]}" "$OUT"; do
  ip link show dev "$dev" >/dev/null 2>&1 || { echo "Конфигурация сохранена. Интерфейс $dev отсутствует; применение отложено."; exit 1; }
 done
 for i in "${!LANS[@]}"; do
  pref=$((5100+i));table=$((199+i));lan=${LANS[i]}
  occupied=$(ip -4 rule show | awk -v p="$pref:" '$1==p {print}')
  [[ -z "$occupied" || "$occupied" == *"iif $lan lookup $table"* ]] || { echo "Приоритет $pref занят"; exit 1; }
 done
 echo '[1/6] Проверка интерфейсов, правил и networkd'
 local -a networkd_pairs=()
 for i in "${!LANS[@]}"; do networkd_pairs+=("${LANS[i]}=${ADDRS[i]}"); done
 python3 "$p/routes.py" check "${networkd_pairs[@]}" || exit 1
 python3 "$p/networkd.py" check "${networkd_pairs[@]}" || exit 1
 if [[ "$OUT" == tailscale0 ]]; then
  if [[ -n "$EXIT_NODE" ]]; then
   tailscale set --exit-node="$EXIT_NODE" --exit-node-allow-lan-access=true --accept-routes=false || exit 1
  else
   tailscale set --exit-node-allow-lan-access=true || exit 1
  fi
  ts42_wait_running || exit 1
  ts_wait_exit_node || { echo 'Нет default tailscale0'; exit 1; }
  ts42_ipv4 || exit 1
  [[ -n "$EXIT_NODE" ]] || { echo 'Для загрузки нужен явный EXIT_NODE'; exit 1; }
  ts43_install_exit_restore "$EXIT_NODE" || exit 1
 fi
 echo '[2/6] Проверка пакетов и DHCP-конфигурации'
 apt-get install -y dnsmasq-base iptables iproute2 || exit 1
 if [[ "$DHCP_OWNER" == managed ]]; then dnsmasq --test --conf-file="$p/dhcp.conf" || exit 1; else dnsmasq --test || exit 1; fi
 systemctl disable --now bobarev-router-watchdog.timer bobarev-tailscale-bootfix.timer 2>/dev/null || true
 systemctl stop bobarev-router-watchdog.service bobarev-tailscale-bootfix.service 2>/dev/null || true
 echo '[3/6] Применение LAN-конфигурации'
 systemctl stop bobarev-router-dhcp.service bobarev-router-v2.service 2>/dev/null || true
 if [[ "$DHCP_OWNER" == managed && "$old_dns_active" == true ]]; then
  local bd
  bd=$(mktemp -d /root/bobarev-dhcp.XXXXXX) || exit 1
  cp -a /etc/dnsmasq.conf "$bd/" || exit 1
  [[ ! -d /etc/dnsmasq.d ]] || cp -a /etc/dnsmasq.d "$bd/" || exit 1
  [[ ! -f /var/lib/misc/dnsmasq.leases ]] || cp -a /var/lib/misc/dnsmasq.leases "$bd/" || exit 1
  echo "DHCP backup: $bd"
  touch /etc/bobarev-router-dnsmasq-was-active
  systemctl disable --now dnsmasq.service || exit 1
 elif [[ "$DHCP_OWNER" == existing ]]; then
  systemctl disable --now bobarev-router-dhcp.service || exit 1
 fi
 # Migrate the exact legacy rules owned by this module.
 if [[ -f /etc/bobarev-router-v2/config ]]; then
  bash <<'BR26_LEGACY'
source /etc/bobarev-router-v2/config
for lan in "${LANS[@]:-${LAN:-}}"; do
 [[ -n "$lan" ]] || continue
 for spec in '5100 199' '11990 52' '11991 199'; do
  read -r pref table <<< "$spec"
  while ip -4 rule del pref "$pref" iif "$lan" lookup "$table" 2>/dev/null; do :; done
 done
 if [[ -n "${ADDR:-}" ]]; then
  while ip -4 rule del pref 11989 to "${ADDR%.*}.0/24" lookup 199 2>/dev/null; do :; done
  for proto in udp tcp; do
   while iptables -w 5 -t nat -D PREROUTING -i "$lan" -p "$proto" --dport 53 -j DNAT --to-destination "$ADDR:53" 2>/dev/null; do :; done
  done
 fi
 done
BR26_LEGACY
 fi
 install -m 600 "$p/config" /etc/bobarev-router-v2/config
 install -m 600 "$p/dhcp.conf" /etc/bobarev-router-v2/dhcp.conf
 install -m 700 "$p/runtime" /usr/local/sbin/bobarev-router-v2
 install -m 700 "$p/performance" /usr/local/sbin/bobarev-router-performance
 install -m 700 "$p/networkd.py" /usr/local/sbin/bobarev-router-networkd.py
 install -m 700 "$p/routes.py" /usr/local/sbin/bobarev-router-routes.py
 python3 /usr/local/sbin/bobarev-router-networkd.py apply "${networkd_pairs[@]}" || exit 1
 python3 /usr/local/sbin/bobarev-router-routes.py ensure "${networkd_pairs[@]}" || exit 1
 echo '[4/6] Установка служб и правил доступа'

 rm -f /etc/systemd/system/bobarev-router-v2.service.d/override.conf
 cat > /etc/systemd/system/bobarev-router-v2.service <<'UNIT'
[Unit]
Description=Local IPv4 router
After=network-online.target tailscaled.service ufw.service
Wants=network-online.target tailscaled.service
[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=325
ExecStart=/usr/local/sbin/bobarev-router-v2 start
ExecStop=/usr/local/sbin/bobarev-router-v2 stop
[Install]
WantedBy=multi-user.target
UNIT
 if [[ "$DHCP_OWNER" == managed ]]; then
  cat > /etc/systemd/system/bobarev-router-dhcp.service <<'UNIT'
[Unit]
Description=Local DHCP and DNS
Requires=bobarev-router-v2.service
After=bobarev-router-v2.service
[Service]
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/bobarev-router-v2/dhcp.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
 else
  systemctl disable --now bobarev-router-dhcp.service 2>/dev/null || true
  rm -f /etc/systemd/system/bobarev-router-dhcp.service
 fi
 if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -E '^Status: active' >/dev/null; then
  for lan in "${LANS[@]}"; do
   [[ "$DHCP" == true ]] && ufw allow in on "$lan" to any port 67 proto udp
   ufw allow in on "$lan" to any port 53 proto udp || exit 1
   ufw allow in on "$lan" to any port 53 proto tcp || exit 1
  done
 fi
 echo '[5/6] Запуск маршрутизатора и DHCP/DNS'
 systemctl daemon-reload || exit 1
 systemctl enable bobarev-router-v2.service || exit 1
 if [[ "$DHCP_OWNER" == managed ]]; then systemctl enable bobarev-router-dhcp.service || exit 1; fi
 if ! systemctl restart bobarev-router-v2.service; then
  journalctl -u bobarev-router-v2.service -n 40 --no-pager || true
  echo 'Ошибка применения. Бэкапы и автоматический откат отключены.'; exit 1
 fi
 if [[ "$DHCP_OWNER" == managed ]]; then
  systemctl restart bobarev-router-dhcp.service || exit 1
  sleep 2
  systemctl is-active --quiet bobarev-router-dhcp.service || exit 1
 else
  systemctl is-active --quiet dnsmasq.service || exit 1
 fi
 echo '[6/6] Проверка исходящего и обратного маршрутов' 
 python3 /usr/local/sbin/bobarev-router-routes.py verify "${networkd_pairs[@]}" --out "$OUT" || exit 1
 committed=true
 rm -rf "$p"
 echo 'Применено. Маршруты в обе стороны проверены. Откройте сайт и проверьте IP с LAN-клиента.' 
 )
}
br49_netperf() {
 local c ifaces='' svc=/etc/systemd/system/bobarev-netperf.service bin=/usr/local/sbin/bobarev-netperf-apply
 local def='' wan='' cpu_mask='' ncpu
 if [[ -r /etc/bobarev-router-v2/config ]]; then
  source /etc/bobarev-router-v2/config
  def="${LANS[*]}"
 fi
 wan=$(ip -4 route show default 2>/dev/null | awk '$1=="default"{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1);exit}}')
 [[ -n "$wan" && "$wan" != tailscale0 ]] && def="$def $wan"
 ncpu=$(nproc 2>/dev/null || echo 1)
 cpu_mask=$(python3 -c "print(hex((1<<int('$ncpu'))-1)[2:])")
 while true; do
  smart_menu 'Ускорение сети' "Распределяет обработку пакетов по ядрам (RPS/XPS) и ставит fq_codel на очереди интерфейсов.
Текущие интерфейсы: ${def:-не определены}.
CPU mask: $cpu_mask.
Изменения применяются сразу; сервис включается в автозагрузку." 24 "${WT_WIDTH:-85}" 3 c 1 'Включить / обновить' 2 'Отключить и удалить' 0 'Назад' || return 0
  case "$c" in
   0) return 0 ;;
   1) br26_input 'Интерфейсы через пробел (LAN и WAN; tailscale0 не нужен)' "$def" ifaces || continue
      local ok=true i
      for i in $ifaces; do
       [[ "$i" =~ ^[A-Za-z0-9._-]+$ && -e "/sys/class/net/$i" ]] || { echo "Интерфейс $i не найден."; ok=false; }
      done
      [[ "$ok" == true ]] || { pause_enter; continue; }
      nm_yes "Настроить ускорение сети для: $ifaces?" || continue
      cat > "$bin" <<BR49_NETPERF
#!/bin/bash
set -euo pipefail
for iface in $ifaces; do
 for q in /sys/class/net/\$iface/queues/rx-*/rps_cpus; do
  [[ -e "\$q" ]] && echo "$cpu_mask" > "\$q" 2>/dev/null || true
 done
 for q in /sys/class/net/\$iface/queues/tx-*/xps_cpus; do
  [[ -e "\$q" ]] && echo "$cpu_mask" > "\$q" 2>/dev/null || true
 done
 if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")" = "bbr" ]; then
  tc qdisc replace dev "\$iface" root fq limit 30000 flow_limit 10000 2>/dev/null || tc qdisc replace dev "\$iface" root fq_codel 2>/dev/null || true
 else
  tc qdisc replace dev "\$iface" root fq_codel 2>/dev/null || true
 fi
done
BR49_NETPERF
      chmod 700 "$bin" || return 1
      cat > "$svc" <<BR49_UNIT
[Unit]
Description=Bobarev network acceleration (RPS/XPS, fq_codel)
After=network.target
[Service]
Type=oneshot
ExecStart=$bin
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
BR49_UNIT
      systemctl daemon-reload || return 1
      systemctl enable --now bobarev-netperf.service || return 1
      echo 'Применено. Проверка: tc qdisc show; cat /sys/class/net/*/queues/rx-*/rps_cpus' ;;
   2) nm_yes 'Отключить и удалить настройки ускорения сети?' || continue
      systemctl disable --now bobarev-netperf.service 2>/dev/null || true
      rm -f "$svc" "$bin"
      systemctl daemon-reload || true
      echo 'Удалено. Очереди/настройки ядер не восстанавливаются автоматически.' ;;
  esac
  pause_enter
 done
}

mod_router_sbc() {
 local choice=''
 while true; do
  smart_menu 'Режим локального маршрутизатора' 'Выберите действие.' 15 "${WT_WIDTH:-85}" 4 choice 1 'Статус' 2 'Настроить' 3 'Ускорение сети' 0 'Назад' || return 0
  case "$choice" in
   0) return 0 ;;
   1) if [[ -f /etc/bobarev-router-v2/config ]]; then
       cat /etc/bobarev-router-v2/config
       ip -4 rule show
       iptables -w 5 -nvL BR2_FWD --line-numbers 2>/dev/null || true
       local dhcp_svc="bobarev-router-dhcp.service"
       if grep -qE '^DHCP_OWNER=["'"'"']?existing["'"'"']?$' /etc/bobarev-router-v2/config 2>/dev/null; then
        dhcp_svc="dnsmasq.service"
       fi
       systemctl --no-pager -l status bobarev-router-v2.service "$dhcp_svc" || true
      else echo 'Маршрутизатор не настроен. Выберите «Настроить».'; fi
      pause_enter ;;
   2) mod_router_sbc_setup || true; pause_enter ;;
   3) br49_netperf || true; pause_enter ;;
  esac
 done
}
br29_scan() {
 python3 - "$@" <<'BR29_SCAN'
import sys,json,subprocess,ipaddress,re,pathlib

def get(args):
 try:return json.loads(subprocess.check_output(args,stderr=subprocess.DEVNULL,text=True))
 except (subprocess.SubprocessError,ValueError,OSError):return []

def suggest(links,routes,selected,preferred=None):
 blocked=[]
 for r in routes:
  dst=r.get('dst','default')
  if dst=='default' or r.get('type')=='throw':continue
  try:n=ipaddress.ip_network(dst,strict=False)
  except ValueError:continue
  if n.version!=4:continue
  # Host/local entries for selected LAN are allowed when reusing its connected network.
  if r.get('dev') in selected:continue
  blocked.append(n)
 for l in links:
  if l['ifname'] in selected:continue
  for a in l.get('addr_info',[]):
   if a.get('family')=='inet':blocked.append(ipaddress.ip_network(a['local']+'/'+str(a['prefixlen']),strict=False))
 used=[];result=[]
 for index,name in enumerate(selected):
  existing=[]
  for l in links:
   if l['ifname']==name:
    existing=[a['local'] for a in l.get('addr_info',[]) if a.get('family')=='inet' and a.get('prefixlen')==24]
  choices=[]
  if preferred and name in preferred:choices.append(preferred[name])
  choices+=existing
  choices += [f'192.168.{i}.1' for i in range(50,255)]
  choices += [f'10.77.{i}.1' for i in range(256)]
  chosen=None
  for addr in choices:
   try:x=ipaddress.IPv4Interface(addr+'/24')
   except ValueError:continue
   if not x.ip.is_private or x.ip in (x.network.network_address,x.network.broadcast_address):continue
   if any(x.network.overlaps(n) for n in blocked+used):continue
   chosen=x;break
  if chosen is None:raise ValueError('Нет свободной предложенной подсети; требуется ручной выбор')
  used.append(chosen.network);host=int(str(chosen.ip).split('.')[-1]);prefix=str(chosen.network.network_address).rsplit('.',1)[0]
  if not 50<=host<=200:lo,hi=50,200
  elif 254-host>=host-1:lo,hi=host+1,254
  else:lo,hi=1,host-1
  result.append([name,str(chosen.ip),f'{prefix}.{lo}',f'{prefix}.{hi}'])
 return result

def main():
 links=get(['ip','-j','-4','addr','show']); mainroutes=get(['ip','-j','-4','route','show','table','main']); routes=get(['ip','-j','-4','route','show','table','all'])
 wans=list(dict.fromkeys(r['dev'] for r in mainroutes if r.get('dst')=='default' and r.get('dev') and not re.match(r'^(tailscale|wg|tun|tap|warp)',r['dev'])))
 dns=[]
 try:
  text=pathlib.Path('/etc/bobarev-router-v2/dhcp.conf').read_text()
  dns=re.findall(r'^server=([0-9.]+)$',text,re.M)
 except OSError:pass
 # Stored subnet preferences are parsed as data, not executed.
 preferred={};saved=[]
 try:
  text=pathlib.Path('/etc/bobarev-router-v2/config').read_text()
  ls=re.search(r'^LANS=\(([^\n]*)\)',text,re.M);ads=re.search(r'^ADDRS=\(([^\n]*)\)',text,re.M)
  if ls and ads:
   names=re.findall(r'[A-Za-z0-9_.-]+',ls[1]);addresses=re.findall(r'\d+\.\d+\.\d+\.\d+',ads[1]);preferred=dict(zip(names,addresses));saved=names
  else:
   l=re.search(r'^LAN=([A-Za-z0-9_.-]+)',text,re.M);a=re.search(r'^ADDR=([0-9.]+)',text,re.M)
   if l and a:preferred[l[1]]=a[1];saved=[l[1]]
 except OSError:pass
 inventory=[]
 for l in links:
  n=l['ifname'];state=l.get('operstate','UNKNOWN').lower();addrs=[a['local']+'/'+str(a['prefixlen']) for a in l.get('addr_info',[]) if a.get('family')=='inet']
  path=pathlib.Path('/sys/class/net',n)
  kind='physical' if (path/'device').exists() else 'bridge' if (path/'bridge').exists() else 'virtual'
  tunnel=bool(re.match(r'^(tailscale|wg|tun|tap|warp)',n))
  role='WAN: найден основной выход' if n in wans else 'VPN: виртуальный туннель' if tunnel else 'порт/мост для клиентской сети' if kind in ('physical','bridge') else 'виртуальный интерфейс'
  status='есть линк' if state=='up' else 'нет Ethernet-статуса (для VPN нормально)' if state=='unknown' else state
  inventory.append({'name':n,'kind':kind,'tunnel':tunnel,'wan':n in wans,'saved':n in saved,'description':role+'; '+status+'; IPv4 '+(','.join(addrs) or 'нет')})
 data={'links':links,'routes':routes,'interfaces':inventory,'wans':wans,'preferred':preferred,'dns':','.join(dict.fromkeys(dns)) or '1.1.1.1,8.8.8.8','dhcp': bool(re.search(r'^dhcp-range=', pathlib.Path('/etc/bobarev-router-v2/dhcp.conf').read_text(), re.M)) if pathlib.Path('/etc/bobarev-router-v2/dhcp.conf').exists() else True}
 if sys.argv[1:2]==['suggest']:
  incoming=json.loads(sys.argv[2]);print(json.dumps(suggest(incoming['links'],incoming['routes'],sys.argv[3:],incoming.get('preferred')),ensure_ascii=False))
 else:print(json.dumps(data,ensure_ascii=False))
if __name__=='__main__':main()
BR29_SCAN
}

mod_router_sbc_setup() {
 local selected='' custom='' out='' gw='' dns='' dhcp=true node='' dev='' state='' addr='' first='' last='' mode='' answer='' p='' rows='[]' i=0 scan='' suggestions='' row='' role='' flag='' preferred='' wanted='' detected=''
 local -a options=() lans=() addrs=() starts=() ends=() exits=() fields=()
 scan=$(br29_scan) || return 1
 dns=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["dns"])' "$scan") || return 1
 smart_menu 'Режим локального маршрутизатора' 'Шаг 1. КУДА отправлять интернет-трафик клиентов? После этого выберем порт, КУДА подключены сами клиенты.' 18 "${WT_WIDTH:-85}" 3 mode WAN 'Прямо через WAN — чистый IP' EXISTING 'Через VPN / другой существующий интерфейс' CUSTOM 'Через интерфейс, который укажу вручную' || return 0
 if [[ "$mode" == CUSTOM ]]; then
  br26_input 'Имя выходного интерфейса. Если его ещё нет, применение будет отложено.' '' out || return 0
 else
  while IFS=$'\t' read -r dev role; do
   [[ -n "$dev" ]] && exits+=("$dev" "$role")
  done < <(python3 - "$scan" "$mode" <<'BR29_OUTPUTS'
import json,sys
d=json.loads(sys.argv[1])
for x in d['interfaces']:
 if x['name']=='lo':continue
 if sys.argv[2]=='WAN' and not x['wan']:continue
 print(x['name']+'\t'+x['description'])
BR29_OUTPUTS
 )
  ((${#exits[@]})) || { echo 'WAN не обнаружен. Выберите CUSTOM и укажите интерфейс и шлюз вручную.'; return 1; }
  smart_menu 'Режим локального маршрутизатора' 'Выход в интернет. WAN определён по основному маршруту системы. Для VPN состояние unknown само по себе не является ошибкой.' 21 "${WT_WIDTH:-85}" 8 out "${exits[@]}" || return 0
 fi
 [[ "$out" =~ ^[A-Za-z0-9_.-]{1,15}$ && "$out" != lo ]] || { echo 'Неверное имя выхода'; return 1; }
 if [[ "$out" == tailscale0 ]]; then
  detected=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((p.get("HostName","")+" "+next((ip for ip in p.get("TailscaleIPs",[]) if ":" not in ip),"") for p in d.get("Peer",{}).values() if p.get("ExitNode")),"не выбран"))' 2>/dev/null) || detected='не определён'
  br26_input "Exit node сейчас: $detected. Пустое поле — оставить текущий. Для смены укажите IP или имя." '' node || return 0
  [[ "$node" != -* && "$node" != *[[:space:]]* ]] || return 1
  if [[ -z "$node" ]]; then node=$(ts42_current_exit) || node=''; fi
  [[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || { echo 'Нет выбранного выхода. Укажите явный IP/hostname; пустое значение не сохраняется.'; return 1; }
  nm_yes "Сохраняем выход $node и восстанавливаем при загрузке? Для отмены позже используйте раздел Tailscale." || return 0

 else
  gw=$(ip -4 route show table main default dev "$out" 2>/dev/null | awk '/via/ && !found {print $3;found=1}') || true
  br26_input "Шлюз выхода $out. Найденный адрес уже подставлен. Для VPN без шлюза оставьте пустым." "$gw" gw || return 0
  [[ "$mode" != WAN || -n "$gw" ]] || { echo 'Для WAN нужен IPv4 шлюз'; return 1; }
 fi
 while IFS=$'\t' read -r dev role flag; do
  [[ -n "$dev" ]] && options+=("$dev" "$role" "$flag")
 done < <(python3 - "$scan" "$out" <<'BR29_LANS'
import json,sys
d=json.loads(sys.argv[1]);out=sys.argv[2]
xs=[x for x in d['interfaces'] if x['name'] not in ('lo',out) and not x['wan'] and not x['tunnel'] and x['kind'] in ('physical','bridge')]
for x in xs:
 on=x['saved'] or (len(xs)==1)
 print(x['name']+'\t'+x['description']+'\t'+('ON' if on else 'OFF'))
BR29_LANS
 )
 options+=(CUSTOM 'Ручной LAN (расширенный вариант)' OFF)
 selected=$(whiptail --checklist --separate-output "Шаг 2. ОТКУДА приходит трафик? Выберите порт к клиентам/коммутатору/второму роутеру (обычно LAN на корпусе). Выход $out исключён. Пробел = [*]. Надпись на корпусе по имени Linux достоверно не определяется; сверяйте адреса/линк. VPN и найденный WAN скрыты." 24 "${WT_WIDTH:-85}" 8 "${options[@]}" 3>&1 1>&2 2>&3) || return 0
 while IFS= read -r dev; do
  [[ -n "$dev" ]] || continue
  if [[ "$dev" == CUSTOM ]]; then
   br26_input 'LAN-интерфейсы через пробел. Ручной выбор: проверьте, что это не ваш выход в интернет/SSH.' '' custom || return 0
   local -a manual=(); read -ra manual <<< "$custom";lans+=("${manual[@]}")
  else lans+=("$dev");fi
 done <<< "$selected"
 ((${#lans[@]}>=1 && ${#lans[@]}<=16)) || { echo 'Выберите хотя бы один LAN (не более 16)'; return 1; }
 for dev in "${lans[@]}"; do
  [[ "$dev" =~ ^[A-Za-z0-9_.-]{1,15}$ && "$dev" != lo && "$dev" != "$out" ]] || { echo 'LAN и выход должны быть разными'; return 1; }
 done
 # Warn for manual reassignment of known WAN/VPN rather than silently treating it as LAN.
 wanted=$(python3 - "$scan" "${lans[@]}" <<'BR29_WARN'
import json,sys
names=set(sys.argv[2:]);d=json.loads(sys.argv[1])
print(', '.join(x['name'] for x in d['interfaces'] if x['name'] in names and (x['wan'] or x['tunnel'])))
BR29_WARN
 )
 if [[ -n "$wanted" ]]; then
  echo "Автоматическое назначение WAN/VPN ролью LAN запрещено: $wanted"; return 1
 fi
 suggestions=$(br29_scan suggest "$scan" "${lans[@]}") || return 1
 for i in "${!lans[@]}"; do
  dev=${lans[i]}; mapfile -t fields < <(python3 -c 'import json,sys;print("\n".join(json.loads(sys.argv[1])[int(sys.argv[2])][1:]))' "$suggestions" "$i")
  br26_input "LAN $dev → выход $out. Это локальный адрес маршрутизатора, НЕ публичный IP. Предложение по найденным сетям: ${fields[0]}/24. Enter — принять." "${fields[0]}" addr || return 0
  if [[ "$addr" == "${fields[0]}" ]]; then first=${fields[1]};last=${fields[2]}
  else
   row=$(python3 - "$addr" <<'BR29_POOL'
import sys,ipaddress
x=ipaddress.IPv4Interface(sys.argv[1]+'/24');h=int(str(x.ip).split('.')[-1]);p=str(x.network.network_address).rsplit('.',1)[0]
if not 50<=h<=200:a,b=50,200
elif 254-h>=h-1:a,b=h+1,254
else:a,b=1,h-1
print(f'{p}.{a} {p}.{b}')
BR29_POOL
 ) || return 1
   read -r first last <<< "$row"
  fi
  br26_input "LAN $dev: начало адресов, выдаваемых клиентам (DHCP)." "$first" first || return 0
  br26_input "LAN $dev: конец адресов, выдаваемых клиентам (DHCP)." "$last" last || return 0
  addrs+=("$addr");starts+=("$first");ends+=("$last")
 done
 local dhcp_owner=managed
 if systemctl is-active --quiet dnsmasq.service; then
  smart_menu 'Владелец DHCP/DNS' 'Сохранить работающий dnsmasq? LAN/адреса должны соответствовать его конфигу. Миграция использует новый DNS/MTU и отдельные аренды.' 18 "${WT_WIDTH:-85}" 2 dhcp_owner existing 'Сохранить существующий (рекомендуется)' managed 'Использовать отдельный DHCP/DNS скрипта' || return 0
 fi
 if [[ "$dhcp_owner" == existing ]]; then
  local dr r_start r_end answer
  dr=$(br48_dnsmasq_range) || dr=''
  if [[ "$dr" =~ ^[0-9.]+[[:space:]]+[0-9.]+$ && ${#lans[@]} -eq 1 ]]; then
   read -r r_start r_end <<< "$dr"
   if [[ "$r_start" != "${starts[0]}" || "$r_end" != "${ends[0]}" ]]; then
    smart_menu 'DHCP: диапазон dnsmasq' "В работающем dnsmasq найден диапазон: $r_start - $r_end.
В мастере указан: ${starts[0]} - ${ends[0]}.
Для режима «Сохранить существующий» рекомендуется использовать диапазон dnsmasq." 20 "${WT_WIDTH:-85}" 2 answer adopt 'Использовать диапазон dnsmasq (рекомендуется)' keep 'Оставить значения мастера' || return 0
    if [[ "$answer" == adopt ]]; then starts[0]=$r_start; ends[0]=$r_end; fi
   fi
  fi
 fi
 local mss=true dns_redirect=false
 smart_menu 'MSS clamping' 'Подрезка MSS для TCP через туннель. Уменьшает риск зависаний из-за фрагментации при MTU 1420.' 20 "${WT_WIDTH:-85}" 2 mss true 'Включить (рекомендуется)' false 'Выключить' || return 0
 smart_menu 'DNS-redirect' 'Перенаправлять UDP/TCP 53 клиентов на этот шлюз? Полезно, если на клиентах жёстко прописан DNS. Работает только в режиме маршрутизатора.' 20 "${WT_WIDTH:-85}" 2 dns_redirect true 'Включить' false 'Выключить (по умолчанию)' || return 0
 if [[ "$dhcp_owner" == managed ]]; then
 local -a dhcp_options=()
 if [[ $(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["dhcp"])' "$scan") == False ]]; then
  dhcp_options=(no 'Нет — сохранить ручную адресацию' yes 'Да — включить DHCP')
 else dhcp_options=(yes 'Да — DHCP (обычный вариант)' no 'Нет — адреса клиентов задам вручную'); fi
 smart_menu 'Режим локального маршрутизатора' 'Выдавать клиентам адреса автоматически? Прежний режим предложен первым.' 16 "${WT_WIDTH:-85}" 2 answer "${dhcp_options[@]}" || return 0
 [[ "$answer" == no ]] && dhcp=false
 br26_input 'DNS для клиентов: ранее настроенные адреса или стандартное предложение. Enter — принять.' "$dns" dns || return 0;dns=${dns// /}
 else
  dhcp=true
  echo "Существующие DHCP/DNS/MTU не изменяются."
 fi
 rows=$(python3 - "${lans[*]}" "${addrs[*]}" "${starts[*]}" "${ends[*]}" <<'BR26_ROWS'
import sys,json
print(json.dumps(list(zip(*(s.split() for s in sys.argv[1:])))))
BR26_ROWS
 ) || return 1
 python3 - "$out" "$gw" "$dns" "$dhcp" "$rows" <<'BR26_VALIDATE'
import ipaddress,json,subprocess,sys,re
out,gw,dns,enable,config=sys.argv[1:]
d=json.loads(config);nets=[]
valid=lambda n:bool(re.fullmatch(r'[A-Za-z0-9_.-]{1,15}',n)) and n!='lo'
if not valid(out):raise SystemExit('Неверное имя выхода')
if not 1<=len(d)<=16:raise SystemExit('Выберите от 1 до 16 LAN')
for n in dns.split(','):ipaddress.IPv4Address(n.strip())
if gw:ipaddress.IPv4Address(gw)
seen=set()
for row in d:
 lan,addr,start,end=row
 if not valid(lan) or lan==out or lan in seen:raise SystemExit('LAN и выход должны быть разными, без повторов')
 seen.add(lan);x=ipaddress.IPv4Interface(addr+'/24');a,b=map(ipaddress.IPv4Address,(start,end))
 if x.ip in (x.network.network_address,x.network.broadcast_address):raise SystemExit('Адрес LAN совпадает с сетью/broadcast')
 if not (a in x.network and b in x.network and int(a)<=int(b)):raise SystemExit('Неверный диапазон DHCP')
 if a==x.network.network_address or b==x.network.broadcast_address or int(a)<=int(x.ip)<=int(b):raise SystemExit('Пул включает адрес LAN/сети/broadcast')
 if any(x.network.overlaps(n) for n in nets):raise SystemExit('Сети LAN пересекаются')
 nets.append(x.network)
for link in json.loads(subprocess.check_output(['ip','-j','-4','addr','show'])):
 if link['ifname'] in seen:continue
 for a in link.get('addr_info',[]):
  n=ipaddress.ip_network(a['local']+'/'+str(a['prefixlen']),strict=False)
  if any(n.overlaps(x) for x in nets):raise SystemExit('LAN пересекается с '+link['ifname'])
for route in json.loads(subprocess.check_output(['ip','-j','-4','route','show','table','all'])):
 if route.get('dev') in seen or route.get('type')=='throw' or route.get('dst','default')=='default':continue
 try:n=ipaddress.ip_network(route['dst'],strict=False)
 except (ValueError,KeyError):continue
 if any(n.overlaps(x) for x in nets):raise SystemExit('LAN пересекается с видимым маршрутом '+str(n))

BR26_VALIDATE
 [[ $? == 0 ]] || return 1
 nm_yes "Сохранить и применить? LAN: ${lans[*]}; адреса: ${addrs[*]}; выход: $out; шлюз: ${gw:-нет}; DHCP: $dhcp; DNS: $dns. IPv6 клиентов блокируется. Нет авто-WAN, бэкапов и автоотката. Закреплены PMTU=1, очереди/RPS/XPS f, DHCP MTU=1280, MSS clamp и возврат LAN по правилу 5090 -> main. Отсутствующие интерфейсы НЕ создаются: применение отложится. Автоподбор проверяет только видимые ОС сети, не скрытые подсети за другими роутерами. LAN закрепляется в networkd. Применение может кратковременно прервать LAN и SSH; на старых networkctl reload может затронуть WAN. Смена exit node влияет на выход хоста." || return 0
 install -d -m 700 /etc/bobarev-router-v2/pending
 p=/etc/bobarev-router-v2/pending
 {
  printf 'LANS=('; printf ' %q' "${lans[@]}"; printf ' )\n'
  printf 'ADDRS=('; printf ' %q' "${addrs[@]}"; printf ' )\n'
  printf 'STARTS=('; printf ' %q' "${starts[@]}"; printf ' )\n'
  printf 'ENDS=('; printf ' %q' "${ends[@]}"; printf ' )\n'
  printf 'OUT=%q\nGATEWAY=%q\nDHCP=%q\nEXIT_NODE=%q\n' "$out" "$gw" "$dhcp" "$node"
  printf 'DHCP_OWNER=%q\n' "$dhcp_owner"
  printf 'MSS_CLAMP=%q\n' "${mss:-true}"
  printf 'DNS_REDIRECT=%q\n' "${dns_redirect:-false}"
 } > "$p/config"
 {
  printf 'port=53\nbind-dynamic\nno-resolv\ndhcp-leasefile=/var/lib/misc/bobarev-router.leases\n'
  if [[ "$dhcp" == true ]]; then printf 'dhcp-option=26,1280\n'; fi
  for i in "${!lans[@]}"; do
   printf 'interface=%s\n' "${lans[i]}"
   if [[ "$dhcp" == true ]]; then
    printf 'dhcp-range=set:lan%s,%s,%s,255.255.255.0,12h\n' "$i" "${starts[i]}" "${ends[i]}"
    printf 'dhcp-option=tag:lan%s,3,%s\n' "$i" "${addrs[i]}"
    printf 'dhcp-option=tag:lan%s,6,%s\n' "$i" "$dns"
   fi
  done
  local -a resolvers=(); IFS=',' read -ra resolvers <<< "$dns"
  for dev in "${resolvers[@]}"; do printf 'server=%s\n' "$dev"; done
 } > "$p/dhcp.conf"
 cat > "$p/performance" <<'BR32_PERFORMANCE'
#!/bin/bash
set -euo pipefail
PERF_SYSCTL=/etc/sysctl.d/99-router-performance.conf
mkdir -p /etc/sysctl.d
cat > "$PERF_SYSCTL" <<'FIXED_SYSCTL'
# Fixed local-router performance settings
net.ipv4.ip_forward = 1
net.ipv4.ip_forward_use_pmtu = 1
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = 10000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
FIXED_SYSCTL
profile_errors=0
if ! sysctl -p "$PERF_SYSCTL"; then echo 'Часть sysctl не применена.' >&2; profile_errors=1; fi
source /etc/bobarev-router-v2/config
all_devs=("${LANS[@]}" "$OUT")
while read -r dev; do [[ -n "$dev" ]] && all_devs+=("$dev"); done < <(ip -4 route show table main default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[[ -d /sys/class/net/tailscale0 ]] && all_devs+=(tailscale0)
cpu_mask=$(python3 -c "import os; n=os.cpu_count() or 1; print(hex((1<<min(max(n,1),64))-1)[2:])" 2>/dev/null || echo "f")
declare -A seen=()
for dev in "${all_devs[@]}"; do
 [[ -n "$dev" && "$dev" != lo && -z "${seen[$dev]:-}" ]] || continue
 seen[$dev]=1
 [[ -d "/sys/class/net/$dev" ]] || continue
 if ! ip link set dev "$dev" txqueuelen 10000; then profile_errors=1; fi
 for q in /sys/class/net/"$dev"/queues/rx-*; do
  [[ -d "$q" && -e "$q/rps_cpus" ]] || continue
  if ! { printf '%s\n' "$cpu_mask" > "$q/rps_cpus"; } 2>/dev/null; then echo "RPS недоступен: $q" >&2; profile_errors=1; fi
 done
 if [[ "$dev" != tailscale* && "$dev" != tun* && "$dev" != wg* && "$dev" != warp* ]]; then
  for q in /sys/class/net/"$dev"/queues/tx-*; do
   [[ -d "$q" && -w "$q/xps_cpus" ]] || continue
   { printf '%s\n' "$cpu_mask" > "$q/xps_cpus"; } 2>/dev/null || true
  done
 fi
 done
if ! iptables -w 5 -t mangle -C FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
 iptables -w 5 -t mangle -I FORWARD 1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
if ((profile_errors)); then echo 'Профиль применён частично; предупреждения выше. Автоотката нет.' >&2; exit 1; fi
echo 'Фиксированные параметры применены; скорость проверьте отдельно.'
BR32_PERFORMANCE
 cat > "$p/networkd.py" <<'BR33_NETWORKD'
#!/usr/bin/env python3
import argparse,ipaddress,os,pathlib,re,subprocess,sys
ROOT=pathlib.Path('/etc/systemd/network')
MARK='# BOBAREV_ROUTER_NETWORKD_33'
def run(args):return subprocess.run(args,text=True,capture_output=True,env=dict(os.environ,LC_ALL='C',SYSTEMD_COLORS='0'))
def rows(values):
 result=[];nets=[];seen=set()
 for value in values:
  dev,addr=value.split('=',1);x=ipaddress.IPv4Interface(addr+'/24')
  if not re.fullmatch(r'[A-Za-z0-9_.-]{1,15}',dev) or dev=='lo' or dev in seen:raise ValueError('Неверный LAN')
  if x.ip in (x.network.network_address,x.network.broadcast_address) or any(x.network.overlaps(n) for n in nets):raise ValueError('Неверная/пересекающаяся сеть')
  result.append((dev,str(x.ip)));nets.append(x.network);seen.add(dev)
 if not result:raise ValueError('Нет LAN')
 return result
def filename(dev):return '05-bobarev-lan-'+dev+'.network'
def content(dev,addr):
 net=str(ipaddress.ip_interface(addr+'/24').network)
 return f'''{MARK}
[Match]
Name={dev}

[Link]
RequiredForOnline=no

[Network]
Address={addr}/24
DHCP=no
IPv6AcceptRA=no
LinkLocalAddressing=no
ConfigureWithoutCarrier=yes
IgnoreCarrierLoss=yes

[RoutingPolicyRule]
To={net}
Table=main
Priority=5090
'''
def current_file(dev):
 p=run(['networkctl','status',dev,'--no-pager']);m=re.search(r'^\s*Network File:\s*(.+)$',p.stdout,re.M)
 return pathlib.Path(m[1].strip()) if m and m[1].strip().startswith('/') else None

def check(data):
 if run(['systemctl','is-active','--quiet','systemd-networkd.service']).returncode:raise ValueError('systemd-networkd не активен; текущая настройка не изменена.')
 if run(['systemctl','is-active','--quiet','NetworkManager.service']).returncode==0:
  for dev,addr in data:
   p=run(['nmcli','-g','GENERAL.NM-MANAGED','device','show',dev])
   if p.returncode or p.stdout.strip().lower() not in ('no','нет'):raise ValueError('LAN управляется NetworkManager либо статус неизвестен: '+dev)
 for dev,addr in data:
  f=ROOT/filename(dev)
  if f.exists() and MARK not in f.read_text():raise ValueError('Файл занят чужой конфигурацией: '+str(f))
  old=current_file(dev)
  if old and old.name<filename(dev) and old!=f:raise ValueError('Более ранний .network перекрывает LAN: '+str(old))

def apply(data):
 check(data);ROOT.mkdir(parents=True,exist_ok=True);changed=[]
 for dev,addr in data:
  f=ROOT/filename(dev);text=content(dev,addr)
  if not f.exists() or f.read_text()!=text:f.write_text(text);f.chmod(0o644);changed.append(dev)
 if not changed:print('LAN .network уже актуальны; reload networkd не выполняется.');return
 args=['networkctl','reload']
 if '--no-reconfigure' in run(['networkctl','--help']).stdout:args.append('--no-reconfigure')
 else:print('Внимание: reload старого networkctl может затронуть другие изменённые сетевые файлы.')
 p=run(args)
 if p.returncode:raise RuntimeError(p.stderr.strip())
 for dev in changed:
  p=run(['networkctl','reconfigure',dev])
  if p.returncode:raise RuntimeError(p.stderr.strip())
  f=current_file(dev)
  if f is None or f.name!=filename(dev):raise RuntimeError('Не подтверждён LAN-файл '+dev+'; автоотката нет.')
  print('LAN networkd: '+dev+'; '+str(ROOT/filename(dev)))
def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['check','apply']);p.add_argument('pairs',nargs='+');a=p.parse_args();data=rows(a.pairs)
 if a.action=='check':check(data);print('Проверка networkd пройдена')
 else:apply(data)
if __name__=='__main__':
 try:main()
 except (ValueError,RuntimeError,OSError) as e:print('ОШИБКА networkd: '+str(e),file=sys.stderr);sys.exit(1)
BR33_NETWORKD
 cat > "$p/routes.py" <<'BR34_ROUTES'
#!/usr/bin/env python3
import argparse,ipaddress,json,pathlib,re,subprocess,sys
ROOT=pathlib.Path('/etc/systemd/network')
MARK='# BOBAREV_ROUTER_NETWORKD_33'
PREF=5090
def run(args):return subprocess.run(args,text=True,capture_output=True)
def ipjson(args):
 p=run(['ip','-j','-4']+args)
 if p.returncode:raise RuntimeError(p.stderr.strip())
 return json.loads(p.stdout)
def prefix(rule,field):
 raw=rule.get(field,'all');length=rule.get(field+'len')
 try:
  if raw in ('all','default',None,''):
   return ipaddress.IPv4Network('0.0.0.0/0') if length is None or int(length)==0 else None
  raw=str(raw)
  if '/' in raw:
   value=ipaddress.IPv4Network(raw,strict=False)
   if length is not None and value.prefixlen!=int(length):return None
   return value
  return ipaddress.IPv4Network(raw+'/'+str(32 if length is None else int(length)),strict=False)
 except (ValueError,TypeError):return None

def table(rule):
 value=rule.get('table');return 'main' if value in ('main',254,'254') else str(value)
def priority(rule):
 try:return int(rule.get('priority',-1))
 except (ValueError,TypeError):return -1
def plain(rule,allowed):
 return not(set(rule)-allowed) and not rule.get('flags') and rule.get('action','to_tbl') in ('to_tbl','lookup')
def matches(rule,net):
 allowed={'priority','src','srclen','dst','dstlen','table','protocol','flags','action','family'}
 return (priority(rule)==PREF and prefix(rule,'src')==ipaddress.IPv4Network('0.0.0.0/0')
 and prefix(rule,'dst')==ipaddress.IPv4Network(net,strict=False) and table(rule)=='main' and plain(rule,allowed))
def outgoing_matches(rule,lan,index):
 allowed={'priority','src','srclen','table','iif','iifname','protocol','flags','action','family'}
 iface=rule.get('iif',rule.get('iifname'))
 if 'iif' in rule and 'iifname' in rule and rule['iif']!=rule['iifname']:return False
 return (priority(rule)==5100+index and iface==lan and table(rule)==str(199+index)
 and prefix(rule,'src')==ipaddress.IPv4Network('0.0.0.0/0') and plain(rule,allowed))
def parse(pairs):
 result=[];seen=set();nets=[]
 for item in pairs:
  lan,addr=item.split('=',1);x=ipaddress.IPv4Interface(addr+'/24')
  if not re.fullmatch(r'[A-Za-z0-9_.-]{1,15}',lan) or lan=='lo' or lan in seen:raise ValueError('Неверное имя LAN')
  if x.ip in (x.network.network_address,x.network.broadcast_address) or any(x.network.overlaps(n) for n in nets):raise ValueError('Неверная/пересекающаяся сеть LAN')
  result.append((lan,str(x.ip),str(x.network)));seen.add(lan);nets.append(x.network)
 if not result:raise ValueError('Нет LAN')
 return result
def owned_nets():
 result=set()
 for f in ROOT.glob('05-bobarev-lan-*.network'):
  text=f.read_text()
  if MARK not in text:continue
  for addr in re.findall(r'^Address=([0-9.]+/24)\s*$',text,re.M):result.add(str(ipaddress.ip_interface(addr).network))
 return result

def check(data):
 rules=ipjson(['rule','show']);allowed={row[2] for row in data}|owned_nets()
 for r in rules:
  if priority(r)==5090 and not any(matches(r,n) for n in allowed):raise ValueError('Приоритет 5090 занят другим правилом: '+json.dumps(r,ensure_ascii=False)+'. Ничего не удаляется.')
 for i,(lan,addr,net) in enumerate(data):
  for r in rules:
   if priority(r)==5100+i and not outgoing_matches(r,lan,i):raise ValueError('Занят приоритет '+str(5100+i)+': '+json.dumps(r,ensure_ascii=False))
 return rules

def ensure(data):
 rules=check(data)
 for lan,addr,net in data:
  if not any(matches(r,net) for r in rules):
   p=run(['ip','-4','rule','add','pref','5090','to',net,'lookup','main'])
   if p.returncode:raise RuntimeError(p.stderr.strip())
   rules.append({'priority':5090,'src':'all','dst':net,'table':'main'})
  print('Возврат LAN: '+net+' -> main, приоритет 5090')
def verify(data,out):
 for lan,addr,net in data:
  n=ipaddress.ip_network(net);client=str(n.network_address+50)
  if client==addr:client=str(n.network_address+51)
  for mark in (None,'0x40000'):
   args=['route','get',client,'from','1.1.1.1','iif',out]
   if mark:args+=['mark',mark]
   r=ipjson(args)
   if not r or r[0].get('dev')!=lan:raise RuntimeError('Неверный обратный маршрут: '+json.dumps(r))
   print('Возврат '+client+(' mark='+mark if mark else '')+' -> '+lan+': OK')
  r=ipjson(['route','get','1.1.1.1','from',client,'iif',lan])
  if not r or r[0].get('dev')!=out:raise RuntimeError('Неверный исходящий маршрут: '+json.dumps(r))
  print('Выход '+lan+' -> '+out+': OK')
def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['check','ensure','verify']);p.add_argument('--out');p.add_argument('pairs',nargs='+');a=p.parse_args();data=parse(a.pairs)
 if a.action=='check':check(data);print('Приоритеты правил проверены')
 elif a.action=='ensure':ensure(data)
 else:
  if not a.out:raise ValueError('Нужен --out')
  verify(data,a.out)
if __name__=='__main__':
 try:main()
 except (ValueError,RuntimeError,OSError) as e:print('ОШИБКА маршрутизации: '+str(e),file=sys.stderr);sys.exit(1)
BR34_ROUTES
 cat > "$p/runtime" <<'BR26_RUNTIME'
#!/bin/bash
set -euo pipefail
[[ -r /etc/bobarev-router-v2/config ]] || { echo 'Маршрутизатор не настроен. Выберите «Настроить».' >&2; exit 1; }
source /etc/bobarev-router-v2/config
networkd_pairs=()
for i in "${!LANS[@]}"; do networkd_pairs+=("${LANS[i]}=${ADDRS[i]}"); done
clean() {
 for spec in 'filter FORWARD BR2_FWD' 'nat POSTROUTING BR2_NAT' 'mangle FORWARD BR2_MSS'; do
  read -r table parent chain <<< "$spec"
  while iptables -w 5 -t "$table" -D "$parent" -j "$chain" 2>/dev/null; do :; done
  iptables -w 5 -t "$table" -F "$chain" 2>/dev/null || true
  iptables -w 5 -t "$table" -X "$chain" 2>/dev/null || true
 done
 while iptables -w 5 -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
 for i in "${!LANS[@]}"; do
  for proto in udp tcp; do
   while iptables -w 5 -t nat -D PREROUTING -i "${LANS[i]}" -p "$proto" --dport 53 -j DNAT --to-destination "${ADDRS[i]}" 2>/dev/null; do :; done
  done
 done
 for i in "${!LANS[@]}"; do
  lan=${LANS[i]}; table=$((199+i)); pref=$((5100+i))
  while ip -4 rule del pref "$pref" iif "$lan" lookup "$table" 2>/dev/null; do :; done
  ip -4 route flush table "$table" 2>/dev/null || true
  while ip6tables -w 5 -D FORWARD -i "$lan" -j DROP 2>/dev/null; do :; done
 done
}
if [[ ${1:-} == stop ]]; then clean; exit 0; fi
# Fail-closed guard for forwarded LAN traffic during startup; INPUT remains available.
guard_clean() {
 for bin in iptables ip6tables; do
  while "$bin" -w 5 -D FORWARD -j BR42_WAIT 2>/dev/null; do :; done
  "$bin" -w 5 -F BR42_WAIT 2>/dev/null || true
  "$bin" -w 5 -X BR42_WAIT 2>/dev/null || true
 done
}
for bin in iptables ip6tables; do
 "$bin" -w 5 -N BR42_WAIT 2>/dev/null || "$bin" -w 5 -S BR42_WAIT >/dev/null
 for lan in "${LANS[@]}"; do
  "$bin" -w 5 -C BR42_WAIT -i "$lan" -j DROP 2>/dev/null || "$bin" -w 5 -A BR42_WAIT -i "$lan" -j DROP
 done
 while "$bin" -w 5 -D FORWARD -j BR42_WAIT 2>/dev/null; do :; done
 "$bin" -w 5 -I FORWARD 1 -j BR42_WAIT
done
if [[ "$OUT" == tailscale0 ]]; then
 [[ -n "${EXIT_NODE:-}" ]] || { echo 'EXIT_NODE пуст: откройте мастер и сохраните явный выход.'; guard_clean; exit 1; }
 for attempt in {1..60}; do
  state=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null) || state=''
  [[ "$state" == Running ]] && break
  sleep 2
 done
 [[ "${state:-}" == Running ]] || { echo 'Нет Running. Guard снят: без правил forwarding LAN не получит интернет, но и не останется в чёрной дыре.'; guard_clean; exit 1; }
 peer_ready=false
 for attempt in {1..60}; do
  tailscale status 2>/dev/null | grep -q -- "$EXIT_NODE" && { peer_ready=true; break; }
  sleep 2
 done
 [[ "$peer_ready" == true ]] || { echo 'Exit node не появился в netmap за 120 секунд. Guard снят; повторите позже или используйте WAN-режим.'; guard_clean; exit 1; }
 current=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((ip for p in (d.get("Peer") or {}).values() if p.get("ExitNode") for ip in p.get("TailscaleIPs",[]) if ":" not in ip),""))') || current=''
 if [[ "$current" != "$EXIT_NODE" ]]; then
  tailscale set --exit-node="$EXIT_NODE" --exit-node-allow-lan-access=true || { echo 'Не удалось применить exit node. Guard снят.'; guard_clean; exit 1; }
 fi
 ready=false
 for attempt in {1..60}; do
  if ip -4 route show table 52 default 2>/dev/null | grep -Eq '^default dev tailscale0([[:space:]]|$)'; then ready=true; break; fi
  sleep 2
 done
 [[ "$ready" == true ]] || { echo 'Нет маршрута exit node. Guard снят.'; guard_clean; exit 1; }
fi
# Missing custom interfaces are not created implicitly.
for dev in "${LANS[@]}" "$OUT"; do ip link show dev "$dev" >/dev/null || { echo "Отсутствует интерфейс $dev. Сначала создайте его."; exit 1; }; done
if [[ "$OUT" == tailscale0 ]]; then
 ip -4 route show table 52 default | grep -E '^default[[:space:]]+dev[[:space:]]+tailscale0([[:space:]]|$)' >/dev/null || { echo 'Exit node не активен'; exit 1; }
fi
python3 /usr/local/sbin/bobarev-router-routes.py check "${networkd_pairs[@]}"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
for dev in all "${LANS[@]}" "$OUT"; do sysctl -w "net.ipv4.conf.$dev.rp_filter=0" >/dev/null; done
clean
iptables -w 5 -N BR2_FWD
iptables -w 5 -t nat -N BR2_NAT
iptables -w 5 -t mangle -N BR2_MSS
for i in "${!LANS[@]}"; do
 lan=${LANS[i]}; addr=${ADDRS[i]}; net=${addr%.*}.0/24; table=$((199+i))
 ip link set dev "$lan" up
 ip address replace "$addr/24" dev "$lan"
 ip -4 route replace table "$table" "$net" dev "$lan" scope link
 if [[ -n "$GATEWAY" ]]; then
  ip -4 route replace table "$table" default via "$GATEWAY" dev "$OUT" onlink
 else
  ip -4 route replace table "$table" default dev "$OUT"
 fi
 ip -4 route add table "$table" unreachable default metric 32760
 iptables -w 5 -A BR2_FWD -i "$lan" -o "$OUT" -s "$net" -j ACCEPT
 iptables -w 5 -A BR2_FWD -i "$lan" -j DROP
 iptables -w 5 -A BR2_FWD -o "$lan" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
 iptables -w 5 -t nat -A BR2_NAT -s "$net" -o "$OUT" -j MASQUERADE
 ip6tables -w 5 -I FORWARD 1 -i "$lan" -j DROP
 done
iptables -w 5 -I FORWARD 2 -j BR2_FWD
iptables -w 5 -t nat -I POSTROUTING 1 -j BR2_NAT
iptables -w 5 -t mangle -I FORWARD 1 -j BR2_MSS
python3 /usr/local/sbin/bobarev-router-routes.py ensure "${networkd_pairs[@]}"
for i in "${!LANS[@]}"; do
 ip -4 rule add pref "$((5100+i))" iif "${LANS[i]}" lookup "$((199+i))"
 ip -4 route get 1.1.1.1 from "${STARTS[i]}" iif "${LANS[i]}"
done
if ! /usr/local/sbin/bobarev-router-performance; then
 echo 'ВНИМАНИЕ: профиль производительности применён частично; основная маршрутизация настроена.' >&2
fi
python3 /usr/local/sbin/bobarev-router-routes.py verify "${networkd_pairs[@]}" --out "$OUT"
for bin in iptables ip6tables; do
 while "$bin" -w 5 -D FORWARD -j BR42_WAIT 2>/dev/null; do :; done
 "$bin" -w 5 -F BR42_WAIT
 "$bin" -w 5 -X BR42_WAIT
done
if [[ "${MSS_CLAMP:-true}" == true ]]; then
 iptables -w 5 -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -w 5 -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
else
 while iptables -w 5 -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
fi
if [[ "${DNS_REDIRECT:-false}" == true ]]; then
 for i in "${!LANS[@]}"; do
  for proto in udp tcp; do
   iptables -w 5 -t nat -C PREROUTING -i "${LANS[$i]}" -p "$proto" --dport 53 -j DNAT --to-destination "${ADDRS[$i]}" 2>/dev/null || iptables -w 5 -t nat -A PREROUTING -i "${LANS[$i]}" -p "$proto" --dport 53 -j DNAT --to-destination "${ADDRS[$i]}"
  done
 done
else
 for i in "${!LANS[@]}"; do
  for proto in udp tcp; do
   while iptables -w 5 -t nat -D PREROUTING -i "${LANS[$i]}" -p "$proto" --dport 53 -j DNAT --to-destination "${ADDRS[$i]}" 2>/dev/null; do :; done
  done
 done
fi
BR26_RUNTIME
 chmod 600 "$p/config" "$p/dhcp.conf" "$p/runtime" "$p/performance" "$p/networkd.py" "$p/routes.py"
 br26_apply
}

br_snapshot() {
 local d="/root/bobarev-network-backup-$(date +%Y%m%d-%H%M%S)-$$"
 mkdir -m 700 "$d" || return 1
 cp -a /etc/ufw "$d/" 2>/dev/null || true
 cp -a /etc/dnsmasq.conf /etc/dnsmasq.d /etc/bobarev-router-v2 "$d/" 2>/dev/null || true
 iptables-save > "$d/iptables.txt"
 ip6tables-save > "$d/ip6tables.txt"
 ip -4 rule > "$d/ip-rule.txt"
 ip -4 route show table all > "$d/routes.txt"
 systemctl list-unit-files > "$d/units.txt"
 command -v tailscale >/dev/null && tailscale debug prefs > "$d/tailscale-prefs.json" 2>/dev/null || true
 echo "Резервная копия: $d (содержит приватные настройки; не публикуйте)"
}

ts_is_online() {
 command -v tailscale >/dev/null 2>&1 || return 1
 local js state online
 js="$(tailscale status --json 2>/dev/null)" || return 1
 [[ -n "$js" ]] || return 1
 state="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' <<<"$js" 2>/dev/null)" || return 1
 [[ "$state" == "Running" ]] || return 1
 online="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(bool(d.get("Self",{}).get("Online",False))).lower())' <<<"$js" 2>/dev/null)" || return 1
 [[ "$online" == "true" ]]
}

ts_wait_exit_node() {
 local i
 for i in $(seq 1 90); do
  ip -4 route show table 52 default 2>/dev/null | grep -E '^default[[:space:]]+dev[[:space:]]+tailscale0([[:space:]]|$)' >/dev/null && return 0
  sleep 1
 done
 return 1
}

ts_exit_node_works() {
 /usr/bin/curl -4 --noproxy '*' --connect-timeout 5 --max-time 10 -fsS https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1
}

# BOBAREV SHELL: isolated fail-fast network controller.
install_bobarev_mullvad_runtime() {
 local lib=/usr/local/lib/bobarev-shell
 [[ $EUID == 0 ]] || { echo 'Нужен root.';return 1; }
 if [[ -f /var/lib/bobarev-shell-mullvad/pending && -x "$lib/mullvad.sh" ]];then
  echo 'Незавершённая транзакция: используйте пункт восстановления. Контроллер сохранён.'
  return 0
 fi
 install -d -m 700 "$lib"
 cat > "$lib/mullvad.sh.new" <<'BOBAREV_ENGINE_3146'
#!/usr/bin/env bash
# BOBAREV SHELL 3.14.55
set -Eeuo pipefail
umask 077
export PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BASE=/var/lib/bobarev-shell-mullvad
LIB=/usr/local/lib/bobarev-shell
SELF=$LIB/mullvad.sh
CFG=$BASE/config
PENDING=$BASE/pending
PREF=1050
MARK=0x80000000/0x80000000
TX=''
log(){ printf '[BOBAREV SHELL] %s\n' "$*"; }
die(){ log "ОШИБКА: $*" >&2; exit 1; }
root(){ [[ $EUID == 0 && -d /run/systemd/system ]] || die 'Нужны root и systemd.'; }
snap_file(){
 python3 - "$TX" "$1" <<'PY_SNAP'
import json,pathlib,shutil,sys,os
root=pathlib.Path(sys.argv[1]);p=pathlib.Path(sys.argv[2]);manifest=root/'manifest.json'
m=json.loads(manifest.read_text()) if manifest.exists() else []
if any(x['path']==str(p) for x in m):sys.exit(0)
target=root/'files'/str(p).lstrip('/');target.parent.mkdir(parents=True,exist_ok=True)
exists=os.path.lexists(p)
if exists:
 if p.is_symlink():target.symlink_to(os.readlink(p))
 elif p.is_dir():shutil.copytree(p,target,symlinks=True)
 else:shutil.copy2(p,target)
m.append({'path':str(p),'exists':exists});manifest.write_text(json.dumps(m,indent=2))
PY_SNAP
}
unit_state(){
 local a e
 a=$(systemctl is-active "$1" 2>/dev/null) || true
 e=$(systemctl is-enabled "$1" 2>/dev/null) || true
 printf '%s\t%s\t%s\n' "$1" "$a" "$e" >> "$TX/services.tsv"
}
preflight(){
 root
 command -v apt-get >/dev/null || die 'Поддерживаются Debian/Ubuntu с apt.'
 command -v python3 >/dev/null || { apt-get update; apt-get install -y python3; }
 [[ ! -f /etc/bobarev-router-v2/config && ! -f /etc/default/bobarev-router ]] || die 'LAN-router обнаружен. Этот мастер предназначен для VPS, не LAN.'
 python3 - <<'PY_NET'
import json,subprocess,sys
r=json.loads(subprocess.check_output(['ip','-j','-4','route','show','table','main','default']))
if len(r)!=1 or not r[0].get('dev') or r[0]['dev'].startswith(('tailscale','wg','tun','warp')):sys.exit('Нужен один обычный WAN default в table main.')
PY_NET
 WAN=$(ip -j -4 route show table main default | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["dev"])')
 [[ "$WAN" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die 'Неверное имя WAN.'
 if [[ ! -f "$CFG" ]]; then
  if ip -4 rule show | grep -q "^$PREF:"; then die "Приоритет $PREF занят."; fi
  if command -v iptables-save >/dev/null && iptables-save -t mangle | grep -qE 'BMGE_|0x80000000'; then die 'Конфликт mark/цепочек: нужен аудит.'; fi
 fi
 [[ ! -e "$PENDING" ]] || die 'Незавершённая транзакция: сначала восстановление.'
 [[ ! -f /etc/naiveproxy/mesh-upstream.port && ! -f /etc/naiveproxy/mesh-paused ]] || die 'Сначала штатно отключите mesh/paused режим NaiveProxy.'
 log "WAN=$WAN. Держите консоль провайдера открытой; не перезагружайте VPS до KEEP."
}
validate_dns(){
 python3 - "$1" <<'PY_DNS'
import sys,ipaddress,re
v=sys.argv[1]
try:ip,name=v.split('#')
except ValueError:
 ip,name=v,None
if ipaddress.ip_address(ip).version!=4:sys.exit('Нужен IPv4 DNS')
if name is not None and not re.fullmatch(r'(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?',name):sys.exit('Неверное TLS-имя')
PY_DNS
}
transaction(){
 mkdir -p "$BASE/transactions"
 TX=$(mktemp -d "$BASE/transactions/tx-$(date +%Y%m%d-%H%M%S)-XXXXXX")
 chmod 700 "$TX"
 for p in /etc/ufw /etc/default/ufw /etc/resolv.conf /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d /etc/caddy /etc/naiveproxy /etc/default/bobarev-cascade /usr/local/bin/caddy /etc/systemd/system/caddy.service /etc/systemd/system/naive-return-route.service /usr/local/sbin/bobarev-mullvad-return-route.sh /etc/systemd/system/bobarev-shell-return.service /etc/systemd/system/bobarev-shell-dns.service "$CFG" "$BASE/client-links.txt"; do snap_file "$p"; done
 for u in ufw.service caddy.service systemd-resolved.service naive-return-route.service bobarev-shell-return.service bobarev-shell-dns.service; do unit_state "$u"; done
 if command -v resolvectl >/dev/null;then
  python3 - "$TX" "$WAN" <<'PY_LINK_SNAPSHOT'
import subprocess,json,sys,pathlib
result={}
for setting in ('dns','domain','default-route'):
 p=subprocess.run(['resolvectl',setting,sys.argv[2]],text=True,capture_output=True)
 if p.returncode==0:result[setting]=p.stdout.split('):',1)[-1].strip().split()
pathlib.Path(sys.argv[1],'link-dns.json').write_text(json.dumps({'wan':sys.argv[2],'settings':result}))
PY_LINK_SNAPSHOT
 fi
 ip -4 rule show > "$TX/ip-rules.txt"
 ip -4 route show table all > "$TX/routes.txt"
 if command -v iptables-save >/dev/null; then iptables-save > "$TX/iptables.txt"; fi
 for k in net.ipv4.conf.all.rp_filter net.ipv4.conf."$WAN".rp_filter; do printf '%s\t%s\n' "$k" "$(sysctl -n "$k")" >> "$TX/sysctls.tsv"; done
 if command -v tailscale >/dev/null; then tailscale debug prefs > "$TX/prefs.json"; tailscale status --json > "$TX/status.json"; fi
 trap 'cleanup_exit "$?"' EXIT
 printf '%s\n' "$$" > "$TX/wizard.pid"
 python3 - "$$" "$TX" <<'PY_WRITER_ID'
import pathlib,sys,json
pid=int(sys.argv[1]);p=pathlib.Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()
pathlib.Path(sys.argv[2],'writer-id.json').write_text(json.dumps({'pid':pid,'start':p[19],'boot':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()}))
PY_WRITER_ID
 printf '%s\n' "$TX" > "$PENDING"
 printf '%s\n' "$TX" > "$BASE/latest"
 cat > /etc/systemd/system/bobarev-shell-rollback.service <<'UNIT_ROLL'
[Unit]
Description=Bobarev BOBAREV SHELL transaction recovery
[Service]
Type=oneshot
ExecStart=/usr/local/lib/bobarev-shell/mullvad.sh recover pending
UNIT_ROLL
 cat > /etc/systemd/system/bobarev-shell-rollback.timer <<'UNIT_TIMER'
[Unit]
Description=Bobarev transaction watchdog
[Timer]
OnActiveSec=45min
AccuracySec=1s
Unit=bobarev-shell-rollback.service
[Install]
WantedBy=timers.target
UNIT_TIMER
 cat > /etc/systemd/system/bobarev-shell-boot-recover.service <<'UNIT_BOOT'
[Unit]
Description=Recover interrupted Bobarev transaction after reboot
After=network-online.target tailscaled.service
Wants=network-online.target
ConditionPathExists=/var/lib/bobarev-shell-mullvad/pending
[Service]
Type=oneshot
ExecStart=/usr/local/lib/bobarev-shell/mullvad.sh recover pending
[Install]
WantedBy=multi-user.target
UNIT_BOOT
 systemctl daemon-reload
 systemctl enable bobarev-shell-boot-recover.service
 rm -f /run/systemd/system/bobarev-shell-rollback.timer.d/window.conf
 systemctl daemon-reload
 systemctl restart bobarev-shell-rollback.timer
 trap 'on_error "$?" "$LINENO"' ERR
 trap 'on_error 130 "$LINENO"' INT TERM HUP
 log "Резервная копия: $TX (приватные настройки, не публикуйте)."
}
on_error(){
 local code=$1 line=$2
 trap - ERR INT TERM HUP
 log "Ошибка $code на строке $line."
 exit "$code"
}
cleanup_exit(){
 local code=$1
 trap - EXIT ERR INT TERM HUP
 exec 8>&- || true
 if [[ -n "$TX" && -f "$PENDING" && $(cat "$PENDING") == "$TX" ]]; then
  log 'Незавершённая транзакция: восстановление.'
  "$SELF" recover pending || log 'Неполный откат: используйте консоль провайдера.'
 fi
 exit "$code"
}
restore_files(){
 python3 - "$TX" <<'PY_RESTORE'
import json,pathlib,shutil,sys,os
root=pathlib.Path(sys.argv[1])
for entry in reversed(json.loads((root/'manifest.json').read_text())):
 p=pathlib.Path(entry['path']);s=root/'files'/str(p).lstrip('/')
 if p.is_symlink() or p.is_file():p.unlink()
 elif p.is_dir():shutil.rmtree(p)
 if not entry['exists']:continue
 p.parent.mkdir(parents=True,exist_ok=True)
 if s.is_symlink():p.symlink_to(os.readlink(s))
 elif s.is_dir():shutil.copytree(s,p,symlinks=True)
 else:shutil.copy2(s,p)
PY_RESTORE
}
recover(){
 root
 mkdir -p "$BASE"
 local mode=${1:-pending}
 if [[ "$mode" == pending ]]; then [[ -f "$PENDING" ]] || { log 'Нет незавершённой транзакции.'; return 0; };TX=$(cat "$PENDING")
 else [[ -f "$BASE/latest" ]] || die 'Нет резервной копии.';TX=$(cat "$BASE/latest");fi
 [[ "$TX" == "$BASE/transactions/"* && -f "$TX/manifest.json" ]] || die 'Некорректная резервная копия.'
 [[ ! -f "$TX/restored" ]] || { log 'Транзакция уже восстановлена.';return 0; }
 python3 - "$TX" "$$" "$PPID" <<'PY_STOP_WRITER'
import json,pathlib,sys,os,signal
f=pathlib.Path(sys.argv[1],'writer-id.json')
if not f.exists():sys.exit(0)
j=json.loads(f.read_text());pid=j['pid'];me=int(sys.argv[2]);parent=int(sys.argv[3])
if pid in (me,parent):sys.exit(0)
try:
 stat=pathlib.Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()
 if stat[19]!=j['start'] or pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()!=j['boot']:sys.exit(0)
except FileNotFoundError:sys.exit(0)
parents={}
for d in pathlib.Path('/proc').iterdir():
 if not d.name.isdecimal():continue
 try:parents[int(d.name)]=int((d/'stat').read_text().rsplit(')',1)[1].split()[1])
 except (OSError,ValueError,IndexError):pass
victims={pid}
while True:
 expanded=victims|{p for p,pp in parents.items() if pp in victims}
 if expanded==victims:break
 victims=expanded
if me in victims:sys.exit(0)
for p in sorted(victims,reverse=True):
 try:os.kill(p,signal.SIGKILL)
 except ProcessLookupError:pass
PY_STOP_WRITER
 exec 8>"$BASE/state.lock"; flock -w 20 8 || die 'Восстановление уже работает.'
 # Re-check after obtaining the commit/recovery lock.
 [[ ! -f "$TX/restored" ]] || return 0
 if [[ "$mode" == pending && ! -f "$PENDING" ]];then return 0;fi
 local failed=0
 if command -v tailscale >/dev/null; then tailscale set --exit-node= --exit-node-allow-lan-access=false --accept-dns=false || failed=1;fi
 systemctl stop bobarev-shell-return.service bobarev-shell-dns.service 2>/dev/null || true
 route_stop || failed=1
 if [[ -f "$TX/services.tsv" ]];then
  while IFS=$'\t' read -r u active enabled;do
   case "$enabled" in not-found|'') systemctl disable "$u" 2>/dev/null || true;;esac
  done < "$TX/services.tsv"
 fi
 restore_files || failed=1
 systemctl daemon-reload || failed=1
 if [[ -f "$TX/ufw-changed" ]] && command -v ufw >/dev/null;then ufw reload || failed=1;fi
 if [[ -f "$TX/sysctls.tsv" ]]; then while IFS=$'\t' read -r k v;do sysctl -w "$k=$v" || failed=1;done < "$TX/sysctls.tsv";fi
 if [[ -f "$TX/nm.tsv" ]] && command -v nmcli >/dev/null;then
  while IFS=$'\t' read -r uuid key value;do nmcli connection modify "$uuid" "$key" "$value" || failed=1;done < "$TX/nm.tsv"
 fi
 if systemctl is-active --quiet systemd-networkd;then networkctl reload || failed=1;fi
 if [[ -f "$TX/legacy-rules.json" ]];then
  python3 - "$TX/legacy-rules.json" <<'PY_LEGACY_RESTORE'
import json,sys,subprocess
failed=False
for args in json.load(open(sys.argv[1])):
 r=subprocess.run(['ip','-4','rule','add']+args,text=True,capture_output=True)
 if r.returncode and 'File exists' not in r.stderr:
  print(r.stderr,file=sys.stderr);failed=True
sys.exit(1 if failed else 0)
PY_LEGACY_RESTORE
  [[ $? == 0 ]] || failed=1
 fi
 if [[ -s "$TX/legacy-firewall.sh" ]];then bash -e "$TX/legacy-firewall.sh" || failed=1;fi
 if [[ -f "$TX/services.tsv" ]];then
  while IFS=$'\t' read -r u active enabled;do
   case "$enabled" in enabled|enabled-runtime) systemctl enable "$u" || failed=1;;disabled) systemctl disable "$u" || failed=1;;esac
   case "$active" in active) systemctl restart "$u" || failed=1;;*) systemctl stop "$u" 2>/dev/null || true;;esac
  done < "$TX/services.tsv"
 fi
 if [[ -f "$TX/link-dns.json" ]] && command -v resolvectl >/dev/null;then
  python3 - "$TX/link-dns.json" <<'PY_LINK_RESTORE'
import subprocess,json,sys
j=json.load(open(sys.argv[1]))
for setting,values in j['settings'].items():
 if not values and setting=='default-route':continue
 subprocess.run(['resolvectl',setting,j['wan']]+(values or ['']),check=True)
PY_LINK_RESTORE
  [[ $? == 0 ]] || failed=1
 fi
 if [[ -f "$TX/prefs.json" ]] && command -v tailscale >/dev/null;then
  python3 - "$TX" <<'PY_TS_RESTORE'
import json,subprocess,sys
from pathlib import Path
p=Path(sys.argv[1]);prefs=json.loads((p/'prefs.json').read_text());status=json.loads((p/'status.json').read_text())
node=str(prefs.get('ExitNodeIP') or '')
if node in ('invalid IP','<nil>'):node=''
if not node and prefs.get('ExitNodeID'):
 for peer in status.get('Peer',{}).values():
  if peer.get('ID')==prefs['ExitNodeID']:
   node=next((ip for ip in peer.get('TailscaleIPs',[]) if ':' not in ip),'');break
 if not node:raise SystemExit('Прежний exit node не найден; оставлен WAN. Восстановите выбор вручную.')
args=['tailscale','set','--exit-node='+node,'--exit-node-allow-lan-access='+str(bool(node and prefs.get('ExitNodeAllowLANAccess'))).lower(),'--accept-dns='+str(bool(prefs.get('CorpDNS',True))).lower(),'--accept-routes='+str(bool(prefs.get('RouteAll',False))).lower(),'--advertise-exit-node='+str(any(r in ('0.0.0.0/0','::/0') for r in prefs.get('AdvertiseRoutes',[]) or [])).lower()]
subprocess.run(args,check=True)
PY_TS_RESTORE
  [[ $? == 0 ]] || failed=1
 fi
 if [[ $failed == 0 ]];then
  touch "$TX/restored";rm -f "$PENDING"
  if grep -q $'bobarev-shell-return.service\tactive' "$TX/services.tsv";then systemctl restart bobarev-shell-return.service || return 1;fi
  systemctl stop bobarev-shell-rollback.timer || true
  log "Восстановлены файлы и настройки $TX. Пакеты и кэши остаются."
 else log "Неполное восстановление: смотрите journalctl -u bobarev-shell-rollback и $TX.";return 1;fi
}
route_stop(){
 local rc=0
 if command -v iptables >/dev/null;then
  while iptables -w -t mangle -D PREROUTING -j BMGE_IN 2>/dev/null;do :;done
  while iptables -w -t mangle -D OUTPUT -j BMGE_OUT 2>/dev/null;do :;done
  while iptables -w -t mangle -D OUTPUT -j BMGE_MSS 2>/dev/null;do :;done
  while iptables -w -t mangle -D FORWARD -j BMGE_MSS 2>/dev/null;do :;done
  for chain in BMGE_IN BMGE_OUT BMGE_MSS;do
   if iptables -w -t mangle -S "$chain" >/dev/null 2>&1;then iptables -w -t mangle -F "$chain" || rc=1;iptables -w -t mangle -X "$chain" || rc=1;fi
  done
 fi
 if command -v ip6tables >/dev/null;then
  while ip6tables -w -t mangle -D PREROUTING -j BMGE6_IN 2>/dev/null;do :;done
  while ip6tables -w -t mangle -D OUTPUT -j BMGE6_OUT 2>/dev/null;do :;done
  while ip6tables -w -t mangle -D OUTPUT -j BMGE6_MSS 2>/dev/null;do :;done
  while ip6tables -w -t mangle -D FORWARD -j BMGE6_MSS 2>/dev/null;do :;done
  for chain in BMGE6_IN BMGE6_OUT BMGE6_MSS;do
   if ip6tables -w -t mangle -S "$chain" >/dev/null 2>&1;then ip6tables -w -t mangle -F "$chain" || rc=1;ip6tables -w -t mangle -X "$chain" || rc=1;fi
  done
 fi
 while ip -4 rule del pref "$PREF" fwmark "$MARK" lookup main 2>/dev/null;do :;done
 while ip -6 rule del pref "$PREF" fwmark "$MARK" lookup main 2>/dev/null;do :;done
 return "$rc"
}
route_start(){
 root
 [[ ! -f "$PENDING" || ${BOBAREV_APPLY:-0} == 1 ]] || { log 'Startup отложен до восстановления pending.';return 0; }
 [[ -f "$CFG" ]] || die 'Нет config.'
 source "$CFG"
 ip link show "$WAN" >/dev/null
 local other
 other=$(ip -4 rule show | awk -v p="$PREF:" '$1==p && $0 !~ /fwmark 0x80000000\/0x80000000 lookup main/ {print}')
 [[ -z "$other" ]] || die 'Конфликт приоритета обратного маршрута.'
 route_stop
 ip -4 rule add pref "$PREF" fwmark "$MARK" lookup main
 iptables -w -t mangle -N BMGE_IN
 iptables -w -t mangle -A BMGE_IN -i "$WAN" -m addrtype --dst-type LOCAL -m conntrack --ctdir ORIGINAL -j CONNMARK --set-xmark "$MARK"
 iptables -w -t mangle -I PREROUTING 1 -j BMGE_IN
 iptables -w -t mangle -N BMGE_OUT
 iptables -w -t mangle -A BMGE_OUT -m connmark --mark "$MARK" -j CONNMARK --restore-mark --nfmask 0x80000000 --ctmask 0x80000000
 iptables -w -t mangle -A OUTPUT -j BMGE_OUT
 if command -v ip6tables >/dev/null && ip -6 addr show dev "$WAN" scope global 2>/dev/null | grep -q 'inet6';then
  ip -6 rule add pref "$PREF" fwmark "$MARK" lookup main 2>/dev/null || true
  ip6tables -w -t mangle -N BMGE6_IN 2>/dev/null || true
  ip6tables -w -t mangle -A BMGE6_IN -i "$WAN" -m addrtype --dst-type LOCAL -m conntrack --ctdir ORIGINAL -j CONNMARK --set-xmark "$MARK" 2>/dev/null || true
  ip6tables -w -t mangle -I PREROUTING 1 -j BMGE6_IN 2>/dev/null || true
  ip6tables -w -t mangle -N BMGE6_OUT 2>/dev/null || true
  ip6tables -w -t mangle -A BMGE6_OUT -m connmark --mark "$MARK" -j CONNMARK --restore-mark --nfmask 0x80000000 --ctmask 0x80000000 2>/dev/null || true
  ip6tables -w -t mangle -A OUTPUT -j BMGE6_OUT 2>/dev/null || true
 fi
 if [[ ${MSS_PROFILE:-auto} == diagnostic1140 ]];then
  iptables -w -t mangle -N BMGE_MSS
  iptables -w -t mangle -A BMGE_MSS -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140
  iptables -w -t mangle -A OUTPUT -j BMGE_MSS
  iptables -w -t mangle -A FORWARD -j BMGE_MSS
  if command -v ip6tables >/dev/null;then
   ip6tables -w -t mangle -N BMGE6_MSS 2>/dev/null || true
   ip6tables -w -t mangle -A BMGE6_MSS -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140 2>/dev/null || true
   ip6tables -w -t mangle -A OUTPUT -j BMGE6_MSS 2>/dev/null || true
   ip6tables -w -t mangle -A FORWARD -j BMGE6_MSS 2>/dev/null || true
  fi
 fi
 sysctl -w net.ipv4.conf.all.rp_filter=2 net.ipv4.conf."$WAN".rp_filter=2
}
migrate_legacy(){
 [[ -f /usr/local/sbin/bobarev-mullvad-return-route.sh ]] || return 0
 log 'Миграция старой BOBAREV SHELL Return-Path-службы; только распознанные правила.'
 python3 - "$TX" <<'PY_LEGACY'
import re,pathlib,subprocess,json,ipaddress,sys
text=pathlib.Path('/usr/local/sbin/bobarev-mullvad-return-route.sh').read_text()
ip=re.search(r'^PUB_IP="([0-9.]+)"$',text,re.M);port=re.search(r'^SSH_P="([0-9]+)"$',text,re.M)
if not ip or not port:raise SystemExit('Старый helper не распознан; нужна ручная миграция.')
ipaddress.IPv4Address(ip[1]);p=int(port[1]);assert 1<=p<=65535
rules=[['from',ip[1]+'/32','table','main','priority','100'],['sport',str(p),'table','main','priority','98'],['sport','443','table','main','priority','99'],['sport','80','table','main','priority','101']];removed=[]
for args in rules:
 while subprocess.run(['ip','-4','rule','del']+args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:removed.append(args)
pathlib.Path(sys.argv[1],'legacy-rules.json').write_text(json.dumps(removed))
PY_LEGACY
 if systemctl is-active --quiet naive-return-route.service;then
  install -d /run/systemd/system/naive-return-route.service.d
  printf '[Service]\nExecStop=\n' > /run/systemd/system/naive-return-route.service.d/shell-migration.conf
  systemctl daemon-reload;systemctl disable --now naive-return-route.service
  rm -f /run/systemd/system/naive-return-route.service.d/shell-migration.conf
  systemctl daemon-reload
 fi
 systemctl disable naive-return-route.service 2>/dev/null || true
 command -v iptables >/dev/null || die 'Старый helper есть, но iptables отсутствует; нужна ручная миграция.'
 : > "$TX/legacy-firewall.sh"
 for table_chain in 'nat POSTROUTING' 'mangle FORWARD' 'mangle OUTPUT' 'mangle POSTROUTING';do
  local table chain;read -r table chain <<< "$table_chain"
  local -a spec
  if [[ $table == nat ]];then spec=(-o tailscale0 -j MASQUERADE);else spec=(-o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1140);fi
  while iptables -w -t "$table" -C "$chain" "${spec[@]}" 2>/dev/null;do
   printf 'iptables -w -t %q -A %q ' "$table" "$chain" >> "$TX/legacy-firewall.sh";printf '%q ' "${spec[@]}" >> "$TX/legacy-firewall.sh";printf '\n' >> "$TX/legacy-firewall.sh"
   iptables -w -t "$table" -D "$chain" "${spec[@]}"
  done
 done
}
install_dependencies(){
 export DEBIAN_FRONTEND=noninteractive
 apt-get update
 apt-get install -y curl ca-certificates openssl iptables iproute2 python3 git wget tar unzip apache2-utils util-linux
 if ! command -v tailscale >/dev/null;then
  curl -q --proto '=https' --tlsv1.2 -fSL --connect-timeout 10 --max-time 120 https://tailscale.com/install.sh -o "$TX/tailscale-install.sh"
  sh -n "$TX/tailscale-install.sh"
  sh "$TX/tailscale-install.sh"
 fi
 systemctl enable --now tailscaled
 local state
 state=$(tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState",""))')
 if [[ $state != Running ]];then
  log 'Авторизуйте Tailscale по ссылке (до 5 минут).'
  timeout 300 tailscale up --accept-dns=false --accept-routes=false
 fi
 tailscale status --json | python3 -c 'import json,sys;assert json.load(sys.stdin).get("BackendState")=="Running"'
 tailscale set --exit-node= --exit-node-allow-lan-access=false --accept-dns=false
}
manager_dns(){
 local uuid key old file name
 if systemctl is-active --quiet NetworkManager && command -v nmcli >/dev/null;then
  uuid=$(nmcli -g GENERAL.CON-UUID device show "$WAN")
  [[ -n $uuid && $uuid != -- ]] || die 'Не определён NM UUID WAN.'
  for key in ipv4.ignore-auto-dns ipv6.ignore-auto-dns ipv4.dns ipv6.dns ipv4.dns-search ipv6.dns-search;do
   old=$(nmcli -g "$key" connection show "$uuid")
   printf '%s\t%s\t%s\n' "$uuid" "$key" "$old" >> "$TX/nm.tsv"
   if [[ $key == *.ignore-auto-dns ]];then nmcli connection modify "$uuid" "$key" yes;else nmcli connection modify "$uuid" "$key" '';fi
  done
 elif systemctl is-active --quiet systemd-networkd;then
  file=$(LC_ALL=C networkctl status "$WAN" --no-pager | sed -n 's/^[[:space:]]*Network File: //p' | head -n 1)
  [[ -n $file && $file == *.network ]] || die 'Не определён .network WAN.'
  name=$(basename "$file")
  local drop="/etc/systemd/network/$name.d/90-bobarev-shell-dns.conf"
  snap_file "$drop";mkdir -p "$(dirname "$drop")"
  cat > "$drop" <<'NETWORK_DNS'
[Network]
DNS=
Domains=
[DHCPv4]
UseDNS=no
UseDomains=no
[DHCPv6]
UseDNS=no
UseDomains=no
[IPv6AcceptRA]
UseDNS=no
UseDomains=no
NETWORK_DNS
  networkctl reload
 else
  if command -v resolvconf >/dev/null || command -v dhclient >/dev/null;then
   log 'NM/networkd не найдены: переключаю системный DNS на systemd-resolved.'
   ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  fi
 fi
}
dns_guard(){
 [[ -f "$CFG" ]] || return 0
 source "$CFG"
 resolvectl dns "$WAN" ''
 resolvectl domain "$WAN" ''
 resolvectl default-route "$WAN" no
 if ip link show tailscale0 >/dev/null 2>&1;then resolvectl revert tailscale0;fi
}
configure_dns(){
 apt-get install -y systemd-resolved whiptail
 manager_dns
 mkdir -p /etc/systemd/resolved.conf.d
 for f in /etc/systemd/resolved.conf.d/*.conf;do
  [[ -e "$f" ]] || continue
  [[ "$f" == *90-bobarev-shell-mullvad.conf ]] && continue
  cp -a "$f" "$TX/" || true
  rm -f "$f"
 done
 local dot_mode=no
 [[ "$DNS" == *#* ]] && dot_mode=yes
 cat > /etc/systemd/resolved.conf.d/90-bobarev-shell-mullvad.conf <<EOF_DNS
[Resolve]
DNS=
DNS=$DNS
FallbackDNS=
Domains=
Domains=~.
DNSOverTLS=$dot_mode
DNSStubListener=yes
Cache=yes
EOF_DNS
 systemctl enable --now systemd-resolved
 ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
 chmod 755 /etc/systemd/resolved.conf.d
 chmod 644 /etc/systemd/resolved.conf.d/90-bobarev-shell-mullvad.conf
 if ! systemctl restart systemd-resolved;then
  journalctl -u systemd-resolved --since "5 minutes ago" --no-pager > "$TX/resolved-failure.log" 2>&1 || true
  echo 'Не удалось перезапустить systemd-resolved. Последние строки журнала:' >&2
  tail -n 60 "$TX/resolved-failure.log" >&2
  die 'Проверьте /etc/systemd/resolved.conf.d/90-bobarev-shell-mullvad.conf.'
 fi
 sleep 2
 dns_guard
 resolvectl flush-caches || true
 systemd-analyze cat-config systemd/resolved.conf > "$TX/effective-resolved.txt"
 python3 - "$TX/effective-resolved.txt" "$DNS" <<'PY_EFFECTIVE'
import sys
values={'DNS':[],'FallbackDNS':[],'Domains':[]};scalar={};section=''
for line in open(sys.argv[1]):
 line=line.strip()
 if not line or line.startswith(('#',';')):continue
 if line.startswith('['):section=line;continue
 if section!='[Resolve]' or '=' not in line:continue
 key,value=map(str.strip,line.split('=',1))
 if key in values:
  if not value:values[key]=[]
  else:values[key].extend(value.split())
 else:scalar[key]=value
assert values['DNS']==[sys.argv[2]],'Сторонний DNS drop-in перекрывает выбор'
assert not values['FallbackDNS'] and values['Domains']==['~.'],'Конфликт DNS routing/fallback'
assert scalar.get('DNSStubListener')=='yes','Конфликт режима resolver'
PY_EFFECTIVE
 cat > /etc/systemd/system/bobarev-shell-dns.service <<'UNIT_DNS'
[Unit]
Description=Bobarev DNS runtime reconciliation
Wants=network-online.target systemd-resolved.service
After=network-online.target systemd-resolved.service tailscaled.service NetworkManager.service systemd-networkd.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/bobarev-shell/mullvad.sh dns-guard
[Install]
WantedBy=multi-user.target
UNIT_DNS
 systemctl daemon-reload;systemctl enable bobarev-shell-dns.service
}
configure_route(){
 printf 'WAN=%q\nDNS=%q\nNODE=%q\n' "$WAN" "$DNS" "$NODE" > "$CFG"
 cat > /etc/systemd/system/bobarev-shell-return.service <<'UNIT_RETURN'
[Unit]
Description=Bobarev BOBAREV SHELL IPv4 ingress reply routing
Wants=network-online.target
After=network-online.target ufw.service
Before=tailscaled.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/bobarev-shell/mullvad.sh route-start
ExecStop=/usr/local/lib/bobarev-shell/mullvad.sh route-stop
[Install]
WantedBy=multi-user.target
UNIT_RETURN
 systemctl daemon-reload;systemctl enable bobarev-shell-return.service
 route_start
}
test_dot(){
 [[ "$DNS" != *#* ]] && return 0
 local ip=${DNS%%#*} host=${DNS#*#}
 timeout 12 openssl s_client -connect "$ip:853" -servername "$host" -verify_hostname "$host" -verify_return_error -CApath /etc/ssl/certs </dev/null > "$TX/dot-tls.txt" 2>&1
}
probe_ip(){
 local u value
 for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com;do
  if value=$(curl -q -4 --noproxy '*' -fsS --connect-timeout 5 --max-time 12 "$u");then
   if python3 - "$value" <<'PY_IP'
import ipaddress,sys
assert ipaddress.ip_address(sys.argv[1].strip()).version==4
PY_IP
   then printf '%s\n' "$value";return 0;fi
  fi
 done
 return 1
}
smoke(){
 local ok=0 url attempt
 for domain in www.google.com github.com;do timeout 15 resolvectl query "$domain" >/dev/null 2>&1 || true;done
 for attempt in 1 2 3;do
  ok=0
  for url in https://www.google.com https://www.debian.org https://www.cloudflare.com https://api.ipify.org;do
   if curl -q -4 --noproxy '*' -fsS -o /dev/null --connect-timeout 8 --max-time 20 "$url" >>"$TX/smoke-attempt-$attempt.log" 2>&1;then
    ok=$((ok+1))
   fi
  done
  [[ $ok -gt 0 ]] && return 0
  [[ $attempt < 3 ]] && sleep 10
 done
 {
  echo '=== curl -v к https://www.google.com ==='
  curl -q -4 --noproxy '*' -v -o /dev/null --connect-timeout 8 --max-time 20 https://www.google.com 2>&1 || true
  echo '=== ip -4 route show table 52 ==='
  ip -4 route show table 52
  echo '=== ip -4 rule ==='
  ip -4 rule
  echo '=== resolvectl status ==='
  resolvectl status 2>&1 || true
  echo '=== journalctl -u tailscaled ==='
  journalctl -u tailscaled --since "10 minutes ago" --no-pager 2>&1 | tail -n 60 || true
 } > "$TX/smoke-failure.log" 2>&1 || true
 echo 'HTTPS smoke-проверки не прошли после 3 попыток. Диагностика:' >&2
 tail -n 80 "$TX/smoke-failure.log" >&2
 echo "Полный лог: $TX/smoke-failure.log" >&2
 die 'Через exit node не прошёл ни один HTTPS-запрос; установка остановлена.'
}
check_exit(){
 local n
 for n in {1..60};do
  if ip -4 route show table 52 default 2>/dev/null | grep -E '^default[[:space:]]+dev[[:space:]]+tailscale0([[:space:]]|$)' >/dev/null;then
   log "Маршрут exit node появился на попытке $n/60."
   break
  fi
  if (( n % 12 == 0 ));then
   echo "Маршрут exit node ещё не появился (${n}/60). Повторяю применение exit node." >&2
   tailscale set --advertise-exit-node=false --accept-dns=false --exit-node="$NODE" --exit-node-allow-lan-access=true || true
  fi
  sleep 5
 done
 if ! ip -4 route show table 52 default 2>/dev/null | grep -E '^default[[:space:]]+dev[[:space:]]+tailscale0([[:space:]]|$)' >/dev/null;then
  {
   echo '=== ip -4 route show table 52 ==='
   ip -4 route show table 52
   echo '=== ip -4 rule ==='
   ip -4 rule
   echo '=== tailscale status ==='
   tailscale status 2>&1 || true
   echo '=== tailscale status --json: строки про exit node ==='
   tailscale status --json 2>/dev/null > "$TX/exit-node-status.json" || true
   grep -n -F "$NODE" "$TX/exit-node-status.json" 2>/dev/null | head -n 60 || true
   grep -n -E "ExitNode|Online" "$TX/exit-node-status.json" 2>/dev/null | head -n 60 || true
   echo '=== journalctl -u tailscaled ==='
   journalctl -u tailscaled --since "15 minutes ago" --no-pager 2>&1 | tail -n 80 || true
  } > "$TX/exit-node-failure.log" 2>&1 || true
  echo 'Exit node не подтвердился за 5 минут. Диагностика сохранена и показана ниже.' >&2
  tail -n 100 "$TX/exit-node-failure.log" >&2
  echo "Полный лог: $TX/exit-node-failure.log" >&2
  echo "Проверьте: tailscale status — узел $NODE должен быть Online и предлагать exit node." >&2
  die 'Exit node недоступен или не объявлен; установка остановлена до smoke-проверок.'
 fi
 tailscale status --json > "$TX/after-status.json"
 python3 - "$TX/after-status.json" <<'PY_EXIT'
import json,sys
j=json.load(open(sys.argv[1]))
if not any(p.get('ExitNode') for p in j.get('Peer',{}).values()) and not (j.get('ExitNodeStatus') or {}).get('ID'):raise SystemExit('Tailscale не подтверждает выбранный exit node.')
PY_EXIT
 test_dot;resolvectl flush-caches;smoke
 OUT_IP=$(probe_ip) || die 'Не удалось определить выходной IPv4 по трём сервисам.'
 [[ $OUT_IP != "$DIRECT_IP" ]] || die 'Внешний IPv4 не изменился: VPN не подтверждён.'
 log "WAN: $DIRECT_IP; сейчас: $OUT_IP. Проверьте соответствие выбранному узлу/стране."
}
renew_watchdog(){
 mkdir -p /run/systemd/system/bobarev-shell-rollback.timer.d
 printf '[Timer]\nOnActiveSec=\nOnActiveSec=5min\n' > /run/systemd/system/bobarev-shell-rollback.timer.d/window.conf
 systemctl daemon-reload;systemctl restart bobarev-shell-rollback.timer
}
commit(){
 local answer=''
 log 'Откройте НОВУЮ SSH-сессию по публичному IPv4 и проверьте NaiveProxy/Shadowrocket.'
 log 'Проверьте выходной IP через клиентский прокси. Серверный curl этого не заменяет.'
 log 'Введите KEEP после успешной проверки NaiveProxy/Shadowrocket. Автоматический откат — не ранее чем через 45 минут.'
 read -r -p 'Введите KEEP для подтверждения (ожидание без ограничения времени; автоматический откат не ранее чем через 45 минут): ' answer
 [[ $answer == KEEP ]] || die 'Изменения не подтверждены.'
 exec 8>"$BASE/state.lock";flock -w 10 8
 [[ -f "$PENDING" && $(cat "$PENDING") == "$TX" && ! -f "$TX/restored" ]] || die 'Транзакция уже откатилась.'
 BOBAREV_APPLY=1 route_start
 dns_guard
 systemctl stop bobarev-shell-rollback.timer
 rm -f "$PENDING";touch "$TX/committed"
 trap - ERR INT TERM HUP EXIT
 flock -u 8
 systemctl restart bobarev-shell-return.service
 systemctl restart bobarev-shell-dns.service
 log 'Применено. Теперь нужен reboot-тест. Резервная копия сохранена.'
}
build_caddy(){
 source "$LIB/build-pins.conf"
 local temp arch sha actual
 temp=$(mktemp -d "$TX/caddy-build-XXXXXX")
 arch=$(dpkg --print-architecture)
 case $arch in amd64) sha=$GO_SHA256_AMD64;;arm64) sha=$GO_SHA256_ARM64;;*) die 'Поддерживаются amd64/arm64.';;esac
 local need_go_dl=1
 if command -v go >/dev/null;then
  local gver gmaj gmin
  gver=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+' || echo "0.0")
  gmaj=${gver%%.*}; gmin=${gver#*.}
  if (( gmaj > 1 || (gmaj == 1 && gmin >= 25) ));then need_go_dl=0;fi
 fi
 if (( need_go_dl == 1 ));then
  curl -q --proto '=https' -fSL --retry 2 --connect-timeout 10 --max-time 300 "https://go.dev/dl/go${GO_VERSION_PIN}.linux-${arch}.tar.gz" -o "$temp/go.tar.gz"
  actual=$(sha256sum "$temp/go.tar.gz" | awk '{print $1}')
  [[ $actual == "$sha" ]] || die 'SHA256 Go не совпал с pin исходника; сборка остановлена.'
  mkdir "$temp/toolchain";tar -C "$temp/toolchain" -xzf "$temp/go.tar.gz"
  export PATH="$temp/toolchain/go/bin:$PATH"
 fi
 export GOPATH=/root/go GOCACHE=/root/.cache/go-build GOTMPDIR=$temp TMPDIR=$temp
 local caddy_cache="$BASE/caddy/caddy"
 if [[ ! -x /usr/local/bin/caddy ]] || ! /usr/local/bin/caddy list-modules 2>/dev/null | grep -F 'http.handlers.forward_proxy' >/dev/null;then
  if [[ -x "$caddy_cache" ]] && "$caddy_cache" list-modules 2>/dev/null | grep -F 'http.handlers.forward_proxy' >/dev/null;then
   install -m 755 "$caddy_cache" /usr/local/bin/caddy
   log 'Восстановлен ранее собранный Caddy из локального кэша — сборка не требуется.'
  fi
 fi
 if [[ ! -x /usr/local/bin/caddy ]] || ! /usr/local/bin/caddy list-modules | grep -F 'http.handlers.forward_proxy' >/dev/null;then
  log 'Сборка Caddy с NaiveProxy: это может занять несколько минут.'
  if ! go install "github.com/caddyserver/xcaddy/cmd/xcaddy@${XCADDY_VERSION_PIN}" >"$TX/caddy-build.log" 2>&1;then
   tail -n 40 "$TX/caddy-build.log" >&2
   die 'Не удалось установить xcaddy. Полный лог: '"$TX/caddy-build.log"
  fi
  if ! "$GOPATH/bin/xcaddy" build "$CADDY_VERSION_PIN" --with "github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${FORWARDPROXY_REF_PIN}" --output "$temp/caddy" >>"$TX/caddy-build.log" 2>&1;then
   tail -n 60 "$TX/caddy-build.log" >&2
   die 'Не удалось собрать Caddy. Полный лог: '"$TX/caddy-build.log"
  fi
  "$temp/caddy" list-modules | grep -F 'http.handlers.forward_proxy' >/dev/null
  install -m 755 "$temp/caddy" /usr/local/bin/caddy
  mkdir -p "$(dirname "$caddy_cache")"
  install -m 755 "$temp/caddy" "$caddy_cache"
  log 'Caddy собран успешно и сохранён в локальный кэш.'
 fi
 unset GOTMPDIR TMPDIR
 rm -rf "$temp"
}
setup_caddy(){
 local domain email user pass hash conflict
 read -r -p 'Домен NaiveProxy (A-запись уже на VPS): ' domain
 read -r -p 'Email ACME: ' email
 read -r -p 'Новый пользователь (a-z A-Z 0-9 _ -): ' user
 python3 - "$domain" "$email" "$user" <<'PY_INPUT'
import re,sys
assert re.fullmatch(r'(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?',sys.argv[1]) and '.' in sys.argv[1],'Неверный домен'
assert re.fullmatch(r'[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+',sys.argv[2]),'Неверный email'
assert re.fullmatch(r'[A-Za-z0-9_-]{1,64}',sys.argv[3]),'Неверный пользователь'
PY_INPUT
 pass=$(openssl rand -hex 16)
 [[ ${#pass} == 32 ]] || die 'Генератор пароля не сработал.'
 for port in 80 443;do
  conflict=$(ss -H -lntup "sport = :$port" | grep -v '"caddy"' || true)
  [[ -z $conflict ]] || die "Порт $port занят: $conflict"
 done
 if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active';then
  touch "$TX/ufw-changed"
  ufw allow 80/tcp comment 'BOBAREV SHELL ACME'
  ufw allow 443/tcp comment 'BOBAREV SHELL NaiveProxy'
 fi
 log '80/tcp и 443/tcp также должны быть разрешены в панели хостинга. Firewall не сбрасывается.'
 getent ahostsv4 "$domain" > "$TX/domain-addresses.txt"
 build_caddy
 mkdir -p /etc/caddy /etc/naiveproxy /var/www/html
 printf '%s\n' '<!doctype html><meta charset="utf-8"><title>OK</title><p>Service is running.</p>' > /var/www/html/index.html
 chmod 644 /var/www/html/index.html
 hash=$(printf '%s\n' "$pass" | htpasswd -niBC 12 "$user" | cut -d: -f2)
 [[ $hash == '$2'* ]] || die 'bcrypt не создан.'
 touch /etc/naiveproxy/users.conf /etc/naiveproxy/users.pass
 sed -i "/^${user}:/d" /etc/naiveproxy/users.conf /etc/naiveproxy/users.pass
 printf '%s:%s\n' "$user" "$hash" >> /etc/naiveproxy/users.conf
 printf '%s:%s\n' "$user" "$pass" >> /etc/naiveproxy/users.pass
 chmod 600 /etc/naiveproxy/users.conf /etc/naiveproxy/users.pass
 python3 - "$domain" "$email" <<'PY_CADDY'
from pathlib import Path
import re,sys
rows=[]
for line in Path('/etc/naiveproxy/users.conf').read_text().splitlines():
 u,h=line.split(':',1)
 if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}',u) or not re.fullmatch(r'\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}',h):raise SystemExit('Некорректная существующая запись пользователя')
 rows.append('            '+u+' '+h)
text='''{
    order forward_proxy before file_server
    email EMAIL
    servers {
        protocols h1 h2
    }
}
:443, DOMAIN {
    @naive_proxy method CONNECT
    route @naive_proxy {
        request_header Authorization "{http.request.header.Proxy-Authorization}"
        basic_auth bcrypt {
AUTH
        }
        request_header -Authorization
        forward_proxy {
            hide_ip
            hide_via
        }
    }
    root * /var/www/html
    file_server
    handle_errors {
        @auth_error expression {http.error.status_code} == 401
        handle @auth_error {
            header -WWW-Authenticate
            respond "Not Found" 404
        }
    }
}
'''.replace('EMAIL',sys.argv[2]).replace('DOMAIN',sys.argv[1]).replace('AUTH','\n'.join(rows))
p=Path('/etc/caddy/Caddyfile');p.write_text(text);p.chmod(0o600)
PY_CADDY
 /usr/local/bin/caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null 2>&1 || true
 if ! /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >"$TX/caddy-validate.log" 2>&1; then
  echo 'Caddyfile не прошёл валидацию.' >&2
  tail -n 40 "$TX/caddy-validate.log" >&2
  die 'Проверьте /etc/caddy/Caddyfile и повторите настройку.'
 fi
 cat > /etc/systemd/system/caddy.service <<'UNIT_CADDY'
[Unit]
Description=NaiveProxy Caddy — BOBAREV SHELL
After=network-online.target
Wants=network-online.target
[Service]
Type=notify
User=root
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
[Install]
WantedBy=multi-user.target
UNIT_CADDY
 printf 'CASCADE_ROLE=%q\nNAIVE_DOMAIN=%q\nNAIVE_EMAIL=%q\nNAIVE_OUT_MODE=%q\n' standalone_naive "$domain" "$email" mullvad_ts > /etc/default/bobarev-cascade
 systemctl daemon-reload;systemctl enable caddy.service;systemctl restart caddy.service
 local http_code="" verified=0
 for n in {1..30};do
  http_code=$(curl -q --noproxy '*' --resolve "$domain:443:127.0.0.1" -o /dev/null -sS -w '%{http_code}' --connect-timeout 3 --max-time 5 "https://$domain" 2>>"$TX/local-caddy-check.txt" || true)
  if [[ $http_code =~ ^[1-5][0-9][0-9]$ ]];then verified=1;break;fi
  sleep 3
 done
 if [[ $verified != 1 ]];then
  journalctl -u caddy --since "10 minutes ago" --no-pager > "$TX/caddy-failure.log" 2>&1 || true
  echo 'Локальная TLS-проверка Caddy не прошла. Последние строки журнала:' >&2
  tail -n 60 "$TX/caddy-failure.log" >&2
  echo "Полный лог: $TX/caddy-failure.log" >&2
  if grep -qiE 'obtain|certificate|acme|challenge' "$TX/caddy-failure.log";then
   echo 'Наиболее вероятно: ACME не смог получить сертификат. Проверьте A-запись и доступность 80/tcp/443/tcp извне.' >&2
  elif grep -qiE 'address already in use|bind' "$TX/caddy-failure.log";then
   echo 'Порт 80/443 занят другим процессом.' >&2
  fi
  die 'Установка остановлена до включения exit node.'
 fi
 python3 - "$domain" "$user" "$pass" "$BASE/client-links.txt" <<'PY_LINKS'
import base64,pathlib,sys,urllib.parse
host,u,p,dest=sys.argv[1:];b=base64.b64encode(f'{u}:{p}@{host}:443'.encode()).decode()
text=f'http2://{b}?obfs=none#{host}-{u}\nhttps://{urllib.parse.quote(u,safe="")}:{urllib.parse.quote(p,safe="")}@{host}:443?padding=true\n'
f=pathlib.Path(dest);f.write_text(text);f.chmod(0o600)
PY_LINKS
 log "Ссылки с паролем: $BASE/client-links.txt (root-only)."
}
ui_input(){
 if command -v whiptail >/dev/null;then
  whiptail --title 'BOBAREV SHELL' --inputbox "$1" 10 60 "${2:-}" 3>&1 1>&2 2>&3
 else
  read -r -p "$1 [${2:-}]: " REPLY
  printf '%s' "$REPLY"
 fi
}
ui_yesno(){
 if command -v whiptail >/dev/null;then
  whiptail --title 'BOBAREV SHELL' --yesno "$1" 10 60
 else
  read -r -p "$1 [y/N]: " REPLY
  [[ $REPLY == APPLY || $REPLY == y || $REPLY == Y ]]
 fi
}
apply(){
 local kind=${1:-exit} answer
 preflight
 [[ -t 0 ]] || die 'Нужен интерактивный терминал.'
 log 'Публичный Mullvad DNS объявлен к отключению 02.11.2026; по умолчанию Quad9 DoT.'
 DNS=$(ui_input 'DNS IPv4 или IPv4#TLS-hostname:' '9.9.9.9') || die 'Отменено.'
 [[ -z $DNS ]] && DNS='9.9.9.9'
 validate_dns "$DNS"
 NODE=$(ui_input 'IP/имя exit node (пусто — показать список после установки):' '') || die 'Отменено.'
 [[ -z $NODE || $NODE =~ ^[A-Za-z0-9_.:-]+$ ]] || die 'Неверный узел.'
 log 'Новые исходящие соединения VPS пойдут через exit node; это НЕ VPN kill switch.'
 log 'Откат восстанавливает прежние настройки, включая прежний exit node, если он был.'
 if ! ui_yesno 'Создать резервную копию и продолжить?';then return 0;fi
 transaction
 export BOBAREV_APPLY=1
 if command -v tailscale >/dev/null;then tailscale set --exit-node= --exit-node-allow-lan-access=false --accept-dns=false;fi
 migrate_legacy
 install_dependencies
 if [[ -z $NODE ]];then tailscale exit-node list;NODE=$(ui_input 'Выберите IP/имя exit node из списка:' '') || die 'Отменено.';fi
 [[ $NODE =~ ^[A-Za-z0-9_.:-]+$ ]] || die 'Неверный узел.'
 DIRECT_IP=$(probe_ip) || die 'Не определён прямой WAN IPv4; исходный интернет не подтверждён.'
 log "Прямой WAN IPv4: $DIRECT_IP"
 if [[ $kind == full ]];then setup_caddy;fi
 [[ -f "$PENDING" && $(cat "$PENDING") == "$TX" && ! -f "$TX/restored" ]] || die 'Транзакция была прервана во время подготовки.'
 renew_watchdog
 configure_route
 configure_dns
 test_dot
 local dns_ok=0
 for n in 1 2 3;do
  if timeout 15 resolvectl query www.google.com >/dev/null 2>&1;then dns_ok=1;break;fi
  sleep 2
 done
 if [[ $dns_ok != 1 ]];then
  journalctl -u systemd-resolved --since "5 minutes ago" --no-pager > "$TX/resolved-query-failure.log" 2>&1 || true
  echo 'systemd-resolved не ответил на тестовый запрос www.google.com.' >&2
  echo 'Последние строки журнала:' >&2
  tail -n 60 "$TX/resolved-query-failure.log" >&2
  echo "Полный лог: $TX/resolved-query-failure.log" >&2
  die 'DNS не заработал после настройки; установка остановлена до exit node.'
 fi
 tailscale set --advertise-exit-node=false --accept-dns=false --exit-node="$NODE" --exit-node-allow-lan-access=true
 check_exit
 printf 'DIRECT_IP=%q\nOUT_IP=%q\n' "$DIRECT_IP" "$OUT_IP" >> "$CFG"
 commit
}
diag(){
 log 'Диагностика без изменения сети:'
 ip -4 rule show;ip -4 route show table main;ip -4 route show table 52 || true
 command -v tailscale >/dev/null && tailscale debug prefs | grep -E 'ExitNode|CorpDNS|RouteAll' || true
 command -v resolvectl >/dev/null && resolvectl status || true
 for s in bobarev-shell-return bobarev-shell-dns bobarev-shell-rollback.timer caddy;do systemctl status "$s" --no-pager -l || true;done
 if [[ -f "$CFG" ]];then source "$CFG";log "WAN=$WAN NODE=$NODE DNS=$DNS";fi
 if command -v resolvectl >/dev/null;then timeout 15 resolvectl query www.google.com || true;fi
 if value=$(probe_ip);then log "Текущий IPv4: $value";else log 'Проверка внешнего IP не прошла.';fi
}
mss_change(){
 root;[[ -f "$CFG" ]] || die 'Сначала настройте exit node.'
 [[ ${1:-} == auto || ${1:-} == diagnostic1140 ]] || die 'Профиль auto или diagnostic1140.'
 local profile=$1 confirm
 preflight
 read -r -p 'Диагностический MSS-профиль. APPLY для применения с откатом: ' confirm
 [[ $confirm == APPLY ]] || return 0
 source "$CFG"
 transaction
 export BOBAREV_APPLY=1
 sed -i '/^MSS_PROFILE=/d' "$CFG"
 printf 'MSS_PROFILE=%q\n' "$profile" >> "$CFG"
 source "$CFG"
 renew_watchdog
 route_start
 smoke
 commit
}
case ${1:-help} in
 --library) :;;
 full|exit) root;mkdir -p "$BASE";exec 9>"$BASE/wizard.lock";flock -n 9 || die 'Мастер уже работает.';apply "$1";;
 recover) trap - ERR;set +e;recover "${2:-pending}";;
 route-start) route_start;;
 route-stop) route_stop;;
 dns-guard) root;dns_guard;;
 diag) diag;;
 direct) root;tailscale set --exit-node= --exit-node-allow-lan-access=false;log 'Exit node отключён; DNS и обратный путь сохранены.';;
 mss) root;mkdir -p "$BASE";exec 9>"$BASE/wizard.lock";flock -n 9 || die 'Мастер уже работает.';mss_change "${2:-auto}";;
 links) root;[[ -f "$BASE/client-links.txt" ]] && cat "$BASE/client-links.txt";;
 *) echo 'Команды: full | exit | diag | direct | recover pending | recover latest | links';;
esac
BOBAREV_ENGINE_3146
 bash -n "$lib/mullvad.sh.new" || return 1
 chmod 700 "$lib/mullvad.sh.new" || return 1
 mv -f "$lib/mullvad.sh.new" "$lib/mullvad.sh" || return 1
 {
  printf 'GO_VERSION_PIN=%q\n' "$GO_VERSION_PIN"
  printf 'GO_SHA256_AMD64=%q\n' "$GO_SHA256_AMD64"
  printf 'GO_SHA256_ARM64=%q\n' "$GO_SHA256_ARM64"
  printf 'CADDY_VERSION_PIN=%q\n' "$CADDY_VERSION_PIN"
  printf 'XCADDY_VERSION_PIN=%q\n' "$XCADDY_VERSION_PIN"
  printf 'FORWARDPROXY_REF_PIN=%q\n' "$FORWARDPROXY_REF_PIN"
 } > "$lib/build-pins.conf"
 chmod 600 "$lib/build-pins.conf"
}
# Old function retained as a compatibility message, never a silent DNS rewrite.
ensure_mullvad_return_route_and_dot_dns() {
 echo 'Используйте мастер пункта 24: изменения применяются только транзакцией с откатом.'
 return 1
}
setup_vless_reality_mullvad_inbound() {
 echo -e "${C_CYAN} === ДОПОЛНИТЕЛЬНЫЙ ВХОД VLESS-REALITY (IPv4 + IPv6) -> MULLVAD EXIT NODE ===${C_RESET}"
 ensure_xray_installed || return 1
 local x_port="8443"
 prompt_default "1/2. Введите TCP-порт для VLESS-REALITY (например 8443, чтобы не занимать 443 у NaiveProxy):" "$x_port" x_port
 [ "$MODULE_CANCELED" = true ] || [ -z "$x_port" ] && return 0
 x_port="${x_port//[^0-9]/}"
 local x_sni="gateway.icloud.com"
 prompt_default "2/2. Введите SNI-домен для маскировки REALITY (TLS 1.3):" "$x_sni" x_sni
 [ "$MODULE_CANCELED" = true ] || [ -z "$x_sni" ] && return 0

 local keys=$(/usr/local/bin/xray x25519 2>/dev/null || true)
 local x_priv=$(echo "$keys" | awk -F':' 'tolower($1) ~ /private/ {print $2; exit}' | tr -d '[:space:]')
 local x_pub=$(echo "$keys" | awk -F':' 'tolower($1) ~ /public|password/ {print $2; exit}' | tr -d '[:space:]')
 local x_uuid=$(/usr/local/bin/xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
 local x_short_id=$(openssl rand -hex 8)

 [ -z "$x_priv" ] || [ -z "$x_pub" ] && { echo -e "${C_RED} Ошибка генерации ключей x25519!${C_RESET}"; return 1; }

 render_xray_server_config "$x_port" "$x_uuid" "$x_priv" "$x_short_id" "$x_sni" "direct"
 write_xray_service
 silent_run systemctl enable --now bobarev-xray.service
 systemctl restart bobarev-xray.service || return 1

 if command -v ufw &>/dev/null; then
  silent_run ufw allow "${x_port}/tcp" comment 'Xray VLESS REALITY Mullvad'
 fi

 local wan_dev=$(get_wan_if)
 local pub_ip=$(ip -4 -o addr show dev "${wan_dev:-ens3}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 | tr -d '[:space:]' || true)
 local pub_ipv6=$(ip -6 -o addr show dev "${wan_dev:-ens3}" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 | tr -d '[:space:]' || true)
 [ -z "$pub_ip" ] && pub_ip="IP_СЕРВЕРА"

 local vless_v4="vless://${x_uuid}@${pub_ip}:${x_port}?encryption=none&security=reality&sni=${x_sni}&fp=chrome&pbk=${x_pub}&sid=${x_short_id}&type=tcp#VPS-Mullvad-IPv4"
 mkdir -p /var/lib/bobarev-shell-mullvad
 {
  echo "=== VLESS-REALITY ССЫЛКИ ДЛЯ SHADOWROCKET / V2BOX (ВЫХОД ЧЕРЕЗ TAILSCALE MULLVAD) ==="
  echo "IPv4: $vless_v4"
  if [ -n "$pub_ipv6" ]; then
   echo "IPv6: vless://${x_uuid}@[${pub_ipv6}]:${x_port}?encryption=none&security=reality&sni=${x_sni}&fp=chrome&pbk=${x_pub}&sid=${x_short_id}&type=tcp#VPS-Mullvad-IPv6"
  fi
 } > /var/lib/bobarev-shell-mullvad/vless-links.txt
 chmod 600 /var/lib/bobarev-shell-mullvad/vless-links.txt

 echo -e "\n${C_GREEN} Вход VLESS-REALITY на порту ${x_port}/tcp запущен! Весь трафик с него уходит в активный Tailscale Mullvad Exit Node.${C_RESET}"
 cat /var/lib/bobarev-shell-mullvad/vless-links.txt
}

manage_naive_mullvad_menu() {
 local pick='' profile=''
 local ctl=/usr/local/lib/bobarev-shell/mullvad.sh
 install_bobarev_mullvad_runtime || return 1
 while true;do
  smart_menu 'BOBAREV SHELL — NaiveProxy / VLESS / Mullvad' \
   'VPS IPv4 + Dual-Stack IPv6. Мастер с резервной копией, conntrack return-path (IPv4/IPv6), строгим DoT и откатом. Позволяет подключаться с iPhone по NaiveProxy (HTTP/2) и/или VLESS-REALITY и выходить через Mullvad Exit Node в Tailscale.' \
   25 "$WT_WIDTH" 11 pick \
   1 'Мастер под ключ: Tailscale + NaiveProxy + DNS + exit node' \
   2 'Список доступных exit nodes' \
   3 'Подключить / сменить exit node и DNS (без сборки Caddy)' \
   4 'Прямой WAN (сохранить DNS и return-path)' \
   5 'Восстановить последнюю транзакцию / отменить незавершённую' \
   6 'Пользователи NaiveProxy / ссылки' \
   7 'Диагностика и проверка после перезагрузки' \
   8 'Диагностический MSS: auto / 1140 (с откатом)' \
   9 'Добавить вход VLESS-REALITY (порт 8443, IPv4/IPv6) -> Mullvad' \
   0 'Назад' || return 0
  case "$pick" in
   0) return 0;;
   1) bash "$ctl" full || echo 'Мастер завершился без подтверждённого успеха; проверьте сообщения и откат.';pause_enter;;
   2) if command -v tailscale >/dev/null;then tailscale exit-node list || true;else echo 'Tailscale ещё не установлен: пункт 1.';fi;pause_enter;;
   3) bash "$ctl" exit || echo 'Изменения не подтверждены; проверьте откат.';pause_enter;;
   4) if nm_yes 'Отключить exit node? DNS и обратный путь будут сохранены.';then bash "$ctl" direct || echo 'Не удалось отключить exit node.';fi;pause_enter;;
   5) if nm_yes 'Восстановить сохранённые файлы и прежний exit node? Поздние ручные изменения могут быть заменены.';then
       if [[ -f /var/lib/bobarev-shell-mullvad/pending ]];then bash "$ctl" recover pending || echo 'Откат неполный!';else bash "$ctl" recover latest || echo 'Откат неполный!';fi
      fi;pause_enter;;
   6) manage_naive_users_menu; if nm_yes 'Показать сохранённые мастером ссылки (содержат пароль)?';then bash "$ctl" links || true; [ -f /var/lib/bobarev-shell-mullvad/vless-links.txt ] && cat /var/lib/bobarev-shell-mullvad/vless-links.txt || true;fi;pause_enter;;
   7) bash "$ctl" diag || true;pause_enter;;
   8) MODULE_CANCELED=false;prompt_default 'Профиль: auto (без принудительного MSS) или diagnostic1140' auto profile
      if [[ "$MODULE_CANCELED" == false ]];then bash "$ctl" mss "$profile" || echo 'Профиль не применён.';fi;pause_enter;;
   9) setup_vless_reality_mullvad_inbound || true;pause_enter;;
  esac
 done
}

mod_network_reset() {
 local selected='' item='' unit='' ts_exit='' ts_adv=''
 local -a items=()
 echo 'Сканирование сетевых настроек...'
 echo '--- Интерфейсы ---'
 ip -br address || true
 echo '--- IPv4 policy routing ---'
 ip -4 rule || true
 echo '--- NAT / MASQUERADE ---'
 iptables -t nat -S POSTROUTING 2>/dev/null | grep -E 'MASQUERADE|SNAT' || true
 echo '--- Активные сетевые службы ---'
 for unit in bobarev-router-v2 bobarev-router-dhcp bobarev-cascade-ru bobarev-udp2raw bobarev-xray hysteria-client hysteria-server naive-mesh-bridge xray-mesh-socks xraymesh; do
  [[ -f "/etc/systemd/system/$unit.service" ]] || continue
  printf '%-32s %s\n' "$unit" "$(systemctl is-active "$unit.service" 2>/dev/null || echo unknown)"
 done
 if command -v tailscale >/dev/null; then
  ts_exit="$(tailscale get exit-node 2>/dev/null || echo '')"
  ts_adv="$(tailscale get advertise-exit-node 2>/dev/null || echo false)"
  echo "--- Tailscale exit node: ${ts_exit:-не выбран} ---"
  echo "--- Анонсирование exit node: $ts_adv ---"
 fi
 echo ''
 echo 'Базовая ОС, SSH, пользователи, ключи и авторизация VPN сохраняются.'
 echo 'Это не заводской сброс. Неизвестные старые правила показываются, но автоматически не удаляются.'
 echo ''
 if [[ -f /etc/systemd/system/bobarev-router-v2.service ]]; then
  items+=('LAN_ROUTER' 'Отключить LAN-маршрутизатор, DHCP и его NAT/MASQUERADE' OFF)
 fi
 if command -v tailscale >/dev/null; then
  if [[ -n "$ts_exit" && "$ts_exit" != "none" && "$ts_exit" != "false" ]]; then
   items+=('TS_EXIT' 'Отключить выбранный Tailscale exit node' OFF)
  fi
  if [[ "$ts_adv" == "true" ]]; then
   items+=('TS_ADV' 'Отключить анонсирование сервера как exit node' OFF)
  fi
 fi
 for unit in bobarev-cascade-ru bobarev-udp2raw bobarev-xray hysteria-client hysteria-server naive-mesh-bridge xray-mesh-socks xraymesh; do
  [[ -f "/etc/systemd/system/$unit.service" ]] || continue
  local state
  state="$(systemctl is-active "$unit.service" 2>/dev/null || echo unknown)"
  items+=("$unit" "Остановить службу [$state]" OFF)
 done
 ((${#items[@]})) || { echo 'Нет распознанных компонентов для безопасного отключения.'; return 0; }
 selected=$(whiptail --title 'Сброс сетевых настроек' --checklist \
  'Пробел — выбрать. Отключаются только выбранные маршрутизация, NAT/MASQUERADE и службы. Конфиги, пакеты, SSH и авторизация VPN сохраняются.' \
  24 "$WT_WIDTH" 12 "${items[@]}" 3>&1 1>&2 2>&3) || return 0
 [[ -n "$selected" ]] || return 0
 echo 'Будут отключены:'
 for item in $selected; do echo "  ${item//\"/}"; done
 nm_yes 'Подтвердить выбранный сброс?' || return 0
 br_snapshot || return 1
 for item in $selected; do
  item=${item//\"/}
  case "$item" in
   LAN_ROUTER)
    systemctl disable --now bobarev-router-dhcp.service bobarev-router-v2.service || true
    if [[ -f /etc/bobarev-router-dnsmasq-was-active ]]; then
     systemctl start dnsmasq.service || true
     rm -f /etc/bobarev-router-dnsmasq-was-active
    fi
    echo 'LAN-маршрутизатор, DHCP и его NAT/MASQUERADE отключены.' ;;
   TS_EXIT)
    tailscale set --exit-node="" || true
    echo 'Tailscale exit node отключён.' ;;
   TS_ADV)
    tailscale set --advertise-exit-node=false || true
    echo 'Анонсирование exit node отключено.' ;;
   *)
    systemctl disable --now "$item.service" || true
    echo "Служба $item остановлена и отключена." ;;
  esac
 done
 echo 'Сброс завершён. Конфигурации сохранены для повторного включения.'
}


mod_backup_manager() {
    echo -e "${C_CYAN} === 18/27. ЭКСПОРТ И ИМПОРТ НАСТРОЕК ===${C_RESET}"
    local target_user=$(get_active_user)
    local target_home=$(getent passwd "$target_user" | cut -d: -f6)
    [ -z "$target_home" ] && target_home="/root"

    local b_choice
    if ! smart_menu "Экспорт и импорт настроек" "Выберите действие:" 13 $WT_WIDTH 3 "b_choice" \
    "1" " Сохранить настройки в архив (Экспорт)" \
    "2" " Восстановить настройки из архива (Импорт)" \
    "0" " Отмена" || [ "$b_choice" = "0" ]; then
        MODULE_CANCELED=true
        return 0
    fi

    if [ "$b_choice" = "1" ]; then
        local archive_path="${target_home}/bobarev_backup_$(hostname)_$(date +%Y%m%d_%H%M%S).tar.gz"
        local files_to_pack=()
        for item in /etc/sudoers /etc/sudoers.d /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/sysctl.d /etc/ufw /etc/default/ufw /etc/default/bobarev-router /etc/bobarev-router-v2 /etc/bobarev-tailscale /var/lib/bobarev-shell-mullvad/config /etc/default/bobarev-netfilter /etc/default/bobarev-derp /etc/default/bobarev-cascade /etc/derp /etc/wireguard /etc/caddy /etc/naiveproxy /etc/hysteria /etc/xray /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-client.service /etc/systemd/system/bobarev-xray.service /etc/systemd/system/bobarev-router-v2.service /etc/systemd/system/bobarev-router-dhcp.service /etc/systemd/system/bobarev-tailscale-exit-restore.service /etc/systemd/system/derper.service /etc/systemd/system/caddy.service /etc/systemd/system/bobarev-cascade-ru.service /etc/systemd/system/bobarev-udp2raw.service /usr/local/bin/udp2raw /usr/local/bin/bobarev-cascade-ru.sh /usr/local/sbin/bobarev-router-v2 /usr/local/sbin/bobarev-router-performance /usr/local/sbin/bobarev-router-networkd.py /usr/local/sbin/bobarev-router-routes.py /usr/local/sbin/bobarev-tailscale-exit-restore /usr/local/bin/bobarev-router-up.sh /etc/systemd/system/bobarev-router.service /etc/dnsmasq.conf /etc/default/zramswap /etc/systemd/journald.conf /etc/udev/rules.d/60-ioscheduler.rules; do
            [ -e "$item" ] && files_to_pack+=("$item")
        done

        tar -czf "$archive_path" "${files_to_pack[@]}" 2>/dev/null || true
        silent_run chown "$target_user:$target_user" "$archive_path"
        echo -e "${C_GREEN} Архив настроек успешно сохранен:${C_RESET} ${C_BLUE}$archive_path${C_RESET}"
    elif [ "$b_choice" = "2" ]; then
        local import_path=""
        prompt_default "Введите полный путь к архиву .tar.gz для восстановления:" "${target_home}/" import_path
        [ "$MODULE_CANCELED" = true ] && return 0

        if [ ! -f "$import_path" ]; then
            echo -e "${C_RED} Файл не найден: $import_path${C_RESET}"
            return 0
        fi

        if prompt_yn "Восстановить системные настройки из архива $import_path и перезапустить службы?" "false"; then
            tar -xzf "$import_path" -C / 2>/dev/null
            silent_run systemctl daemon-reload 2>/dev/null || true
            sysctl --system >/dev/null 2>&1 || true
            if [ -x /usr/local/sbin/bobarev-router-v2 ] && [ -f /etc/bobarev-router-v2/config ]; then
                silent_run systemctl restart bobarev-router-v2.service
            elif [ -x /usr/local/bin/bobarev-router-up.sh ]; then
                /usr/local/bin/bobarev-router-up.sh
            fi
            [ -x /usr/local/bin/bobarev-cascade-ru.sh ] && /usr/local/bin/bobarev-cascade-ru.sh
            [ -f /etc/systemd/system/derper.service ] && [ -x /usr/local/bin/derper ] && silent_run systemctl restart derper.service
            is_naive_active && silent_run systemctl restart caddy.service
            is_warp_active && silent_run systemctl restart wg-quick@warp
            [ -f /etc/systemd/system/bobarev-udp2raw.service ] && [ -x /usr/local/bin/udp2raw ] && silent_run systemctl restart bobarev-udp2raw.service
            [ -f /etc/wireguard/wg-cascade.conf ] && silent_run systemctl restart wg-quick@wg-cascade
            silent_run systemctl restart systemd-journald
            silent_run systemctl restart sshd || silent_run systemctl restart ssh
            command -v ufw &>/dev/null && flush_and_reload_nat
            disable_ufw_strict_rpfilter
            echo -e "${C_GREEN} Настройки успешно восстановлены и применены!${C_RESET}"
        fi
    fi
}

# 21. Универсальный аудит сети, протоколов обхода ТСПУ и каскадных пар (network-audit v3.1)
install_network_audit_tool() {
    if ! command -v tcpdump &>/dev/null || ! command -v mtr &>/dev/null || ! command -v conntrack &>/dev/null; then
        echo -e "${C_BLUE} Доустановка диагностических утилит (tcpdump, mtr-tiny, conntrack) для глубокого перехвата пакетов...${C_RESET}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -yq tcpdump mtr-tiny conntrack >/dev/null 2>&1 || true
    fi
    cat << 'NET_AUDIT_EOF' > /usr/local/bin/bobarev-network-audit.sh
#!/bin/bash
# ==============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ АУДИТА СЕТИ, ПРОТОКОЛОВ ОБХОДА ТСПУ И КАСКАДНЫХ ПАР (v3.1)
# ------------------------------------------------------------------------------
# Поддерживает 4 режима работы (через интерактивное меню или флаги CLI):
#   Режим 1: Автономный срез сервера и "жизни" уже работающего каскада (постфактум).
#   Режим 2: Активное тестирование ПАРЫ серверов (PMTU, TCP MSS, MTR, порты, iperf3).
#   Режим 3: МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ ("Черный ящик" / Fail-Safe Live Recorder)
#            Записывает в реальном времени все новые/активные сессии, пакеты,
#            дельту ретрансмитов и ошибок. Безотказно финализирует отчет как при
#            нажатии Ctrl+C / Enter / 'q', так и при внезапном обрыве SSH-канала!
#   Режим 4: Полный комбо-режим (Режим 1 + Режим 2).
# ==============================================================================

export LC_ALL=C

HOST_NAME=$(hostname)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Определение домашней директории реально залогиненного пользователя (даже при запуске через sudo)
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME="$HOME"
fi

# Если домашняя папка найдена и доступна на запись — сохраняем туда, иначе в текущую директорию
if [ -d "$USER_HOME" ] && [ -w "$USER_HOME" ]; then
    OUT_DIR="$USER_HOME"
else
    OUT_DIR="$(pwd)"
fi

# Значения по умолчанию
MODE="" # 1 = standalone/post-factum, 2 = pair test, 3 = real-time recorder, 4 = combo (1+2)
TARGETS=()
TCP_PORTS="22,80,443,8080,8443"
UDP_PORTS="53,443,51820,1194"
IPERF_PORT="5201"
DO_PCAP=1
LIVE_DURATION=15
LIVE_FILTER=""
MAX_RT_TIME=3600       # Страховочный лимит времени для Режима 3 (в секундах, по умолчанию 1 час)
RT_SAMPLE_INTERVAL=5   # Интервал опроса сокетов/счетчиков в Режиме 3 (сек)

usage() {
    cat <<EOF
Использование: sudo $0 [ОПЦИИ]

Режимы работы (если не указаны, откроется интерактивное меню):
  -m, --mode MODE           Режим работы:
                              1 - Автономный срез сервера и "жизни соединения" (постфактум)
                              2 - Активная проверка каскадной пары (до указанных IP)
                              3 - Мониторинг в РЕАЛЬНОМ ВРЕМЕНИ (до нажатия Стоп или обрыва SSH)
                              4 - Полный аудит (Режим 1 + Режим 2)

Опции для Режима 1 и 3 (Срез / Реальное время):
  -d, --duration SEC        Для Режима 1: длительность записи tcpdump (по умолчанию: $LIVE_DURATION сек)
                            Для Режима 3: макс. страховочное время записи (по умолчанию: $MAX_RT_TIME сек)
  -f, --filter "BPF"        Фильтр tcpdump/мониторинга (например, IP второго узла: "host 185.x.x.x")

Опции для Режима 2 (Активная проверка пары):
  -t, --targets "IP1 IP2"   Список целевых IP для проверки пары
  -p, --tcp-ports PORTS     TCP-порты через запятую (по умолчанию: $TCP_PORTS)
  -u, --udp-ports PORTS     UDP-порты через запятую (по умолчанию: $UDP_PORTS)
  -i, --iperf-port PORT     Порт iperf3 (по умолчанию: $IPERF_PORT)

Общие опции:
  -o, --out-dir DIR         Директория сохранения отчета (по умолчанию: $OUT_DIR)
  --no-pcap                 Отключить перехват пакетов tcpdump
  -h, --help                Показать справку

Примеры запуска:
  1) Запуск с удобным интерактивным меню:
     sudo $0
  2) Включить запись в РЕАЛЬНОМ ВРЕМЕНИ (Режим 3) с фильтром по IP второго сервера:
     sudo $0 -m 3 -f "host 185.10.20.30"
  3) Снять данные постфактум на сервере (Режим 1, 20 сек):
     sudo $0 -m 1 -d 20
  4) Проверить каскадную пару до зарубежных серверов (Режим 2):
     sudo $0 -m 2 -t "185.10.20.30 91.20.30.40"
EOF
    exit 0
}

# Разбор аргументов командной строки
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -d|--duration)
            LIVE_DURATION="$2"
            MAX_RT_TIME="$2"
            shift 2
            ;;
        -f|--filter)
            LIVE_FILTER="$2"
            shift 2
            ;;
        -t|--targets)
            for ip in $2; do TARGETS+=("$ip"); done
            shift 2
            ;;
        -p|--tcp-ports)
            TCP_PORTS="$2"
            shift 2
            ;;
        -u|--udp-ports)
            UDP_PORTS="$2"
            shift 2
            ;;
        -i|--iperf-port)
            IPERF_PORT="$2"
            shift 2
            ;;
        -o|--out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --no-pcap)
            DO_PCAP=0
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            TARGETS+=("$1")
            shift
            ;;
    esac
done

# Интерактивное меню, если режим не задан флагом
if [ -z "$MODE" ]; then
    if [ -t 0 ]; then
        echo "=========================================================================="
        echo " УНИВЕРСАЛЬНЫЙ АУДИТ СЕТИ, ТУННЕЛЕЙ И КАСКАДНЫХ СОЕДИНЕНИЙ v3.1 ($HOST_NAME)"
        echo "=========================================================================="
        echo "Выберите режим работы скрипта:"
        echo ""
        echo "  [1] Автономный срез сервера и «жизни соединения» (Постфактум)"
        echo "      -> Снимает текущую картину на сервере: все типы VPN/прокси/туннелей,"
        echo "         живые TCP/UDP сессии (MSS, PMTU, RTT, CWND, ретрансмиты), conntrack"
        echo "         и записывает срез пакетов за короткое фиксированное время ($LIVE_DURATION сек)."
        echo ""
        echo "  [2] Активная проверка каскадной «пары» серверов (Тест связки РФ <-> Зарубеж)"
        echo "      -> Активно тестирует маршрут до указанных IP: ищет точный Path MTU и TCP MSS,"
        echo "         гоняет MTR (ICMP/TCP/UDP), проверяет открытость портов, TLS и скорость iperf3."
        echo ""
        echo "  [3] МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ («Черный ящик» / Запись под нагрузкой)"
        echo "      -> Включает живую запись пакетов, сокетов, колебаний RTT/CWND и потерь."
        echo "         Вы пользуетесь каскадом сколько нужно. Скрипт БЕЗОТКАЗНО сохранит"
        echo "         полный отчет и сводку: а) при нажатии СТОП (Enter / q / Ctrl+C),"
        echo "         б) даже если ваш SSH-канал внезапно оборвется!"
        echo ""
        echo "  [4] Полный комбо-аудит (Выполнить Пункт 1 + Пункт 2 последовательно)"
        echo ""
        echo "  [0] Выход"
        echo "--------------------------------------------------------------------------"
        read -r -p "Ваш выбор [1/2/3/4/0] (по умолчанию 1): " MENU_CHOICE
        MENU_CHOICE=${MENU_CHOICE:-1}

        case "$MENU_CHOICE" in
            1)
                MODE=1
                echo ""
                read -r -p "Сколько секунд записывать срез IP-пакетов? [по умолчанию $LIVE_DURATION]: " INPUT_DUR
                [ -n "$INPUT_DUR" ] && LIVE_DURATION="$INPUT_DUR"
                read -r -p "Укажите IP второго узла каскада для фильтрации (или Enter, чтобы снимать ВЕСЬ трафик): " INPUT_FLT
                if [ -n "$INPUT_FLT" ]; then
                    if [[ "$INPUT_FLT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        LIVE_FILTER="host $INPUT_FLT"
                    else
                        LIVE_FILTER="$INPUT_FLT"
                    fi
                fi
                ;;
            2)
                MODE=2
                if [ ${#TARGETS[@]} -eq 0 ]; then
                    echo ""
                    read -r -p "Введите IP целевого сервера(ов) через пробел: " INPUT_IPS
                    for ip in $INPUT_IPS; do TARGETS+=("$ip"); done
                fi
                read -r -p "TCP порты для проверки [по умолчанию $TCP_PORTS]: " INPUT_TCP
                [ -n "$INPUT_TCP" ] && TCP_PORTS="$INPUT_TCP"
                read -r -p "UDP порты для проверки [по умолчанию $UDP_PORTS]: " INPUT_UDP
                [ -n "$INPUT_UDP" ] && UDP_PORTS="$INPUT_UDP"
                ;;
            3)
                MODE=3
                echo ""
                read -r -p "Укажите IP второго узла каскада/клиента для фильтра (или Enter, чтобы мониторить ВЕСЬ трафик кроме SSH): " INPUT_FLT
                if [ -n "$INPUT_FLT" ]; then
                    if [[ "$INPUT_FLT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        LIVE_FILTER="host $INPUT_FLT"
                    else
                        LIVE_FILTER="$INPUT_FLT"
                    fi
                fi
                read -r -p "Интервал снятия метрик сокетов (сек) [по умолчанию $RT_SAMPLE_INTERVAL]: " INPUT_INT
                [ -n "$INPUT_INT" ] && RT_SAMPLE_INTERVAL="$INPUT_INT"
                read -r -p "Максимальный страховочный таймер авто-остановки (сек) [по умолчанию $MAX_RT_TIME (1 час)]: " INPUT_MAX
                [ -n "$INPUT_MAX" ] && MAX_RT_TIME="$INPUT_MAX"
                ;;
            4)
                MODE=4
                echo ""
                read -r -p "Сколько секунд записывать срез IP-пакетов в Режиме 1? [по умолчанию $LIVE_DURATION]: " INPUT_DUR
                [ -n "$INPUT_DUR" ] && LIVE_DURATION="$INPUT_DUR"
                if [ ${#TARGETS[@]} -eq 0 ]; then
                    read -r -p "Введите IP целевого сервера(ов) через пробел для Режима 2: " INPUT_IPS
                    for ip in $INPUT_IPS; do TARGETS+=("$ip"); done
                fi
                ;;
            0)
                echo "Выход."
                exit 0
                ;;
            *)
                echo "[!] Неверный выбор, запускается Режим 1."
                MODE=1
                ;;
        esac
        echo "=========================================================================="
    else
        if [ ${#TARGETS[@]} -gt 0 ]; then
            MODE=4
        else
            MODE=1
        fi
    fi
fi

mkdir -p "$OUT_DIR"

case "$MODE" in
    1) MODE_TAG="standalone-postfactum" ;;
    2) MODE_TAG="pair-test" ;;
    3) MODE_TAG="realtime-recorder" ;;
    4) MODE_TAG="full-combo" ;;
    *) MODE_TAG="audit" ;;
esac

OUTPUT_FILE="${OUT_DIR}/network-debug-${HOST_NAME}-${MODE_TAG}-${TIMESTAMP}.txt"

# Функция безопасного вызова команд
run_cmd() {
    local title="$1"
    shift
    echo "=== $title ==="
    if command -v "$1" >/dev/null 2>&1; then
        "$@"
    else
        echo "[!] Утилита '$1' не установлена. Пропуск."
    fi
    echo ""
}

# ==============================================================================
# ФУНКЦИЯ 1: БАЗОВЫЙ ЛОКАЛЬНЫЙ СРЕЗ СЕТИ (ОБЩИЙ ДЛЯ ВСЕХ РЕЖИМОВ)
# ==============================================================================
collect_base_system_info() {
    echo "##################################################################"
    echo "# БЛОК 1: ЛОКАЛЬНЫЙ СРЕЗ СЕТИ, СТЕКА TCP/IP И ПРАВИЛ ФАЙРВОЛА"
    echo "##################################################################"
    echo ""

    echo "=== [1.0] Время работы сервера (uptime) и нагрузка ==="
    uptime
    echo ""

    run_cmd "[1.1] Активные слушающие сокеты и порты (ss -tulpn)" ss -tulpn
    run_cmd "[1.2] Сводка по сокетам и соединениям (ss -s)" ss -s
    run_cmd "[1.3] Сетевые интерфейсы, IP, виртуальные туннели и их MTU (ip -d a)" ip -d a
    run_cmd "[1.4] Статистика пакетов, ошибок, дропов и коллизий на интерфейсах (ip -s -s link)" ip -s -s link
    run_cmd "[1.5] Основная таблица маршрутизации (ip r)" ip r
    run_cmd "[1.6] Правила политики маршрутизации (ip rule show)" ip rule show
    run_cmd "[1.7] Все таблицы маршрутизации, включая таблицы туннелей/fwmark (ip route show table all)" ip route show table all
    run_cmd "[1.8] Кэш маршрутов и вычисленных PMTU ядра (ip -s route show cache)" ip -s route show cache

    echo "=== [1.9] Ключевые параметры стека ядра (sysctl: BBR, MTU probing, буферы, conntrack) ==="
    sysctl -a 2>/dev/null | grep -E "net\.ipv4\.(ip_forward|ip_no_pmtu_disc|tcp_mtu_probing|tcp_base_mss|tcp_congestion_control|tcp_available_congestion_control|tcp_ecn|tcp_fastopen|tcp_rmem|tcp_wmem|tcp_window_scaling|tcp_timestamps|tcp_sack|tcp_tw_reuse|tcp_fin_timeout|tcp_keepalive_time|tcp_max_syn_backlog|tcp_syncookies)|net\.core\.(default_qdisc|rmem_max|wmem_max|rmem_default|wmem_default|netdev_max_backlog|somaxconn)|net\.netfilter\.nf_conntrack_(max|count|tcp_timeout_established|udp_timeout|udp_timeout_stream)" | sort
    echo ""

    run_cmd "[1.10] Дисциплины очередей и шейпинг трафика (tc -s qdisc show)" tc -s qdisc show
    run_cmd "[1.11] iptables (filter)" iptables -L -v -n --line-numbers
    run_cmd "[1.12] iptables (nat)" iptables -t nat -L -v -n --line-numbers
    run_cmd "[1.13] iptables (mangle - проверка правил TCPMSS clamping и маркировки fwmark)" iptables -t mangle -L -v -n --line-numbers
    run_cmd "[1.14] iptables (raw)" iptables -t raw -L -v -n --line-numbers
    run_cmd "[1.15] nftables ruleset" nft list ruleset
}

# ==============================================================================
# ФУНКЦИЯ 1.B: ГЛУБОКАЯ ИНСПЕКЦИЯ ВСЕХ ТИПОВ ТУННЕЛЕЙ, VPN И ПРОКСИ КАСКАДА
# ==============================================================================
collect_all_tunnels_and_proxies() {
    echo "=== [2.1] Полная ревизия всех протоколов туннелирования, VPN, прокси и сетевых интерфейсов каскада ==="

    echo "--- [A] Виртуальные и туннельные интерфейсы ядра (tun, tap, wg, amnezia, gre, ipip, sit, vxlan, geneve, l2tp, ppp, vti, xfrm, tailscale, zt) ---"
    ip -d -s link show | grep -B 1 -A 6 -E "tun|tap|wg|awg|gre|gretap|erspan|ipip|sit|vxlan|geneve|l2tp|ppp|vti|xfrm|tailscale|zt|nebula|warp|utun" || echo "Туннельных сетевых интерфейсов на уровне L2/L3 не обнаружено (возможно, используется L4/L7 проксирование без виртуального интерфейса)."
    echo ""

    echo "--- [B] WireGuard / AmneziaWG / BoringTun (интерфейсы, пиры, ключи, свежие хендшейки, трафик) ---"
    if command -v wg >/dev/null 2>&1; then
        WG_OUT=$(wg show all 2>/dev/null)
        if [ -n "$WG_OUT" ]; then
            echo "$WG_OUT"
        else
            echo "Активных интерфейсов WireGuard не найдено."
        fi
    else
        echo "Утилита wg не установлена."
    fi
    if command -v awg >/dev/null 2>&1; then
        echo "[AmneziaWG (awg show all)]:"
        awg show all 2>/dev/null
    fi
    echo ""

    echo "--- [C] Политики и состояния шифрования ядра XFRM / IPsec / StrongSwan / Libreswan (ip xfrm) ---"
    echo "[XFRM Policy]:"
    ip -s xfrm policy 2>/dev/null || true
    echo "[XFRM State]:"
    ip -s xfrm state 2>/dev/null || true
    if command -v ipsec >/dev/null 2>&1; then
        ipsec statusall 2>/dev/null || true
    fi
    if command -v swanctl >/dev/null 2>&1; then
        swanctl --list-sas 2>/dev/null || true
    fi
    echo ""

    echo "--- [D] L3/L2 туннели ядра (IPIP, GRE, SIT, VXLAN, L2TP) ---"
    ip -s tunnel show 2>/dev/null || true
    if command -v ip >/dev/null 2>&1; then
        ip l2tp show tunnel 2>/dev/null || true
        ip l2tp show session 2>/dev/null || true
    fi
    echo ""

    echo "--- [E] Прокси-серверы и средства обхода ТСПУ (Xray, V2Ray, Sing-box, Hysteria2, Tuic, Trojan, Shadowsocks, OpenVPN, Cloak, ShadowTLS, Reality, Gost, Socat, HAProxy, Nginx, Caddy, Chisel, Frp, Rathole, Tor, SSH-туннели, MTProto) ---"
    echo "[Активные процессы и их аргументы запуска]:"
    ps -eo pid,user,pcpu,pmem,etime,args | grep -E "xray|v2ray|sing-box|hysteria|tuic|trojan|ss-server|ss-local|ss-redir|ss-tunnel|shadowsocks|v2ray-plugin|xray-plugin|obfs-server|obfs-local|ck-server|ck-client|cloak|shadow-tls|naive|brook|mieru|juicity|openvpn|ocserv|softether|wg-quick|boringtun|amnezia|gost|socat|haproxy|nginx|envoy|caddy|traefik|rathole|frps|frpc|chisel|wstunnel|stunnel|sslh|sniproxy|nebula|tailscaled|zerotier-one|cloudflared|warp-svc|tor|mtproto|mtg|telemt|3proxy|tinyproxy|squid|danted|microsocks|badvpn|udpgw|udp2raw|udpspeeder|kcptun|ipt2socks|tun2socks|redsocks|tpws|nfqws|zapret|byedpi|goodbyedpi|spoofdpi" | grep -v "grep -E" || echo "Ни одного известного процесса прокси/туннеля/DPI-обхода в списке процессов не найдено."
    echo ""

    echo "--- [F] Системные службы systemd, связанные с VPN / Прокси / Туннелями ---"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-units --type=service --state=running --no-pager 2>/dev/null | grep -iE "vpn|wg|wireguard|amnezia|xray|v2ray|sing-box|hysteria|tuic|trojan|shadowsocks|ss-|gost|socat|haproxy|nginx|caddy|envoy|frp|rathole|chisel|stunnel|sslh|cloak|tailscale|zerotier|nebula|warp|tor|3proxy|dante|zapret|docker|containerd" || echo "Соответствующих активных systemd-служб не найдено."
    fi
    echo ""

    echo "--- [G] Запущенные Docker / Podman контейнеры ---"
    if command -v docker >/dev/null 2>&1; then
        docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Docker демон недоступен или нет контейнеров."
    elif command -v podman >/dev/null 2>&1; then
        podman ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
    else
        echo "Docker / Podman не установлены."
    fi
    echo ""

    echo "--- [H] Активные SSH-туннели (Port Forwarding / ProxyJump / SOCKS -D / tun -w) ---"
    ps -eo pid,user,etime,args | grep -E "ssh .*(-L|-R|-D|-W|-w|notty)" | grep -v "grep" || echo "Активных пробросов портов через SSH не обнаружено."
    echo ""
}

# ==============================================================================
# ФУНКЦИЯ 2: СНЯТИЕ ДАННЫХ О «ЖИЗНИ СОЕДИНЕНИЯ» ПОСТФАКТУМ (РЕЖИМ 1)
# ==============================================================================
collect_live_cascade_state() {
    echo "##################################################################"
    echo "# БЛОК 2: АНАЛИЗ «ЖИЗНИ СОЕДИНЕНИЯ» И РАБОТАЮЩЕГО КАСКАДА (ПОСТФАКТУМ)"
    echo "##################################################################"
    echo ""

    collect_all_tunnels_and_proxies

    echo "=== [2.2] Детальная анатомия ВСЕХ активных TCP-соединений (ss -tinpe) ==="
    ss -tinpe state established
    echo ""

    echo "=== [2.3] Активные UDP-потоки и сокеты (ss -uapne) ==="
    ss -uapne
    echo ""

    echo "=== [2.4] ТОП-30 IP-адресов по количеству открытых соединений с этим сервером ==="
    ss -ntu state established | awk 'NR>1 {print $5}' | sed 's/:[^:]*$//' | sort | uniq -c | sort -nr | head -n 30
    echo ""

    echo "=== [2.5] Глобальные накопительные счетчики сетевого стека за время жизни сервера (nstat -az) ==="
    if command -v nstat >/dev/null 2>&1; then
        nstat -az | grep -E "Ip|Icmp|Tcp|Udp|TcpExt"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -s
    else
        cat /proc/net/snmp
        echo ""
        cat /proc/net/netstat
    fi
    echo ""

    echo "=== [2.6] Таблица отслеживания соединений Netfilter Conntrack ==="
    if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
        echo "Заполнено записей conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count) из $(cat /proc/sys/net/netfilter/nf_conntrack_max)"
    fi
    if command -v conntrack >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
        echo "--- Статистика conntrack (-S) ---"
        conntrack -S 2>/dev/null
        echo ""
        echo "--- Выборка топ-50 активных потоков conntrack (-L) ---"
        conntrack -L 2>/dev/null | grep -E "ESTABLISHED|ASSURED" | head -n 50
    elif [ -f /proc/net/nf_conntrack ]; then
        echo "--- Выборка топ-50 активных потоков из /proc/net/nf_conntrack ---"
        grep -E "ESTABLISHED|ASSURED" /proc/net/nf_conntrack | head -n 50
    else
        echo "[!] Утилита conntrack и /proc/net/nf_conntrack недоступны."
    fi
    echo ""

    if [ "$DO_PCAP" -eq 1 ] && command -v tcpdump >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
        echo "=== [2.7] Снимок ЖИВОГО движения IP-пакетов на сервере за ${LIVE_DURATION} секунд (tcpdump) ==="
        SSH_PORT=$( echo "$SSH_CLIENT" | awk '{print $3}' )
        if [ -n "$LIVE_FILTER" ]; then
            BPF_EXPR="$LIVE_FILTER"
        elif [ -n "$SSH_PORT" ]; then
            BPF_EXPR="not port $SSH_PORT"
        else
            BPF_EXPR=""
        fi

        LIVE_PCAP_LOG=$(mktemp /tmp/live_pcap_XXXXXX.log)
        if [ -n "$BPF_EXPR" ]; then
            timeout "$LIVE_DURATION" tcpdump -i any -nn -v -tt -c 500 "$BPF_EXPR" > "$LIVE_PCAP_LOG" 2>&1
        else
            timeout "$LIVE_DURATION" tcpdump -i any -nn -v -tt -c 500 > "$LIVE_PCAP_LOG" 2>&1
        fi

        cat "$LIVE_PCAP_LOG"
        echo "------------------------------------------------------------------"
        echo ""
        analyze_pcap_log "$LIVE_PCAP_LOG" "2.8"
        rm -f "$LIVE_PCAP_LOG"
    else
        echo "=== [2.7] Снимок живого движения IP-пакетов пропущен (требуется root и установленный tcpdump) ==="
        echo ""
    fi
}

analyze_pcap_log() {
    local pcap_file="$1"
    local sec_num="$2"
    echo "=== [$sec_num] Сводная аналитика по перехваченным IP-пакетам ==="
    echo "--- Распределение пакетов по интерфейсам и направлениям (In / Out) ---"
    grep -E " In | Out " "$pcap_file" | awk '{print $2, $3}' | sort | uniq -c | sort -nr | head -n 25
    echo ""
    echo "--- Топ-25 самых крупных размеров пакетов в потоке ---"
    grep -oE "length [0-9]+" "$pcap_file" | awk '{print $2}' | sort -nr | uniq -c | head -n 25
    echo ""
    echo "--- Обнаруженные согласования TCP MSS в рукопожатиях [SYN / SYN-ACK] ---"
    grep -E "Flags \[S\]|Flags \[S\.\]" "$pcap_file" | grep -oE "IP [^:]+: .* options \[[^]]+\]" | head -n 40 || echo "Новых TCP SYN рукопожатий не зафиксировано."
    echo ""
    echo "--- Пакеты сброса/ошибок: TCP RST [R] и ICMP Unreachable / Fragmentation Needed ---"
    grep -E "Flags \[R|ICMP .* unreachable|ICMP .* need to frag|mtu [0-9]+" "$pcap_file" | head -n 40 || echo "Пакетов TCP RST или ошибок фрагментации ICMP за время записи не обнаружено."
    echo ""
}

# ==============================================================================
# ФУНКЦИЯ 3: МОНИТОРИНГ В РЕАЛЬНОМ ВРЕМЕНИ С ЗАЩИТОЙ ОТ ОБРЫВА SSH (РЕЖИМ 3)
# ==============================================================================
run_realtime_fail_safe_recorder() {
    RT_WORK_DIR=$(mktemp -d /tmp/net_rt_recorder_XXXXXX)
    RT_PCAP_TEXT="${RT_WORK_DIR}/tcpdump_realtime.log"
    RT_SAMPLES_LOG="${RT_WORK_DIR}/socket_samples.log"
    RT_NSTAT_BEFORE="${RT_WORK_DIR}/nstat_before.log"
    RT_NSTAT_AFTER="${RT_WORK_DIR}/nstat_after.log"
    RT_LINKS_BEFORE="${RT_WORK_DIR}/links_before.log"
    RT_LINKS_AFTER="${RT_WORK_DIR}/links_after.log"

    FINALIZED=0
    RT_START_EPOCH=$(date +%s)
    RT_START_HUMAN=$(date)
    STOP_REASON="User Stop"

    SSH_PORT=$( echo "$SSH_CLIENT" | awk '{print $3}' )
    SSH_CLIENT_IP=$( echo "$SSH_CLIENT" | awk '{print $1}' )
    if [ -n "$LIVE_FILTER" ]; then
        BPF_EXPR="$LIVE_FILTER"
    elif [ -n "$SSH_PORT" ] && [ -n "$SSH_CLIENT_IP" ]; then
        BPF_EXPR="not (host $SSH_CLIENT_IP and port $SSH_PORT)"
    elif [ -n "$SSH_PORT" ]; then
        BPF_EXPR="not port $SSH_PORT"
    else
        BPF_EXPR=""
    fi

    finalize_realtime_report() {
        [ "$FINALIZED" -eq 1 ] && return
        FINALIZED=1

        trap '' INT TERM HUP QUIT PIPE

        RT_END_EPOCH=$(date +%s)
        RT_END_HUMAN=$(date)
        RT_ELAPSED=$((RT_END_EPOCH - RT_START_EPOCH))

        [ -n "$RT_TCPDUMP_PID" ] && kill -INT "$RT_TCPDUMP_PID" 2>/dev/null
        [ -n "$RT_SAMPLER_PID" ] && kill -TERM "$RT_SAMPLER_PID" 2>/dev/null
        sleep 1
        [ -n "$RT_TCPDUMP_PID" ] && kill -9 "$RT_TCPDUMP_PID" 2>/dev/null
        [ -n "$RT_SAMPLER_PID" ] && kill -9 "$RT_SAMPLER_PID" 2>/dev/null

        if command -v nstat >/dev/null 2>&1; then
            nstat -az > "$RT_NSTAT_AFTER" 2>/dev/null
        else
            cat /proc/net/snmp /proc/net/netstat > "$RT_NSTAT_AFTER" 2>/dev/null
        fi
        ip -s -s link > "$RT_LINKS_AFTER" 2>/dev/null

        {
            echo "##################################################################"
            echo "# БЛОК 2: ОТЧЕТ МОНИТОРИНГА В РЕАЛЬНОМ ВРЕМЕНИ («ЧЕРНЫЙ ЯЩИК»)   #"
            echo "##################################################################"
            echo "  Старт записи:        $RT_START_HUMAN"
            echo "  Остановка записи:    $RT_END_HUMAN"
            echo "  Длительность сессии: ${RT_ELAPSED} секунд"
            echo "  Причина остановки:   $STOP_REASON"
            echo "  Фильтр перехвата:    ${BPF_EXPR:-ВЕСЬ ТРАФИК}"
            echo "=================================================================="
            echo ""

            echo "=== [2.1] Сравнение счетчиков стека ДО и ПОСЛЕ сессии (ДЕЛЬТА за ${RT_ELAPSED} сек) ==="
            if [ -f "$RT_NSTAT_BEFORE" ] && [ -f "$RT_NSTAT_AFTER" ]; then
                awk '
                    NR==FNR { before[$1]=$2; next }
                    ($1 in before) {
                        delta = $2 - before[$1];
                        if (delta > 0 && $1 ~ /Ip|Icmp|Tcp|Udp/) {
                            printf "  %-38s : +%d (было: %d -> стало: %d)\n", $1, delta, before[$1], $2
                        }
                    }
                ' "$RT_NSTAT_BEFORE" "$RT_NSTAT_AFTER"
            fi
            echo ""

            echo "=== [2.2] Состояние интерфейсов и счетчиков дропов ПОСЛЕ завершения теста ==="
            cat "$RT_LINKS_AFTER"
            echo ""

            echo "=== [2.3] Срез сокетов и активных туннелей на момент завершения записи ==="
            collect_all_tunnels_and_proxies

            echo "=== [2.4] Журнал периодического опроса активных соединений во время теста ==="
            if [ -f "$RT_SAMPLES_LOG" ]; then
                cat "$RT_SAMPLES_LOG"
            else
                echo "Нет записей сэмплера."
            fi
            echo ""

            if [ -f "$RT_PCAP_TEXT" ] && [ -s "$RT_PCAP_TEXT" ]; then
                analyze_pcap_log "$RT_PCAP_TEXT" "2.5"

                echo "=== [2.6] Хронологический лог перехваченных IP-пакетов ==="
                TOTAL_LINES=$(wc -l < "$RT_PCAP_TEXT")
                echo "Всего зафиксировано строк в дампе пакетов: $TOTAL_LINES"
                echo ""
                if [ "$TOTAL_LINES" -le 3000 ]; then
                    cat "$RT_PCAP_TEXT"
                else
                    echo "--- [НАЧАЛО ЗАПИСИ ПАКЕТОВ (первые 1500 строк)] ---"
                    head -n 1500 "$RT_PCAP_TEXT"
                    echo ""
                    echo "... [пропущено $((TOTAL_LINES - 3000)) промежуточных строк] ..."
                    echo ""
                    echo "--- [КОНЕЦ ЗАПИСИ ПАКЕТОВ ПЕРЕД ОСТАНОВКОЙ (последние 1500 строк)] ---"
                    tail -n 1500 "$RT_PCAP_TEXT"
                fi
            else
                echo "=== [2.5] Лог tcpdump пуст или перехват был отключен ==="
            fi
            echo ""
            echo "=================================================================="
            echo " ЗАПИСЬ В РЕАЛЬНОМ ВРЕМЕНИ УСПЕШНО СОХРАНЕНА: $(date)"
            echo "=================================================================="
        } >> "$OUTPUT_FILE" 2>&1

        rm -rf "$RT_WORK_DIR"

        echo "" >&2
        echo "==========================================================================" >&2
        echo "[+] ЗАПИСЬ ОСТАНОВЛЕНА ($STOP_REASON). Длительность: ${RT_ELAPSED} сек." >&2
        echo "[+] Полный отчет реального времени надежно сохранен в файл:" >&2
        echo "    $OUTPUT_FILE" >&2
        echo "==========================================================================" >&2
        exit 0
    }

    trap 'STOP_REASON="Ручная остановка пользователем (SIGINT / Ctrl+C)"; finalize_realtime_report' INT QUIT
    trap 'STOP_REASON="Сигнал завершения процесса (SIGTERM)"; finalize_realtime_report' TERM
    trap 'STOP_REASON="Обрыв SSH-канала управления (SIGHUP Fail-Safe)"; finalize_realtime_report' HUP
    trap 'STOP_REASON="Разрыв потока терминала (SIGPIPE Fail-Safe)"; finalize_realtime_report' PIPE
    trap 'STOP_REASON="Завершение скрипта (EXIT)"; finalize_realtime_report' EXIT

    {
        echo "=================================================================="
        echo " SERVER NETWORK & CASCADE DIAGNOSTIC REPORT (v3.1 - REAL-TIME MODE)"
        echo " Date:     $RT_START_HUMAN"
        echo " Hostname: $HOST_NAME"
        echo " Kernel:   $(uname -a)"
        echo " Mode:     3 (Real-Time Fail-Safe Recorder)"
        echo " Filter:   ${BPF_EXPR:-ALL (excluding current SSH)}"
        echo "=================================================================="
        echo ""
        collect_base_system_info
    } > "$OUTPUT_FILE" 2>&1

    if command -v nstat >/dev/null 2>&1; then
        nstat -az > "$RT_NSTAT_BEFORE" 2>/dev/null
    else
        cat /proc/net/snmp /proc/net/netstat > "$RT_NSTAT_BEFORE" 2>/dev/null
    fi
    ip -s -s link > "$RT_LINKS_BEFORE" 2>/dev/null

    RT_TCPDUMP_PID=""
    if [ "$DO_PCAP" -eq 1 ] && command -v tcpdump >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
        if [ -n "$BPF_EXPR" ]; then
            tcpdump -i any -nn -v -tt -l "$BPF_EXPR" > "$RT_PCAP_TEXT" 2>&1 &
        else
            tcpdump -i any -nn -v -tt -l > "$RT_PCAP_TEXT" 2>&1 &
        fi
        RT_TCPDUMP_PID=$!
    fi

    (
        SAMPLE_NUM=0
        while true; do
            SAMPLE_NUM=$((SAMPLE_NUM + 1))
            {
                echo ">>> [СЭМПЛ #${SAMPLE_NUM} | Время: $(date +%H:%M:%S) (+$(( $(date +%s) - RT_START_EPOCH ))s)] <<<"
                echo "[Активные TCP-соединения с ненулевой очередью или трафиком]:"
                if [ -n "$LIVE_FILTER" ]; then
                    CLEAN_IP=$(echo "$LIVE_FILTER" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 || true)
                    if [ -n "$CLEAN_IP" ]; then
                        ss -tin state established | grep -A 1 -E "${CLEAN_IP}|10\.200\.200\.|100\.|172\.16\.|:443 " | head -n 40 || echo "  (нет активных TCP-соединений каскада в эту секунду)"
                    else
                        ss -tin state established | head -n 30
                    fi
                else
                    if [ -n "$SSH_PORT" ]; then
                        ss -tin state established | grep -v -B 0 -A 1 ":$SSH_PORT " | head -n 40
                    else
                        ss -tin state established | head -n 40
                    fi
                fi
                echo ""
                echo "[Сводка сокетов (ss -s) и conntrack]:"
                ss -s | grep -E "Total:|TCP:|UDP:"
                if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
                    echo "Conntrack active: $(cat /proc/sys/net/netfilter/nf_conntrack_count)"
                fi
                echo "------------------------------------------------------------------"
            } >> "$RT_SAMPLES_LOG" 2>&1
            sleep "$RT_SAMPLE_INTERVAL"
        done
    ) &
    RT_SAMPLER_PID=$!

    echo ""
    echo "=========================================================================="
    echo " [!] РЕЖИМ МОНИТОРИНГА В РЕАЛЬНОМ ВРЕМЕНИ АКТИВИРОВАН!"
    echo "--------------------------------------------------------------------------"
    echo "  * Файл отчета:        $OUTPUT_FILE"
    echo "  * Фильтр пакетов:     ${BPF_EXPR:-весь трафик}"
    echo "  * Интервал сэмплов:   каждые ${RT_SAMPLE_INTERVAL} сек."
    echo "  * Авто-таймаут:       ${MAX_RT_TIME} сек."
    echo "--------------------------------------------------------------------------"
    echo "  ТЕПЕРЬ ВЫ МОЖЕТЕ ПОЛЬЗОВАТЬСЯ КАСКАДОМ / ТЕСТИРОВАТЬ СОЕДИНЕНИЕ."
    echo ""
    echo "  Как остановить запись и сохранить отчет:"
    echo "    Способ Б (Штатный):  Нажмите [ENTER], введите 'q' или нажмите [Ctrl+C]"
    echo "    Способ А (Аварийный): Обрыв SSH-канала перехватится автоматически!"
    echo "=========================================================================="

    ELAPSED_WAIT=0
    while [ "$ELAPSED_WAIT" -lt "$MAX_RT_TIME" ]; do
        if [ -t 0 ]; then
            if read -r -t 2 USER_CMD; then
                STOP_REASON="Пользователь нажал Enter / ввел команду остановки ('$USER_CMD')"
                finalize_realtime_report
            fi
            READ_STATUS=$?
            if [ "$READ_STATUS" -eq 1 ]; then
                STOP_REASON="Обнаружено закрытие входного потока SSH (EOF на stdin)"
                finalize_realtime_report
            fi
        else
            sleep 2
        fi
        ELAPSED_WAIT=$((ELAPSED_WAIT + 2))
        if [ $((ELAPSED_WAIT % 10)) -eq 0 ]; then
            PKT_CNT=0
            [ -f "$RT_PCAP_TEXT" ] && PKT_CNT=$(wc -l < "$RT_PCAP_TEXT")
            echo -ne "\r[*] Идет запись: ${ELAPSED_WAIT} сек. | Перехвачено строк пакетов: ${PKT_CNT} ... (Нажмите Enter или Ctrl+C для СТОП) "
        fi
    done

    STOP_REASON="Достигнут максимальный страховочный таймер (${MAX_RT_TIME} сек)"
    finalize_realtime_report
}

# ==============================================================================
# ФУНКЦИЯ 4: АКТИВНОЕ ТЕСТИРОВАНИЕ КАСКАДНОЙ ПАРЫ СЕРВЕРОВ (РЕЖИМ 2)
# ==============================================================================
collect_active_pair_tests() {
    if [ ${#TARGETS[@]} -eq 0 ]; then
        echo "##################################################################"
        echo "# БЛОК 3: АКТИВНОЕ ТЕСТИРОВАНИЕ ПАРЫ ПРОПУЩЕНО (НЕ УКАЗАНЫ IP)   #"
        echo "##################################################################"
        echo ""
        return
    fi

    echo "##################################################################"
    echo "# БЛОК 3: АКТИВНАЯ ПРОВЕРКА КАСКАДНОЙ ПАРЫ ДО ЦЕЛЕВЫХ СЕРВЕРОВ"
    echo "##################################################################"
    echo ""

    IFS=',' read -r -a T_PORTS <<< "$TCP_PORTS"
    IFS=',' read -r -a U_PORTS <<< "$UDP_PORTS"

    for TARGET in "${TARGETS[@]}"; do
        echo "=================================================================="
        echo " >>> АНАЛИЗ КАСКАДНОЙ ПАРЫ: $HOST_NAME  <===>  $TARGET"
        echo "=================================================================="
        echo ""

        echo "--- [3.1] Маршрут ядра и кэш PMTU до $TARGET ---"
        ip -d route get "$TARGET"
        echo ""

        echo "--- [3.2] Проверка ICMP Ping ---"
        ping -c 10 -i 0.2 -W 2 "$TARGET"
        echo ""

        echo "--- [3.3] Поиск реального Path MTU (PMTU Discovery с флагом DF) ---"
        FOUND_MTU=0
        for PAYLOAD in 1472 1464 1452 1422 1392 1372 1332 1252; do
            MTU_VAL=$((PAYLOAD + 28))
            if ping -c 2 -M do -s "$PAYLOAD" -W 1 "$TARGET" >/dev/null 2>&1; then
                echo "  [+] УСПЕХ: Payload ${PAYLOAD} байт -> Path MTU >= ${MTU_VAL} (TCP MSS <= $((MTU_VAL - 40)))"
                if [ "$FOUND_MTU" -eq 0 ]; then
                    FOUND_MTU=$MTU_VAL
                fi
                break
            else
                echo "  [-] БЛОК/ФРАГМЕНТАЦИЯ: Payload ${PAYLOAD} байт (MTU ${MTU_VAL}) НЕ проходит"
            fi
        done
        echo ""

        echo "--- [3.4] Трассировка маршрута (MTR / Traceroute) ---"
        if command -v mtr >/dev/null 2>&1; then
            mtr -r -w -c 10 -n "$TARGET"
        elif command -v traceroute >/dev/null 2>&1; then
            traceroute -n -I -q 2 -w 2 "$TARGET"
        else
            echo "[!] Не найдены mtr или traceroute."
        fi
        echo ""

        echo "--- [3.5] Проверка открытости TCP и UDP портов ---"
        for P in "${T_PORTS[@]}"; do
            if timeout 2 bash -c "</dev/tcp/$TARGET/$P" 2>/dev/null; then
                echo "  [TCP $P] ОТКРЫТ"
            else
                echo "  [TCP $P] НЕДОСТУПЕН/ЗАКРЫТ"
            fi
        done
        echo ""

        echo "--- [3.7] Проверка TLS Handshake и HTTP/HTTPS (порт 443) ---"
        if command -v curl >/dev/null 2>&1; then
            curl -I -k -s -S --connect-timeout 3 -m 5 \
                -w "\n[Метрики Curl] DNS: %{time_namelookup}s | TCP: %{time_connect}s | TLS: %{time_appconnect}s | Total: %{time_total}s\n" \
                "https://${TARGET}:443" 2>&1
        else
            echo "[!] Утилита curl не установлена."
        fi
        echo ""

        echo "--- [3.8] Тестирование пропускной способности (iperf3 на порт $IPERF_PORT) ---"
        if command -v iperf3 >/dev/null 2>&1; then
            iperf3 -c "$TARGET" -p "$IPERF_PORT" -P 2 -t 3 --connect-timeout 2000 2>&1 || echo "  [!] iperf3 сервер недоступен."
        else
            echo "[!] Утилита iperf3 не установлена."
        fi
        echo ""
    done
}

# ==============================================================================
# ГЛАВНЫЙ ПЕРЕКЛЮЧАТЕЛЬ РЕЖИМОВ
# ==============================================================================

if [ "$MODE" = "3" ]; then
    run_realtime_fail_safe_recorder
    exit 0
fi

echo "[*] Хост: $HOST_NAME | Выбран режим: $MODE ($MODE_TAG)"
echo "[*] Папка сохранения отчетов: $OUT_DIR"
echo "[*] Файл отчета: $OUTPUT_FILE"

{
    echo "=================================================================="
    echo " SERVER NETWORK & CASCADE DIAGNOSTIC REPORT (v3.1)"
    echo " Date:     $(date)"
    echo " Hostname: $HOST_NAME"
    echo " Kernel:   $(uname -a)"
    echo " Mode:     $MODE ($MODE_TAG)"
    if [ "$MODE" = "1" ] || [ "$MODE" = "4" ]; then
        echo " Live Capture Duration: ${LIVE_DURATION}s | Filter: ${LIVE_FILTER:-ALL}"
    fi
    if [ "$MODE" = "2" ] || [ "$MODE" = "4" ]; then
        echo " Target Pair IPs:       ${TARGETS[*]:-None}"
    fi
    echo "=================================================================="
    echo ""

    if [ "$EUID" -ne 0 ]; then
        echo "[ВНИМАНИЕ] Скрипт запущен БЕЗ прав root (sudo)!"
        echo ""
    fi

    collect_base_system_info

    case "$MODE" in
        1)
            collect_live_cascade_state
            ;;
        2)
            collect_active_pair_tests
            ;;
        4)
            collect_live_cascade_state
            collect_active_pair_tests
            ;;
    esac

    echo "=================================================================="
    echo " ДИАГНОСТИКА ЗАВЕРШЕНА: $(date)"
    echo "=================================================================="

} > "$OUTPUT_FILE" 2>&1

echo "[+] Готово! Отчет сохранен в файл:"
echo "    $OUTPUT_FILE"
NET_AUDIT_EOF
    chmod +x /usr/local/bin/bobarev-network-audit.sh
    ln -sf /usr/local/bin/bobarev-network-audit.sh /usr/local/bin/network-audit 2>/dev/null || true
}

mod_network_cascade_audit() {
    install_network_audit_tool
    while true; do
        MODULE_CANCELED=false
        local default_peer_ip=""
        if [ -f /etc/default/bobarev-cascade ]; then
            # shellcheck disable=SC1091
            source /etc/default/bobarev-cascade
            if [ -n "${FOREIGN_WG_ENDPOINT:-}" ]; then
                default_peer_ip=$(echo "$FOREIGN_WG_ENDPOINT" | cut -d: -f1)
            elif [ -n "${EXIT_TS_IP:-}" ]; then
                default_peer_ip="$EXIT_TS_IP"
            fi
        fi

        local na_choice=""
        if ! smart_menu " 26/27. Аудит системы 2 и каскадные пары (v3.1)" "\nВыберите режим диагностики сети, туннелей и обхода ТСПУ:\n(Отчет сохраняется в домашнюю директорию пользователя)" 19 $WT_WIDTH 6 "na_choice" \
        "1" " Срез состояния системы" \
        "2" " Тест связи между серверами" \
        "3" " Мониторинг трафика Live" \
        "4" " Полный комплексный аудит" \
        "5" " Запуск консольного меню" \
        "0" " Вернуться в главное меню" || [ "$na_choice" = "0" ]; then
            break
        fi

        clear
        case "$na_choice" in
            1)
                local dur="15"
                prompt_default "Сколько секунд записывать срез живых IP-пакетов (tcpdump)?" "15" dur
                if [ "$MODULE_CANCELED" = true ]; then continue; fi
                dur="${dur//[^0-9]/}"
                [ -z "$dur" ] && dur="15"

                local flt=""
                prompt_default "IP второго узла для фильтрации (оставьте пустым для записи ВСЕГО трафика):" "$default_peer_ip" flt
                if [ "$MODULE_CANCELED" = true ]; then continue; fi

                if [ -n "$flt" ]; then
                    if [[ "$flt" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        flt="host $flt"
                    fi
                    /usr/local/bin/bobarev-network-audit.sh -m 1 -d "$dur" -f "$flt" || true
                else
                    /usr/local/bin/bobarev-network-audit.sh -m 1 -d "$dur" || true
                fi
                pause_enter
                ;;
            2)
                local target_ips=""
                prompt_default "Введите IP целевого сервера(ов) через пробел для проверки пары:" "$default_peer_ip" target_ips
                if [ "$MODULE_CANCELED" = true ] || [ -z "$target_ips" ]; then continue; fi

                local t_ports="22,80,443,8080,8443,51888"
                prompt_default "TCP-порты для проверки открытости (через запятую):" "$t_ports" t_ports
                if [ "$MODULE_CANCELED" = true ]; then continue; fi

                local u_ports="53,443,51820,51888,1194"
                prompt_default "UDP-порты для проверки (через запятую):" "$u_ports" u_ports
                if [ "$MODULE_CANCELED" = true ]; then continue; fi

                /usr/local/bin/bobarev-network-audit.sh -m 2 -t "$target_ips" -p "$t_ports" -u "$u_ports" || true
                pause_enter
                ;;
            3)
                local flt_rt=""
                prompt_default "IP второго узла/клиента для фильтрации (пусто — весь трафик кроме SSH):" "$default_peer_ip" flt_rt
                if [ "$MODULE_CANCELED" = true ]; then continue; fi

                local max_rt="3600"
                prompt_default "Максимальный страховочный таймер авто-остановки (сек):" "3600" max_rt
                if [ "$MODULE_CANCELED" = true ]; then continue; fi
                max_rt="${max_rt//[^0-9]/}"
                [ -z "$max_rt" ] && max_rt="3600"

                if [ -n "$flt_rt" ]; then
                    if [[ "$flt_rt" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        flt_rt="host $flt_rt"
                    fi
                    /usr/local/bin/bobarev-network-audit.sh -m 3 -d "$max_rt" -f "$flt_rt" || true
                else
                    /usr/local/bin/bobarev-network-audit.sh -m 3 -d "$max_rt" || true
                fi
                pause_enter
                ;;
            4)
                local dur_c="15"
                prompt_default "Сколько секунд записывать срез IP-пакетов в Режиме 1?" "15" dur_c
                if [ "$MODULE_CANCELED" = true ]; then continue; fi
                dur_c="${dur_c//[^0-9]/}"
                [ -z "$dur_c" ] && dur_c="15"

                local target_ips_c=""
                prompt_default "Введите IP целевого сервера(ов) через пробел для Режима 2:" "$default_peer_ip" target_ips_c
                if [ "$MODULE_CANCELED" = true ] || [ -z "$target_ips_c" ]; then continue; fi

                /usr/local/bin/bobarev-network-audit.sh -m 4 -d "$dur_c" -t "$target_ips_c" || true
                pause_enter
                ;;
            5)
                /usr/local/bin/bobarev-network-audit.sh || true
                pause_enter
                ;;
        esac
    done
}

run_full_auto_setup() {
    echo " ЗАПУСК ПОСЛЕДОВАТЕЛЬНОЙ НАСТРОЙКИ ВСЕХ КОМПОНЕНТОВ..."
    local local_aborted=false
    for m in mod_timezone mod_hostname mod_apt_update mod_user_setup mod_ssh_key mod_ssh_config mod_hardening mod_ufw mod_lock_root_auto mod_tailscale_auto mod_logging_manager_auto mod_ram_flash_opt; do
        MODULE_CANCELED=false
        $m
        if [ "$MODULE_CANCELED" = true ]; then
            echo -e "${C_YELLOW} Автоматическая настройка прервана.${C_RESET}"
            local_aborted=true
            break
        fi
    done
    if [ "$local_aborted" = false ]; then echo -e "\n${C_GREEN} ВСЕ ЭТАПЫ НАСТРОЙКИ УСПЕШНО ЗАВЕРШЕНЫ!${C_RESET}"; fi
    MODULE_CANCELED=false
}


nm_reload_caddy() {
 local cb="${CADDY_BIN:-/usr/local/bin/caddy}" cf="${CADDYFILE:-/etc/caddy/Caddyfile}"
 [[ -x "$cb" ]] || cb=$(command -v caddy) || { echo 'Не найден Caddy.' >&2; return 1; }
 "$cb" validate --config "$cf" --adapter caddyfile || return 1
 "$cb" reload --config "$cf" --adapter caddyfile --force || {
  echo 'Caddy не принял конфигурацию через admin API. Автоматического restart не будет.' >&2
  return 1
 }
}

nm_prompt() {
 local value
 if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
  value=$(whiptail --inputbox "$1" 11 "${WT_WIDTH:-85}" "$2" 3>&1 1>&2 2>&3) || return 1
  printf -v "$3" '%s' "${value:-$2}"
 else
  IFS= read -r -p "$1 [$2]: " value || return 1
  printf -v "$3" '%s' "${value:-$2}"
 fi
}
nm_state() { systemctl is-active "$1.service" 2>/dev/null || true; }
nm_detect_role() {
 local bridge=0 exitnode=0
 [[ "$(nm_state xray-mesh-socks)" != active ]] || exitnode=1
 if [[ "$(nm_state naive-mesh-bridge)" == active || "$(nm_state gost-mesh)" == active || -f /etc/naiveproxy/mesh-upstream.port ]]; then bridge=1; fi
 if ((bridge && exitnode)); then echo mixed
 elif ((exitnode)); then echo 2
 elif ((bridge)); then echo 1
 else echo unknown; fi
}

nm_status() {
 local role="${1:-}" unit label state optional
 [[ -n "$role" ]] || role=$(nm_detect_role)
 echo 'ЛОКАЛЬНАЯ ДИАГНОСТИКА — настройки не меняются'
 case "$role" in 1) echo 'Сервер 1 — вход (по выбранному мастеру или признакам служб).' ;; 2) echo 'Сервер 2 — выход (по выбранному мастеру или признакам служб).' ;; *) echo 'Назначение сервера не определено однозначно.' ;; esac
 [[ ! -f /etc/naiveproxy/mesh-paused ]] || echo 'NaiveProxy приостановлен. Управление: раздел управления.'
 for unit in xraymesh caddy xray-mesh-socks microsocks-local naive-mesh-bridge gost-mesh; do
  optional=no
  case "$unit" in
   xraymesh) label='Связь между серверами' ;;
   caddy) label='Вход NaiveProxy'; [[ "$role" != 2 ]] || optional=yes ;;
   xray-mesh-socks) label='Xray SOCKS'; [[ "$role" != 1 ]] || optional=yes ;;
   microsocks-local) label='Старый microsocks'; optional=yes ;;
   naive-mesh-bridge) label='Локальный мост'; [[ "$role" != 2 ]] || optional=yes ;;
   gost-mesh) label='Альтернативный мост'; [[ "$role" != 2 ]] || optional=yes ;;
  esac
  state=$(nm_state "$unit")
  if [[ "$state" == active ]]; then echo "$label: запущено."
  elif [[ "$optional" == yes ]]; then echo "$label: не требуется на этом сервере."
  elif [[ "$state" == failed ]]; then echo "$label: остановлено из-за ошибки."
  else echo "$label: не запущено или ещё не установлено."; fi
 done
 [[ "$role" != 1 ]] || echo 'Достаточно одного работающего варианта локального моста.'
 echo 'Сетевые адреса:'; ip -br -4 address || true
 echo 'Узлы внутренней сети:'
 if [[ -x /opt/xraymesh/bin/easytier-cli ]]; then /opt/xraymesh/bin/easytier-cli peer || echo 'Список недоступен.'; fi
 echo 'Это состояние текущего сервера, не тест всей цепочки.'
}
nm_mesh() (
 # Opening the menu must use the installed CLI, never the online installer.
 local tmp rc installed
 if [[ $# -eq 0 ]]; then
  installed=$(type -P xraymesh || true)
  if [[ -z "$installed" || ! -x "$installed" ]]; then
   echo 'Установленная команда xraymesh не найдена в PATH.' >&2
   echo 'Установщик автоматически не запускается. Проверьте: command -v xraymesh' >&2
   exit 127
  fi
  "$installed"
  rc=$?
  exit "$rc"
 fi
 command -v curl >/dev/null || { echo 'Установите curl и ca-certificates.'; exit 1; }
 tmp=$(mktemp -d) || exit 1
 trap 'rm -rf -- "$tmp"' EXIT
 echo 'Загрузка официального XRayMesh (main)...'
 if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 --retry 2 https://raw.githubusercontent.com/Erfan-XRay/XRayMesh/main/xraymesh.sh -o "$tmp/xraymesh.sh"; then
  echo 'Ошибка загрузки. Локальная копия не используется.'; exit 1
 fi
 [[ -s "$tmp/xraymesh.sh" ]] && bash -n "$tmp/xraymesh.sh" || { echo 'Пустой или синтаксически неверный файл.'; exit 1; }
 bash "$tmp/xraymesh.sh" "$@"; rc=$?; exit "$rc"
)
nm_load() {
 NM_ENTRY=10.144.144.1 NM_EXIT=10.144.144.2 NM_SOCKS=1080 NM_LOCAL=10808
 NM_SERVER1=server1 NM_SERVER2=server2
 [[ ! -f /etc/naiveproxy/mesh-wizard.env ]] || source /etc/naiveproxy/mesh-wizard.env
}
nm_questions() {
 nm_load
 local key
 nm_prompt 'Название сервера 1 (вход)' "$NM_SERVER1" NM_SERVER1 || return 1
 nm_prompt 'Название сервера 2 (выход)' "$NM_SERVER2" NM_SERVER2 || return 1
 nm_prompt 'Реальный mesh IPv4 сервера 1' "$NM_ENTRY" NM_ENTRY || return 1
 nm_prompt 'Реальный mesh IPv4 сервера 2' "$NM_EXIT" NM_EXIT || return 1
 nm_prompt 'SOCKS-порт сервера 2' "$NM_SOCKS" NM_SOCKS || return 1
 nm_prompt 'Порт localhost-моста сервера 1' "$NM_LOCAL" NM_LOCAL || return 1
 python3 - "$NM_ENTRY" "$NM_EXIT" "$NM_SOCKS" "$NM_LOCAL" <<'NM_VALIDATE'
import ipaddress,sys
ips=[ipaddress.IPv4Address(v) for v in sys.argv[1:3]]
if ips[0]==ips[1] or not all(v.is_private and not v.is_loopback and not v.is_link_local and not v.is_unspecified and not v.is_multicast for v in ips):
 raise SystemExit('Нужны два различных частных mesh IPv4')
for v in sys.argv[3:]:
 if not v.isdecimal() or not 1024<=int(v)<=65535: raise SystemExit('Порты: 1024..65535')
NM_VALIDATE
 [[ $? == 0 ]] || return 1
 mkdir -p /etc/naiveproxy
 (umask 077; for key in NM_ENTRY NM_EXIT NM_SOCKS NM_LOCAL NM_SERVER1 NM_SERVER2; do printf '%s=%q\n' "$key" "${!key}"; done > /etc/naiveproxy/mesh-wizard.env)
}
nm_helper() (
 local tmp rc
 tmp=$(mktemp -d) || exit 1
 trap 'rm -rf -- "$tmp"' EXIT
 case "$1" in 1) nm_write_entry > "$tmp/helper.sh" ;; 2) nm_write_exit > "$tmp/helper.sh" ;; *) exit 1 ;; esac
 env ENTRY_IP="$NM_ENTRY" EXIT_IP="$NM_EXIT" SOCKS_PORT="$NM_SOCKS" LOCAL_PORT="$NM_LOCAL" bash "$tmp/helper.sh"
 rc=$?; exit "$rc"
)
nm_apply() {
 [[ ! -f /etc/naiveproxy/mesh-paused ]] || { echo "Каскад на паузе. Сначала выберите возобновление или отключение в меню управления."; return 1; }
 command -v python3 >/dev/null || { echo 'Установите python3'; return 1; }
 nm_questions || return 1
 local role="${1:-}" answer
 [[ "$role" == 1 || "$role" == 2 ]] || return 1
 echo 'Это изменение конфигурации. Работающую связку применять повторно не требуется.'
 nm_prompt 'Применить? Введите YES' no answer || return 1
 [[ "$answer" == YES ]] || return 2
 if [[ "$role" == 2 ]]; then
  if ! command -v ufw >/dev/null || ! LC_ALL=C ufw status | grep -q '^Status: active'; then
   echo "Ограничьте firewall/ACL: $NM_ENTRY -> $NM_EXIT:$NM_SOCKS. Xray SOCKS без аутентификации."
   nm_prompt 'ACL уже настроен? Введите ACL-READY' no answer || return 1
   [[ "$answer" == ACL-READY ]] || return 1
  fi
 else
  systemctl is-active --quiet caddy || { echo 'Сначала настройте NaiveProxy через пункт 22.'; return 1; }
  if [[ -f /etc/default/bobarev-cascade ]]; then
   local CASCADE_ROLE=''
   source /etc/default/bobarev-cascade
   [[ ( "$CASCADE_ROLE" == standalone_naive || "$CASCADE_ROLE" == none ) && "${NAIVE_OUT_MODE:-direct}" == direct ]] || { echo 'Сначала отключите другой каскад/WG.'; return 1; }
  fi
 fi
 nm_helper "$role" || return 1
 if [[ "$role" == 1 ]]; then (umask 077; printf '%s\n' "$NM_LOCAL" > /etc/naiveproxy/mesh-upstream.port); fi
}

nm_yes() {
 if command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]]; then
  whiptail --yesno "$1" 12 "${WT_WIDTH:-85}" --defaultno
  return $?
 fi
 local answer
 nm_prompt "$1 Введите ДА" нет answer || return 1
 [[ "$answer" == ДА || "$answer" == да || "$answer" == YES ]]
}
nm_bound() {
 [[ -f /etc/naiveproxy/mesh-upstream.port || -f /etc/naiveproxy/mesh-paused ]] && return 0
 if [[ "$(nm_state naive-mesh-bridge)" == active || "$(nm_state gost-mesh)" == active ]]; then
  grep -Eq '^[[:space:]]*upstream[[:space:]]+socks5://127\.0\.0\.1:' /etc/caddy/Caddyfile 2>/dev/null && return 0
 fi
 return 1
}
nm_direct_candidate() {
 python3 - "$1" "$2" <<'NM_DIRECT'
import pathlib,re,sys
src,dst=map(pathlib.Path,sys.argv[1:])
s=src.read_text()
if re.search(r'(?m)^\s*import\s',s): raise SystemExit('Конфигурация с внешними включениями: автоматическое переключение остановлено.')
blocks=list(re.finditer(r'(?m)^[ \t]*forward_proxy\s*\{[^\S\n]*(?:#.*)?$',s))
if len(blocks)!=1: raise SystemExit('Нужен один простой блок прокси. Настройки не изменены.')
a=blocks[0].end();b=s.find('}',a)
if b<0 or '{' in s[a:b]: raise SystemExit('Сложная конфигурация: настройки не изменены.')
block=s[a:b]
up=list(re.finditer(r'(?m)^[ \t]*upstream\s+([^\n]+)\n?',block))
if len(up)>1: raise SystemExit('Несколько направлений выхода: автоматическое переключение остановлено.')
if up:
 value=up[0].group(1).strip()
 if not re.fullmatch(r'socks5://127\.0\.0\.1:[0-9]{1,5}',value): raise SystemExit('Неизвестное направление выхода. Настройки не изменены.')
 block=block[:up[0].start()]+block[up[0].end():]
dst.write_text(s[:a]+block+s[b:])
NM_DIRECT
}
nm_direct() {
 local cf=/etc/caddy/Caddyfile cb=/usr/local/bin/caddy backup tmp paused=0
 echo 'ВОЗВРАТ К ВЫХОДУ ЧЕРЕЗ ЭТОТ СЕРВЕР'
 echo 'Клиенты NaiveProxy больше не будут направляться на сервер 2.'
 echo 'Это может раскрыть IP сервера 1. Внешние VPN/маршруты автоматически не отключаются.'
 nm_yes 'Переключить выход?' || return 2
 [[ -f "$cf" && ! -L "$cf" ]] || { echo 'Не найден обычный файл настроек Caddy. Ничего не изменено.'; return 1; }
 [[ -x "$cb" ]] || { echo 'Не найден используемый бинарник Caddy.'; return 1; }
 command -v python3 >/dev/null || { echo 'Нужен Python 3.'; return 1; }
 # Do not silently switch unrelated BOBAREV cascades.
 if [[ -f /etc/default/bobarev-cascade ]] && ! grep -Eq '^CASCADE_ROLE="(standalone_naive|none)"$' /etc/default/bobarev-cascade; then
  echo 'Обнаружен другой каскад. Автоматическое переключение остановлено.'; return 1
 fi
 backup=$(mktemp -d /root/bobarev-direct-backup-XXXXXXXX) || return 1
 chmod 700 "$backup"
 cp -a "$cf" "$backup/Caddyfile" || return 1
 mkdir -p /etc/naiveproxy
 [[ ! -f /etc/naiveproxy/mesh-upstream.port ]] || cp -a /etc/naiveproxy/mesh-upstream.port "$backup/"
 [[ ! -f /etc/naiveproxy/mesh-paused ]] || paused=1
 tmp="$backup/candidate"
 nm_direct_candidate "$cf" "$tmp" || return 1
 "$cb" validate --config "$tmp" --adapter caddyfile || { echo 'Проверка не пройдена. Рабочие настройки сохранены.'; return 1; }
 cat "$tmp" > "$cf" || { cp -a "$backup/Caddyfile" "$cf"; return 1; }
 if systemctl is-active --quiet caddy.service; then
  if ! nm_reload_caddy; then
   cp -a "$backup/Caddyfile" "$cf"; nm_reload_caddy || echo 'ВНИМАНИЕ: прежний файл восстановлен, но применить его к Caddy не удалось.' >&2
   echo 'Не удалось применить. Прежняя конфигурация восстановлена.'; return 1
  fi
 else
  if ! systemctl start caddy.service; then
   cp -a "$backup/Caddyfile" "$cf"
   echo 'Не удалось запустить Caddy. Прежняя конфигурация восстановлена.'; return 1
  fi
 fi
 # Only remove the mode markers AFTER successful validation and service application.
 rm -f /etc/naiveproxy/mesh-upstream.port /etc/naiveproxy/mesh-paused
 systemctl enable caddy.service >/dev/null || echo 'Не удалось включить автозапуск Caddy. Проверьте отдельно.'
 echo 'NaiveProxy переключён на маршрутизацию текущего сервера.'
 echo "Резервная копия: $backup"
 echo 'XRayMesh и компоненты второго сервера не удалены.'
}
nm_pause() {
 nm_bound || { echo 'Активная привязка NaiveProxy к mesh не обнаружена.'; return 1; }
 echo 'Будет остановлен Caddy целиком: NaiveProxy и сайты, которые он обслуживает.'
 echo 'Перехода на прямой выход НЕ будет. XRayMesh и другие сетевые службы останутся запущены.'
 nm_yes 'Приостановить?' || return 2
 systemctl stop caddy.service || return 1
 systemctl disable caddy.service >/dev/null || { echo 'Служба остановлена, но отключить автозапуск не удалось.'; return 1; }
 mkdir -p /etc/naiveproxy
 (umask 077; printf 'paused\n' > /etc/naiveproxy/mesh-paused)
 echo 'Каскад приостановлен. Для запуска используйте «Возобновить».'
}
nm_resume() {
 [[ -f /etc/naiveproxy/mesh-paused ]] || { echo 'Сохранённая пауза не найдена. Используйте мастер сервера 1 для настройки.'; return 1; }
 nm_yes 'Запустить Caddy с сохранённой конфигурацией каскада?' || return 2
 /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || return 1
 systemctl enable caddy.service >/dev/null && systemctl start caddy.service || return 1
 systemctl is-active --quiet caddy.service || return 1
 rm -f /etc/naiveproxy/mesh-paused
 echo 'Caddy запущен. Проверьте соединение Shadowrocket; доступность выхода отдельно не проверялась.'
}
nm_remove_proxy_parts() {
 if nm_bound; then echo 'Сначала переключите NaiveProxy на выход через этот сервер (пункт 3).'; return 1; fi
 echo 'Удаляются только известные локальные службы моста и выхода: socat/GOST mesh и старый microsocks mesh.'
 echo 'XRayMesh, Caddy, пакеты и правила firewall не удаляются.'
 echo 'На сервере 2 это отключит выход для подключённых к нему клиентов.'
 nm_yes 'Отключить и удалить эти локальные службы?' || return 2
 local unit
 for unit in naive-mesh-bridge gost-mesh xray-mesh-socks realm-mesh microsocks-mesh microsocks-local; do
  if [[ -f "/etc/systemd/system/$unit.service" ]]; then
   systemctl disable --now "$unit.service" || { echo "Не удалось остановить $unit; удаление прервано."; return 1; }
   rm -f "/etc/systemd/system/$unit.service"
  fi
 done
 systemctl daemon-reload || return 1
 echo 'Локальные службы удалены. Правила firewall оставлены: проверьте их отдельно.'
}
nm_lifecycle() {
 local choice
 while true; do
  if ! smart_menu 'Управление каскадом' 'Действия выполняются только на текущем сервере.
Возврат прямого выхода выполняйте на сервере 1.' 22 "$WT_WIDTH" 7 choice \
   '1' 'Пауза NaiveProxy' \
   '2' 'Возобновить NaiveProxy' \
   '3' 'Прямой выход (сервер 1)' \
   '4' 'Удаление локальных служб...' \
   '5' 'Остановить XRayMesh...' \
   '6' 'Удалить XRayMesh...' \
   '0' 'Вернуться в меню'; then break; fi
  case "$choice" in
   0) break ;;
   1) nm_pause || echo 'Пауза не завершена или отменена'; pause_enter ;;
   2) nm_resume || echo 'Возобновление не завершено или отменено'; pause_enter ;;
   3) nm_direct || echo 'Переключение не завершено или отменено'; pause_enter ;;
   4) nm_remove_proxy_parts || echo 'Удаление не завершено или отменено'; pause_enter ;;
   5|6)
    if nm_bound; then echo 'Сначала выберите пункт 3: Caddy ещё привязан к mesh.'
    else
     echo 'Отключатся ВСЕ локальные туннели XRayMesh, включая дополнительные пересылки и сервисы.'
     echo 'Это может нарушить работу других клиентов и SSH через mesh. Используйте прямой доступ или консоль провайдера.'
     if nm_yes 'Продолжить?'; then
      if [[ "$choice" == 5 ]]; then nm_mesh stop || echo 'Не удалось остановить все службы. Проверьте состояние.'
      else nm_mesh uninstall || echo 'Удаление не завершено'; fi
     fi
    fi
    pause_enter ;;
  esac
 done
}

nm_ready() { [[ -f /etc/xraymesh/config.env ]] && systemctl is-active --quiet xraymesh.service; }
nm_wizard() {
 local target="$1"
 echo "НАСТРОЙКА СЕРВЕРА $target. Сначала сервер 2 — выход; затем сервер 1 — вход."
 nm_yes 'Продолжить на этом сервере?' || return 2
 if nm_ready; then echo 'Работающая сеть сохраняется.'
 else
  if [[ "$target" == 2 ]]; then echo 'В официальном мастере выберите Create, задайте внутренний адрес сервера 2 и включите шифрование.'; nm_mesh setup-node || return 1
  else echo 'Вставьте код подключения сервера 2.'; nm_mesh join || return 1; fi
  nm_ready || { echo 'XRayMesh ещё не готов.'; return 1; }
 fi
 if [[ "$target" == 1 ]] && ! systemctl is-active --quiet caddy.service; then
  setup_standalone_naive
  systemctl is-active --quiet caddy.service || return 1
 fi
 nm_apply "$target" || return 1
 nm_status "$target"
 if [[ "$target" == 2 ]]; then
  if nm_yes 'Показать код подключения сервера 1?'; then nm_mesh invite || return 1; fi
 else echo 'Проверьте внешний IP через Shadowrocket.'; fi
}
nm_tools_menu() {
 local c
 while true; do
  if ! smart_menu 'Сеть XRayMesh' 'Изменения только после подтверждения.' 20 "$WT_WIDTH" 6 c \
   1 'Создать / изменить узел' 2 'Показать код' 3 'Войти по коду' 4 'Меню XRayMesh' 0 'Назад'; then break; fi
  case "$c" in
   0) break ;; 1) if nm_yes 'Изменить узел?'; then nm_mesh setup-node || true; fi; pause_enter ;;
   2) nm_mesh invite || true; pause_enter ;;
   3) if nm_yes 'Подключиться к сети?'; then nm_mesh join || true; fi; pause_enter ;;
   4) nm_mesh || true; pause_enter ;;
  esac
 done
}
nm_checks_menu() {
 local c
 while true; do
  if ! smart_menu 'Проверка' 'SOCKS-тесты проверяют выход, но не клиентский NaiveProxy.' 20 "$WT_WIDTH" 5 c \
   1 'Службы и сеть' 2 'SOCKS на сервере 2' 3 'Мост на сервере 1' 4 'Журналы служб' 0 'Назад'; then break; fi
  case "$c" in
   0) break ;; 1) nm_status; pause_enter ;;
   2|3) nm_load
    if [[ "$c" == 2 ]]; then target="$NM_EXIT:$NM_SOCKS"; else target="127.0.0.1:$NM_LOCAL"; fi
    curl --noproxy '' -4 -fsS --connect-timeout 10 --max-time 30 --socks5-hostname "$target" https://ifconfig.me || echo 'Проверка не пройдена'
    echo; pause_enter ;;
   4) journalctl -u caddy -u naive-mesh-bridge -u xray-mesh-socks -u xraymesh -n 60 --no-pager || true; pause_enter ;;
  esac
 done
}
manage_naive_mesh_menu() {
 local action
 while true; do
  if ! smart_menu 'NaiveProxy + XRayMesh' 'Настройка: сначала сервер 2, затем сервер 1.
Обновление меню не меняет работающие службы.' 23 "$WT_WIDTH" 9 action \
   1 'Проверка и журналы' \
   2 'Сервер 2: выход SOCKS' \
   3 'Сервер 1: вход NaiveProxy' \
   4 'Выбрать выходной сервер' \
   5 'Пользователи и ссылки' \
   6 'Сеть и коды подключения' \
   7 'Автономный NaiveProxy' \
   8 'Пауза / выход / удаление' \
   0 'Назад'; then break; fi
  case "$action" in
   0) break ;; 1) nm_checks_menu ;;
   2) nm_wizard 2 || echo 'Мастер остановлен'; pause_enter ;;
   3) nm_wizard 1 || echo 'Мастер остановлен'; pause_enter ;;
   4) nm_select_exit || echo 'Выбор отменён или не завершён'; pause_enter ;;
   5) manage_naive_users_menu ;; 6) nm_tools_menu ;;
   7) if nm_yes 'Настроить автономный NaiveProxy (изменит конфигурацию входа)?'; then setup_standalone_naive; fi ;;
   8) nm_lifecycle ;;
  esac
 done
}

nm_select_exit() (
 command -v python3 >/dev/null || { echo 'Нужен Python 3.'; exit 1; }
 nm_load
 local selected_ip="$NM_EXIT" selected_port="$NM_SOCKS" tmp
 echo 'ВЫБОР ВЫХОДА — на входном сервере 1'
 echo 'На выбранном mesh-узле должен работать SOCKS-выход (настройка сервера 2).'
 nm_prompt 'Mesh IPv4 выходного сервера' "$NM_EXIT" selected_ip || exit 1
 nm_prompt 'SOCKS-порт выхода' "$NM_SOCKS" selected_port || exit 1
 tmp=$(mktemp -d) || exit 1
 trap 'rm -rf -- "$tmp"' EXIT
 cat > "$tmp/switch.py" <<'NM_SWITCH_PY'
import ipaddress,json,pathlib,re,shlex,shutil,subprocess,sys,tempfile

def run(args):
    return subprocess.run(args,check=True,text=True)
def output(args):
    return subprocess.check_output(args,text=True).strip()
def patch_endpoint(text,ip,port,local):
    commands=list(re.finditer(r'(?m)^ExecStart=(.+)$',text))
    if len(commands)!=1:raise ValueError('Нужна одна команда запуска моста.')
    m=commands[0];cmd=m.group(1)
    if 'socat ' in cmd:
        if not re.search(r'TCP4-LISTEN:'+re.escape(local)+r',bind=127\.0\.0\.1,',cmd):raise ValueError('Не распознан localhost-слушатель socat.')
        pattern=r'(TCP4:)(\d{1,3}(?:\.\d{1,3}){3}):(\d+)(?=,|\s|$)'
    elif re.search(r'(?:^|/)gost\s',cmd):
        if not re.search(r'(?:socks5?|socks5h)://127\.0\.0\.1:'+re.escape(local)+r'(?=[\s"\x27]|$)',cmd):raise ValueError('Не распознан localhost-слушатель GOST.')
        pattern=r'(-F[= ]socks5h?://)(\d{1,3}(?:\.\d{1,3}){3}):(\d+)(?=[\s"\x27/?]|$)'
    else:raise ValueError('Неизвестный тип моста.')
    targets=list(re.finditer(pattern,cmd))
    if len(targets)!=1:raise ValueError('Неоднозначное направление выхода.')
    t=targets[0];old=t.group(2)+':'+t.group(3)
    cmd=cmd[:t.start()]+t.group(1)+ip+':'+port+cmd[t.end():]
    return text[:m.start(1)]+cmd+text[m.end(1):],old

def probe(target):
    value=output(['curl','--noproxy','','-4','-fsS','--connect-timeout','10','--max-time','30','--socks5-hostname',target,'https://ifconfig.me'])
    return str(ipaddress.IPv4Address(value))

def main():
    ip,port=sys.argv[1:]
    addr=ipaddress.IPv4Address(ip)
    if not addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_unspecified or addr.is_multicast or addr.is_reserved:raise ValueError('Нужен частный unicast mesh IPv4.')
    if not port.isdecimal() or not 1024<=int(port)<=65535:raise ValueError('Порт: 1024..65535.')
    run(['systemctl','is-active','--quiet','xraymesh.service'])
    run(['systemctl','is-active','--quiet','caddy.service'])
    if pathlib.Path('/etc/naiveproxy/mesh-paused').exists():raise ValueError('Сначала возобновите каскад, раздел управления.')
    nodes=json.loads(output(['ip','-j','-4','address','show']))
    if any(a.get('local')==ip for n in nodes for a in n.get('addr_info',[])):raise ValueError('Указан адрес текущего сервера.')
    text=pathlib.Path('/etc/caddy/Caddyfile').read_text()
    if re.search(r'(?m)^\s*import\s',text):raise ValueError('Caddy с import не поддерживается переключателем.')
    ports=re.findall(r'(?m)^\s*upstream\s+socks5://127\.0\.0\.1:([0-9]+)\s*(?:#.*)?$',text)
    if len(ports)!=1:raise ValueError('Нужен один Caddy upstream на localhost. Сначала настройте сервер 1.')
    local=ports[0]
    units=[u+'.service' for u in ['naive-mesh-bridge','gost-mesh'] if subprocess.run(['systemctl','is-active','--quiet',u+'.service']).returncode==0]
    if len(units)!=1:raise ValueError('Должен быть активен ровно один известный мост.')
    unit=units[0]
    if output(['systemctl','show',unit,'-p','DropInPaths','--value']):raise ValueError('Есть drop-in службы. Автоматическое изменение остановлено.')
    path=pathlib.Path(output(['systemctl','show',unit,'-p','FragmentPath','--value']))
    if path!=pathlib.Path('/etc/systemd/system')/unit or path.is_symlink():raise ValueError('Необычный файл службы.')
    candidate,old=patch_endpoint(path.read_text(),ip,port,local)
    print('Проверяем новый SOCKS-выход...',flush=True)
    public=probe(ip+':'+port)
    print('Мост: '+old+' -> '+ip+':'+port+'; внешний IPv4: '+public)
    print('Caddyfile и локальный порт не меняются. Соединения моста могут прерваться.')
    if input('Переключить? Введите ДА: ').strip() not in ['ДА','да','YES']:
        print('Отменено.');return
    root=pathlib.Path('/etc/naiveproxy');root.mkdir(exist_ok=True)
    env=root/'mesh-wizard.env';marker=root/'mesh-upstream.port';paths=[path,env,marker]
    backup=pathlib.Path(tempfile.mkdtemp(prefix='bobarev-mesh-exit-',dir='/root'))
    snapshots={p:p.read_bytes() if p.exists() else None for p in paths}
    for i,p in enumerate(paths):
        if p.exists():shutil.copy2(p,backup/(str(i)+'-'+p.name))
    (backup/'paths.txt').write_text('\n'.join(str(p) for p in paths))
    try:
        path.write_text(candidate)
        run(['systemctl','daemon-reload']);run(['systemctl','restart',unit])
        run(['systemctl','is-active','--quiet',unit])
        actual=probe('127.0.0.1:'+local)
        if actual!=public:raise ValueError('Внешний IPv4 через мост не совпал с проверенным выходом.')
        et=env.read_text() if env.exists() else ''
        for k,v in [('NM_EXIT',ip),('NM_SOCKS',port),('NM_LOCAL',local)]:
            et=re.sub(r'(?m)^'+k+r'=.*\n?','',et)
            et=et.rstrip('\n')+'\n'+k+'='+shlex.quote(v)+'\n'
        env.write_text(et);env.chmod(0o600)
        marker.write_text(local+'\n');marker.chmod(0o600)
    except BaseException:
        errors=[]
        for p,data in snapshots.items():
            try:
                if data is None:p.unlink(missing_ok=True)
                else:p.write_bytes(data)
            except Exception as e:errors.append(str(e))
        for cmd in [['systemctl','daemon-reload'],['systemctl','restart',unit]]:
            try:run(cmd)
            except Exception as e:errors.append(str(e))
        print('Выполнен откат; резервная копия: '+str(backup),file=sys.stderr)
        if errors:print('Ошибки восстановления: '+'; '.join(errors),file=sys.stderr)
        raise
    print('Готово. Внешний IPv4: '+actual+'; резервная копия: '+str(backup))
    print('Проверьте прежний профиль Shadowrocket: https://ifconfig.me')

if __name__=='__main__':
    try:main()
    except Exception as e:
        print('Переключение не завершено: '+str(e),file=sys.stderr);sys.exit(1)
NM_SWITCH_PY
 python3 "$tmp/switch.py" "$selected_ip" "$selected_port"
)

nm_write_entry() {
cat <<'NM_ENTRY_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
nm_reload_caddy() {
 local cb="${CADDY_BIN:-/usr/local/bin/caddy}" cf="${CADDYFILE:-/etc/caddy/Caddyfile}"
 [[ -x "$cb" ]] || cb=$(command -v caddy) || { echo 'Не найден Caddy.' >&2; return 1; }
 "$cb" validate --config "$cf" --adapter caddyfile || return 1
 "$cb" reload --config "$cf" --adapter caddyfile --force || {
  echo 'Caddy не принял конфигурацию через admin API. Автоматического restart не будет.' >&2
  return 1
 }
}

[[ $EUID -eq 0 ]] || { echo 'Запустите через sudo bash'; exit 1; }
command -v apt-get >/dev/null || { echo 'Поддерживаются Debian/Ubuntu с systemd'; exit 1; }
ENTRY_IP=${ENTRY_IP:-10.144.144.1}
EXIT_IP=${EXIT_IP:-10.144.144.2}
SOCKS_PORT=${SOCKS_PORT:-1080}
LOCAL_PORT=${LOCAL_PORT:-10808}
apt-get update
apt-get install -y python3 curl iproute2
python3 - "$ENTRY_IP" "$EXIT_IP" "$SOCKS_PORT" "$LOCAL_PORT" <<'PY'
import ipaddress,sys
for x in sys.argv[1:3]:
    if ipaddress.ip_address(x).version != 4: raise SystemExit('Нужны IPv4 mesh-адреса')
for x in sys.argv[3:]:
    if not x.isdecimal() or not 1024 <= int(x) <= 65535: raise SystemExit('Порты: 1024..65535')
PY
check_local_ip() {
 python3 - "$1" <<'PY'
import json,subprocess,sys
nodes=json.loads(subprocess.check_output(['ip','-j','-4','addr','show']))
if not any(a.get('local')==sys.argv[1] for n in nodes for a in n.get('addr_info',[])):
    raise SystemExit('Mesh-IP отсутствует на сервере: '+sys.argv[1]+'. Сначала настройте XRayMesh.')
PY
}

check_local_ip "$ENTRY_IP"
CADDYFILE=${CADDYFILE:-/etc/caddy/Caddyfile}
CADDY_BIN=${CADDY_BIN:-/usr/local/bin/caddy}
[[ -x $CADDY_BIN ]] || CADDY_BIN=$(command -v caddy)
[[ -f $CADDYFILE ]] || { echo 'Caddyfile не найден'; exit 1; }
[[ ! -L $CADDYFILE ]] || { echo 'Caddyfile — symlink. Укажите реальный файл через CADDYFILE.'; exit 1; }
systemctl is-active --quiet caddy || { echo 'Сначала восстановите рабочий Caddy'; exit 1; }
echo 'Проверка SOCKS на зарубежном сервере через mesh:'
curl -4 -fsS --connect-timeout 10 --max-time 30 --socks5-hostname "$EXIT_IP:$SOCKS_PORT" https://ifconfig.me; echo

# Сохраняем уже работающий GOST: ничего не скачиваем и не заменяем.
if ss -H -ltn "sport = :$LOCAL_PORT" | grep -q .; then
 echo "Порт $LOCAL_PORT уже занят. Проверяем существующий мост, не изменяя его."
 if ! systemctl is-active --quiet gost-mesh.service && ! systemctl is-active --quiet naive-mesh-bridge.service; then
   echo 'Неизвестный слушатель. Проверьте ss -ltnp и его автозапуск. Остановка.'; exit 1
 fi
 echo 'Убедитесь: существующий мост направлен на нужный EXIT_IP и слушает только localhost.'
 ss -ltnp "sport = :$LOCAL_PORT"
else
 # Для новой установки достаточно прозрачного TCP-реле: SOCKS обрабатывает сервер 2.
 apt-get install -y socat
 SOCAT=$(command -v socat)
 cat > /etc/systemd/system/naive-mesh-bridge.service <<EOF
[Unit]
Description=Loopback TCP relay to mesh SOCKS5 exit
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
DynamicUser=yes
ExecStart=$SOCAT TCP4-LISTEN:$LOCAL_PORT,bind=127.0.0.1,reuseaddr,fork TCP4:$EXIT_IP:$SOCKS_PORT,connect-timeout=10
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
 systemctl daemon-reload
 systemctl enable --now naive-mesh-bridge.service
 sleep 2
 systemctl is-active --quiet naive-mesh-bridge.service || { journalctl -u naive-mesh-bridge -n 30 --no-pager; exit 1; }
fi

echo 'Проверка SOCKS через локальный мост:'
curl -4 -fsS --connect-timeout 10 --max-time 30 --socks5-hostname "127.0.0.1:$LOCAL_PORT" https://ifconfig.me; echo

BACKUP="$CADDYFILE.bak.mesh.$(date +%Y%m%d-%H%M%S).$$"
cp -a "$CADDYFILE" "$BACKUP"
rollback() {
 echo "Ошибка. Возвращаем $BACKUP"
 cp -a "$BACKUP" "$CADDYFILE"
 nm_reload_caddy || echo 'ВНИМАНИЕ: прежний файл восстановлен, но применить его к Caddy не удалось.' >&2
}
trap 'rollback' ERR
# Изменяем только upstream одного forward_proxy. Не трогаем TLS/auth/route.
python3 - "$CADDYFILE" "$LOCAL_PORT" <<'PY'
import re,sys
p,port=sys.argv[1:]
s=open(p).read()
starts=list(re.finditer(r'(?m)^[ \t]*forward_proxy\s*\{[^\S\n]*(?:#.*)?$',s))
if len(starts)!=1: raise SystemExit('Нужен ровно один простой блок forward_proxy. Файл оставлен без изменений.')
m=starts[0]; start=m.end(); end=s.find('}',start)
if end<0 or '{' in s[start:end]: raise SystemExit('Сложный/вложенный блок: настройте upstream вручную')
block=s[start:end]
lines=list(re.finditer(r'(?m)^[ \t]*upstream\s+[^\n]+',block))
if len(lines)>1: raise SystemExit('Несколько upstream: требуется ручная проверка')
line='        upstream socks5://127.0.0.1:'+port
if lines:
    a=lines[0]; block=block[:a.start()]+line+block[a.end():]
else:
    block='\n'+line+'\n'+block
with open(p,'w') as f: f.write(s[:start]+block+s[end:])
PY
"$CADDY_BIN" fmt --overwrite "$CADDYFILE"
"$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile
nm_reload_caddy
trap - ERR
echo "Готово. Бэкап: $BACKUP"
echo 'Проверьте Shadowrocket: прежний профиль  https://ifconfig.me'
echo 'Это финальная проверка всей цепочки; curl выше проверяет мост, но не клиентский NaiveProxy.'

NM_ENTRY_SCRIPT
}

nm_write_exit() {
cat <<'NM_EXIT_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Запустите через sudo bash'; exit 1; }
command -v apt-get >/dev/null || { echo 'Поддерживаются Debian/Ubuntu с systemd'; exit 1; }
ENTRY_IP=${ENTRY_IP:-10.144.144.1}
EXIT_IP=${EXIT_IP:-10.144.144.2}
SOCKS_PORT=${SOCKS_PORT:-1080}
LOCAL_PORT=${LOCAL_PORT:-10808}
apt-get update
apt-get install -y python3 curl iproute2
python3 - "$ENTRY_IP" "$EXIT_IP" "$SOCKS_PORT" "$LOCAL_PORT" <<'PY'
import ipaddress,sys
for x in sys.argv[1:3]:
    if ipaddress.ip_address(x).version != 4: raise SystemExit('Нужны IPv4 mesh-адреса')
for x in sys.argv[3:]:
    if not x.isdecimal() or not 1024 <= int(x) <= 65535: raise SystemExit('Порты: 1024..65535')
PY
check_local_ip() {
 python3 - "$1" <<'PY'
import json,subprocess,sys
nodes=json.loads(subprocess.check_output(['ip','-j','-4','addr','show']))
if not any(a.get('local')==sys.argv[1] for n in nodes for a in n.get('addr_info',[])):
    raise SystemExit('Mesh-IP отсутствует на сервере: '+sys.argv[1]+'. Сначала настройте XRayMesh.')
PY
}

check_local_ip "$EXIT_IP"
# Existing unrelated services are never stopped automatically.
if ss -H -ltn "sport = :$SOCKS_PORT" | grep -q .; then
 systemctl is-active --quiet xray-mesh-socks.service || { echo 'Порт занят другой службой. Она сохранена. Выберите свободный порт или выполните миграцию вручную.'; exit 1; }
fi
apt-get install -y curl unzip ca-certificates
if [[ ! -x /usr/local/bin/xray ]]; then
 case "$(dpkg --print-architecture)" in
 amd64) asset=Xray-linux-64.zip ;; arm64) asset=Xray-linux-arm64-v8a.zip ;; *) echo 'Архитектура не поддерживается'; exit 1 ;; esac
 tmp=$(mktemp -d)
 trap 'rm -rf -- "$tmp"' EXIT
 curl -fSL --retry 2 "https://github.com/XTLS/Xray-core/releases/latest/download/$asset" -o "$tmp/xray.zip"
 unzip -qo "$tmp/xray.zip" -d "$tmp"
 install -m 755 "$tmp/xray" /usr/local/bin/xray
fi
mkdir -p /etc/xray
python3 - "$EXIT_IP" "$SOCKS_PORT" <<'PY'
import json,sys,pathlib
p=pathlib.Path('/etc/xray/mesh-socks.json')
if p.exists():
 import shutil,time
 shutil.copy2(p,str(p)+'.bak.'+str(time.time_ns()))
c={'log':{'loglevel':'warning'},'inbounds':[{'listen':sys.argv[1],'port':int(sys.argv[2]),'protocol':'socks','settings':{'auth':'noauth','udp':False}}],'outbounds':[{'protocol':'freedom','settings':{'domainStrategy':'UseIPv4'}}]}
p.write_text(json.dumps(c,indent=2)+'\n');p.chmod(0o600)
PY
/usr/local/bin/xray run -test -c /etc/xray/mesh-socks.json
MESH_IF=$(python3 - "$EXIT_IP" <<'PY'
import json,subprocess,sys
for n in json.loads(subprocess.check_output(['ip','-j','-4','addr','show'])):
 if any(a.get('local')==sys.argv[1] for a in n.get('addr_info',[])):print(n['ifname']);break
PY
)
if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then
 ufw insert 1 deny in to "$EXIT_IP" port "$SOCKS_PORT" proto tcp
 ufw insert 1 allow in on "$MESH_IF" from "$ENTRY_IP" to "$EXIT_IP" port "$SOCKS_PORT" proto tcp
fi
cat > /etc/systemd/system/xray-mesh-socks.service <<'EOF'
[Unit]
Description=Xray SOCKS exit for XRayMesh
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/xray run -c /etc/xray/mesh-socks.json
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable xray-mesh-socks.service
systemctl restart xray-mesh-socks.service
systemctl is-active --quiet xray-mesh-socks.service
echo "Xray SOCKS: $EXIT_IP:$SOCKS_PORT. Старые службы сохранены."
echo 'Проверку с mesh-адреса выполните на сервере 1 (меню Проверка).'

NM_EXIT_SCRIPT
}

# ------------------------------------------------------------------------------
# ОБРАБОТКА CLI-АРГУМЕНТОВ БЫСТРОГО ЗАПУСКА
# ------------------------------------------------------------------------------
if [ "${1:-}" != "" ]; then
    case "${1:-}" in
        --bobarev-mullvad)
            install_bobarev_mullvad_runtime
            shift
            bash /usr/local/lib/bobarev-shell/mullvad.sh "$@"
            exit $?
            ;;
        --audit|-a)
            mod_server_audit
            exit 0
            ;;
        --net-audit|-n)
            install_network_audit_tool
            shift
            /usr/local/bin/bobarev-network-audit.sh "$@"
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
            echo -e "${C_BOLD}BOBAREV SHELL v3.14.55 (BOBAREV SHELL — Mullvad VPS Safety Revision)${C_RESET}"
            echo "Использование: $0 [опция]"
            echo "  (без опций)   Запуск интерактивного меню"
            echo "  --audit, -a   Мгновенный вывод интеллектуального аудита (Модуль 17)"
            echo "  --net-audit   Глубокий аудит сети, ТСПУ и каскадных пар (Модуль 21)"
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
# ===  ЗАПУСК ГЛАВНОГО МЕНЮ (ВСЕГДА В САМОМ КОНЦЕ ФАЙЛА) ===
# ==============================================================================
while true; do
    BOBAREV_SECTION_TITLE=''
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
    if ! smart_menu " ГЛАВНОЕ МЕНЮ" \
    "\n   Системные данные:
   Хост: $(hostname) ($(get_system_type_short))
   Часовой пояс: $tz
   Статус UFW: $ufw_status
   Сеть Tailscale: $ts_main_status

   Выберите желаемый этап настройки:" $WT_HEIGHT $WT_WIDTH $WT_MENU "choice" \
    "1" " Часовой пояс" \
    "2" " Имя сервера" \
    "3" " Обновление компонентов" \
    "4" " Создание и настройка пользователя" \
    "5" " Привязка ключа безопасности" \
    "6" " Конфигурация удаленного доступа" \
    "7" " Настройка системной защиты" \
    "8" " Управление брандмауэром" \
    "9" " Блокировка доступа суперпользователя" \
    "10" " Настройка закрытой сети Tailscale" \
    "11" " Управление системными журналами" \
    "12" " Оптимизация памяти" \
    "13" " Управление файлом подкачки" \
    "14" " Утилиты ПК и режим процессора" \
    "15" " Сброс видеовыхода HDMI" \
    "16" " Анализ времени загрузки" \
    "17" " Режим локального маршрутизатора" \
    "18" " Экспорт / Импорт настроек" \
    "19" " Каскад 1: NaiveProxy + WireGuard + WARP" \
    "20" " Каскад 2: NaiveProxy + Hysteria 2 + WARP" \
    "21" " Каскад 3: NaiveProxy + Xray REALITY + WARP" \
    "22" " Автономный NaiveProxy (+ WG Dual-Gateway)" \
    "23" "NaiveProxy-XRayMesh" \
    "24" "NaiveProxy-Tailscale Mullvad Exit" \
    "25" "Аудит системы 1" \
    "26" "Аудит системы 2 и каскадные пары" \
    "27" "Сброс сетевых надстроек (выборочно)" \
    "A" " Выполнить первичную настройку целиком (Шаги 1-12)" \
    "0" " Завершить работу" || [ "$choice" = "0" ]; then
        clear
        echo "Работа скрипта завершена."
        exit 0
    fi

    MODULE_CANCELED=false
    clear

    BOBAREV_SECTION_TITLE=${BOBAREV_MENU_TITLES[$choice]:-}
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
        17) mod_router_sbc ;;
        18) mod_backup_manager; pause_enter ;;
        19) mod_direct_wg_cascade ;;
        20) manage_cascade_hysteria_menu ;;
        21) manage_cascade_xray_menu ;;
        22) setup_standalone_naive ;;
        23) manage_naive_mesh_menu ;;
        24) manage_naive_mullvad_menu ;;
        25) mod_server_audit; pause_enter ;;
        26) mod_network_cascade_audit ;;
        27) mod_network_reset ;;
        A) run_full_auto_setup; pause_enter ;;
    esac
done
