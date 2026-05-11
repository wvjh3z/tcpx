# TCP 加速一键管理脚本

针对 NyanPass 转发 / AnyTLS 代理 / NFT 前置转发场景优化的服务器初始化与网络调优脚本。

## 使用方法

海外服务器：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wvjh3z/tcpx/main/tcpx.sh)
```

国内服务器（GitHub 加速）：
```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/wvjh3z/tcpx/main/tcpx.sh)
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
 0. 退出
```

## 推荐流程

```
新机器: 8 → 1 → 4 → 重启
```

1. **[8]** 安装基础系统包（工具链 + 时间同步 + NextTrace）
2. **[1]** 安装 XanMod 内核（自动选择 MAIN 或 LTS + BBRv3）
3. **[4]** 智能网络优化（自动检测 CN/海外，应用对应 TCP 参数）
4. **重启** 使内核生效

## 系统支持

| 系统 | 所有功能可用 | XanMod 内核 | 推荐度 |
|------|:---:|:---:|:---:|
| **Debian 13 (trixie)** | ✅ | MAIN (全功能) | ⭐⭐⭐ 最佳 |
| **Ubuntu 24.04 (noble)** | ✅ | MAIN (全功能) | ⭐⭐⭐ 最佳 |
| Ubuntu 25.04 (plucky) | ✅ | MAIN | ⭐⭐ |
| Ubuntu 26.04 (resolute) | ✅ | MAIN | ⭐⭐ |
| **Debian 12 (bookworm)** | ✅ | 仅 LTS | ⭐⭐ |
| Debian 11 (bullseye) | 菜单1不可用 | ❌ 不支持 | ⭐ 建议升级 |
| Debian 10 (buster) | 菜单1不可用 | ❌ 不支持 | ⭐ 建议升级 |
| Ubuntu 22.04 (jammy) | 菜单1不可用 | ❌ 不支持 | ⭐ 建议升级 |
| Ubuntu 20.04 (focal) | 菜单1不可用 | ❌ 不支持 | ⭐ 建议升级 |

> Debian 10/11 和 Ubuntu 20/22 可以使用菜单 [9] 逐级升级到支持的版本。

## XanMod 内核说明

菜单 [1] 自动检测系统版本：
- **Debian 13 / Ubuntu 24.04+** → 安装 MAIN 分支（BBRv3 + Cloudflare TCP 优化 + 低延迟调度）
- **Debian 12** → 安装 LTS 分支（仓库仅有此分支）
- **Debian 10-11 / Ubuntu 20-22** → 报错并建议升级系统

CPU 等级自动检测：
- v3 (AVX2, 2015年+) → 安装 x64v3 包
- v2 (SSE4.2, 2009年+) → 安装 x64v2 包
- v1 (基础 x86_64) → LTS 安装 x64v1，其他分支自动升级到 v2

## 网络优化说明

菜单 [4] 智能优化根据服务器位置自动选择参数：

| 参数 | 国内服务器 | 海外服务器 |
|------|-----------|-----------|
| ECN | 关闭 (中间设备不兼容) | 开启 |
| 缓冲区 | 大 (高 RTT 需要) | 更大 (高带宽利用) |
| 重传策略 | 保守 (高丢包) | 激进 (低丢包) |
| MTU 探测 | 开启 (应对黑洞) | 开启 |
| TCP Fast Open | 开启 | 开启 |
| fin_timeout | 15s | 10s |

菜单 [7] NFT 转发优化额外配置：
- conntrack 表大小（根据内存动态计算）
- conntrack 超时（适配 AnyTLS/TLS 长连接）
- 网卡队列（高 PPS 场景）
- rp_filter 关闭（避免非对称路由丢包）

## 换源测速

菜单 [5]/[6]/[9] 在换源或升级前会并行测速所有候选镜像（下载 ~10MB 文件测实际带宽），自动选择最快的。

国内镜像：阿里云、腾讯云、华为云、中科大、清华大学

海外镜像：
- Debian: 官方、Fastly CDN、Cloudflare、MIT、Kernel.org
- Ubuntu: 官方、Kernel.org、MIT、xTom、DigitalOcean

## 命令行模式

```bash
./tcpx.sh op0    # 智能网络优化
./tcpx.sh op5    # 中国大陆换源
./tcpx.sh op6    # 海外换源
./tcpx.sh op7    # NFT 转发优化
```
