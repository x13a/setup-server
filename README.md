# Ubuntu Server Bootstrap Script

This repository contains an automated **server setup and hardening script** written in Bash.  
It’s designed to quickly prepare a clean Ubuntu server for secure remote access and Docker-based 
workloads.

## Features

- **User Management**
  - Creates a new sudo-enabled user.
  - Automatically switches to the new user context.
  - Grants passwordless `sudo` access.

- **SSH Configuration**
  - Prompts for your SSH public key and securely installs it.
  - Deploys a custom SSH configuration (`/etc/ssh/sshd_config.d/srv.conf`).
  - Changes the SSH port, which can be configured via the environment variable `SSH_PORT` 
  (default: `10101`).
  - Ensures correct permissions for SSH directories and keys.

- **Firewall & Security**
  - Configures **UFW** to allow only SSH access on the configured port.
  - Installs and sets up **Fail2Ban** to protect against brute-force attacks.
  - Deploys custom sysctl config for network hardening and swap optimisation.

- **Docker Installation**
  - Automatically installs the latest Docker version using the official script.
  - Adds the created user to the `docker` group.
  - Deploys custom Docker daemon config with `userns-remap`.
  - Deploys custom Docker systemd overrides and memory limit service.

- **Memory Optimization**
  - Optionally enables **ZRAM** (compressed RAM swap) on hosts with limited memory.
  - Defaults to auto mode: turns on ZRAM when RAM ≤ 2 GB, otherwise leaves it off.
  - ZRAM sizing and cap can be tuned via environment variables.
  - Checks if a swap file exists; if not, creates one based on the configured size.
  - Swap size can be set via the environment variable `SWAP_SIZE` (e.g., `export SWAP_SIZE=1G`).
  - Enables the swap file and sets appropriate permissions.
  - Ensures the swap is persistent across reboots.

- **System Maintenance**
  - Updates and upgrades system packages.
  - Removes obsolete packages after setup.

## Requirements

- Ubuntu 22.04/24.04 with `sudo` available.

## Usage

Clone the repo and switch into it:

```sh
git clone https://github.com/x13a/setup-server
cd setup-server
```

Optional configuration before running:

- `SSH_PORT`: custom SSH port (only used when the current port is `22`; default `10101`).
- `SWAP_SIZE`: swap file size (e.g., `1G`, `2G`; default `512M`).
- `ZRAM`: `auto` (default), `on`, or `off`. Auto enables ZRAM when the server has 2 GB RAM or less.
- `ZRAM_PERCENT`: percent of total RAM to allocate for ZRAM swap (default `50`).
- `ZRAM_MAX`: cap for ZRAM size in megabytes (default `2048`).

Run the setup:

```sh
./setup.sh
```

Prompts you will see:

- New username to create and switch into.
- SSH public key (press Enter to skip, but password auth is disabled).

After a successful run the script will ask for a reboot to apply everything cleanly.

## Extras

A minimal Watchtower example is available at `watchtower/compose.yml` for automatic Docker image 
updates once Docker is up.

## License

MIT
