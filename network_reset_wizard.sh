#!/usr/bin/env bash
# Bobarev Shell — safe selective network reset wizard
# This module performs read-only discovery and allowlisted disable actions only.

network_reset_wizard() (
    set -uo pipefail

    local tmp='' choice='' selected='' answer='' unit='' item='' d='' failed=0
    local -a candidates=() actions=()

    tmp=$(mktemp -d) || return 1
    trap 'rm -rf -- "$tmp"' EXIT
    chmod 700 "$tmp"

    echo 'Сканирование сетевых настроек (без изменений)...'

    {
        echo '=== Интерфейсы ==='
        ip -br address

        echo '=== Сокеты ==='
        ss -tulnp

        echo '=== IPv4 rules/routes ==='
        ip -4 rule
        ip -4 route show table all

        echo '=== IPv6 rules/routes ==='
        ip -6 rule
        ip -6 route show table all

        echo '=== Сетевые службы (обнаружение, не разрешение удаления) ==='
        systemctl list-units --all --no-pager | grep -Ei 'tailscale|wireguard|wg-|warp|caddy|xray|mesh|realm|gost|socat|hysteria|dnsmasq|network|resolved|openvpn' || true

        echo '=== UFW ==='
        command -v ufw >/dev/null && ufw status numbered

        echo '=== nftables ==='
        command -v nft >/dev/null && nft list ruleset

        echo '=== Tailscale ==='
        command -v tailscale >/dev/null && tailscale status
    } > "$tmp/inventory.txt" 2>&1

    # Core networking, sshd and tailscaled are intentionally never offered for disabling.
    for unit in bobarev-router-v2 bobarev-router-dhcp bobarev-router bobarev-cascade-ru bobarev-udp2raw bobarev-xray hysteria-client hysteria-server naive-mesh-bridge xray-mesh-socks xraymesh gost-mesh realm-mesh xraymesh-realm xraymesh-iperf xraymesh-web; do
        if [[ -f "/etc/systemd/system/${unit}.service" && ! -L "/etc/systemd/system/${unit}.service" ]]; then
            local state
            state=$(systemctl is-active "${unit}.service" 2>/dev/null || true)
            candidates+=("$unit" "Отключить: ${state:-unknown}" OFF)
        fi
    done

    if command -v tailscale >/dev/null; then
        tailscale debug prefs > "$tmp/prefs.json" 2>/dev/null || true

        if command -v python3 >/dev/null; then
            python3 - "$tmp/prefs.json" > "$tmp/ts-flags" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        prefs = json.load(fh)

    exit_node = prefs.get("ExitNodeID") or prefs.get("ExitNodeIP")
    if exit_node not in (None, "", "0.0.0.0", "::"):
        print("EXIT")

    advertised = prefs.get("AdvertiseRoutes", []) or []
    if any(route in ("0.0.0.0/0", "::/0") for route in advertised):
        print("ADVERTISE")
except Exception:
    pass
PY

            grep -qx EXIT "$tmp/ts-flags" && candidates+=("TS_EXIT" "Выключить использование exit node" OFF)
            grep -qx ADVERTISE "$tmp/ts-flags" && candidates+=("TS_ADVERTISE" "Не анонсировать себя как exit node" OFF)
        fi
    fi

    while true; do
        choice=''
        smart_menu 'Сброс сетевых настроек' 'Сканируются службы, интерфейсы, маршруты, сокеты и firewall. Безопасный режим: выборочное отключение; неизвестные настройки только показываются. Удаление файлов, пакетов и общий сброс firewall запрещены.' 21 "$WT_WIDTH" 5 choice 1 'Показать полный отчёт' 2 'Выбрать компоненты для отключения' 0 'Назад' || return 0

        case "$choice" in
            0) return 0 ;;
            1)
                if command -v less >/dev/null; then
                    less "$tmp/inventory.txt"
                else
                    cat "$tmp/inventory.txt"
                fi
                pause_enter
                ;;
            2) break ;;
        esac
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo 'Нет распознанных компонентов для безопасного отключения. См. отчёт.'
        pause_enter
        return 0
    fi

    selected=$(whiptail --title 'Выбор компонентов' --checklist 'Пробел — выбрать. По умолчанию всё сохраняется. Службы будут отключены, но файлы и VPN-ключи останутся.' 24 "$WT_WIDTH" 12 "${candidates[@]}" 3>&1 1>&2 2>&3) || return 0

    [[ -n "$selected" ]] || return 0

    local found=0 i
    for item in $selected; do
        item=${item//\"/}

        case "$item" in
            TS_EXIT|TS_ADVERTISE)
                actions+=("$item")
                ;;
            *)
                found=0
                for ((i = 0; i < ${#candidates[@]}; i += 3)); do
                    [[ "$item" == "${candidates[i]}" ]] && found=1
                done

                if [[ $found -ne 1 ]]; then
                    echo "Неизвестный компонент: $item"
                    return 1
                fi

                actions+=("$item")
                ;;
        esac
    done

    local ssh_src=${SSH_CONNECTION%% *}
    if [[ -n "$ssh_src" ]]; then
        case "$ssh_src" in
            100.*|fd7a:*) ;;
            *)
                echo 'SSH идёт не через известный адрес Tailscale. Отключение маршрутов/каскадов заблокировано: используйте Tailscale или локальную консоль.'
                pause_enter
                return 1
                ;;
        esac
    fi

    local dep=''
    for item in "${actions[@]}"; do
        case "$item" in
            naive-mesh-bridge|gost-mesh|xraymesh)
                if grep -Eq '^[[:space:]]*upstream[[:space:]]+socks5h?://127\.0\.0\.1:' /etc/caddy/Caddyfile 2>/dev/null; then
                    echo 'БЛОКИРОВКА: Caddy использует локальный SOCKS upstream. Сначала верните прямой выход в меню mesh; автоматическая правка Caddy запрещена.'
                    pause_enter
                    return 1
                fi
                ;;
            TS_EXIT)
                echo 'Зависимость: отключение exit node изменит выход всего хоста и LAN-клиентов. При kill switch LAN может остаться без интернета.'
                ;;
            bobarev-router-v2)
                if systemctl is-active --quiet bobarev-router-dhcp.service; then
                    dep='no'
                    for unit in "${actions[@]}"; do
                        [[ "$unit" == "bobarev-router-dhcp" ]] && dep='yes'
                    done

                    if [[ "$dep" != "yes" ]]; then
                        echo 'Выберите также bobarev-router-dhcp: DHCP зависит от маршрутизатора.'
                        pause_enter
                        return 1
                    fi
                fi
                ;;
        esac
    done

    echo 'ПЛАН: отключить только:'
    printf '  %s\n' "${actions[@]}"
    echo 'DHCP, mesh и выходные прокси могут перестать обслуживать клиентов. Чужие NAT и маршруты не удаляются.'
    echo 'Это не возврат к заводским настройкам. Старые правила могут сохраниться после остановки старых служб.'

    IFS= read -r -p 'Введите RESET для применения (Enter — отмена): ' answer || return 0
    [[ "$answer" == "RESET" ]] || return 0

    d="/root/bobarev-reset-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -m 700 "$d" || return 1

    cp "$tmp/inventory.txt" "$d/"
    [[ ! -s "$tmp/prefs.json" ]] || cp "$tmp/prefs.json" "$d/"

    iptables-save > "$d/iptables.v4" || return 1
    ip6tables-save > "$d/iptables.v6" || return 1
    [[ ! -d /etc/ufw ]] || cp -a /etc/ufw "$d/" || return 1

    printf '#!/bin/bash\nset -e\n' > "$d/restore-services.sh"

    for item in "${actions[@]}"; do
        case "$item" in
            TS_*) continue ;;
        esac

        systemctl cat "${item}.service" > "$d/${item}.unit.txt" || return 1
        systemctl is-enabled "${item}.service" > "$d/${item}.enabled" 2>&1 || true
        systemctl is-active "${item}.service" > "$d/${item}.active" 2>&1 || true

        if grep -qx enabled "$d/${item}.enabled"; then
            printf 'systemctl enable %q\n' "${item}.service" >> "$d/restore-services.sh"
        fi

        if grep -qx active "$d/${item}.active"; then
            printf 'systemctl start %q\n' "${item}.service" >> "$d/restore-services.sh"
        fi
    done

    chmod 600 "$d/restore-services.sh"

    # Stop DHCP before the router; all service state is backed up first.
    for item in bobarev-router-dhcp "${actions[@]}"; do
        if [[ "$item" == "bobarev-router-dhcp" ]]; then
            [[ " ${actions[*]} " == *' bobarev-router-dhcp '* ]] || continue
        fi

        case "$item" in
            TS_EXIT)
                tailscale set --exit-node="" || { failed=1; break; }
                ;;
            TS_ADVERTISE)
                tailscale set --advertise-exit-node=false || { failed=1; break; }
                ;;
            *)
                systemctl disable --now "${item}.service" || { failed=1; break; }
                ;;
        esac

        printf '%s\n' "$item" >> "$d/applied.txt"
    done

    echo "Резервная копия и журнал: $d (не публикуйте: приватные настройки)"

    if ((failed)); then
        echo 'Часть действий не выполнена. Применение остановлено; автоматического отката нет.'
    else
        echo 'Выбранные действия выполнены. Это не подтверждает доступ клиентов в интернет.'
    fi

    echo 'Восстановление служб: bash restore-services.sh из каталога копии. Tailscale и firewall восстанавливайте отдельно после проверки.'
    pause_enter
    return "$failed"
)
