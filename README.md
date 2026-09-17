# Ubuntu Server Bootstrap Scripts

Bash scripts for Ubuntu 24.04/26.04 with `sudo` available.

## Scripts

- `setup.sh`: system updates, user creation with passwordless sudo, SSH, iptables, Fail2Ban and sysctl settings.
- `setup-docker.sh`: Docker installation, daemon configuration and systemd resource limits.
- `setup-swap.sh`: swap and ZRAM configuration.
- `setup-relay.sh`: TCP/UDP forwarding to an IP or domain using iptables.

## Usage

```sh
git clone https://github.com/x13a/setup-server
cd setup-server
./setup.sh
```

When started as root, setup prompts for a username and continues as that user. SSH setup prompts for a public key and disables password and root login. Ensure the selected user has a working key before skipping the prompt.

Run optional scripts as your sudo-enabled user from the repository directory:

```sh
./setup-docker.sh
./setup-swap.sh
./setup-relay.sh
```

## Configuration

Pass environment variables to the relevant script, for example:

```sh
SSH_PORT=2222 ./setup.sh
SWAP_SIZE=1G ZRAM=on ./setup-swap.sh
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `SSH_PORT` | `10101` | Port 1–65535 |
| `UFW` | - | Skip iptables configuration if set |
| `SWAP_SIZE` | `512M` | It can be 512M or 1G etc; an active swap file is kept if the same size |
| `ZRAM` | `auto` | `auto`, `on`, or `off`; auto configures ZRAM when RAM <= 2 GiB, otherwise leaves it unchanged |
| `ZRAM_PERCENT` | `50` | Percentage of RAM used to calculate ZRAM size |
| `ZRAM_MAX` | `2048` | Maximum ZRAM size in MiB |

## License

MIT
