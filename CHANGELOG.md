# Changelog

## v1.0

### 本次重构总结

#### 菜单精简
- 从原版 27 个菜单项精简到 9 个
- 菜单编号改为 1-9 + 0 退出
- 移除所有 CentOS/RHEL 支持，仅保留 Debian/Ubuntu
- 移除 31 个不再使用的死函数

#### 当前菜单
```
1. 安装 XanMod 内核(自动选择)   2. 启用 BBR+FQ 加速
3. 删除旧内核
4. 智能网络优化(自动适配)       5. 中国大陆换源(测速)
6. 海外服务器换源(测速)         7. 腾讯云NFT转发优化
8. 安装基础系统包               9. 系统大版本升级
0. 退出
```

#### 镜像测速
- 所有换源/升级操作统一使用 `_speedtest_mirrors` 函数
- 并行下载 ~10MB 文件 (Contents-amd64.gz) 测实际带宽
- 每个镜像最多 10 秒超时
- 显示实际 MB/s 速度
- 自动推荐最快镜像，支持手动选择

#### XanMod 内核
- 菜单 [1] 自动检测系统版本选择 MAIN 或 LTS
- 仓库 Suite 使用系统代号 (非 "releases")
- Debian 12 自动切换到 LTS (仓库仅有此分支)
- 不支持的系统明确报错并建议升级

#### 网络优化
- 菜单 [4] 智能优化: 自动检测 CN/海外，应用对应 TCP 参数
- 国内: ECN关闭、大缓冲区、MTU探测、高RTT重传优化
- 海外: ECN开启、低延迟、激进重传
- 菜单 [7] NFT转发: conntrack 动态计算、并行hashsize

#### 系统升级
- 菜单 [9] 自动检测当前版本，升级到下一级
- 升级前自动测速选择最快镜像
- Debian: 10→11→12→13 逐级升级
- Ubuntu: 20.04→22.04→24.04 逐级升级

#### 健壮性
- _check_network: 网络连通性检查
- _check_disk_space: 磁盘空间检查
- _safe_dpkg_install: deb 包完整性验证
- _safe_sysctl_apply: sysctl 错误参数捕获
- set -o pipefail: 管道错误传播
- 操作日志: /var/log/tcpx.log

### 新增
- **菜单 [34] 中国大陆网络专项优化** — 一键式分步引导
  - APT/YUM 源替换国内镜像 (5 选 1: 阿里/腾讯/华为/中科大/清华)
  - DNS 优化 (4 种方案: 阿里/腾讯/114/混合模式)
  - 自动检测 systemd-resolved 并适配配置方式
  - TCP 跨境链路专项调参:
    - 高 RTT (150-300ms) 环境缓冲区动态放大 (基于内存计算 BDP)
    - ECN 关闭 (国内中间设备兼容性)
    - MTU 探测开启 + base_mss 设置 (应对 MTU 黑洞)
    - 重传策略优化 (syn_retries/synack_retries/retries2)
    - TCP Fast Open 启用 (减少握手 RTT)
    - KeepAlive 针对跨境长连接优化 (300s/30s/3次)
    - SACK/DSACK/Window Scaling 强制开启
    - TIME_WAIT 桶扩大到 55000
  - XanMod 源加速建议与 APT 代理配置支持
- 命令行新增 `op5` 参数直接执行 CN 优化

### 改进
- `check_cn_status` 增加备用检测方式 (ipinfo.io)，Cloudflare 不可达时仍能判断
- `safe_wget` 镜像列表更新，新增 `mirror.ghproxy.com` 和 `github.moeyy.xyz`
- DNS 配置支持 `resolv.conf` 锁定 (chattr +i) 防止 DHCP 覆盖

## v200.0.2.0 — XanMod / Debian / Ubuntu 深度优化

### 新增
- XanMod 安装引擎完全重写
  - 使用现代 DEB822 格式 (`.sources`) 配置源 (Debian 12+ / Ubuntu 24+)
  - 旧版系统 (Debian 10-11 / Ubuntu 20-22) 自动回退传统 `.list` 格式
  - GPG 密钥存放在 `/etc/apt/keyrings/` (符合现代 APT 规范)
  - 正确处理各分支的 CPU 等级可用性 (仓库不发布 v4 包)
  - EDGE/MAIN/RT 分支无 v1 包时自动升级到 v2
  - Secure Boot 检测与警告 (XanMod 未签名)
  - 安装前通过 `apt-cache` 验证包是否存在
  - 安装后自动配置 BBRv3 拥塞控制
  - CPU 等级本地回退检测 (网络不可用时通过 /proc/cpuinfo 判断)
  - 详细的分支说明 (MAIN/EDGE/LTS/RT 用途解释)
  - 安装结果展示 (列出已安装的 XanMod 包)
- Debian backports 源配置优化
  - 完整代号映射 (buster → trixie)
  - Debian sid/unstable 自动跳过 backports
  - 检查 backports 源是否已存在，避免重复添加
- Ubuntu HWE 内核显式版本映射 (20.04 → 26.04)
- Liquorix/Zen 安装增加错误处理和版本兼容性检查

### 修复
- 修复 XanMod EDGE 分支尝试安装不存在的 x64v1 包的问题
- 修复 Debian testing/sid 错误添加 backports 源的问题
- 修复 Ubuntu 非 LTS 版本 HWE 包不存在时的错误处理

## v200.0.1.0 (基于原版 v100.0.5.10 优化)

### 修复
- 修复 `lsb_release` 未安装导致 Debian backports 源配置失败的问题
- 修复函数内 `exit 1` 导致整个脚本意外退出的问题
- 修复 `cd` 失败后继续执行可能导致在错误目录操作的问题
- 修复下载空文件时误报"下载成功"的问题

### 优化
- GitHub API 响应缓存，同一仓库只请求一次（headers + image 两次调用共享）
- systemd/limits 配置改用 drop-in 文件，不再覆盖系统主配置
- THP 改为提示而非强制开启
- 卸载全部加速增加二次确认
- 添加 `--help` 命令行参数

### 变更
- 菜单编号保持不变
