# TCP 加速一键管理脚本

针对 NyanPass 转发 / AnyTLS 代理 / NFT 前置转发场景优化的服务器初始化与网络调优脚本。

## 使用方法

一键执行（自动判断网络环境）：
```bash
bash <(curl -fsSL --max-time 5 https://raw.githubusercontent.com/wvjh3z/tcpx/main/tcpx.sh || curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/wvjh3z/tcpx/main/tcpx.sh)
```

直接执行某个功能（适合批量远程执行）：
```bash
curl -fsSL https://raw.githubusercontent.com/wvjh3z/tcpx/main/tcpx.sh | bash -s op0
```

## 菜单

```
———————————————— 内核 ————————————————
 1. 安装 XanMod 内核(自动选择)   2. 启用 BBR+FQ 加速
 3. 删除旧内核
———————————————— 优化 ————————————————
 4. 智能网络优化(自动适配)       5. 中国大陆换源(测速)
 6. 海外服务器换源(测速)         7. 腾讯云NFT转发优化
———————————————— 系统 ————————————————
 8. 安装基础系统包               9. 系统大版本升级
10. 清理日志+定时任务           11. 安装WARP IPv6
12. 添加虚拟内存(Swap)           0. 退出脚本
```

## 推荐流程

```
新机器: 8 → 1 → 4 → 重启
```

## CLI 命令对照

| 菜单 | CLI 参数 | 功能 |
|------|----------|------|
| 1 | `xanmod` | 安装 XanMod 内核 |
| 2 | `bbr` | 启用 BBR+FQ |
| 4 | `op0` | 智能网络优化 |
| 5 | `op5` | 中国大陆换源 |
| 6 | `op6` | 海外换源 |
| 7 | `op7` | NFT 转发优化 |
| 8 | `op8` | 安装基础包 |
| 9 | `op9` | 系统升级 |
| 10 | `log` | 清理日志+定时任务 |
| 11 | `warp6` | 安装 WARP IPv6 |
| 12 | `swap` | 添加虚拟内存 |

## 系统支持

| 系统 | 所有功能可用 | XanMod 内核 | 推荐度 |
|------|:---:|:---:|:---:|
| **Debian 13 (trixie)** | ✅ | MAIN (全功能) | ⭐⭐⭐ 最佳 |
| **Ubuntu 24.04 (noble)** | ✅ | MAIN (全功能) | ⭐⭐⭐ 最佳 |
| Ubuntu 25.04 (plucky) | ✅ | MAIN | ⭐⭐ |
| Ubuntu 26.04 (resolute) | ✅ | MAIN | ⭐⭐ |
| **Debian 12 (bookworm)** | ✅ | 仅 LTS | ⭐⭐ |
| Debian 11 (bullseye) | 菜单1不可用 | ❌ 不支持 | ⭐ 建议升级 |
| Ubuntu 22.04 (jammy) | 菜单1不可用 | ❌ 不支持 | ⭐ 建议升级 |
| Ubuntu 20.04 (focal) | 菜单1不可用 | ❌ 不支持 | ⭐ 建议升级 |

## 功能说明

### 智能网络优化 (菜单4)
自动检测服务器位置（CN/海外），应用对应 TCP 参数：
- 国内：ECN关闭、大缓冲区、MTU探测、高RTT重传优化
- 海外：ECN开启、低延迟、激进重传

### NFT 转发优化 (菜单7)
针对 nftables 四层转发机：conntrack 动态计算、hashsize 持久化、rp_filter 关闭

### WARP IPv6 (菜单11)
通过 Cloudflare WARP WireGuard 隧道添加 IPv6，IPv4 不受影响，自动设置 IPv4 优先出站

### 换源测速 (菜单5/6)
并行下载 ~10MB 文件测实际带宽，自动选择最快镜像

### 系统升级 (菜单9)
自动检测当前版本逐级升级：Debian 11→12→13，Ubuntu 20→22→24
