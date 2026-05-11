# Changelog

## v1.2

### 新增
- **菜单 [13] 设置 IPv4 优先** — 独立菜单设置 IPv4 优先出站
  - 写入 `/etc/gai.conf` precedence 规则
  - 自动检测当前状态（已设置时提示是否重新写入）
  - getent 验证是否生效
  - 支持 CLI: `ipv4prio`
  - 兼容所有 6 个系统（Debian 11/12/13, Ubuntu 20.04/22.04/24.04）
- **菜单 [11] WARP IPv6** — 通过 Cloudflare WARP WireGuard 隧道添加 IPv6
  - 支持 Debian 11/12/13, Ubuntu 20.04/22.04/24.04
  - wgcf 从 GitHub releases 直接下载（不依赖失效的 git.io）
  - 自动设置 IPv4 优先出站（/etc/gai.conf）
  - 重启后自动恢复
  - 不影响 IPv4 网络
- **菜单 [12] 添加虚拟内存** — 自动检测并创建 Swap
  - 已有 Swap 时跳过
  - 根据内存大小自动决定 Swap 大小
  - swappiness=10（优先物理内存）
  - 持久化到 /etc/fstab
- **菜单 [10] 清理日志+定时任务**
  - 独立清理脚本 /root/clean_logs.sh
  - journald 存储禁用（Storage=none）
  - crontab 每天 03:00 自动清理
  - 自动安装 cron（Debian 12/13 默认没有）

### 修复
- XanMod GPG 密钥 403 → 多源回退（Ubuntu Keyserver + OpenPGP）
- BBR 模块未加载 → `modprobe tcp_bbr` 前置
- Debian 11 backports 404 → EOL 版本不写 backports
- Ubuntu 缺少 resolvconf → WireGuard 配置不设 DNS
- IPv6 地址格式 /128/128 重复 → 正确解析 wgcf 配置
- v1 CPU 强行升级到 v2 → 改为回退 LTS 分支
- debian-security 镜像重定向 → 固定用 deb.debian.org
- 系统升级 base-files 未更新 → 单独 --force-confnew
- Windows CRLF → 脚本开头自动修复
- UTF-8 BOM → 已移除
- 非交互模式 read 卡住 → _is_interactive 检测

## v1.1

### 新增
- 菜单 [10] 日志清理+定时任务

## v1.0

### 初始版本
- 菜单 1-9 + 0
- XanMod 内核自动安装（MAIN/LTS 自动选择）
- 智能网络优化（CN/海外自动适配）
- 镜像测速换源（并行下载测带宽）
- NFT 转发优化（conntrack 动态计算）
- 系统大版本升级（逐级升级）
- 基础系统包安装
- 全系统测试通过（Debian 11/12/13, Ubuntu 20/22/24）
