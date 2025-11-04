#!/bin/bash

set -eEuo pipefail
trap 'echo "error: $BASH_COMMAND on line $LINENO" >&2' ERR

readonly BASE_DIR="$(dirname "$(realpath "$0")")"
readonly CONF_DIR="$BASE_DIR/docker"

readonly OVERRIDE_FILE="/etc/systemd/system/docker.service.d/override.conf"
readonly DAEMON_FILE="/etc/docker/daemon.json"

# ============================
# Helpers
# ============================

is_root() {
    (( EUID == 0 ))
}

# ============================
# Docker
# ============================

install_deps() {
    local deps=()
    command -v curl &>/dev/null || deps+=(curl)
    (( ${#deps[@]} != 0 )) || return 0
    echo "[*] installing ${deps[*]}"
    sudo apt-get update
    sudo apt-get install -y "${deps[@]}"
    echo "[+] dependencies installed"
}

install_docker() {
    command -v docker &>/dev/null && { 
        echo "[*] docker already installed";
        add_user_to_docker
        return 0;
    }
    install_deps
    echo "[*] installing docker"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm -f get-docker.sh
    add_user_to_docker
    echo "[+] docker installed"
}

add_user_to_docker() {
    sudo groupadd -f docker
    sudo usermod -aG docker "$(whoami)"
}

set_docker_limits() {
    echo "[*] setting docker limits"
    local -r src="$CONF_DIR/$OVERRIDE_FILE"
    [[ -f "$src" ]] || { echo "[!] error: file not found $src, exit" >&2; exit 1; }
    sudo install -Db -S '~' -m 0644 "$src" "$OVERRIDE_FILE"
    echo "[+] docker limits file deployed to $OVERRIDE_FILE"
}

configure_docker() {
    echo "[*] configuring docker"
    local -r src="$CONF_DIR/$DAEMON_FILE"
    [[ -f "$src" ]] || { echo "[!] error: file not found $src, exit" >&2; exit 1; }
    sudo install -Db -S '~' -m 0644 "$src" "$DAEMON_FILE"
    echo "[+] docker config file deployed to $DAEMON_FILE"
}

restart_docker() {
    sudo systemctl daemon-reload
    sudo systemctl restart docker.service
}

# ============================
# Main
# ============================

main() {
    echo "[*] starting"
    is_root && {
        echo "[!] error: running as root denied, exit" >&2;
        exit 1;
    }
    install_docker
    configure_docker
    set_docker_limits
    restart_docker
    echo "[+] done"
}

main "$@"
