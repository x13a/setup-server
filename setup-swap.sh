#!/bin/bash

set -eEuo pipefail
trap 'echo "error: $BASH_COMMAND on line $LINENO" >&2' ERR

readonly BASE_DIR="$(dirname "$(realpath "$0")")"
readonly CONF_DIR="$BASE_DIR/swap"

readonly SWAP_FILE="/swapfile"
readonly ZRAM_FILE="/etc/default/zramswap"
readonly FSTAB_FILE="/etc/fstab"

readonly ZRAM_MODE_AUTO="auto"
readonly ZRAM_MODE_ON="on"
readonly ZRAM_MODE_OFF="off"

readonly SWAP_SIZE="${SWAP_SIZE:-512M}"
readonly ZRAM="${ZRAM:-$ZRAM_MODE_AUTO}"
readonly ZRAM_PERCENT="${ZRAM_PERCENT:-50}"
readonly ZRAM_MAX="${ZRAM_MAX:-2048}"

readonly SWAP_MIN_FREE=1024
readonly ZRAM_AUTO_LIMIT=2048
readonly ZRAM_MIN=128

readonly RAM_MB="$(awk '/MemTotal/ { printf "%.0f", $2 / 1024 }' /proc/meminfo)"

# ============================
# Swap
# ============================

setup_swap() {
    echo "[*] setting up swap"
    echo "[*] SWAP_SIZE=$SWAP_SIZE"
    [[ "$SWAP_SIZE" =~ ^([1-9][0-9]*)([mMgG])$ ]] || {
        echo "[!] error: invalid SWAP_SIZE (ex 512M or 1G etc)" >&2;
        return 1;
    }
    local -r size_value="${BASH_REMATCH[1]}"
    local -r size_unit="${BASH_REMATCH[2]}"
    local swap_mb=$size_value
    [[ "$size_unit" == [gG] ]] && swap_mb=$(( size_value * 1024 ))
    local swap_file_bytes=0
    local swap_bytes need_mb
    swap_bytes=$(( swap_mb * 1024 * 1024 ))
    [[ -f "$SWAP_FILE" ]] && swap_file_bytes=$(stat -c %s "$SWAP_FILE")
    need_mb=$(( ( swap_bytes - swap_file_bytes ) / 1024 / 1024 ))
    check_space_for_swap $need_mb || return 1
    if swapon --show=NAME --noheadings | grep -qxF "$SWAP_FILE"; then
        if (( swap_bytes != swap_file_bytes )); then
            echo "[*] turning off old swap"
            sudo swapoff "$SWAP_FILE" || {
                echo "[!] error: failed to turn off old swap" >&2;
                return 1;
            }
        else
            add_swap_to_fstab
            return 0
        fi
    fi
    sudo rm -f "$SWAP_FILE"
    echo "[*] creating swapfile at $SWAP_FILE"
    sudo fallocate -l "$SWAP_SIZE" "$SWAP_FILE" || {
        echo "[!] error: failed to allocate swapfile" >&2;
        return 1;
    }
    sudo chmod 0600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE" >/dev/null
    sudo swapon "$SWAP_FILE"
    add_swap_to_fstab
    echo "[+] swap created and activated"
}

check_space_for_swap() {
    local swap_mb=$1
    local disk_mb
    disk_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    (( disk_mb - swap_mb >= SWAP_MIN_FREE )) && return 0
    echo "[!] error: not enough free disk space to safely create $SWAP_SIZE swapfile" >&2
    echo "           available: $disk_mb mb, required: $(( swap_mb + SWAP_MIN_FREE )) mb" >&2
    return 1

}

add_swap_to_fstab() {
    grep -qE "^${SWAP_FILE}[[:space:]]" "$FSTAB_FILE" && return 0
    echo "[*] adding swapfile to $FSTAB_FILE"
    echo "$SWAP_FILE none swap sw 0 0" | sudo tee -a "$FSTAB_FILE" >/dev/null
}

# ============================
# ZRAM
# ============================

setup_zram() {
    echo "[*] setting up zram"
    echo "[*] ZRAM=$ZRAM"
    local zram_mode="$ZRAM"
    zram_mode=$(echo "$zram_mode" | tr '[:upper:]' '[:lower:]')
    case "$zram_mode" in
        $ZRAM_MODE_AUTO|$ZRAM_MODE_ON|$ZRAM_MODE_OFF) ;;
        *)
            echo "[!] error: ZRAM must be auto, on or off" >&2
            return 1
            ;;
    esac
    echo "[*] ZRAM_PERCENT=$ZRAM_PERCENT"
    [[ "$ZRAM_PERCENT" =~ ^([1-9][0-9]?|100)$ ]] || {
        echo "[!] error: invalid ZRAM_PERCENT" >&2;
        return 1;
    }
    echo "[*] ZRAM_MAX=$ZRAM_MAX"
    [[ "$ZRAM_MAX" =~ ^[1-9][0-9]*$ ]] || {
        echo "[!] error: invalid ZRAM_MAX" >&2;
        return 1;
    }
    (( ZRAM_MAX >= ZRAM_MIN )) || {
        echo "[!] error: ZRAM_MAX < ZRAM_MIN" >&2;
        return 1;
    }
    if [[ "$zram_mode" == "$ZRAM_MODE_AUTO" ]]; then
        if (( RAM_MB <= ZRAM_AUTO_LIMIT )); then
            zram_mode="$ZRAM_MODE_ON"
        else
            zram_mode="$ZRAM_MODE_OFF"
        fi
        echo "[*] auto-selected zram mode: $zram_mode"
    fi
    [[ "$zram_mode" != "$ZRAM_MODE_OFF" ]] || return 0
    local zram_size_mb
    zram_size_mb=$(( RAM_MB * ZRAM_PERCENT / 100 ))
    (( zram_size_mb >= ZRAM_MIN )) || {
        echo "[!] error: calculated zram size is less than $ZRAM_MIN mb" >&2;
        return 1;
    }
    (( zram_size_mb > ZRAM_MAX )) && zram_size_mb=$ZRAM_MAX
    echo "[*] enabling zram"
    local -r src="$CONF_DIR/$ZRAM_FILE"
    [[ -f "$src" ]] || { echo "[!] error: file not found $src, exit" >&2; exit 1; }
    install_zram
    local tmp_file
    tmp_file="$(mktemp)"
    sed \
        -e "s/{{SIZE}}/$zram_size_mb/" \
        "$src" > "$tmp_file"
    sudo install -Db -S '~' -m 0644 "$tmp_file" "$ZRAM_FILE"
    rm -f "$tmp_file"
    restart_zram
    echo "[+] zram activated"
}

install_zram() {
    echo "[*] installing zram dependencies"
    sudo apt-get update
    sudo apt-get install -y zram-tools linux-modules-extra-$(uname -r)
    echo "[+] zram dependencies installed"
}

restart_zram() {
    sudo systemctl enable zramswap.service
    sudo systemctl restart zramswap.service
}

# ============================
# Main
# ============================

main() {
    echo "[*] starting"
    setup_swap
    setup_zram
    echo "[+] done"
}

main "$@"
