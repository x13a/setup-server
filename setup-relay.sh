#!/bin/bash

set -eEuo pipefail
trap 'echo "error: $BASH_COMMAND on line $LINENO" >&2' ERR

readonly BASE_DIR="$(dirname "$(realpath "$0")")"
readonly CONF_DIR="$BASE_DIR/relay"

readonly SYSCTL_FILE="/etc/sysctl.d/99-relay.conf"

DEST_IP=""
DEST_PORT=""
SRC_PORT=""
PROTO=""

readonly DEFAULT_PROTO="udp"
readonly COMMENT_PREFIX="relay"

# ============================
# Helpers
# ============================

is_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

is_ipv6() {
    [[ "$1" == *:* ]]
}

is_domain() {
    local label='[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?'
    local tld="([[:alpha:]]{2,}|[xX][nN]--${label})"
    local pattern="^(${label}\.)+${tld}\.?$"
    [[ "$1" =~ $pattern ]]
}

# ============================
# Relay
# ============================

configure_system() {
    echo "[*] configuring system"
    [[ -f "$SYSCTL_FILE" ]] && { echo "[*] skip: sysctl config file exists $SYSCTL_FILE"; return 0; }
    local -r src="$CONF_DIR/$SYSCTL_FILE"
    [[ -f "$src" ]] || { echo "[!] error: file not found $src, exit" >&2; exit 1; }
    sudo install -m 0644 "$src" "$SYSCTL_FILE"
    sudo sysctl --system >/dev/null
    echo "[+] sysctl config file deployed to $SYSCTL_FILE"
}

install_deps() {
    local deps=()
    command -v netfilter-persistent &>/dev/null || deps+=(iptables-persistent)
    command -v dig &>/dev/null || deps+=(dnsutils)
    (( ${#deps[@]} != 0 )) || return 0
    echo "[*] installing ${deps[*]}"
    sudo apt-get update
    sudo apt-get install -y "${deps[@]}"
    echo "[+] dependencies installed"
}

ask_dest_addr() {
    local dest
    while true; do
        read -rp "[?] enter destination ip or domain: " dest
        resolve_dest "$dest" && {
            [[ "$dest" != "$DEST_IP" ]] && echo "[+] resolved $dest to $DEST_IP"
            break
        }
        echo "[-] invalid or unreachable destination"
    done
}

resolve_dest() {
    local dest="$1"
    [[ -n "$dest" ]] || return 1
    is_domain "$dest" && {
        local ips
        ips=$(dig +short +tries=1 "$dest" A "$dest" AAAA) || return 1
        local ip
        while IFS= read -r ip; do
            { [[ -z "$ip" ]] || is_domain "$ip"; } && continue
            check_ip "$ip" && return 0
        done <<< "$ips"
    }
    check_ip "$dest"
}

ask_dest_port() {
    local port
    while true; do
        read -rp "[?] enter destination port: " port
        is_port "$port" && {
            readonly DEST_PORT="$port"
            break
        }
        echo "[-] invalid port"
    done
}

ask_src_port() {
    local default="$DEST_PORT"
    local port
    while true; do
        read -rp "[?] enter source port [$default]: " port
        port="${port:-$default}"
        is_port "$port" && {
            readonly SRC_PORT="$port"
            break
        }
        echo "[-] invalid port"
    done
}

ask_proto() {
    local default="$DEFAULT_PROTO"
    local proto
    while true; do
        read -rp "[?] enter protocol (tcp/udp) [$default]: " proto
        proto="${proto:-$default}"
        [[ "$proto" == "tcp" || "$proto" == "udp" ]] && {
            readonly PROTO="$proto"
            break
        }
        echo "[-] invalid protocol"
    done
}

check_ip() {
    local ip="$1"
    local opt
    for opt in 4 6; do
        ip -"$opt" route get "$ip" &>/dev/null || continue
        readonly DEST_IP="$ip"
        return 0
    done
    return 1
}

setup_iptables() {
    echo "[*] setting up iptables rules"
    local cmd dst
    if is_ipv6 "$DEST_IP"; then
        cmd="ip6tables"
        dst="[$DEST_IP]:$DEST_PORT"
    else
        cmd="iptables"
        dst="$DEST_IP:$DEST_PORT"
    fi
    local -r comment="$COMMENT_PREFIX:$PROTO:$SRC_PORT"
    add_iptables_rule "$cmd" filter FORWARD "$COMMENT_PREFIX" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -j ACCEPT
    add_or_replace_iptables_rule "$cmd" nat PREROUTING "$comment" \
        -p "$PROTO" --dport "$SRC_PORT" \
        -m addrtype --dst-type LOCAL \
        -j DNAT --to-destination "$dst"
    add_or_replace_iptables_rule "$cmd" nat POSTROUTING "$comment" \
        -p "$PROTO" -d "$DEST_IP" --dport "$DEST_PORT" \
        -m conntrack --ctstate DNAT \
        -j MASQUERADE
    add_or_replace_iptables_rule "$cmd" filter FORWARD "$comment" \
        -p "$PROTO" -d "$DEST_IP" --dport "$DEST_PORT" \
        -m conntrack --ctstate DNAT \
        -j ACCEPT
    echo "[+] iptables rules setted"
}

add_or_replace_iptables_rule() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    local comment="$4"
    shift 4
    local rules rule_num
    rules=$(sudo "$cmd" -t "$table" -S "$chain") || {
        echo "[!] error: failed to get rules for $table $chain, exit" >&2
        exit 1
    }
    rule_num=$(awk -v comment="$comment" '
        $1 != "-A" { next }
        {
            n++
            for (i = 3; i < NF; i++) {
                if ($i != "--comment") {
                    continue
                }
                value = $(i + 1)
                gsub(/^"|"$/, "", value)
                if (value == comment) {
                    print n
                    exit
                }
            }
        }
    ' <<< "$rules")
    [[ -n "$rule_num" ]] || rule_num=0
    if (( $rule_num != 0 )); then
        sudo "$cmd" -t "$table" -R "$chain" "$rule_num" "$@" \
        -m comment --comment "$comment"
    else
        add_iptables_rule "$cmd" "$table" "$chain" "$comment" "$@"
    fi
}

add_iptables_rule() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    local comment="$4"
    shift 4
    sudo "$cmd" -t "$table" -C "$chain" "$@" -m comment --comment "$comment" \
    || sudo "$cmd" -t "$table" -A "$chain" "$@" -m comment --comment "$comment"
}

save_iptables() {
    echo "[*] saving iptables rules"
    sudo netfilter-persistent save
    echo "[+] iptables rules saved"
}

# ============================
# Main
# ============================

main() {
    echo "[*] starting"
    configure_system
    install_deps
    ask_dest_addr
    ask_dest_port
    ask_src_port
    ask_proto
    setup_iptables
    save_iptables
    echo "[+] done"
}

main "$@"
