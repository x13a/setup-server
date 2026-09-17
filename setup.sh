#!/bin/bash

set -eEuo pipefail
trap 'echo "error: $BASH_COMMAND on line $LINENO" >&2' ERR

readonly BASE_DIR="$(dirname "$(realpath "$0")")"
readonly CONF_DIR="$BASE_DIR/server"

readonly SSH_FILE="/etc/ssh/sshd_config.d/99-srv.conf"
readonly IPTABLES_FILE_PART="/etc/iptables/rules.v"
readonly FAIL2BAN_FILE="/etc/fail2ban/jail.d/sshd.local"
readonly SYSCTL_FILE="/etc/sysctl.d/99-srv.conf"

USERNAME="$(whoami)"
SSH_PORT="${SSH_PORT:-}"

readonly DEFAULT_SSH_PORT="10101"

# ============================
# Helpers
# ============================

is_root() {
    (( EUID == 0 ))
}

is_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

# ============================
# User management
# ============================

change_user() {
    echo "[*] changing user"
    prompt_username
    create_user
    switch_to_user
}

prompt_username() {
    local username
    while true; do
        read -rp "[?] enter new username: " username
        [[ -n "$username" ]] && break
        echo "[-] username cannot be empty"
    done
    readonly USERNAME="$username"
}

create_user() {
    id "$USERNAME" &>/dev/null || {
        adduser --gecos "" "$USERNAME"
        usermod -aG sudo,adm "$USERNAME"
        echo "[+] user '$USERNAME' created and added to sudo and adm groups"
    }
    local -r sudoers_file="/etc/sudoers.d/$USERNAME"
    echo "[*] creating file $sudoers_file"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
    chmod 0440 "$sudoers_file"
}

switch_to_user() {
    local script_path src_base script_name user_home
    script_path="$(realpath "$0")" || { 
        echo "[!] error: cannot resolve current script path, exit" >&2
        exit 1
    }
    src_base="$(basename "$BASE_DIR")"
    script_name="$(basename "$script_path")"
    user_home=$(eval echo "~$USERNAME")
    local -r dest_dir="$user_home/$src_base"
    echo "[*] copying $BASE_DIR to $dest_dir"
    mkdir -p "$dest_dir"
    cp -a "$BASE_DIR/." "$dest_dir/"
    chown -R "$USERNAME:$USERNAME" "$dest_dir"
    [[ "$BASE_DIR" == /root/* ]] && {
        echo "[*] removing $BASE_DIR"
        rm -rf "$BASE_DIR"
    }
    echo "[*] switching to user '$USERNAME'"
    exec su --login \
        --whitelist-environment=SSH_PORT,UFW \
        "$USERNAME" \
        -c "bash '$dest_dir/$script_name'"
}

# ============================
# SSH
# ============================

configure_ssh() {
    local confirm port
    read -rp "[?] configure ssh (Y/n): " confirm
    [[ "$confirm" == [nN] ]] && {
        port=$(find_ssh_port) || exit 1
        readonly SSH_PORT="$port"
        return 0
    }
    echo "[*] configuring ssh"
    echo "[*] SSH_PORT=$SSH_PORT"
    port="$SSH_PORT"
    [[ -n "$port" ]] || { port=$(find_ssh_port) || exit 1; }
    is_port "$port" || {
        echo "[!] error: invalid ssh port $port, exit" >&2
        exit 1
    }
    [[ "$port" == "22" && "$SSH_PORT" != "22" ]] && port="$DEFAULT_SSH_PORT"
    readonly SSH_PORT="$port"
    echo "[*] ssh port set to $SSH_PORT"
    add_ssh_pub_key
    deploy_ssh_config
}

find_ssh_port() {
    local ports
    ports="$(sudo sshd -G | awk '/^port / {print $2}')" || {
        echo "[!] error: failed to read ssh config" >&2
        return 1
    }
    local port=""
    local tmp_port
    while IFS= read -r tmp_port; do
        [[ -n "$tmp_port" ]] || continue
        port="$tmp_port"
        [[ "$port" != "22" ]] && break
    done <<< "$ports"
    [[ -n "$port" ]] || port="$DEFAULT_SSH_PORT"
    printf '%s' "$port"

}

add_ssh_pub_key() {
    local pub_key
    read -rp "[?] enter your ssh public key (press enter to skip): " pub_key
    [[ -z "$pub_key" ]] && return 0
    local -r ssh_dir="$HOME/.ssh"
    local -r authorized_keys="$ssh_dir/authorized_keys"
    echo "[*] creating file $authorized_keys"
    install -d -m 0700 "$ssh_dir"
    install -b -S '~' -m 0600 /dev/null "$authorized_keys"
    echo "$pub_key" >> "$authorized_keys"
    echo "[+] ssh public key added to $authorized_keys"
}

deploy_ssh_config() {
    echo "[*] deploying ssh config for user '$USERNAME' with port '$SSH_PORT'"
    local -r src="$CONF_DIR/$SSH_FILE"
    [[ -f "$src" ]] || { echo "[!] error: file not found $src, exit" >&2; exit 1; }
    local tmp_file
    tmp_file="$(mktemp)"
    sed \
        -e "s/$DEFAULT_SSH_PORT/$SSH_PORT/" \
        -e "s/SOME_USERNAME/$USERNAME/" \
        "$src" > "$tmp_file"
    local has_conf=false
    sudo test -f "$SSH_FILE" && has_conf=true
    sudo install -b -S '~' -m 0600 "$tmp_file" "$SSH_FILE"
    rm -f "$tmp_file"
    sudo sshd -t || {
        echo "[!] error: ssh config file test failed, exit" >&2
        sudo rm -f "$SSH_FILE"
        [[ "$has_conf" == true ]] && sudo cp -p "$SSH_FILE~" "$SSH_FILE"
        exit 1
    }
    echo "[+] ssh config file deployed to $SSH_FILE"
}

# ============================
# iptables
# ============================

configure_iptables() {
    [[ -v "UFW" ]] && return 0
    local confirm
    read -rp "[?] configure iptables (Y/n): " confirm
    [[ "$confirm" == [nN] ]] && return 0
    echo "[*] configuring iptables rules"
    local opt dst src tmp_file cmd
    for opt in 4 6; do
        echo "[*] configuring ipv$opt rules"
        dst="$IPTABLES_FILE_PART${opt}"
        src="$CONF_DIR/$dst"
        [[ -f "$src" ]] || { echo "[!] error: file not found $src, exit" >&2; exit 1; }
        tmp_file="$(mktemp)"
        sed \
            -e "s/$DEFAULT_SSH_PORT/$SSH_PORT/" \
            "$src" > "$tmp_file"
        cmd="iptables-restore"
        [[ "$opt" == "6" ]] && cmd="ip6tables-restore"
        sudo "$cmd" --test "$tmp_file" || {
            echo "[!] error: iptables config file test failed, exit" >&2
            rm -f "$tmp_file"
            exit 1
        }
        sudo install -b -S '~' -m 0640 "$tmp_file" "$dst"
        rm -f "$tmp_file"
        echo "[+] iptables config file deployed to $dst"
    done
    echo "[+] iptables configured"
}

# ============================
# Fail2Ban
# ============================

setup_fail2ban() {
    local confirm
    read -rp "[?] configure fail2ban (Y/n): " confirm
    [[ "$confirm" == [nN] ]] && return 0
    echo "[*] setting up fail2ban"
    local -r src="$CONF_DIR/$FAIL2BAN_FILE"
    [[ -f "$src" ]] || { echo "[!] error: file not found $src, exit" >&2; exit 1; }
    local tmp_file
    tmp_file="$(mktemp)"
    sed \
        -e "s/$DEFAULT_SSH_PORT/$SSH_PORT/" \
        "$src" > "$tmp_file"
    local has_conf=false
    [[ -f "$FAIL2BAN_FILE" ]] && has_conf=true
    sudo install -Db -S '~' -m 0644 "$tmp_file" "$FAIL2BAN_FILE"
    rm -f "$tmp_file"
    sudo fail2ban-client -t || {
        echo "[!] error: fail2ban config file test failed, exit" >&2
        sudo rm -f "$FAIL2BAN_FILE"
        [[ "$has_conf" == true ]] && sudo cp -p "$FAIL2BAN_FILE~" "$FAIL2BAN_FILE"
        exit 1
    }
    echo "[+] fail2ban config file deployed to $FAIL2BAN_FILE"
}

# ============================
# System
# ============================

update_system() {
    local deps=(
        "fail2ban"
        "unattended-upgrades"
    )
    [[ -v "UFW" ]] || deps+=("iptables-persistent")
    echo "[*] updating system"
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install -y "${deps[@]}"
    sudo apt-get autoremove -y
    echo "[+] system updated"
}

configure_system() {
    echo "[*] configuring system"
    local -r src="$CONF_DIR/$SYSCTL_FILE"
    [[ -f "$src" ]] || { echo "[!] error: file not found $src, exit" >&2; exit 1; }
    sudo install -m 0644 "$src" "$SYSCTL_FILE"
    echo "[+] sysctl config file deployed to $SYSCTL_FILE"
}

# ============================
# Main
# ============================

main() {
    echo "[*] starting"
    is_root && {
        echo "[*] running as root"
        change_user
        exit 0
    }
    readonly USERNAME
    echo "[*] running as $USERNAME"
    update_system
    configure_ssh
    configure_iptables
    setup_fail2ban
    configure_system
    echo "[+] done, reboot"
}

main "$@"
