# Dev_Ops_Tools

Linux 服务器运维辅助脚本集，包含批量用户管理和 SSH 公钥配置。

## 脚本列表

| 脚本 | 用途 |
|---|---|
| `batch_adduser.sh` | 批量创建用户，自动配置 sudo 与免密 sudo |
| `add_ssh_key.sh` | 将 SSH 公钥添加到服务器 authorized_keys |

---

## batch_adduser.sh

批量创建 Linux 服务器新用户，并自动配置免密码 sudo 权限。

### 功能

- **权限校验** — 必须以 `root` 或 `sudo` 运行
- **发行版自适应** — 自动识别 Debian/Ubuntu（sudo 组）和 RHEL/CentOS/Rocky（wheel 组）
- **交互式创建** — 逐个输入用户名，支持连续创建多个用户
- **密码设置** — 调用 `passwd` 为每个用户设置登录密码
- **sudo 分组** — 自动将用户加入对应 sudo 组（`sudo` 或 `wheel`）
- **免密 sudo** — 在 `/etc/sudoers.d/` 下创建配置，实现 `NOPASSWD:ALL`
- **安全校验** — 写入 sudoers 文件后校验语法，校验失败自动回滚删除
- **退出统计** — 脚本结束时列出所有成功创建的用户

### 支持的系统

| 发行版类别 | 代表系统 | sudo 组 |
|---|---|---|
| Debian-based | Debian, Ubuntu | `sudo` |
| Red Hat-based | RHEL, CentOS, Rocky Linux | `wheel` |

不支持 Arch 及其他滚动发行版。

### 使用方法

```bash
# 以 root 身份运行
sudo bash batch_adduser.sh
```

按提示输入用户名、设置密码，完成后可选择继续创建下一个用户或退出。

### 示例

```
$ sudo bash batch_adduser.sh

Checking Linux distribution...
### Debian-based system detected.
### The sudo group is set to 'sudo'.

### Starting to add new users to the system ###

Enter the username to add (or 'exit' to quit): alice
Creating user 'alice'...
✅ User 'alice' has been added successfully.
Please set a password for user 'alice'...
✅ User alice created and password set successfully!
Adding user 'alice' to the 'sudo' group...
✅ User 'alice' has been added to the 'sudo' group successfully.
Configuring passwordless sudo for user 'alice'...
✅ User 'alice' set to passwordless sudo successfully.
✅ All operations completed for user 'alice'!

Do you want to create another user? (y/n): n

### Script execution completed! ###
✅ Successfully added 1 user(s):
  - alice
```

---

## add_ssh_key.sh

将 SSH 公钥添加到当前用户的 `~/.ssh/authorized_keys`，实现免密码 SSH 登录。

### 功能

- **交互式添加** — 提示用户输入公钥字符串
- **格式校验** — 验证公钥是否以 `ssh-rsa`、`ssh-ed25519`、`ssh-ecdsa` 或 `ssh-dsa` 开头
- **目录初始化** — 自动创建 `~/.ssh` 目录并设置正确权限（700）
- **去重检查** — 检测公钥是否已存在，避免重复添加
- **权限加固** — `authorized_keys` 文件自动设为 600

### 使用方法

```bash
bash add_ssh_key.sh
```

按提示输入公钥字符串即可。

### 示例

```
$ bash add_ssh_key.sh

Welcome, alice! This script will help you add public SSH keys to this server.
Please follow the prompts to complete the process.
Add Public Key to this Server (y/n)? y
This script will add your SSH public key to this server

Enter the public key for the SSH key: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...

SSH key has been added to the authorized_keys file.
You can now use this key to access the server.
please check login with the new SSH key to ensure it works correctly.
```

---

## License

MIT © 2026 JirenYoung
