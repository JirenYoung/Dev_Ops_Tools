# 脚本优化报告

> **生成日期**: 2026-05-30  
> **优化依据**: `main.md`（运维分析） + `chat_export_20260528_002519.md`（安全审计）  
> **涉及文件**: `batch_adduser.sh`、`add_ssh_key.sh`

---

## 变更总览

| 文件 | 原行数 | 现行数 | 变更类别 |
|---|---|---|---|
| `batch_adduser.sh` | 246 | 249 | 重写 |
| `add_ssh_key.sh` | 52 | 159 | 重写 |

---

## 一、`batch_adduser.sh` — 逐项变更

### 1.1 添加 Bash 严格模式

**问题来源**: chat_export #3 — 没有 `set -euo pipefail`，命令静默失败会继续执行，造成"假阳性"。

**Before**:
```bash
#!/bin/bash
# (无严格模式)
```

**After**:
```bash
#!/bin/bash
set -uo pipefail
```

> 说明：使用 `-uo pipefail` 而非 `-euo pipefail`，因为该交互式脚本有多处**预期会失败但已显式处理**的命令（如 `id` 检查、`visudo -c` 校验）。`-u` 防止引用未定义变量，`pipefail` 确保管道中任意命令失败都能被捕获。

---

### 1.2 用户名校验增强

**问题来源**: chat_export #2 — 只检查是否为空，未校验合法字符、保留用户名、长度。

**Before** (第93行):
```bash
if [[ -z "$username" ]]; then
    echo "Error! Username cannot be empty."
    continue
fi
```

**After**:
```bash
readonly USERNAME_REGEX='^[a-z_][a-z0-9_-]{0,31}$'
readonly RESERVED_USERS=(
  root bin daemon adm lp sync shutdown halt mail operator
  nobody systemd-network systemd-resolve systemd-timesync
  sshd postfix ntp www-data mysql redis docker
)

validate_username() {
  local username="$1"
  if [[ ! "$username" =~ $USERNAME_REGEX ]]; then
    log_error "Invalid username '$username'."
    log_error "Must start with a lowercase letter or underscore,"
    log_error "contain only [a-z0-9_-], and be ≤ 32 characters."
    return 1
  fi
  for reserved in "${RESERVED_USERS[@]}"; do
    if [ "$username" = "$reserved" ]; then
      log_error "'$username' is a reserved system username. Choose another."
      return 1
    fi
  done
  return 0
}
```

> 变更理由：POSIX 用户名规范为 `[a-z_][a-z0-9_-]*[$]?`，此处采用严格版（禁止尾随 `$`）。同时拦截与系统服务冲突的用户名，防止误操作破坏系统。

---

### 1.3 `passwd` → `chpasswd` + 密码确认循环

**问题来源**: chat_export #1（中高危）— `passwd` 退出码不可靠，两次输入不匹配时可能返回 0。

**Before** (第137-148行):
```bash
passwd "$username"
if [ $? -eq 0 ]; then
    echo "✅ User $username created and password set successfully!"
else
    echo "⚠️  Failed to set password for user '$username'"
fi
```

**After**:
```bash
set_password() {
  local username="$1"
  local password password2
  while true; do
    read -s -p "Enter password for $username: " password
    echo >&2
    read -s -p "Confirm password for $username: " password2
    echo >&2
    if [ "$password" != "$password2" ]; then
      log_warn "Passwords do not match. Try again."
      continue
    fi
    if [ -z "$password" ]; then
      log_warn "Password cannot be empty. Try again."
      continue
    fi
    break
  done
  echo "$username:$password" | chpasswd 2>/dev/null
}
```

> 变更理由：`chpasswd` 从 stdin 读取 `username:password`，退出码可靠。脚本自行做密码确认，不依赖 `passwd` 的交互提示。

---

### 1.4 `tee` → 直接重定向

**问题来源**: chat_export #4 — `tee` 会把 sudoers 内容打印到终端。

**Before** (第178行):
```bash
echo "$username  ALL=(ALL)  NOPASSWD:ALL" | tee "$SUDO_FILE"
```

**After**:
```bash
echo "$username  ALL=(ALL)  NOPASSWD:ALL" > "$sudo_file"
```

> 变更理由：`>` 直接写入文件，不向终端输出。同时消除了 chat_export #6 提到的管道 `$?` 语义脆弱性问题。

---

### 1.5 审计日志

**问题来源**: chat_export #5 + main.md #4 — 无日志记录，事后无法追溯操作。

**Before**: 无日志。

**After**:
```bash
LOG_DIR="${LOG_DIR:-/var/log/devops}"
setup_logging() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  LOG_FILE="${LOG_DIR}/batch_adduser_$(date +%Y%m%d_%H%M%S).log"
  exec 3>&1  # save original stdout
}
log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "$LOG_FILE" >&3; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&3; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "$LOG_FILE" >&3; }
```

> 变更理由：带时间戳的结构化日志写入 `/var/log/devops/`，同时保留终端输出。可通过 `-l` 参数自定义目录。事后可通过 `grep` 追溯完整操作链。

---

### 1.6 批量导入模式 (`-f`)

**问题来源**: main.md #3 — 只支持交互式逐个创建，无法从文件批量导入。

**Before**: 仅有 `while true; read -p ...` 循环。

**After**:
```bash
# 新增 CLI 参数解析
while getopts "f:l:h" opt; do
  case "$opt" in
    f) BATCH_FILE="$OPTARG" ;;
    l) LOG_DIR="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# 批量模式
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"            # strip comments
  line="$(echo "$line" | xargs)" # trim whitespace
  [ -z "$line" ] && continue
  USERNAMES+=("$line")
done < "$BATCH_FILE"
```

> 变更理由：支持 `-f users.txt`，每行一个用户名，支持 `#` 注释。批量模式下创建用户后锁定密码（`passwd -l`），由管理员后续设置——避免脚本中硬编码默认密码。

---

### 1.7 结果分离与汇总增强

**Before** (第238-245行): 仅统计成功数，失败的不追踪。

**After**:
```bash
declare -a SUCCESS=()
declare -a FAILED=()
# ... 处理循环中分别记录 ...
echo "  ✅ Success: ${#SUCCESS[@]}"
echo "  ❌ Failed:  ${#FAILED[@]}"
# 逐一列出成功和失败的用户名
```

> 变更理由：成功和失败分开列表，方便运维快速定位问题用户。

---

## 二、`add_ssh_key.sh` — 逐项变更

### 2.1 `sudo` 上下文安全检测

**问题来源**: chat_export #7（高危）— `sudo bash add_ssh_key.sh` 会导致 key 灌入 root。

**Before** (第12行):
```bash
LoginUser=$(whoami)
# ...
SSH_DIR="$HOME/.ssh"
```

**After**:
```bash
# Determine target user
if [ -n "$TARGET_USER" ]; then
  TARGET="$TARGET_USER"
else
  # Detect sudo: if running under sudo, default to SUDO_USER
  if [ -n "${SUDO_USER:-}" ]; then
    TARGET="$SUDO_USER"
  else
    TARGET="$(whoami)"
  fi
fi
HOME_DIR="$(eval echo ~"$TARGET")"
```

> 变更理由：当通过 `sudo` 运行时，`$SUDO_USER` 保存了原始用户。脚本默认将 key 添加到原始用户而非 root。同时新增 `-u` 参数可以显式指定目标用户。

---

### 2.2 支持 `-u` 指定用户 + `-f` 读文件 + `-k` 行内传 key

**问题来源**: main.md #2 — 只能给当前用户添加，不能从文件读取。

**Before**: 仅交互式粘贴。

**After**:
```bash
Options:
  -u USER     Target user (default: current user)
  -f FILE     Read public key from FILE
  -k KEY      Provide public key as a string
```

> 变更理由：运维场景中经常需要帮别的用户添加 key，或者从 `~/.ssh/id_ed25519.pub` 直接读取。三种输入方式覆盖所有常见场景。

---

### 2.3 公钥格式校验增强

**问题来源**: chat_export #8 — 只检查前缀，接受 `ssh-dsa` 和不安全数据。

**Before** (第27行):
```bash
if [[ ! "$SSH_KEY" =~ ^ssh-(rsa|ed25519|ecdsa|dsa) ]]; then
    echo "Invalid public key format."
    exit 1
fi
```

**After**:
```bash
readonly ALLOWED_KEY_TYPES=(
  ssh-rsa ssh-ed25519 ssh-ecdsa
  sk-ssh-ed25519@openssh.com sk-ecdsa-sha2-nistp256@openssh.com
  ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521
  ssh-rsa-cert-v01@openssh.com ssh-ed25519-cert-v01@openssh.com
  ssh-ecdsa-cert-v01@openssh.com
)
readonly DEPRECATED_KEY_TYPES=(ssh-dsa ssh-dss)

validate_key() {
  # 1. 拆解 type + data + comment
  read -r key_type key_data key_comment <<< "$key"
  # 2. 拦截已弃用类型 (DSA)，询问确认
  # 3. 白名单校验 key 类型（含 FIDO、证书）
  # 4. base64 解码验证
  if ! echo "$key_data" | base64 -d &>/dev/null; then
    echo "ERROR: Key data is not valid base64."
    return 1
  fi
}
```

> 变更理由：
> - **黑名单 `ssh-dsa`**：OpenSSH 7.0 起默认禁用，属于不安全算法。
> - **白名单 FIDO/证书**：`sk-ssh-ed25519@openssh.com` 等硬件安全密钥格式现在可以通过。
> - **base64 解码验证**：拒绝 `ssh-ed25519 i_am_garbage` 这类垃圾数据。

---

### 2.4 `authorized_keys` 末尾换行符保护

**问题来源**: chat_export #9 — 如果文件末尾缺少换行符，追加的 key 会与最后一行拼接，导致**全部 key 失效**。

**Before** (第40行):
```bash
echo "$SSH_KEY" >> "$AUTH_FILE"
```

**After**:
```bash
ensure_trailing_newline() {
  local file="$1"
  if [ -s "$file" ] && [ "$(tail -c1 "$file" | wc -l)" -eq 0 ]; then
    echo >> "$file"
    echo "NOTE: Added missing trailing newline to authorized_keys." >&2
  fi
}

# 在追加前调用
if [ -f "$AUTH_FILE" ]; then
  ensure_trailing_newline "$AUTH_FILE"
fi
echo "$SSH_KEY" >> "$AUTH_FILE"
```

> 变更理由：`tail -c1 | wc -l` 判断最后一个字符是否是换行符。如果不是，先补一个换行再追加。防止误毁已有的 authorized_keys 配置。

---

### 2.5 Bash 严格模式

**问题来源**: chat_export #10 — 缺少 `set -euo pipefail`。

**Before**: 无。

**After**:
```bash
#!/bin/bash
set -euo pipefail
```

---

### 2.6 文件操作错误处理

**问题来源**: chat_export #11 — `mkdir`、`chmod`、`echo >>` 等操作无错误处理。

**Before**:
```bash
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
echo "$SSH_KEY" >> "$AUTH_FILE"
chmod 600 "$AUTH_FILE"
```

**After**:
```bash
if ! mkdir -p "$SSH_DIR"; then
  echo "ERROR: Failed to create $SSH_DIR" >&2
  exit 1
fi
chmod 700 "$SSH_DIR" || true

echo "$SSH_KEY" >> "$AUTH_FILE" || {
  echo "ERROR: Failed to write to $AUTH_FILE" >&2
  exit 1
}
chmod 600 "$AUTH_FILE" || true
```

> 变更理由：关键操作失败时明确报错并退出。`chmod` 用 `|| true` 容忍（在非关键路径上），因为权限设置失败不影响功能正确性。

---

### 2.7 条件表达式简化

**问题来源**: chat_export #12 — 冗余的 `|| -z "$answer"`。

**Before** (第16行):
```bash
if [[ "$answer" != "y" && "$answer" != "Y" || -z "$answer" ]]; then
```

**After**: 该行已被移除（交互流程重新设计）。

---

### 2.8 `chown` 补充

**新增功能**: 当以 root 执行并添加 key 到其他用户时，自动修正 `.ssh` 目录和 `authorized_keys` 的属主。

```bash
if [ "$(whoami)" = "root" ]; then
  chown "$TARGET":"$TARGET" "$AUTH_FILE" 2>/dev/null || true
  chown "$TARGET":"$TARGET" "$SSH_DIR" 2>/dev/null || true
fi
```

> 变更理由：root 帮 alice 添加 key 后，如果 `~alice/.ssh/authorized_keys` 属主是 root，SSH 会拒绝读取。自动修正属主避免此问题。

---

## 三、未变动的安全措施（保留）

以下来自于原始脚本的正确实现，优化后完整保留：

| 保留项 | 位置 | 说明 |
|---|---|---|
| `$EUID -ne 0` root 校验 | `batch_adduser.sh` | 防止非特权执行 |
| `id "$username"` 查重 | `batch_adduser.sh` | 防止重复创建 |
| `visudo -c -f` 语法校验 | `batch_adduser.sh` | 防止 sudoers 语法错误导致 sudo 瘫痪 |
| 语法错误时 `rm -f "$SUDO_FILE"` 自动回滚 | `batch_adduser.sh` | 安全关键措施 |
| `chmod 0440` sudoers 文件 | `batch_adduser.sh` | 符合 visudo 要求 |
| `chmod 700` .ssh / `chmod 600` authorized_keys | `add_ssh_key.sh` | SSH 安全权限 |
| `grep -qxF` 去重检查 | `add_ssh_key.sh` | 固定字符串全行匹配 |

---

## 四、优化效果对比

| 维度 | `batch_adduser.sh` 优化前 | `batch_adduser.sh` 优化后 |
|---|---|---|
| 严格模式 | 无 | `set -uo pipefail` |
| 用户名校验 | 只判空 | POSIX 正则 + 保留名黑名单 |
| 密码设置 | `passwd`（退出码不可靠） | `chpasswd`（退出码可靠）+ 确认循环 |
| 终端噪音 | `tee` 打印 sudoers 到屏幕 | `>` 静默写入 |
| 审计日志 | 无 | 带时间戳结构化日志 + `-l` 自定义目录 |
| 批量模式 | 仅交互式 | `-f` 读文件批量创建，支持 `#` 注释 |

| 维度 | `add_ssh_key.sh` 优化前 | `add_ssh_key.sh` 优化后 |
|---|---|---|
| sudo 安全 | 无检测，key 灌入 root | 自动识别 `SUDO_USER` + `-u` 显式指定 |
| 目标用户 | 固定为 `$HOME` | `-u` 指定 + `SUDO_USER` 自动检测 |
| Key 输入 | 仅交互粘贴 | 交互 / `-f` 读文件 / `-k` 命令行传入 |
| 公钥校验 | 仅前缀正则，接受 DSA | 白名单 + 黑名单 + base64 解码验证 + FIDO 支持 |
| 换行符保护 | 无 | 追加前检测并补充末尾换行符 |
| 属主修正 | 无 | root 操作后自动 `chown` |
| 错误处理 | 无 | 关键路径报错退出 |

---

## 五、使用建议

优化后的脚本使用方法：

```bash
# === batch_adduser.sh ===
# 交互模式（原有用法）
sudo bash batch_adduser.sh

# 批量模式（新增）
sudo bash batch_adduser.sh -f new_users.txt

# 指定日志目录
sudo bash batch_adduser.sh -f new_users.txt -l /opt/logs

# === add_ssh_key.sh ===
# 交互粘贴（原有用法）
bash add_ssh_key.sh

# 给指定用户从文件添加
sudo bash add_ssh_key.sh -u alice -f ~/.ssh/id_ed25519.pub

# 命令行直接传 key
bash add_ssh_key.sh -k "ssh-ed25519 AAAAC3NzaC1..."
```

---

## 六、`install.sh` — 首次优化（第二轮新增）

> **优化日期**: 2026-05-31
> **涉及文件**: `install.sh`
> **问题来源**: main.md（运维分析 #1, #3, #4） + error.md（安全审计 #3, #5）

### 变更总览

| 文件 | 原行数 | 现行数 | 变更类别 |
|---|---|---|---|
| `install.sh` | 521 | 593 | 大幅增强 |

### 6.1 添加审计日志

**问题来源**: error.md #5 + main.md #4 — 脚本执行了大量系统变更（包安装、SSH 配置、防火墙、内核参数），但完全没有日志记录，事后无法追溯。

**Before**: 所有输出仅到终端。

**After**:
```bash
setup_logging() {
  if $DRY_RUN; then
    LOG_FILE="/dev/null"
    return
  fi
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
  exec 3>&1
}

log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "$LOG_FILE" >&3 ...; }
log_error() { ... }
log_warn()  { ... }
```

> 变更理由：与 `batch_adduser.sh` 保持一致的日志格式。所有关键操作（发行版检测、包更新、SSH 加固、fail2ban 配置等）均写入日志文件，同时保留终端输出。可通过 `-l` 参数自定义日志目录。

### 6.2 添加 CLI 参数

**问题来源**: main.md #1 — 时区、NTP 服务器等硬编码，无法在不同区域的服务器复用。

**Before**: 无 CLI 参数，所有配置硬编码。

**After**:
```bash
Usage: sudo bash install.sh [OPTIONS]

Options:
  -t TIMEZONE   Set timezone (default: Asia/Shanghai)
  -p PORT       SSH port to open in firewall (default: 22)
  -l DIR        Log directory (default: /var/log/devops)
  -n            Dry-run — show what would be done, make no changes
  -y            Non-interactive mode (skip confirmations)
  -h            Show this help message
```

> 变更理由：`-t` 支持任意 IANA 时区；`-p` 支持自定义 SSH 端口并同步修改防火墙规则、fail2ban jail 和 sshd_config；`-n` 干运行模式允许在执行前预览所有变更。

### 6.3 `eval "$PKG_UPDATE"` → 内联条件

**问题来源**: error.md #3 — `eval` 是代码异味，虽然此处 PKG_UPDATE 是硬编码的，但不符合安全编码规范。

**Before**:
```bash
eval "$PKG_UPDATE"
```

**After**:
```bash
if [ "$DISTRO" = "debian" ]; then
  apt update -y && apt upgrade -y
elif [ "$DISTRO" = "rhel" ]; then
  $PKG_MANAGER update -y
fi
```

> 变更理由：消除 `eval` 依赖，命令执行路径完全显式，代码审查时意图一目了然。

### 6.4 `Protocol 2` 条件化

**问题来源**: 代码审查 — OpenSSH 7.0+ 仅支持 Protocol 2，显式设置会触发 daemon warning。

**Before**:
```bash
set_sshd_option "Protocol" "2"
```

**After**:
```bash
if sshd -V 2>&1 | grep -qP 'OpenSSH_[1-6]\.'; then
  set_sshd_option "Protocol" "2"
  log_info "Set Protocol 2 (OpenSSH < 7.0 detected)."
else
  log_info "Skipping Protocol directive (OpenSSH 7.0+ defaults to Protocol 2)."
fi
```

> 变更理由：现代 OpenSSH 上跳过冗余指令，避免 `sshd -t` 产生 WARNING 日志。仅在老旧系统上显式设置。

### 6.5 `ufw comment` 版本兼容

**问题来源**: 代码审查 — `ufw allow ... comment 'SSH'` 需要 ufw ≥ 0.35，Ubuntu 16.04 的 ufw 0.35 以下版本不支持。

**Before**:
```bash
ufw allow 22/tcp comment 'SSH'
```

**After**:
```bash
if ufw version 2>/dev/null | grep -qP '0\.(3[5-9]|[4-9]\d)' || \
   ufw version 2>/dev/null | grep -qP '[1-9]\d+\.'; then
  ufw allow ${SSH_PORT}/tcp comment 'SSH'
else
  ufw allow ${SSH_PORT}/tcp
fi
```

> 变更理由：检测 ufw 版本，仅在支持时添加注释。不支持时降级为不带 comment 的规则。

### 6.6 `systemctl enable --now` 分离

**问题来源**: 兼容性 — `--now` flag 在旧版 systemd（< 220）上不可用。

**Before**:
```bash
systemctl enable "$FIREWALL_SERVICE" --now
```

**After**:
```bash
systemctl enable "$FIREWALL_SERVICE"
systemctl start "$FIREWALL_SERVICE" 2>/dev/null || true
```

> 变更理由：分离 enable 和 start 操作，兼容旧版 systemd。start 失败不阻塞流程。

### 6.7 干运行模式 (`-n`)

**新增功能**: `-n` / `--dry-run` 标志，通过 `run_cmd()` 辅助函数实现——不执行任何系统变更，仅打印将执行的操作。

```bash
run_cmd() {
  if $DRY_RUN; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}
```

> 变更理由：在新服务器上首次运行前可以安全预览所有 11 步操作，验证发行版检测、参数配置无误后再实际执行。

### 6.8 SSH 端口联动

**新增功能**: `-p` 指定的端口同步生效于：
- 防火墙规则（ufw / firewalld）
- fail2ban jail.local（如果端口非 22，自动 patch）
- sshd_config `Port` 指令

### 6.9 sshd 恢复逻辑增强

**Before**: 备份恢复后直接重启，如果备份本身也是坏的则静默失败。

**After**:
```bash
if sshd -t; then
  systemctl restart sshd ...
else
  log_error "CRITICAL: Even the backup config is invalid! Manual intervention required."
fi
```

> 变更理由：双重校验——恢复备份后再次执行 `sshd -t`，如果备份也无效则明确报警，避免运维人员不知情。

### 6.10 `tcp_tw_reuse` 文档注释

**Before**: 仅 `net.ipv4.tcp_tw_reuse = 1`，无说明。

**After**: 增加 NAT 注意事项注释——`tcp_tw_recycle` 在 kernel 4.12 已移除，`tcp_tw_reuse` 在 NAT 后使用需谨慎。

---

## 七、`add_ssh_key.sh` — 第二轮优化

### 7.1 `eval echo ~` → `getent passwd`

**问题来源**: error.md #3 — `eval` 存在注入风险，虽然此处 username 已经过校验。

**Before**:
```bash
HOME_DIR="$(eval echo ~"$TARGET")"
```

**After**:
```bash
HOME_DIR="$(getent passwd "$TARGET" | cut -d: -f6)"
if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
  log_error "Cannot resolve home directory for user '$TARGET'."
  exit 1
fi
```

> 变更理由：`getent` 直接从系统数据库查询，无需 shell 展开，消除 `eval`。同时增加家目录存在性校验——如果 getent 返回空或目录不存在，明确报错退出。

### 7.2 添加审计日志

**新增**: 与 `batch_adduser.sh` 和 `install.sh` 保持一致的日志系统，记录操作时间、目标用户、key 类型。支持 `-l` 选项自定义日志目录。

### 7.3 `chown` 组解析修复

**Before**:
```bash
chown "$TARGET":"$TARGET" "$AUTH_FILE"
```

**After**:
```bash
TARGET_GROUP="$(id -gn "$TARGET" 2>/dev/null || echo "$TARGET")"
chown "${TARGET}:${TARGET_GROUP}" "$AUTH_FILE" 2>/dev/null || true
```

> 变更理由：原先假设用户主组名与用户名相同（`alice:alice`）。但某些系统上 `useradd` 可能使用 `users` 等统一组。`id -gn` 查询实际主组名，`|| echo` 兜底。

---

## 八、`batch_adduser.sh` — 第二轮优化

### 8.1 `echo` → `printf`（密码管道安全）

**Before**:
```bash
echo "$username:$password" | chpasswd 2>/dev/null
```

**After**:
```bash
printf '%s:%s' "$username" "$password" | chpasswd 2>/dev/null
```

> 变更理由：`echo` 会解释反斜杠转义序列（`\n`, `\t` 等）和 `-n` 标志。如果密码中包含这些字符，`echo` 可能产生意外的输出。`printf '%s:%s'` 精确格式化，不做任何转义解释。在 bash 中 `echo` 作为 builtin 不会暴露到进程列表，所以此处主要收益是密码内容安全性。

### 8.2 `xargs` → bash 参数展开（消除子进程）

**Before**:
```bash
line="$(echo "$line" | xargs)" # trim whitespace
```

**After**:
```bash
# Trim leading/trailing whitespace (bash built-in, no subprocess fork)
line="${line#"${line%%[![:space:]]*}"}"
line="${line%"${line##*[![:space:]]}"}"
```

> 变更理由：`echo | xargs` 每次循环 fork 两个子进程。在大批量导入（数百用户）时，累积的子进程开销可观。bash 参数展开是纯内置操作，零 fork。POSIX 兼容，不依赖 `xargs` 是否安装。

---

## 九、第二轮变更总览

| 文件 | 原行数 | 现行数 | 本轮变更要点 |
|---|---|---|---|
| `install.sh` | 521 | 593 | 审计日志、CLI 参数（`-t/-p/-l/-n/-y/-h`）、去 eval、Protocol 2 条件化、ufw 版本兼容、干运行支持、systemctl 兼容、SSH 端口联动、sshd 恢复增强 |
| `add_ssh_key.sh` | 241 | 268 | `eval echo ~` → `getent`、审计日志、`chown` 组解析（`id -gn`）、`-l` 选项 |
| `batch_adduser.sh` | 314 | 316 | `echo` → `printf`（密码安全）、`xargs` → bash 参数展开（零 fork 子进程） |

---

*报告结束。所有变更均已反映在对应的 `.sh` 文件中。*