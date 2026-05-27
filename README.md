# NewServerAdduser

批量创建 Linux 服务器新用户，并自动配置免密码 sudo 权限。

## 功能

- **权限校验** — 必须以 `root` 或 `sudo` 运行
- **发行版自适应** — 自动识别 Debian/Ubuntu（sudo 组）和 RHEL/CentOS/Rocky（wheel 组）
- **交互式创建** — 逐个输入用户名，支持连续创建多个用户
- **密码设置** — 调用 `passwd` 为每个用户设置登录密码
- **sudo 分组** — 自动将用户加入对应 sudo 组（`sudo` 或 `wheel`）
- **免密 sudo** — 在 `/etc/sudoers.d/` 下创建配置，实现 `NOPASSWD:ALL`
- **安全校验** — 写入 sudoers 文件后校验语法，校验失败自动回滚删除
- **退出统计** — 脚本结束时列出所有成功创建的用户

## 支持的系统

| 发行版类别 | 代表系统 | sudo 组 |
|---|---|---|
| Debian-based | Debian, Ubuntu | `sudo` |
| Red Hat-based | RHEL, CentOS, Rocky Linux | `wheel` |

不支持 Arch 及其他滚动发行版。

## 使用方法

```bash
# 下载脚本（如需要）
# chmod +x NewServerAdduser.sh

# 以 root 身份运行
sudo bash NewServerAdduser.sh
```

按提示输入用户名、设置密码，完成后可选择继续创建下一个用户或退出。

## 示例

```
$ sudo bash NewServerAdduser.sh

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

## License

MIT © 2026 JirenYoung
