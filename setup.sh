#!/usr/bin/env bash
set -eEuo pipefail
trap 'echo "error: $BASH_COMMAND on line $LINENO" >&2' ERR

BASE_DIR="$(dirname "$(realpath "$0")")"

declare -A VARS
declare -A DEFAULTS

VARS[username]="$(whoami)"
VARS[ssh_port]=""
DEFAULTS[ssh_port]="10101"

# ============================
# Helpers
# ============================

is_root() {
    [ "$(id -u)" -eq 0 ]
}

# ============================
# User management
# ============================

prompt_username() {
    local username
    read -rp "enter new username: " username
    [ -z "$username" ] && { echo "error: username cannot be empty, exit" >&2; exit 1; }
    VARS[username]="$username"
}

create_user() {
    local username="${VARS[username]}"
    local sudoers_file="/etc/sudoers.d/$username"
    if ! id "$username" &>/dev/null; then
        adduser --gecos "" "$username"
        usermod -aG sudo,adm "$username"
        echo "[+] user '$username' created and added to sudo group"
    fi
    echo "$username ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
    chmod 440 "$sudoers_file"
}

switch_to_user() {
    local username="${VARS[username]}"
    local script_path src_base user_home dest_dir script_name
    script_path="$(realpath "$0")" || { echo "error: cannot resolve script path, exit" >&2; exit 1; }
    src_base="$(basename "$BASE_DIR")"
    script_name="$(basename "$script_path")"
    user_home=$(eval echo "~$username")
    dest_dir="$user_home/$src_base"
    mkdir -p "$dest_dir"
    cp -a "$BASE_DIR/." "$dest_dir/"
    chown -R "$username:$username" "$dest_dir"
    if [[ "$BASE_DIR" == /root/* ]]; then
        rm -rf "$BASE_DIR"
    fi
    echo "[*] switching to user '$username'..."
    exec su - "$username" -c "bash '$dest_dir/$script_name'"
}

# ============================
# SSH
# ============================

configure_ssh() {
    local port
    add_ssh_pub_key
    port="$(sudo sshd -G 2>/dev/null | awk '/^port / {print $2}')"
    if [ "$port" = "22" ]; then
        port="${SSH_PORT:-${DEFAULTS[ssh_port]}}"
        echo "[*] SSH port set to $port"
    fi
    VARS[ssh_port]="$port"
    deploy_ssh_config
}

add_ssh_pub_key() {
    local ssh_dir="$HOME/.ssh"
    local authorized_keys="$ssh_dir/authorized_keys"
    local pub_key
    read -rp "enter your SSH public key, press enter to skip: " pub_key
    if [ -z "$pub_key" ]; then
        return 0
    fi
    install -d -m 700 "$ssh_dir"
    install -m 600 /dev/null "$authorized_keys"
    if grep -qxF "$pub_key" "$authorized_keys" 2>/dev/null; then
        return 0
    fi
    echo "$pub_key" >> "$authorized_keys"
    echo "[+] SSH public key added successfully"
}

deploy_ssh_config() {
    local username="${VARS[username]}"
    local ssh_port="${VARS[ssh_port]}"
    local target="/etc/ssh/sshd_config.d/99-srv.conf"
    local template="$BASE_DIR/$target"
    local tmp_file
    [[ -f "$template" ]] || { echo "error: missing SSH template $template, exit" >&2; exit 1; }
    echo "[*] deploying SSH config for user '$username' on port '$ssh_port'..."
    tmp_file="$(mktemp)"
    sed \
        -e "s/${DEFAULTS[ssh_port]}/$ssh_port/" \
        -e "s/SOME_USERNAME/$username/" \
        "$template" > "$tmp_file"
    sudo install -m 600 -o root -g root "$tmp_file" "$target"
    rm -f "$tmp_file"
    echo "[+] SSH config deployed to $target"
}

# ============================
# UFW & Fail2Ban
# ============================

configure_ufw() {
    echo "[*] configuring UFW rules..."
    sudo ufw limit "${VARS[ssh_port]}/tcp"
    sudo ufw --force enable
    echo "[+] UFW configured"
}

setup_fail2ban() {
    local target_dir="/etc/fail2ban/jail.d"
    local target_file="$target_dir/sshd.local"
    local template="$BASE_DIR/$target_file"
    local tmp_file
    [[ -f "$template" ]] || { echo "error: missing fail2ban template $template, exit" >&2; exit 1; }
    echo "[*] setting up fail2ban..."
    tmp_file="$(mktemp)"
    sed \
        -e "s/${DEFAULTS[ssh_port]}/${VARS[ssh_port]}/" \
        "$template" > "$tmp_file"
    sudo install -D -m 644 -o root -g root "$tmp_file" "$target_file"
    rm -f "$tmp_file"
    sudo systemctl enable --now fail2ban
    echo "[+] fail2ban config deployed to $target_file"
}

# ============================
# Docker
# ============================

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo "[*] docker already installed"
        return 0
    fi
    echo "[*] installing docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm -f get-docker.sh
    sudo groupadd -f docker
    sudo usermod -aG docker "${VARS[username]}"
    echo "[+] docker installed"
}

set_docker_limits() {
    local gen_limits="/usr/local/bin/gen-docker-memory-limits.sh"
    local svc="/etc/systemd/system/docker-memory-limits.service"
    local d_file="/etc/systemd/system/docker.service.d/override.conf"
    [[ -f "$BASE_DIR/$gen_limits" ]] || { echo "error: missing $gen_limits, exit" >&2; exit 1; }
    [[ -f "$BASE_DIR/$svc" ]] || { echo "error: missing $svc, exit" >&2; exit 1; }
    [[ -f "$BASE_DIR/$d_file" ]] || { echo "error: missing $d_file, exit" >&2; exit 1; }
    echo "[*] setting docker limits..."
    sudo install -D -m 755 -o root -g root "$BASE_DIR/$gen_limits" "$gen_limits"
    sudo install -D -m 644 -o root -g root "$BASE_DIR/$svc" "$svc"
    sudo install -D -m 644 -o root -g root "$BASE_DIR/$d_file" "$d_file"
    sudo systemctl daemon-reload
    sudo systemctl enable --now docker-memory-limits.service
    echo "[+] docker limits applied"
}

configure_docker() {
    local target="/etc/docker/daemon.json"
    [[ -f "$BASE_DIR/$target" ]] || { echo "error: missing $target, exit" >&2; exit 1; }
    echo "[*] configuring docker..."
    sudo install -D -m 644 -o root -g root "$BASE_DIR/$target" "$target"
    echo "[+] docker config deployed to $target"
}

setup_docker() {
    install_docker
    configure_docker
    set_docker_limits
}

# ============================
# System
# ============================

update_system() {
    echo "[*] updating system..."
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install fail2ban ufw curl unattended-upgrades -y
    sudo apt-get autoremove -y
    echo "[+] system updated"
}

configure_system() {
    local target="/etc/sysctl.d/99-srv.conf"
    [[ -f "$BASE_DIR/$target" ]] || { echo "error: missing $target, exit" >&2; exit 1; }
    echo "[*] configuring system..."
    sudo install -m 644 -o root -g root "$BASE_DIR/$target" "$target"
    echo "[+] sysctl config deployed to $target"
}

# ============================
# ZRAM & Swap
# ============================

setup_swap() {
    local swap_file="/swapfile"
    local swap_size="${SWAP_SIZE:-512M}"
    local min_free_mb=1024
    local ram_mb swap_mb avail_mb
    if swapon --show=NAME | grep -qx '$swap_file'; then
        echo "[*] swap is already active"
        return 0
    fi
    ram_mb="$(free -m | awk '/^Mem:/ {print $2}')"
    swap_mb="$(echo "$swap_size" | awk '
        /G$/ {print int($1 * 1024)}
        /M$/ {print int($1)}
        /^[0-9]+$/ {print int($1)}
    ')"
    avail_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
    if (( avail_mb - swap_mb < min_free_mb )); then
        echo "error: not enough free disk space to safely create ${swap_size} swapfile" >&2
        echo "       available: ${avail_mb} MB, required: $((swap_mb + min_free_mb)) MB" >&2
        return 1
    fi
    echo "[*] detected ${ram_mb} MB RAM, will create ${swap_size} swapfile"
    if [ -f "$swap_file" ]; then
        echo "[*] swapfile exists but is not active, recreating..."
        sudo swapoff "$swap_file" 2>/dev/null || true
        sudo rm -f "$swap_file"
    fi
    echo "[*] creating swapfile at $swap_file"
    sudo fallocate -l "$swap_size" "$swap_file" || {
        echo "error: failed to allocate swapfile" >&2
        return 1
    }
    sudo chmod 600 "$swap_file"
    sudo mkswap "$swap_file" >/dev/null
    sudo swapon "$swap_file"
    if ! grep -q "$swap_file" /etc/fstab; then
        echo "$swap_file none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
    fi
    echo "[+] swap created and activated successfully"
}

setup_zram() {
    echo "[*] Detecting system memory…"
    local total_ram_mb=$(awk '/MemTotal/ { printf "%.0f", $2 / 1024 }' /proc/meminfo)
    echo "[*] Total RAM: ${total_ram_mb} MB"
    local zram_enabled="${ZRAM:-auto}"
    local zram_percent="${ZRAM_PERCENT:-50}"
    local zram_max_mb="${ZRAM_MAX:-2048}"
    local target="/etc/default/zramswap"
    local template="$BASE_DIR/$target"
    local tmp_file
    zram_enabled=$(echo "$zram_enabled" | tr '[:upper:]' '[:lower:]')
    echo "[*] ZRAM mode: $zram_enabled"
    if [[ "$zram_enabled" == "auto" ]]; then
        if (( total_ram_mb <= 2048 )); then
            zram_enabled="on"
        else
            zram_enabled="off"
        fi
        echo "[*] Auto-selected ZRAM=$zram_enabled"
    fi
    if [[ "$zram_enabled" == "off" ]]; then
        return 0
    fi
    [[ -f "$template" ]] || { echo "error: missing ZRAM template $template, exit" >&2; exit 1; }
    echo "[+] Enabling ZRAM…"
    sudo apt-get install -y zram-tools linux-modules-extra-$(uname -r)
    tmp_file="$(mktemp)"
    sed \
        -e "s/{{PERCENT}}/${zram_percent}/" \
        -e "s/{{ZRAM_SIZE}}/${zram_max_mb}/" \
        "$template" > "$tmp_file"
    sudo install -D -m 644 -o root -g root "$tmp_file" "$target"
    rm -f "$tmp_file"
    sudo systemctl enable --now zramswap.service
    echo "[+] ZRAM activated"
    echo "[*] Current zram devices:"
    zramctl || true
}

setup_memory_optimization() {
    setup_zram
    setup_swap
}

# ============================
# Main
# ============================

main() {
    if is_root; then
        echo "[*] running as root"
        prompt_username
        create_user
        switch_to_user
    fi
    local username="${VARS[username]}"
    echo "[*] running as $username"
    update_system
    configure_ssh
    configure_ufw
    setup_fail2ban
    configure_system
    setup_docker
    setup_memory_optimization
    echo "[+] done, reboot"
}

main "$@"
