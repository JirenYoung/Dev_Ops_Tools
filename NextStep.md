# 🏢 公司新服务器 — 完整任务清单

## 现有脚本已覆盖（✅ Done）

| # | 任务 | 对应脚本 |
|---|------|----------|
| 1 | 系统更新 + 基础工具安装 | `install.sh` |
| 2 | 防火墙配置（仅开 SSH） | `install.sh` |
| 3 | SSH 加固（禁 root、收紧密钥算法、fail2ban） | `install.sh` |
| 4 | 自动安全更新 | `install.sh` |
| 5 | 内核参数调优（BBR、缓冲区、ICMP 防护） | `install.sh` |
| 6 | 批量创建管理员用户 + 免密 sudo | `batch_adduser.sh` |
| 7 | 部署 SSH 公钥 | `add_ssh_key.sh` |

---

## 🔴 P0 — 不做就危险（安全缺口）

| # | 任务 | 说明 |
|---|------|------|
| **8** | **SSH 仅允许密钥登录** | 现在 `PasswordAuthentication yes`，等于是暴力破解的靶子。需要：验证密钥可用 → 关闭密码登录 → 失败自动回滚 |
| **9** | **SSH 端口变更** | 22 端口是全球扫描重灾区，改成 4222 或其他高位端口，减少 99% 噪音攻击。需同步改 sshd_config + 防火墙 |
| **10** | **防火墙端口管理** | 后续部署 Web/DB/Redis 需要频繁开关端口。需要 `fw_port add 443` / `fw_port del 3306` / `fw_port list` 这样的命令 |

---

## 🟡 P1 — 运维效率（每天都在用的）

| # | 任务 | 说明 |
|---|------|------|
| **11** | **Docker + Docker Compose 安装** | 现代服务器的基础运行时，几乎所有服务都以容器跑 |
| **12** | **Docker 优化配置** | 日志大小限制（`max-size: 10m`）、`live-restore`、镜像加速器 |
| **13** | **反向代理部署（Nginx/Caddy）** | 对外暴露 Web 服务的统一入口，HTTPS 终结 |
| **14** | **SSL 证书自动申请+续期** | Let's Encrypt / acme.sh，现在没有 HTTPS 的服务是不可接受的 |
| **15** | **系统信息一键收集** | CPU/内存/磁盘/网络/进程/内核版本/open files — 排查问题的第一站 |
| **16** | **异常登录检测** | 解析 `/var/log/auth.log`，统计失败登录 IP、用户名，输出可疑活动报告 |
| **17** | **磁盘使用率告警** | 定时检查 `/` `/var` `/var/lib/docker` 占用率 > 80% 就告警 |
| **18** | **服务健康检查** | 检查关键服务（nginx/docker/mysql/redis）是否存活，挂了告警 |
| **19** | **配置备份** | `/etc/ssh/`、`/etc/fail2ban/`、`/etc/nginx/`、`/etc/sysctl.d/` 等关键目录的定时备份 |
| **20** | **日志清理/轮转** | logrotate 配置 + 清理过期日志，防止 `/var/log` 把磁盘吃满 |

---

## 🟢 P2 — 监控与可视化（出问题了才知道）

| # | 任务 | 说明 |
|---|------|------|
| **21** | **Prometheus + Node Exporter** | 采集机器指标（CPU/内存/磁盘/网络/负载） |
| **22** | **Grafana** | 图表展示，导入现成的 Node Exporter Dashboard |
| **23** | **Dozzle（Docker 日志查看）** | 轻量 Web UI，直接浏览器看所有容器日志 |
| **24** | **Loki + Promtail** | 如果你不想用 Dozzle，这是正经的日志聚合方案，和 Grafana 集成 |
| **25** | **Uptime Kuma** | 轻量监控面板，检测网站/端口存活，支持 Telegram/邮件告警 |

---

## 🔵 P3 — 业务就绪（按需选装）

| # | 任务 | 说明 |
|---|------|------|
| **26** | **数据库部署** | PostgreSQL / MySQL / Redis 的 Docker Compose 模板（含持久化、备份） |
| **27** | **对象存储（MinIO）** | S3 兼容，用于文件/备份/静态资源 |
| **28** | **Portainer** | Docker 可视化管理面板，不熟悉 Docker 的人也能操作 |
| **29** | **Git 服务（Gitea）** | 自建轻量 Git 服务，替代 GitHub 私仓 |
| **30** | **CI/CD 流水线** | Woodpecker / Drone / 或直接用 GitHub Actions Self-hosted Runner |
| **31** | **VPN / 内网穿透** | Tailscale（最省心）/ WireGuard / Cloudflare Tunnel |
| **32** | **数据库自动备份** | pg_dump / mysqldump + cron，备份文件同步到 S3/远程 |
| **33** | **文件备份策略** | Restic / BorgBackup / rclone 到云存储 |
| **34** | **Postfix 邮件发送** | 服务器告警需要发邮件，配置一个仅发送的 MTA |

---

## 🟣 P4 — 治理与合规（公司大了才需要）

| # | 任务 | 说明 |
|---|------|------|
| **35** | **审计日志（auditd）** | 监控关键文件访问（`/etc/shadow`、`/etc/sudoers`、`/root/.ssh/`） |
| **36** | **安全审计工具（Lynis）** | 自动化安全扫描，输出加固建议 |
| **37** | **统一入口菜单** | `bash devops.sh` 弹出菜单选择功能，新手友好 |
| **38** | **配置中心** | 把时区、SSH 端口、fail2ban 参数等提取到 `.env` 配置文件 |
| **39** | **公共函数库（common.sh）** | `check_root` / `detect_distro` / `log_info` 等公共函数，所有脚本 `source` |
| **40** | **合规检查脚本** | 定期检查 sudoers 权限、SSH 配置是否偏离基线、是否有未授权用户 |

---

## 📋 建议执行路线图

```
第 1 天：  P0-#8 SSH 密钥登录锁定 + P0-#10 防火墙管理脚本
第 2 天：  P1-#11 Docker 环境安装 + P1-#12 Docker 优化
第 3 天：  P1-#13 反向代理 + P1-#14 SSL 证书自动化
第 4 天：  P1-#15 系统信息收集 + P1-#19 配置备份
第 5 天：  P2-#21/22/23 监控三件套（Prometheus + Grafana + Dozzle）
第 2 周：  P1-#16 异常登录检测 + P1-#20 日志轮转 + P1-#17 磁盘告警
第 3 周：  P3 数据库 + Portainer + 备份策略
第 4 周：  P4 审计 + 合规 + 统一入口
```

---

> **建议：先集中火力把 P0 的 3 个安全脚本写了，这三个是当前最明显的缺口。** 完事之后再按路线图逐步推进。
