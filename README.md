# Dev_Ops_Tools

A collection of Linux server operations scripts for user management, SSH key provisioning, and fresh-server initialisation.

## Scripts

| Script | Purpose |
|---|---|
| `install.sh` | One-stop server initialisation — updates, firewall, SSH hardening, fail2ban, auto-updates, kernel tuning |
| `batch_adduser.sh` | Batch create users with passwordless sudo (interactive or from file) |
| `add_ssh_key.sh` | Add SSH public keys to a user's `authorized_keys` with safety checks |

---

## install.sh

A comprehensive initialisation script for a fresh Linux server. It detects the distribution, updates the system, installs common tooling, configures the firewall, hardens SSH, sets up fail2ban, enables automatic security updates, tunes kernel parameters, and checks swap.

### Supported distributions

| Category | Distributions | Firewall | Package Manager |
|---|---|---|---|
| Debian-based | Debian, Ubuntu | `ufw` | `apt` |
| RHEL-based | RHEL, CentOS, Rocky Linux, AlmaLinux | `firewalld` | `dnf` / `yum` |

### What it does

1. **Distribution detection** — auto-detects Debian/Ubuntu vs RHEL/Rocky and adapts all commands
2. **System update** — `apt update && apt upgrade` or `dnf update`
3. **Base packages** — curl, wget, git, vim, nano, htop, net-tools, lsof, dnsutils/bind-utils, unzip, zip, tar, gzip, ca-certificates, gnupg, plus EPEL on RHEL
4. **Timezone & clock sync** — sets timezone via `timedatectl`, syncs with `ntpdate`, enables `systemd-timesyncd`
5. **Firewall** — default-deny incoming, allow SSH (custom port supported), HTTP/HTTPS commented out
6. **SSH hardening** — disable root login, restrict KexAlgorithms, LoginGraceTime=30s, MaxAuthTries=3, disable X11 forwarding, ClientAlive keep-alives, custom port support; validates config before restarting sshd
7. **fail2ban** — SSH jail with 5 attempts / 10 min → 1 hour ban; respects custom SSH port
8. **Automatic security updates** — `unattended-upgrades` on Debian, `dnf-automatic` on RHEL
9. **Kernel tuning** — TCP BBR congestion control, increased buffer sizes, `tcp_tw_reuse`, ICMP redirect hardening, rp_filter, martian logging
10. **SWAP check** — warns if no swap is active and provides setup instructions

### Usage

```bash
sudo bash install.sh                           # default (Asia/Shanghai, port 22)
sudo bash install.sh -t America/New_York       # custom timezone
sudo bash install.sh -p 2222                   # custom SSH port
sudo bash install.sh -n                        # dry-run — preview only, no changes
sudo bash install.sh -y                        # non-interactive (skip confirmations)
sudo bash install.sh -l /opt/logs              # custom log directory
```

### Post-install checklist

After running `install.sh`, the script prints a checklist:

1. Add your SSH public key: `bash add_ssh_key.sh`
2. Create an admin user: `bash batch_adduser.sh`
3. If SSH port was changed, update your SSH client config
4. After verifying key-based login, disable password auth in `/etc/ssh/sshd_config`
5. Review fail2ban whitelist in `/etc/fail2ban/jail.local`

---

## batch_adduser.sh

Batch create Linux users with automatic sudo group assignment and passwordless sudo configuration.

### Features

- **Permission check** — must run as root or with `sudo`
- **Distribution-aware** — automatically sets `sudo` group for Debian/Ubuntu, `wheel` for RHEL/CentOS/Rocky
- **Two modes** — interactive (prompt for usernames) or batch from file (`-f`)
- **Username validation** — POSIX-compliant regex (`[a-z_][a-z0-9_-]{0,31}`), blocks reserved system usernames
- **Password setting** — interactive mode: double-entry confirmation via `chpasswd`; batch mode: locked password with reminder
- **Duplicate detection** — skips users that already exist
- **Sudo group** — adds user to the correct sudo group (`sudo` or `wheel`)
- **Passwordless sudo** — creates `/etc/sudoers.d/<username>` with `NOPASSWD:ALL`, validates with `visudo -c`, auto-rolls back on syntax errors
- **Structured logging** — timestamped logs written to `/var/log/devops/` (configurable)
- **Summary report** — lists all successful and failed users at the end

### Supported distributions

| Category | Distributions | sudo group |
|---|---|---|
| Debian-based | Debian, Ubuntu | `sudo` |
| RHEL-based | RHEL, CentOS, Rocky Linux | `wheel` |

### Usage

```bash
sudo bash batch_adduser.sh                  # interactive mode
sudo bash batch_adduser.sh -f users.txt     # batch from file (one username per line)
sudo bash batch_adduser.sh -l /var/log/ops  # custom log directory
```

### Batch file format

```
# users.txt — lines starting with # are comments, empty lines are ignored
alice
bob
charlie
```

---

## add_ssh_key.sh

Add an SSH public key to a user's `authorized_keys` with validation, duplicate detection, and permission hardening.

### Features

- **Multiple input methods** — interactive paste, from file (`-f`), or inline string (`-k`)
- **Target user** — specify with `-u`; defaults to current user or `SUDO_USER` when run under sudo
- **Extended key type support** — `ssh-rsa`, `ssh-ed25519`, `ssh-ecdsa`, `ecdsa-sha2-nistp256/384/521`, security keys (`sk-ssh-ed25519@openssh.com`, `sk-ecdsa-sha2-nistp256@openssh.com`), and certificate types
- **Deprecated key warning** — detects `ssh-dsa`/`ssh-dss` with a warning; user can still accept
- **Base64 validation** — verifies the key data decodes correctly
- **Duplicate check** — skips if the exact key already exists in `authorized_keys`
- **Trailing newline fix** — ensures `authorized_keys` ends with a newline before appending
- **Permission hardening** — `.ssh/` set to 700, `authorized_keys` to 600; fixes ownership when run as root
- **Structured logging** — timestamped logs written to `/var/log/ssh_add_keys/` (configurable)

### Usage

```bash
bash add_ssh_key.sh                             # interactive, current user
bash add_ssh_key.sh -u alice                    # for user 'alice'
bash add_ssh_key.sh -f ~/.ssh/id_ed25519.pub    # from key file
bash add_ssh_key.sh -u bob -f bob_key.pub       # combine options
bash add_ssh_key.sh -k "ssh-ed25519 AAAAC3..."  # inline key string
```

---

## Typical workflow

On a fresh server, a typical setup sequence is:

```bash
# 1. Initialise the server (firewall, SSH hardening, fail2ban, etc.)
sudo bash install.sh

# 2. Create an admin user
sudo bash batch_adduser.sh

# 3. Add your SSH key for passwordless login
bash add_ssh_key.sh -u <admin_user> -f ~/.ssh/id_ed25519.pub

# 4. Test key-based login, then disable password auth in /etc/ssh/sshd_config
```

---

## License

MIT © 2026 JirenYoung
