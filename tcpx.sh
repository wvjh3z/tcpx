#!/usr/bin/env bash
#
# TCP加速 一键安装管理脚本 (优化版)
# 基于 ylx2016/Linux-NetSpeed (GPL-2.0) 重构优化
# 仅支持: Debian 10-13, Ubuntu 20.04-26.04
#
# Copyright (c) 2025 wvjh3z
# License: GPL-2.0 (https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
# Source: https://github.com/wvjh3z/tcpx
#

# 自动修复 Windows CRLF 换行符 (从 Windows 复制过来时会带 \r)
if [[ -f "$0" ]] && grep -q $'\r' "$0" 2>/dev/null; then
	sed -i 's/\r$//' "$0"
	exec bash "$0" "$@"
fi

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 异常处理: 管道失败时传播错误码
set -o pipefail 2>/dev/null || true

# =================================================
#  全局配置区 (Configuration as Data)
# =================================================
readonly SH_VER="1.2"

# 颜色变量定义
readonly GREEN_FONT_PREFIX="\033[32m"
readonly RED_FONT_PREFIX="\033[31m"
readonly YELLOW_FONT_PREFIX="\033[33m"
readonly FONT_COLOR_SUFFIX="\033[0m"
readonly INFO="${GREEN_FONT_PREFIX}[信息]${FONT_COLOR_SUFFIX}"
readonly ERROR="${RED_FONT_PREFIX}[错误]${FONT_COLOR_SUFFIX}"
readonly TIP="${YELLOW_FONT_PREFIX}[注意]${FONT_COLOR_SUFFIX}"

# 系统信息全局变量 (初始化)
OS_TYPE=""
OS_ID=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_ARCH=""

# =================================================
#  通用工具函数
# =================================================

# 判断是否为交互式终端 (非交互时跳过 read 确认)
_is_interactive() {
	[[ -t 0 ]]
}

# 安全日志: 记录操作到日志文件 (可选)
_log() {
	local level="$1"
	shift
	local msg="$*"
	local logfile="/var/log/tcpx.log"
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}" >>"$logfile" 2>/dev/null
}

# 磁盘空间检查 (内核安装需要至少 500MB)
_check_disk_space() {
	local required_mb="${1:-500}"
	local available_mb
	available_mb=$(df /boot 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
	if [[ -z "$available_mb" ]]; then
		available_mb=$(df / | awk 'NR==2 {print int($4/1024)}')
	fi
	if [[ "$available_mb" -lt "$required_mb" ]]; then
		echo -e "${ERROR} 磁盘空间不足！"
		echo -e "  需要: ${required_mb}MB"
		echo -e "  可用: ${available_mb}MB (/boot 或 /)"
		echo -e "  建议: 清理旧内核 (菜单 [3]) 或扩容磁盘"
		return 1
	fi
	return 0
}

# 安全执行 sysctl (捕获错误参数)
_safe_sysctl_apply() {
	local conf_file="${1:-/etc/sysctl.d/99-sysctl.conf}"
	local errors=""
	errors=$(sysctl -p "$conf_file" 2>&1 | grep -i "error\|invalid\|cannot\|No such" || true)
	if [[ -n "$errors" ]]; then
		echo -e "${TIP} 部分 sysctl 参数应用时出现警告 (通常不影响使用):"
		echo "$errors" | head -5 | while read -r line; do
			echo -e "  ${YELLOW_FONT_PREFIX}→${FONT_COLOR_SUFFIX} $line"
		done
	fi
	sysctl --system >/dev/null 2>&1
}

# 检查当前用户是否为 root
if [[ "$EUID" -ne 0 ]]; then
	echo -e "${ERROR} 请使用 root 用户身份运行此脚本"
	exit 1
fi

# =================================================
#  系统检测模块
# =================================================
check_sys() {
	# 1. 检测架构
	OS_ARCH=$(uname -m)

	# 2. 系统信息获取 (安全解析 os-release，不直接 source)
	if [[ -f /etc/os-release ]]; then
		OS_ID=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
		OS_VERSION_ID=$(grep -E "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
		OS_VERSION_CODENAME=$(grep -E "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
		OS_ID="${OS_ID:-unknown}"

		# 兼容 Debian testing/sid 没有 VERSION_ID 的情况
		if [[ -z "$OS_VERSION_ID" && "$OS_ID" == "debian" && -f /etc/debian_version ]]; then
			OS_VERSION_ID=$(grep -oE '^[0-9]+' /etc/debian_version | head -n 1)
			[[ -z "$OS_VERSION_ID" ]] && OS_VERSION_ID=$(awk -F'/' '{print $1}' /etc/debian_version)
		fi
		[[ -z "$OS_VERSION_ID" ]] && OS_VERSION_ID="unknown"
	else
		echo -e "${ERROR} 无法检测到受支持的系统版本。仅支持 Debian/Ubuntu 系统。"
		exit 1
	fi

	# 3. 规范化 OS_TYPE
	case "${OS_ID}" in
	debian | ubuntu | pop)
		OS_TYPE="Debian"
		;;
	*)
		echo -e "${ERROR} 不支持的系统分支: ${OS_ID}。仅支持 Debian/Ubuntu 系统。"
		exit 1
		;;
	esac

	echo -e "${INFO} 检测到系统: ${OS_TYPE} (${OS_ID} ${OS_VERSION_ID}) - 架构: ${OS_ARCH}"

	# 4. 依赖检查与安装
	local required_cmds=("curl" "wget" "awk" "jq")
	local install_failed=0

	local need_update=0
	for cmd in "${required_cmds[@]}"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			if [[ $need_update -eq 0 ]]; then
				echo -e "${INFO} 正在更新包索引..."
				if ! apt-get update >/dev/null 2>&1; then
					echo -e "${TIP} apt-get update 出现警告 (可能不影响安装)"
				fi
				need_update=1
			fi
			echo -e "${INFO} 正在安装缺失依赖: $cmd ..."
			if ! apt-get install -y "$cmd" >/dev/null 2>&1; then
				echo -e "${ERROR} 依赖 $cmd 安装失败！"
				install_failed=1
			fi
		fi
	done

	if [[ $install_failed -eq 1 ]]; then
		echo -e "${ERROR} 部分依赖安装失败，脚本可能无法正常工作。"
		echo -e "${TIP} 请手动执行: apt-get update && apt-get install -y curl wget jq"
		echo -e "${TIP} 如果是网络问题，请先检查 DNS 和网络连接。"
	fi

	if ! dpkg-query -W ca-certificates >/dev/null 2>&1; then
		[[ $need_update -eq 0 ]] && apt-get update >/dev/null 2>&1
		apt-get install ca-certificates -y >/dev/null 2>&1
		update-ca-certificates >/dev/null 2>&1
	fi
}

# =================================================
#  网络通信与下载模块
# =================================================

# 全局变量：是否在中国大陆
IS_CN=0

check_cn_status() {
	local cf_trace
	cf_trace=$(curl -sL --max-time 3 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || echo "")
	if echo "$cf_trace" | grep -q "loc=CN"; then
		IS_CN=1
		echo -e "${INFO} 检测到当前节点位于中国大陆，将自动启用 GitHub 加速镜像。"
	else
		# 备用检测: 通过 IP 归属判断 (Cloudflare 不可达时)
		if [[ -z "$cf_trace" ]]; then
			local ip_info
			ip_info=$(curl -sL --max-time 3 https://ipinfo.io/country 2>/dev/null || echo "")
			if [[ "$ip_info" == "CN" ]]; then
				IS_CN=1
				echo -e "${INFO} 检测到当前节点位于中国大陆 (备用检测)。"
			else
				IS_CN=0
				echo -e "${INFO} 当前节点位于海外，使用 GitHub 直连网络。"
			fi
		else
			IS_CN=0
			echo -e "${INFO} 当前节点位于海外，使用 GitHub 直连网络。"
		fi
	fi
}

# 下载函数 (多镜像轮询 failover)
safe_wget() {
	local url="$1"
	local dest="$2"
	local timeout="${3:-15}"

	if [[ -z "$url" || -z "$dest" ]]; then
		echo -e "${ERROR} safe_wget: 参数不完整 (url='$url', dest='$dest')"
		return 1
	fi

	# 国内加速镜像列表 (格式: mirror_prefix + 完整原始URL)
	# 例: https://gh-proxy.com/https://github.com/user/repo/file.deb
	local mirrors=(
		""
		"https://gh-proxy.com/"
		"https://ghfast.top/"
		"https://gh.ddlc.top/"
	)

	[[ $IS_CN -eq 0 ]] && mirrors=("")

	for prefix in "${mirrors[@]}"; do
		local target_url
		if [[ -z "$prefix" ]]; then
			target_url="$url"
		else
			# 镜像格式: prefix + 完整原始 URL (包含 https://)
			target_url="${prefix}${url}"
		fi

		echo -e "${INFO} 正在下载: ${dest} ..."
		if wget --no-check-certificate -qT "$timeout" -t 2 -O "$dest" "$target_url"; then
			if [[ -s "$dest" ]]; then
				echo -e "${INFO} 下载成功！"
				return 0
			fi
			echo -e "${TIP} 下载的文件为空，尝试下一个节点..."
			rm -f "$dest"
		fi
		[[ $IS_CN -eq 1 ]] && echo -e "${TIP} 镜像节点下载失败，尝试切换下一个节点..."
	done

	echo -e "${ERROR} 文件 ${dest} 所有下载节点均失败，请检查网络或稍后再试！"
	return 1
}

# =================================================
# =================================================
#  系统级网络与资源自适应优化 (智能模式)
# =================================================

# 智能网络优化入口: 自动检测环境并选择最佳方案
optimizing_smart() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 智能网络优化 (自动检测环境)"
	echo -e "${INFO} ================================================"
	echo -e ""

	# 1. 先执行通用系统优化 (文件描述符、limits、systemd 等)
	echo -e "${INFO} [第一阶段] 通用系统资源优化..."
	echo -e "————————————————————————————————"
	optimizing_system

	echo -e ""
	echo -e "${INFO} [第二阶段] 网络环境自适应优化..."
	echo -e "————————————————————————————————"

	# 2. 根据 IS_CN 自动选择网络优化方案
	if [[ $IS_CN -eq 1 ]]; then
		echo -e "${INFO} 检测到中国大陆网络环境，自动应用跨境链路优化..."
		echo -e ""
		_optimize_cn_tcp_params
		echo -e ""
		echo -e "${TIP} 如需更换软件源，请手动执行菜单 [5]"
	else
		echo -e "${INFO} 检测到海外网络环境，自动应用高带宽低延迟优化..."
		echo -e ""
		_optimize_overseas_tcp_params
		echo -e ""
		echo -e "${TIP} 如需更换软件源，请手动执行菜单 [6]"
	fi

	echo -e ""
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 智能网络优化完成！"
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 已执行: 通用系统优化 + $([ $IS_CN -eq 1 ] && echo '中国大陆' || echo '海外')网络优化"
	echo -e "${TIP} 建议重启服务器使所有配置完全生效。"
}

optimizing_system() {
	echo -e "${INFO} 开始进行系统级网络优化 (自适应 CPU/内存/内核版本)..."

	# 1. 动态获取系统硬件与内核参数
	local total_mem_kb total_mem_mb cpu_cores kernel_major kernel_minor
	total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	total_mem_mb=$((total_mem_kb / 1024))
	cpu_cores=$(nproc)
	kernel_major=$(uname -r | cut -d. -f1)
	kernel_minor=$(uname -r | cut -d. -f2)

	# 动态获取当前拥塞控制算法，防止覆盖自定义算法
	local current_cc current_qdisc
	current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "bbr")
	current_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "fq")
	[[ "$current_cc" == "unknown" || -z "$current_cc" ]] && current_cc="bbr"
	[[ "$current_qdisc" == "unknown" || -z "$current_qdisc" ]] && current_qdisc="fq"

	# 2. 根据内存大小动态适配
	local tcp_mem_max somaxconn file_max
	if [[ "$total_mem_mb" -ge 8192 ]]; then
		tcp_mem_max=134217728
		somaxconn=1048576
		file_max=2097152
	elif [[ "$total_mem_mb" -ge 2048 ]]; then
		tcp_mem_max=67108864
		somaxconn=65535
		file_max=1048576
	else
		tcp_mem_max=16777216
		somaxconn=32768
		file_max=524288
	fi

	# 3. 根据 CPU 核心数动态适配
	local netdev_max_backlog netdev_budget
	netdev_max_backlog=$((10000 * cpu_cores))
	[[ $netdev_max_backlog -lt 32768 ]] && netdev_max_backlog=32768
	[[ $netdev_max_backlog -gt 100000 ]] && netdev_max_backlog=100000

	netdev_budget=$((300 + 20 * cpu_cores))
	[[ $netdev_budget -gt 50000 ]] && netdev_budget=50000

	# 4. 生成 sysctl 配置文件
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"

	[[ -f "$sysctl_conf" ]] && cp "$sysctl_conf" "${sysctl_conf}.bak.$(date +%Y%m%d%H%M%S)"

	cat >"$sysctl_conf" <<EOF
# === TCP加速脚本自适应优化 (生成时间: $(date '+%Y-%m-%d %H:%M:%S')) ===
# 系统: ${OS_TYPE} (${OS_ID} ${OS_VERSION_ID}) | 内存: ${total_mem_mb}MB | CPU: ${cpu_cores}核

# --- 文件系统与内存基础 ---
fs.file-max = $file_max
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = $file_max
kernel.pid_max = 65535
vm.swappiness = 1
vm.overcommit_memory = 1

# --- 网络核心队列与连接数 ---
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = $netdev_max_backlog
net.core.netdev_budget = $netdev_budget
net.core.rmem_max = $tcp_mem_max
net.core.wmem_max = $tcp_mem_max
net.core.rmem_default = $((tcp_mem_max / 2))
net.core.wmem_default = $((tcp_mem_max / 2))
net.core.optmem_max = 65536

# --- TCP 核心调优 ---
net.ipv4.tcp_rmem = 4096 87380 $tcp_mem_max
net.ipv4.tcp_wmem = 4096 65536 $tcp_mem_max
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = $somaxconn
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_frto = 0

# --- TCP 超时、重传与 KeepAlive ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 2
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3

# --- 路由转发与 IPv6 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.lo.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0

# --- 拥塞控制 (动态继承当前算法) ---
net.core.default_qdisc = $current_qdisc
net.ipv4.tcp_congestion_control = $current_cc
EOF

	# 5. 内核版本兼容处理
	if [[ "$kernel_major" -lt 4 || ("$kernel_major" -eq 4 && "$kernel_minor" -lt 12) ]]; then
		echo "net.ipv4.tcp_tw_recycle = 0" >>"$sysctl_conf"
	fi
	if [[ "$kernel_major" -lt 4 || ("$kernel_major" -eq 4 && "$kernel_minor" -lt 11) ]]; then
		echo "net.ipv4.tcp_fack = 1" >>"$sysctl_conf"
	fi

	# 6. 系统资源限制优化 (使用 drop-in 文件，不覆盖原有配置)
	echo -e "${INFO} 正在优化系统文件描述符限制..."

	# Systemd: 使用 drop-in 配置而非覆盖主文件
	if [[ -d "/etc/systemd" ]]; then
		mkdir -p /etc/systemd/system.conf.d
		cat >/etc/systemd/system.conf.d/99-tcp-optimize.conf <<EOF
[Manager]
DefaultTimeoutStopSec=30s
DefaultLimitCORE=infinity
DefaultLimitNOFILE=$file_max
DefaultLimitNPROC=infinity
DefaultTasksMax=infinity
EOF
		systemctl daemon-reload >/dev/null 2>&1
	fi

	# limits.conf: 使用 drop-in 文件
	mkdir -p /etc/security/limits.d
	cat >/etc/security/limits.d/99-tcp-optimize.conf <<EOF
* soft   nofile    $file_max
* hard   nofile    $file_max
* soft   nproc     unlimited
* hard   nproc     unlimited
* soft   core      unlimited
* hard   core      unlimited
root  soft   nofile    $file_max
root  hard   nofile    $file_max
root  soft   nproc     unlimited
root  hard   nproc     unlimited
root  soft   core      unlimited
root  hard   core      unlimited
EOF

	# 清理旧的 ulimit 注入并添加新的
	sed -i '/ulimit -SHn/d' /etc/profile
	sed -i '/ulimit -SHu/d' /etc/profile
	echo "ulimit -SHn $file_max" >>/etc/profile

	# Pam 会话限制
	if [[ -f "/etc/pam.d/common-session" ]] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
		echo "session required pam_limits.so" >>/etc/pam.d/common-session
	fi

	# 7. 应用配置
	echo -e "${INFO} 正在应用自适应内核配置..."
	_safe_sysctl_apply "$sysctl_conf"

	# THP: 提示用户而非强制开启 (对 Redis/MongoDB 等可能有负面影响)
	if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
		local thp_current
		thp_current=$(cat /sys/kernel/mm/transparent_hugepage/enabled | grep -o '\[.*\]' | tr -d '[]')
		if [[ "$thp_current" != "always" ]]; then
			echo -e "${TIP} 透明大页(THP)当前状态: ${thp_current}。如需开启请手动执行:"
			echo -e "     echo always > /sys/kernel/mm/transparent_hugepage/enabled"
			echo -e "     注意: 运行 Redis/MongoDB 等数据库时建议保持 madvise 或 never"
		fi
	fi

	echo -e "${INFO} 系统网络与资源限制自适应优化完成！(建议重启服务器以全面生效)"
}

# =================================================
#  中国大陆网络专项优化模块
# =================================================
#
# 针对中国大陆服务器的特殊网络环境进行优化:
# 1. 高延迟跨境链路 TCP 调参 (中国 ↔ 海外 RTT 通常 150-300ms)
# 2. 系统软件源替换为国内镜像 (加速 apt)
# 3. TCP 窗口与重传策略针对高丢包环境优化
# 4. MTU/MSS 探测优化 (应对中间设备)
#

# 替换 APT 源 (通用执行函数)
_apply_apt_mirror() {
	local mirror_url="$1"

	local sources_file="/etc/apt/sources.list"
	if [[ -f "$sources_file" ]]; then
		cp "$sources_file" "${sources_file}.bak.$(date +%Y%m%d%H%M%S)"
		echo -e "${INFO} 已备份原始源到 ${sources_file}.bak.*"
	fi

	# Ubuntu 24.04+ 使用 DEB822 格式 (.sources)，需要禁用以避免重复源
	if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
		mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.disabled
		echo -e "${INFO} 已禁用 DEB822 格式源: ubuntu.sources → ubuntu.sources.disabled"
	fi

	local codename="${OS_VERSION_CODENAME}"
	if [[ -z "$codename" ]]; then
		if [[ "$OS_ID" == "debian" ]]; then
			case "$OS_VERSION_ID" in
			10) codename="buster" ;; 11) codename="bullseye" ;;
			12) codename="bookworm" ;; 13) codename="trixie" ;;
			esac
		elif [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "pop" ]]; then
			case "$OS_VERSION_ID" in
			20.04) codename="focal" ;; 22.04) codename="jammy" ;;
			24.04) codename="noble" ;; 24.10) codename="oracular" ;;
			25.04) codename="plucky" ;; 26.04) codename="resolute" ;;
			esac
		fi
	fi

	if [[ -z "$codename" ]]; then
		echo -e "${ERROR} 无法确定系统代号，换源失败。"
		return 1
	fi

	if [[ "$OS_ID" == "debian" ]]; then
		local components="main contrib non-free"
		[[ "${OS_VERSION_ID}" -ge 12 ]] 2>/dev/null && components="main contrib non-free non-free-firmware"

		local security_suite="${codename}-security"
		[[ "${OS_VERSION_ID}" == "10" ]] && security_suite="${codename}/updates"

		# security 源: 优先镜像，不可用时尝试官方，都不行则跳过
		local security_mirror="${mirror_url}"
		local security_line=""
		local sec_test_url="https://${mirror_url}/debian-security/dists/${security_suite}/Release"
		if curl -sL --max-time 5 -o /dev/null -w "%{http_code}" "$sec_test_url" 2>/dev/null | grep -q "200"; then
			security_line="deb https://${security_mirror}/debian-security/ ${security_suite} ${components}"
		else
			local official_sec="https://deb.debian.org/debian-security/dists/${security_suite}/Release"
			if curl -sL --max-time 5 -o /dev/null -w "%{http_code}" "$official_sec" 2>/dev/null | grep -q "200"; then
				security_line="deb https://deb.debian.org/debian-security/ ${security_suite} ${components}"
				echo -e "${TIP} 镜像无 debian-security，使用官方源。"
			else
				echo -e "${TIP} security 源均不可达，暂时跳过。"
			fi
		fi

		# 生成 sources.list
		cat >"$sources_file" <<EOF
# Debian ${codename} - Mirror: ${mirror_url}
deb https://${mirror_url}/debian/ ${codename} ${components}
deb https://${mirror_url}/debian/ ${codename}-updates ${components}
${security_line}
EOF

		# backports 仅对当前支持的版本添加 (EOL 版本的 backports 已被移除)
		if [[ "${OS_VERSION_ID}" -ge 12 ]] 2>/dev/null; then
			echo "deb https://${mirror_url}/debian/ ${codename}-backports ${components}" >>"$sources_file"
		fi
	elif [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "pop" ]]; then
		cat >"$sources_file" <<EOF
# Ubuntu ${codename} - Mirror: ${mirror_url}
deb https://${mirror_url}/ubuntu/ ${codename} main restricted universe multiverse
deb https://${mirror_url}/ubuntu/ ${codename}-updates main restricted universe multiverse
deb https://${mirror_url}/ubuntu/ ${codename}-backports main restricted universe multiverse
deb https://${mirror_url}/ubuntu/ ${codename}-security main restricted universe multiverse
EOF
	fi

	echo -e "${INFO} 源已替换为: ${GREEN_FONT_PREFIX}${mirror_url}${FONT_COLOR_SUFFIX}"
	echo -e "${INFO} 正在验证新源是否可用..."
	if ! apt-get update 2>&1 | tail -5; then
		echo -e "${ERROR} 新源验证失败！正在恢复备份..."
		# 恢复备份
		local latest_bak
		latest_bak=$(ls -t "${sources_file}.bak."* 2>/dev/null | head -1)
		if [[ -n "$latest_bak" ]]; then
			cp "$latest_bak" "$sources_file"
			apt-get update >/dev/null 2>&1
			echo -e "${INFO} 已恢复到之前的源配置。"
		fi
		echo -e "${TIP} 可能原因: 镜像源不完整或网络不通"
		return 1
	fi
	echo -e "${INFO} 换源完成！"
	_log "INFO" "APT mirror changed to: ${mirror_url}"
}


# 针对中国大陆高延迟/高丢包链路的 TCP 专项优化
_optimize_cn_tcp_params() {
	echo -e "${INFO} 正在应用中国大陆跨境链路 TCP 优化..."

	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	[[ ! -f "$sysctl_conf" ]] && touch "$sysctl_conf"

	# 获取内存信息用于动态调参
	local total_mem_mb
	total_mem_mb=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024))

	# 针对高 RTT (150-300ms) 跨境链路的缓冲区计算
	# BDP = 带宽 × RTT，假设 1Gbps 链路 × 200ms RTT = 25MB
	local tcp_mem_max
	if [[ "$total_mem_mb" -ge 8192 ]]; then
		tcp_mem_max=268435456  # 256MB (高配机器，充分利用带宽)
	elif [[ "$total_mem_mb" -ge 4096 ]]; then
		tcp_mem_max=134217728  # 128MB
	elif [[ "$total_mem_mb" -ge 2048 ]]; then
		tcp_mem_max=67108864   # 64MB
	else
		tcp_mem_max=33554432   # 32MB (小内存也要比默认大)
	fi

	# 移除旧的 CN 优化标记段
	sed -i '/# --- 中国大陆跨境链路优化/,/# --- END 中国大陆优化/d' "$sysctl_conf" 2>/dev/null

	cat >>"$sysctl_conf" <<EOF

# --- 中国大陆跨境链路优化 (高RTT/高丢包环境) ---
# 适用场景: 中国大陆服务器与海外通信 (RTT 150-300ms)

# TCP 窗口放大 (高 BDP 链路必须)
net.core.rmem_max = $tcp_mem_max
net.core.wmem_max = $tcp_mem_max
net.ipv4.tcp_rmem = 4096 131072 $tcp_mem_max
net.ipv4.tcp_wmem = 4096 65536 $tcp_mem_max

# 禁用慢启动重启 (长连接在空闲后不重置窗口)
net.ipv4.tcp_slow_start_after_idle = 0

# MTU 探测 (应对中间设备 MTU 黑洞)
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# 重传优化 (高丢包环境减少不必要的超时)
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

# 关闭 ECN (国内部分中间设备不支持，会导致连接异常)
net.ipv4.tcp_ecn = 0

# 启用 TCP Fast Open (减少握手 RTT)
net.ipv4.tcp_fastopen = 3

# 时间戳与 SACK (高延迟环境必须保持开启)
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1

# 连接复用 (减少 TIME_WAIT 占用)
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 55000
net.ipv4.ip_local_port_range = 1024 65535

# KeepAlive 优化 (跨境长连接保活)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# 禁用 autocorking (减少小包延迟)
net.ipv4.tcp_autocorking = 0

# notsent_lowat (减少发送缓冲区延迟)
net.ipv4.tcp_notsent_lowat = 16384

# 连接队列 (应对突发连接)
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535

# --- END 中国大陆优化 ---
EOF

	_safe_sysctl_apply "$sysctl_conf"
	echo -e "${INFO} 中国大陆 TCP 链路优化参数已应用！"
}

# 镜像测速通用函数 (并行下载测实际带宽)
# 用法: _speedtest_mirrors <mirror_names_array_name> <mirror_urls_array_name> <codename>
# 结果通过全局变量 _SELECTED_MIRROR 返回
_speedtest_mirrors() {
	local -n _names=$1
	local -n _urls=$2
	local codename="$3"
	local timeout=10  # 单个镜像最大测试时间(秒)

	# 测速文件: Contents-amd64.gz (~11MB)，所有镜像都有
	local test_file="/debian/dists/${codename}/main/Contents-amd64.gz"
	[[ "$OS_ID" == "ubuntu" || "$OS_ID" == "pop" ]] && test_file="/ubuntu/dists/${codename}/main/Contents-amd64.gz"

	echo -e "${INFO} 正在测试各镜像源的下载速度，请稍候..."
	echo -e "${TIP} 每个镜像最多测试 ${timeout} 秒，所有镜像并行测试"
	echo -e ""

	# 创建临时目录存放测速结果
	local tmp_dir="/tmp/mirror_speedtest_$$"
	mkdir -p "$tmp_dir"

	# 并行启动所有测速任务
	for i in "${!_urls[@]}"; do
		local url="https://${_urls[$i]}${test_file}"
		(
			local result
			result=$(curl -sL --max-time "$timeout" -o /dev/null -w "%{speed_download} %{size_download}" "$url" 2>/dev/null || echo "0 0")
			echo "$result" > "${tmp_dir}/result_${i}"
		) &
	done

	# 等待所有后台任务完成
	wait

	# 收集结果并显示
	local best_idx=0
	local best_speed=0

	for i in "${!_urls[@]}"; do
		local speed_bytes=0 size_bytes=0
		if [[ -f "${tmp_dir}/result_${i}" ]]; then
			local result
			result=$(cat "${tmp_dir}/result_${i}")
			speed_bytes=$(echo "$result" | awk '{printf "%d", $1}')
			size_bytes=$(echo "$result" | awk '{printf "%d", $2}')
		fi

		local speed_mbps="0"
		local downloaded_mb="0"
		if [[ "$speed_bytes" -gt 0 ]]; then
			speed_mbps=$(echo "$speed_bytes" | awk '{printf "%.1f", $1/1024/1024}')
		fi
		if [[ "$size_bytes" -gt 0 ]]; then
			downloaded_mb=$(echo "$size_bytes" | awk '{printf "%.1f", $1/1024/1024}')
		fi

		if [[ "$speed_bytes" -gt 1000 ]]; then
			printf "  ${GREEN_FONT_PREFIX}%-12s${FONT_COLOR_SUFFIX} %-35s ${GREEN_FONT_PREFIX}%s MB/s${FONT_COLOR_SUFFIX} (已下载 %sMB)\n" \
				"${_names[$i]}" "${_urls[$i]}" "$speed_mbps" "$downloaded_mb"
		else
			printf "  ${RED_FONT_PREFIX}%-12s${FONT_COLOR_SUFFIX} %-35s 连接超时\n" "${_names[$i]}" "${_urls[$i]}"
		fi

		if [[ "$speed_bytes" -gt "$best_speed" ]]; then
			best_speed=$speed_bytes
			best_idx=$i
		fi
	done

	# 清理临时文件
	rm -rf "$tmp_dir"

	echo -e ""
	if [[ "$best_speed" -le 1000 ]]; then
		echo -e "${ERROR} 所有镜像源均无法连接，请检查网络后重试。"
		_SELECTED_MIRROR=""
		return 1
	fi

	local best_mbps
	best_mbps=$(echo "$best_speed" | awk '{printf "%.1f", $1/1024/1024}')
	echo -e "${INFO} 测速完成！推荐使用: ${GREEN_FONT_PREFIX}${_names[$best_idx]}${FONT_COLOR_SUFFIX} (${_urls[$best_idx]}) - ${best_mbps} MB/s"
	echo -e ""

	# 非交互模式自动选择最快镜像
	if ! _is_interactive; then
		_SELECTED_MIRROR="${_urls[$best_idx]}"
		echo -e "${INFO} 非交互模式，自动选择最快镜像。"
		return 0
	fi

	echo -e "  1) 使用推荐镜像: ${_names[$best_idx]}"
	echo -e "  2) 手动选择其他镜像"
	echo -e "  0) 取消操作"
	read -p "请选择 [默认1]: " choice
	choice=${choice:-1}

	case "$choice" in
	1) _SELECTED_MIRROR="${_urls[$best_idx]}" ;;
	2)
		echo -e ""
		for i in "${!_names[@]}"; do
			echo -e "  $((i+1))) ${_names[$i]} (${_urls[$i]})"
		done
		read -p "请输入编号 [1-${#_names[@]}]: " manual_choice
		manual_choice=$((manual_choice - 1))
		if [[ "$manual_choice" -ge 0 && "$manual_choice" -lt ${#_urls[@]} ]]; then
			_SELECTED_MIRROR="${_urls[$manual_choice]}"
		else
			echo -e "${ERROR} 输入无效，操作已取消。"
			return 1
		fi
		;;
	0) echo -e "${INFO} 操作已取消。"; return 1 ;;
	*) _SELECTED_MIRROR="${_urls[$best_idx]}" ;;
	esac

	echo -e "${INFO} 已选择镜像: ${_SELECTED_MIRROR}"
	return 0
}


# 中国大陆网络综合优化 (主入口)
optimizing_cn_network() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 中国大陆换源 (自动测速选择最快镜像)"
	echo -e "${INFO} ================================================"
	echo -e ""

	# 国内镜像列表
	local -a mirror_names=("阿里云" "腾讯云" "华为云" "中科大" "清华大学")
	local -a mirror_urls=("mirrors.aliyun.com" "mirrors.tencent.com" "repo.huaweicloud.com" "mirrors.ustc.edu.cn" "mirrors.tuna.tsinghua.edu.cn")

	# 获取当前系统代号用于测速
	local codename="${OS_VERSION_CODENAME:-bookworm}"
	[[ -z "$codename" ]] && codename="bookworm"

	# 测速并选择
	_SELECTED_MIRROR=""
	if ! _speedtest_mirrors mirror_names mirror_urls "$codename"; then
		return 1
	fi

	# 执行换源
	_apply_apt_mirror "$_SELECTED_MIRROR"
}


# 海外高带宽低延迟 TCP 优化
_optimize_overseas_tcp_params() {
	echo -e "${INFO} 正在应用海外服务器 TCP 优化..."

	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	[[ ! -f "$sysctl_conf" ]] && touch "$sysctl_conf"

	local total_mem_mb
	total_mem_mb=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024))
	local cpu_cores
	cpu_cores=$(nproc)

	# 海外服务器通常带宽充足，RTT 较低 (1-50ms 同区域, 50-150ms 跨区域)
	# 缓冲区按 10Gbps × 50ms RTT = 62.5MB 计算
	local tcp_mem_max
	if [[ "$total_mem_mb" -ge 16384 ]]; then
		tcp_mem_max=536870912   # 512MB (高配大带宽)
	elif [[ "$total_mem_mb" -ge 8192 ]]; then
		tcp_mem_max=268435456   # 256MB
	elif [[ "$total_mem_mb" -ge 4096 ]]; then
		tcp_mem_max=134217728   # 128MB
	elif [[ "$total_mem_mb" -ge 2048 ]]; then
		tcp_mem_max=67108864    # 64MB
	else
		tcp_mem_max=33554432    # 32MB
	fi

	local netdev_max_backlog=$((16384 * cpu_cores))
	[[ $netdev_max_backlog -gt 262144 ]] && netdev_max_backlog=262144

	# 移除旧的海外优化标记段
	sed -i '/# --- 海外服务器网络优化/,/# --- END 海外优化/d' "$sysctl_conf" 2>/dev/null

	cat >>"$sysctl_conf" <<EOF

# --- 海外服务器网络优化 (低延迟/高带宽环境) ---
# 适用场景: 海外 VPS/独服 (同区域 RTT <50ms, 跨区域 50-150ms)

# TCP 缓冲区 (大带宽充分利用)
net.core.rmem_max = $tcp_mem_max
net.core.wmem_max = $tcp_mem_max
net.core.rmem_default = $((tcp_mem_max / 4))
net.core.wmem_default = $((tcp_mem_max / 4))
net.ipv4.tcp_rmem = 4096 131072 $tcp_mem_max
net.ipv4.tcp_wmem = 4096 87380 $tcp_mem_max

# 网卡队列 (高吞吐)
net.core.netdev_max_backlog = $netdev_max_backlog
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# 低延迟优化
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1

# ECN (海外网络普遍支持)
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# TCP Fast Open
net.ipv4.tcp_fastopen = 3

# 时间戳与 SACK
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1

# 重传 (低丢包环境可以更激进)
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_frto = 0

# 连接管理
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.ip_local_port_range = 1024 65535

# KeepAlive (海外低延迟可以更频繁探测)
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

# 路由转发
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# --- END 海外优化 ---
EOF

	_safe_sysctl_apply "$sysctl_conf"
	echo -e "${INFO} 海外服务器 TCP 优化参数已应用！"
}

# 海外服务器网络综合优化 (主入口)
optimizing_overseas_network() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 海外服务器换源 (自动测速选择最快镜像)"
	echo -e "${INFO} ================================================"
	echo -e ""

	# 海外镜像列表
	local -a mirror_names mirror_urls

	if [[ "$OS_ID" == "debian" ]]; then
		mirror_names=("Debian官方" "Fastly CDN" "Cloudflare" "MIT" "Kernel.org")
		mirror_urls=("deb.debian.org" "fastly.cdn.debian.net" "cloudflaremirrors.com" "mirrors.mit.edu" "mirrors.kernel.org")
	elif [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "pop" ]]; then
		mirror_names=("Ubuntu官方" "Kernel.org" "MIT" "xTom" "DigitalOcean")
		mirror_urls=("archive.ubuntu.com" "mirrors.kernel.org" "mirrors.mit.edu" "mirrors.xtom.com" "mirrors.digitalocean.com")
	fi

	# 获取当前系统代号用于测速
	local codename="${OS_VERSION_CODENAME:-bookworm}"
	[[ -z "$codename" ]] && codename="bookworm"

	# 测速并选择
	_SELECTED_MIRROR=""
	if ! _speedtest_mirrors mirror_names mirror_urls "$codename"; then
		return 1
	fi

	# 执行换源
	_apply_apt_mirror "$_SELECTED_MIRROR"
}


# =================================================
#  网络加速统一切换引擎
# =================================================

remove_bbr_lotserver() {
	echo -e "${INFO} 正在清理旧的拥塞控制与队列算法配置..."
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	[[ -f "$sysctl_conf" ]] && sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d; /net.ipv4.tcp_ecn/d' "$sysctl_conf"
	[[ -f "/etc/sysctl.conf" ]] && sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d; /net.ipv4.tcp_ecn/d' /etc/sysctl.conf

	sysctl --system >/dev/null 2>&1
	rm -rf bbrmod

	if command -v lotspeed >/dev/null 2>&1; then
		lotspeed stop >/dev/null 2>&1
		rmmod lotspeed >/dev/null 2>&1
	fi
	if lsmod | grep -q "lotspeed"; then
		rmmod lotspeed >/dev/null 2>&1
	fi

	if [[ -e /appex/bin/lotServer.sh ]]; then
		echo | bash <(wget -qO- https://raw.githubusercontent.com/fei5seven/lotServer/master/lotServerInstall.sh) uninstall >/dev/null 2>&1
	fi
}

# 统一加速开启函数
enable_acceleration() {
	local qdisc="$1"
	local cc="$2"

	# 加载拥塞控制模块 (某些内核默认不加载 bbr)
	modprobe tcp_${cc} 2>/dev/null

	# 验证拥塞控制算法是否可用
	local available_cc
	available_cc=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
	if [[ -n "$available_cc" ]] && ! echo "$available_cc" | grep -qw "$cc"; then
		echo -e "${ERROR} 拥塞控制算法 '${cc}' 在当前内核中不可用！"
		echo -e "${INFO} 当前可用算法: ${available_cc}"
		echo -e "${TIP} 可能需要先安装支持该算法的内核 (如 BBRplus 需要专用内核)。"
		return 1
	fi

	remove_bbr_lotserver

	echo -e "${INFO} 正在应用: ${cc} + ${qdisc} ..."
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	[[ ! -f "$sysctl_conf" ]] && touch "$sysctl_conf"
	echo "net.core.default_qdisc=$qdisc" >>"$sysctl_conf"
	echo "net.ipv4.tcp_congestion_control=$cc" >>"$sysctl_conf"

	_safe_sysctl_apply "$sysctl_conf"

	# 验证是否生效
	local actual_cc
	actual_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "unknown")
	if [[ "$actual_cc" == "$cc" ]]; then
		echo -e "${INFO} 加速算法切换成功！当前: ${GREEN_FONT_PREFIX}${actual_cc}${FONT_COLOR_SUFFIX}"
	else
		echo -e "${TIP} 算法已写入配置，但当前未立即生效 (当前: ${actual_cc})。"
		echo -e "${TIP} 请重启服务器使配置完全生效。"
	fi
	_log "INFO" "Acceleration set: ${cc} + ${qdisc}"
}


# =================================================
#  系统引导与内核管理引擎
# =================================================

BBR_grub() {
	echo -e "${INFO} 正在更新系统引导..."
	if command -v update-grub >/dev/null 2>&1; then
		if ! update-grub 2>&1 | grep -v "^$"; then
			echo -e "${TIP} update-grub 执行完成 (部分警告可忽略)"
		fi
	else
		echo -e "${INFO} update-grub 未找到，正在安装..."
		if apt-get install -y grub2-common >/dev/null 2>&1; then
			update-grub >/dev/null 2>&1
		else
			echo -e "${TIP} grub2-common 安装失败。"
			echo -e "${TIP} 如果使用 GRUB 引导，请手动执行: update-grub"
			echo -e "${TIP} 如果使用 systemd-boot，请手动更新引导配置。"
		fi
	fi
}


delete_kernel_custom() {
	clear
	echo -e "${INFO} ==================================================="
	echo -e "${INFO} 正在扫描系统中已安装的内核包..."
	local current_kernel
	current_kernel=$(uname -r)
	local kernel_list=()

	mapfile -t kernel_list < <(dpkg-query -W -f='${Package}\n' | grep -E "^linux-(image|headers|modules)" | sort -V)

	if [[ ${#kernel_list[@]} -eq 0 ]]; then
		echo -e "${ERROR} 未检测到可管理的内核包。"
		sleep 2
		start_menu
		return
	fi

	echo -e "${TIP} 当前正在运行的内核: ${GREEN_FONT_PREFIX}${current_kernel}${FONT_COLOR_SUFFIX}"
	echo -e "${INFO} ==================================================="

	for i in "${!kernel_list[@]}"; do
		local pkg="${kernel_list[$i]}"
		if [[ "$pkg" == *"$current_kernel"* ]]; then
			echo -e "  ${GREEN_FONT_PREFIX}[$i] ${pkg} [*当前运行中*]${FONT_COLOR_SUFFIX}"
		else
			echo -e "  [$i] ${pkg}"
		fi
	done
	echo -e "${INFO} ==================================================="
	echo -e "${TIP} 提示: 排序后默认从最高版本内核启动！"
	echo ""
	read -p "请输入要【删除】的内核编号 (多选请用空格分隔，例如 '0 2 3'，直接回车取消): " del_choices

	if [[ -z "$del_choices" ]]; then
		echo -e "${INFO} 已取消操作，返回主菜单。"
		sleep 2
		start_menu
		return
	fi

	local pkgs_to_del=""
	local is_del_current=0
	for idx in $del_choices; do
		if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 0 ]] && [[ "$idx" -lt ${#kernel_list[@]} ]]; then
			local selected_pkg="${kernel_list[$idx]}"
			pkgs_to_del="$pkgs_to_del $selected_pkg"
			if [[ "$selected_pkg" == *"$current_kernel"* ]]; then
				is_del_current=1
			fi
		else
			echo -e "${TIP} 无效的编号: $idx，已忽略。"
		fi
	done

	if [[ -z "$pkgs_to_del" ]]; then
		echo -e "${INFO} 没有选择有效的内核，操作结束。"
		sleep 2
		start_menu
		return
	fi

	echo -e "${TIP} 即将从系统中彻底卸载以下内核包:"
	echo -e "${RED_FONT_PREFIX}${pkgs_to_del}${FONT_COLOR_SUFFIX}"

	if [[ $is_del_current -eq 1 ]]; then
		echo ""
		echo -e "${ERROR} 高危警告！您选择了删除【当前正在运行的内核】！"
		echo -e "${TIP} 请务必确保系统中还有【至少一个其他已正常安装的内核】！"
		read -p "确定继续？(请输入大写 YES 确认): " confirm_danger
		if [[ "$confirm_danger" != "YES" ]]; then
			echo -e "${INFO} 操作已取消。"
			sleep 2
			start_menu
			return
		fi
	else
		read -p "请确认是否卸载？(回车确认, n取消): " confirm
		if [[ "$confirm" =~ ^[nN]$ ]]; then
			echo -e "${INFO} 操作已取消。"
			sleep 2
			start_menu
			return
		fi
	fi

	echo -e "${INFO} 正在执行卸载..."
	apt-get purge -y $pkgs_to_del
	apt-get autoremove -y >/dev/null 2>&1

	BBR_grub
	echo -e "${INFO} 指定内核卸载完毕！引导项已自动更新。"
	sleep 2
	start_menu
}


# =================================================
#  腾讯云 NFT 转发优化
# =================================================
optimizing_nft_forward() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 腾讯云 NFT 转发优化"
	echo -e "${INFO} ================================================"
	echo -e ""
	echo -e "${INFO} 适用场景: 纯 nftables/iptables 四层转发机 (DNAT+SNAT)"
	echo -e "${INFO} 典型用途: 前置机将 AnyTLS/TLS 流量转发给国内入口"
	echo -e ""
	echo -e "${INFO} 将优化以下内容:"
	echo -e "  • conntrack 表大小与超时 (核心)"
	echo -e "  • 网卡队列与软中断处理"
	echo -e "  • SNAT 端口范围与复用"
	echo -e "  • 转发路径缓冲区"
	echo -e "  • 关闭 ECN (国内中间设备兼容)"
	echo -e ""

	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	[[ ! -f "$sysctl_conf" ]] && touch "$sysctl_conf"

	# 获取系统信息用于动态计算
	local total_mem_mb
	total_mem_mb=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024))
	local cpu_cores
	cpu_cores=$(nproc)

	# conntrack_max 根据内存动态计算 (每条约 300 字节)
	local conntrack_max
	if [[ "$total_mem_mb" -ge 4096 ]]; then
		conntrack_max=524288
	elif [[ "$total_mem_mb" -ge 2048 ]]; then
		conntrack_max=262144
	elif [[ "$total_mem_mb" -ge 1024 ]]; then
		conntrack_max=131072
	else
		conntrack_max=65536
	fi
	local conntrack_buckets=$((conntrack_max / 4))

	# 网卡队列根据 CPU 核心数
	local netdev_backlog=$((16384 * cpu_cores))
	[[ $netdev_backlog -gt 262144 ]] && netdev_backlog=262144
	local netdev_budget=$((300 + 50 * cpu_cores))
	[[ $netdev_budget -gt 2000 ]] && netdev_budget=2000

	echo -e "${INFO} 系统信息: 内存 ${total_mem_mb}MB / CPU ${cpu_cores}核"
	echo -e "${INFO} conntrack_max: ${conntrack_max} / buckets: ${conntrack_buckets}"
	echo -e ""

	# 确保 conntrack 模块已加载
	modprobe nf_conntrack 2>/dev/null
	if ! lsmod | grep -q nf_conntrack; then
		echo -e "${TIP} nf_conntrack 模块未加载，尝试加载..."
		modprobe nf_conntrack 2>/dev/null || true
	fi

	# 设置 hashsize (需要在 sysctl 之前)
	if [[ -f /sys/module/nf_conntrack/parameters/hashsize ]]; then
		echo "$conntrack_buckets" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
		echo -e "${INFO} conntrack hashsize 已设置为 ${conntrack_buckets}"
	fi

	# 持久化 hashsize (开机自动加载)
	mkdir -p /etc/modprobe.d
	echo "options nf_conntrack hashsize=${conntrack_buckets}" > /etc/modprobe.d/nf_conntrack.conf

	# 移除旧的 NFT 优化标记段
	sed -i '/# --- 腾讯云 NFT 转发优化/,/# --- END NFT 转发优化/d' "$sysctl_conf" 2>/dev/null

	cat >>"$sysctl_conf" <<EOF

# --- 腾讯云 NFT 转发优化 (纯四层转发/DNAT+SNAT) ---
# 内存: ${total_mem_mb}MB | CPU: ${cpu_cores}核

# conntrack 核心参数
net.netfilter.nf_conntrack_max = ${conntrack_max}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 15
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120

# 转发开关
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1

# 网卡队列与软中断 (高 PPS 场景)
net.core.netdev_max_backlog = ${netdev_backlog}
net.core.netdev_budget = ${netdev_budget}
net.core.netdev_budget_usecs = 8000

# 转发路径缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# SNAT 端口范围与复用
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 65535
net.ipv4.tcp_timestamps = 1

# 关闭 ECN (国内中间设备兼容)
net.ipv4.tcp_ecn = 0

# 关闭 rp_filter (避免非对称路由丢包)
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# 关闭 ICMP 重定向 (转发机不需要)
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# --- END NFT 转发优化 ---
EOF

	_safe_sysctl_apply "$sysctl_conf"

	echo -e ""
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 腾讯云 NFT 转发优化完成！"
	echo -e "${INFO} ================================================"
	echo -e ""
	echo -e "${INFO} 已应用:"
	echo -e "  • conntrack_max = ${conntrack_max}"
	echo -e "  • established 超时 = 7200s (适配 AnyTLS 长连接)"
	echo -e "  • TIME_WAIT 超时 = 30s (快速回收)"
	echo -e "  • 网卡队列 = ${netdev_backlog}"
	echo -e "  • SNAT 端口 = 1024-65535"
	echo -e "  • ECN = 关闭"
	echo -e "  • rp_filter = 关闭"
	echo -e ""
	echo -e "${TIP} 如果 conntrack 表满会导致丢包，可通过以下命令监控:"
	echo -e "     conntrack -C    # 当前条目数"
	echo -e "     cat /proc/sys/net/netfilter/nf_conntrack_max  # 最大值"
	echo -e "     dmesg | grep conntrack  # 查看是否有 table full 日志"
	_log "INFO" "NFT forward optimization applied: conntrack_max=${conntrack_max}"
}

# =================================================
#  系统大版本升级
# =================================================

# 升级前测速选择最快镜像
_upgrade_select_mirror() {
	local target_codename="$1"

	local -a mirror_names mirror_urls

	if [[ $IS_CN -eq 1 ]]; then
		mirror_names=("阿里云" "腾讯云" "华为云" "中科大" "清华大学")
		mirror_urls=("mirrors.aliyun.com" "mirrors.tencent.com" "repo.huaweicloud.com" "mirrors.ustc.edu.cn" "mirrors.tuna.tsinghua.edu.cn")
	else
		if [[ "$OS_ID" == "debian" ]]; then
			mirror_names=("Debian官方" "Fastly CDN" "Cloudflare" "MIT" "Kernel.org")
			mirror_urls=("deb.debian.org" "fastly.cdn.debian.net" "cloudflaremirrors.com" "mirrors.mit.edu" "mirrors.kernel.org")
		else
			mirror_names=("Ubuntu官方" "Kernel.org" "MIT" "xTom" "DigitalOcean")
			mirror_urls=("archive.ubuntu.com" "mirrors.kernel.org" "mirrors.mit.edu" "mirrors.xtom.com" "mirrors.digitalocean.com")
		fi
	fi

	_speedtest_mirrors mirror_names mirror_urls "$target_codename"
}

upgrade_system_version() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 系统大版本升级"
	echo -e "${INFO} ================================================"
	echo -e ""

	# 检测当前版本和目标版本
	local current_codename="${OS_VERSION_CODENAME}"
	local target_codename=""
	local target_version=""

	if [[ "$OS_ID" == "debian" ]]; then
		case "$OS_VERSION_ID" in
		10)
			target_codename="bullseye"; target_version="11"
			echo -e "${INFO} 当前: Debian 10 (buster)"
			echo -e "${INFO} 目标: Debian 11 (bullseye) → 之后可继续升级到 12/13"
			;;
		11)
			target_codename="bookworm"; target_version="12"
			echo -e "${INFO} 当前: Debian 11 (bullseye)"
			echo -e "${INFO} 目标: Debian 12 (bookworm) [XanMod LTS 可用]"
			;;
		12)
			target_codename="trixie"; target_version="13"
			echo -e "${INFO} 当前: Debian 12 (bookworm)"
			echo -e "${INFO} 目标: Debian 13 (trixie) [XanMod 全部分支可用]"
			;;
		13)
			echo -e "${INFO} 当前已是 Debian 13 (trixie)，无需升级。"
			return 0
			;;
		*)
			echo -e "${ERROR} 无法确定升级路径。"
			return 1
			;;
		esac
	elif [[ "$OS_ID" == "ubuntu" ]]; then
		case "$OS_VERSION_ID" in
		20.04)
			target_codename="jammy"; target_version="22.04"
			echo -e "${INFO} 当前: Ubuntu 20.04 (focal)"
			echo -e "${INFO} 目标: Ubuntu 22.04 (jammy) → 之后可继续升级到 24.04"
			;;
		22.04)
			target_codename="noble"; target_version="24.04"
			echo -e "${INFO} 当前: Ubuntu 22.04 (jammy)"
			echo -e "${INFO} 目标: Ubuntu 24.04 (noble) [XanMod 全部分支可用]"
			;;
		24.04)
			echo -e "${INFO} 当前已是 Ubuntu 24.04 (noble)，XanMod 已完全支持。"
			return 0
			;;
		*)
			echo -e "${INFO} 当前版本 ${OS_VERSION_ID}，无需升级或不在升级路径中。"
			return 0
			;;
		esac
	fi

	echo -e ""
	echo -e "${TIP} =============================================="
	echo -e "${TIP} 系统大版本升级是高风险操作！"
	echo -e "${TIP} • 升级过程中 SSH 可能断开"
	echo -e "${TIP} • 升级后部分软件配置可能需要调整"
	echo -e "${TIP} • 强烈建议先做好数据备份/快照"
	echo -e "${TIP} • 升级完成后需要重启"
	echo -e "${TIP} =============================================="
	echo -e ""
	local confirm=""
	if _is_interactive; then
		read -p "确认要升级吗？(输入大写 YES 确认): " confirm
	else
		confirm="YES"
	fi
	[[ "$confirm" != "YES" ]] && { echo -e "${INFO} 已取消。"; return 0; }

	# 测速选择最快镜像
	echo -e ""
	_SELECTED_MIRROR=""
	if ! _upgrade_select_mirror "$target_codename"; then
		echo -e "${ERROR} 无法找到可用镜像，升级中止。"
		return 1
	fi
	local mirror_url="$_SELECTED_MIRROR"

	echo -e ""
	echo -e "${INFO} 开始升级 (使用镜像: ${mirror_url})..."
	echo -e ""

	if [[ "$OS_ID" == "debian" ]]; then
		# Debian 升级流程
		echo -e "${INFO} [1/5] 更新当前系统并安装目标版本密钥..."
		export DEBIAN_FRONTEND=noninteractive
		apt-get update && apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
		apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
		# 安装目标版本的 archive keyring (解决跨版本签名信任问题)
		apt-get install -y debian-archive-keyring 2>/dev/null

		echo -e "${INFO} [2/5] 写入新版本源 (${target_codename} @ ${mirror_url})..."
		local sources_file="/etc/apt/sources.list"
		cp "$sources_file" "${sources_file}.bak.before-upgrade.$(date +%Y%m%d%H%M%S)"

		# 生成新的 sources.list
		local components="main contrib non-free"
		if [[ "$target_version" -ge 12 ]] 2>/dev/null; then
			components="main contrib non-free non-free-firmware"
		fi

		local security_suite="${target_codename}-security"
		[[ "$target_codename" == "buster" ]] && security_suite="buster/updates"

		# security 源: 优先镜像，不可用时尝试官方，都不行则跳过 (升级不强依赖 security)
		local security_mirror="${mirror_url}"
		local security_line=""
		local sec_test_url="https://${mirror_url}/debian-security/dists/${security_suite}/Release"
		if curl -sL --max-time 5 -o /dev/null -w "%{http_code}" "$sec_test_url" 2>/dev/null | grep -q "200"; then
			security_line="deb https://${security_mirror}/debian-security/ ${security_suite} ${components}"
		else
			# 尝试官方
			local official_sec="https://deb.debian.org/debian-security/dists/${security_suite}/Release"
			if curl -sL --max-time 5 -o /dev/null -w "%{http_code}" "$official_sec" 2>/dev/null | grep -q "200"; then
				security_line="deb https://deb.debian.org/debian-security/ ${security_suite} ${components}"
				echo -e "${TIP} 镜像无 debian-security，使用官方源。"
			else
				echo -e "${TIP} security 源均不可达，升级时暂时跳过 (升级后可手动添加)。"
			fi
		fi

		cat >"$sources_file" <<EOF
# Debian ${target_codename} - 升级源 (${mirror_url})
deb https://${mirror_url}/debian/ ${target_codename} ${components}
deb https://${mirror_url}/debian/ ${target_codename}-updates ${components}
${security_line}
EOF

		# 清理 sources.list.d 中的旧版本源 (避免冲突)
		find /etc/apt/sources.list.d/ -name "*.list" -exec sed -i "s/${current_codename}/${target_codename}/g" {} \; 2>/dev/null
		find /etc/apt/sources.list.d/ -name "*.sources" -exec sed -i "s/${current_codename}/${target_codename}/g" {} \; 2>/dev/null

		echo -e "${INFO} [3/5] 更新包索引..."
		apt-get update --allow-releaseinfo-change 2>&1 | tail -5
		# 验证: 检查目标版本的包是否可用
		local update_ok=0
		if apt-cache policy base-files 2>/dev/null | grep -q "${target_codename}\|${target_version}"; then
			update_ok=1
		elif apt-cache showpkg base-files 2>/dev/null | grep -q "${target_codename}"; then
			update_ok=1
		fi
		if [[ $update_ok -eq 0 ]]; then
			echo -e "${ERROR} 目标版本 (${target_codename}) 的包索引获取失败！"
			echo -e "${TIP} 可能原因: 网络不通或 GPG 签名验证失败"
			echo -e "${TIP} 尝试手动: apt-get update --allow-insecure-repositories"
			return 1
		fi
		echo -e "${INFO} 包索引更新成功。"

		echo -e "${INFO} [4/5] 执行系统升级 (这可能需要 5-30 分钟)..."
		export DEBIAN_FRONTEND=noninteractive
		apt-get -y \
			-o Dpkg::Options::="--force-confdef" \
			-o Dpkg::Options::="--force-confold" \
			dist-upgrade

		local upgrade_ret=$?
		unset DEBIAN_FRONTEND

		if [[ $upgrade_ret -ne 0 ]]; then
			echo -e "${ERROR} dist-upgrade 返回错误码 ${upgrade_ret}"
			echo -e "${TIP} 可尝试: apt-get install -f -y && apt-get dist-upgrade -y"
		fi

		# [5/5] 强制更新 base-files (确保 /etc/os-release 更新)
		echo -e "${INFO} [5/5] 更新系统版本标识..."
		DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confnew" base-files 2>/dev/null

		apt-get autoremove -y 2>/dev/null

	elif [[ "$OS_ID" == "ubuntu" ]]; then
		# Ubuntu 升级流程 (直接修改源 + dist-upgrade，比 do-release-upgrade 更可靠)
		echo -e "${INFO} [1/4] 更新当前系统并安装目标版本密钥..."
		export DEBIAN_FRONTEND=noninteractive
		apt-get update && apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
		apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
		# 安装目标版本的 keyring (解决跨版本签名信任问题)
		apt-get install -y ubuntu-keyring 2>/dev/null

		echo -e "${INFO} [2/4] 写入新版本源 (${target_codename} @ ${mirror_url})..."
		local sources_file="/etc/apt/sources.list"
		cp "$sources_file" "${sources_file}.bak.before-upgrade.$(date +%Y%m%d%H%M%S)"

		# Ubuntu 24.04+ 使用 DEB822 格式，需要禁用
		if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
			mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.disabled
		fi

		cat >"$sources_file" <<EOF
# Ubuntu ${target_codename} - 升级源 (${mirror_url})
deb https://${mirror_url}/ubuntu/ ${target_codename} main restricted universe multiverse
deb https://${mirror_url}/ubuntu/ ${target_codename}-updates main restricted universe multiverse
deb https://${mirror_url}/ubuntu/ ${target_codename}-security main restricted universe multiverse
EOF

		# 清理 sources.list.d 中的旧版本源
		find /etc/apt/sources.list.d/ -name "*.list" -exec sed -i "s/${current_codename}/${target_codename}/g" {} \; 2>/dev/null
		find /etc/apt/sources.list.d/ -name "*.sources" -exec sed -i "s/${current_codename}/${target_codename}/g" {} \; 2>/dev/null

		echo -e "${INFO} [3/4] 更新包索引..."
		apt-get update --allow-releaseinfo-change 2>&1 | tail -5
		if ! apt-cache policy base-files 2>/dev/null | grep -q "${target_codename}\|${target_version}"; then
			echo -e "${ERROR} 目标版本 (${target_codename}) 的包索引获取失败！"
			return 1
		fi
		echo -e "${INFO} 包索引更新成功。"

		echo -e "${INFO} [4/4] 执行系统升级 (这可能需要 5-30 分钟)..."
		export DEBIAN_FRONTEND=noninteractive
		apt-get -y \
			-o Dpkg::Options::="--force-confnew" \
			dist-upgrade

		local upgrade_ret=$?
		unset DEBIAN_FRONTEND

		if [[ $upgrade_ret -ne 0 ]]; then
			echo -e "${ERROR} dist-upgrade 返回错误码 ${upgrade_ret}"
			echo -e "${TIP} 可尝试: apt-get install -f -y && apt-get dist-upgrade -y"
		fi

		# 强制更新 base-files
		apt-get install -y --allow-downgrades base-files 2>/dev/null
		apt-get autoremove -y 2>/dev/null
	fi

	echo -e ""
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 系统升级操作已完成！"
	echo -e "${INFO} ================================================"
	echo -e "${TIP} 请立即重启服务器: reboot"
	echo -e "${TIP} 重启后验证: cat /etc/os-release"
	echo -e ""
	echo -e "${INFO} 重启后如需继续升级到更高版本，再次运行本脚本选择 [9]"
	_log "INFO" "System upgrade: ${OS_ID} ${OS_VERSION_ID} -> ${target_version} (mirror: ${mirror_url})"
}

# =================================================
#  日志清理与定时任务
# =================================================
clean_logs_and_schedule() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 清理系统日志 & 配置定时清理任务"
	echo -e "${INFO} ================================================"
	echo -e ""

	# 1. 创建独立清理脚本
	echo -e "${INFO} [1/4] 创建日志清理脚本 /root/clean_logs.sh..."
	cat > /root/clean_logs.sh <<'SCRIPT'
#!/bin/bash
# 清理 systemd journald 日志
command -v journalctl >/dev/null && journalctl --vacuum-time=1s 2>/dev/null

# 删除旧的、备份的、压缩的日志文件
find /var/log -type f -name "*.log" -delete 2>/dev/null
find /var/log -type f -name "*.gz" -delete 2>/dev/null
find /var/log -type f -name "*.1" -delete 2>/dev/null
find /var/log -type f -name "*.old" -delete 2>/dev/null
find /var/log -type f -name "btmp*" -delete 2>/dev/null

# 置空当前正在使用的核心日志文件
for log in syslog auth.log kern.log dpkg.log btmp; do
  [ -f "/var/log/$log" ] && truncate -s 0 "/var/log/$log"
done

# 清理临时文件
find /tmp -type f -atime +3 -delete 2>/dev/null
SCRIPT
	chmod +x /root/clean_logs.sh
	echo -e "${INFO} 清理脚本已创建。"

	# 2. 立即执行一次清理
	echo -e ""
	echo -e "${INFO} [2/4] 立即执行日志清理..."
	/root/clean_logs.sh
	echo -e "${INFO} 清理完成。"

	# 3. 禁用 journald 磁盘存储
	echo -e ""
	echo -e "${INFO} [3/4] 配置 journald 禁止日志堆积..."
	if [[ -d /etc/systemd ]]; then
		mkdir -p /etc/systemd/journald.conf.d
		cat > /etc/systemd/journald.conf.d/disable.conf <<'EOF'
[Journal]
Storage=none
Compress=no
SystemMaxUse=0
EOF
		systemctl restart systemd-journald >/dev/null 2>&1
		echo -e "${INFO} journald 已设置为不存储日志到磁盘。"
	fi

	# 4. 配置 crontab 定时任务 (每天凌晨 3 点)
	echo -e ""
	echo -e "${INFO} [4/4] 配置定时清理任务..."

	# 确保 cron 已安装
	if ! command -v crontab >/dev/null 2>&1; then
		echo -e "${INFO} 正在安装 cron..."
		apt-get install -y cron >/dev/null 2>&1
		systemctl enable cron 2>/dev/null
		systemctl start cron 2>/dev/null
	fi

	# 清理旧的相关条目，避免重复
	(crontab -l 2>/dev/null | grep -vE "journalctl|vacuum-time|/var/log|clean_logs.sh"; echo "0 3 * * * /root/clean_logs.sh") | crontab -
	echo -e "${INFO} 定时任务已配置: 每天 03:00 自动清理"

	# 同时清理 APT 缓存
	apt-get clean 2>/dev/null

	echo -e ""
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 日志清理方案配置完成！"
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 已配置:"
	echo -e "  • journald 存储已禁用 (不再写入磁盘)"
	echo -e "  • 每天 03:00 自动执行 /root/clean_logs.sh"
	echo -e "  • APT 缓存已清理"
	echo -e ""
	echo -e "${INFO} 当前定时任务:"
	crontab -l 2>/dev/null | grep -v "^#"
	_log "INFO" "Logs cleaned and cron scheduled"
}

# =================================================
#  添加虚拟内存 (Swap)
# =================================================
setup_swap() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 添加虚拟内存 (Swap)"
	echo -e "${INFO} ================================================"
	echo -e ""

	# 检查是否已有 swap
	local current_swap
	current_swap=$(swapon --show --noheadings 2>/dev/null | wc -l)
	if [[ "$current_swap" -gt 0 ]]; then
		local swap_size
		swap_size=$(free -h | awk '/Swap:/ {print $2}')
		echo -e "${INFO} 系统已有 Swap: ${GREEN_FONT_PREFIX}${swap_size}${FONT_COLOR_SUFFIX}"
		swapon --show
		echo -e ""
		echo -e "${INFO} 无需重复添加，跳过。"
		return 0
	fi

	# 根据内存大小决定 swap 大小
	local mem_mb
	mem_mb=$(free -m | awk '/Mem:/ {print $2}')
	local swap_size_mb
	if [[ "$mem_mb" -le 1024 ]]; then
		swap_size_mb=1024
	elif [[ "$mem_mb" -le 2048 ]]; then
		swap_size_mb=1024
	elif [[ "$mem_mb" -le 4096 ]]; then
		swap_size_mb=2048
	else
		swap_size_mb=2048
	fi

	echo -e "${INFO} 当前内存: ${mem_mb}MB，将创建 ${swap_size_mb}MB Swap"
	echo -e ""

	# 创建 swap 文件
	echo -e "${INFO} 正在创建 Swap 文件..."
	fallocate -l ${swap_size_mb}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=${swap_size_mb} 2>/dev/null
	chmod 600 /swapfile
	mkswap /swapfile >/dev/null 2>&1
	swapon /swapfile

	# 验证
	if swapon --show | grep -q "/swapfile"; then
		echo -e "${INFO} Swap 已启用！"
	else
		echo -e "${ERROR} Swap 启用失败！"
		rm -f /swapfile
		return 1
	fi

	# 持久化 (开机自动挂载)
	if ! grep -q "/swapfile" /etc/fstab; then
		echo "/swapfile none swap sw 0 0" >> /etc/fstab
	fi

	# 设置 swappiness (低值 = 尽量用物理内存)
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	[[ ! -f "$sysctl_conf" ]] && touch "$sysctl_conf"
	sed -i '/vm.swappiness/d' "$sysctl_conf" /etc/sysctl.conf 2>/dev/null
	echo "vm.swappiness=10" >> "$sysctl_conf"
	sysctl -w vm.swappiness=10 >/dev/null 2>&1

	echo -e ""
	echo -e "${INFO} ================================================"
	echo -e "${INFO} Swap 配置完成！"
	echo -e "${INFO} ================================================"
	free -h | grep -E "Mem:|Swap:"
	echo -e ""
	echo -e "${INFO} Swap 大小: ${swap_size_mb}MB"
	echo -e "${INFO} Swappiness: 10 (优先使用物理内存)"
	_log "INFO" "Swap created: ${swap_size_mb}MB"
}

# =================================================
#  设置 IPv4 优先
# =================================================
set_ipv4_priority() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 设置 IPv4 优先出站"
	echo -e "${INFO} ================================================"
	echo -e ""

	# 检查当前状态
	local current_status="未设置"
	if [[ -f /etc/gai.conf ]] && grep -q "^precedence.*::ffff:0:0/96" /etc/gai.conf 2>/dev/null; then
		current_status="已设置"
		echo -e "${INFO} 当前状态: ${GREEN_FONT_PREFIX}IPv4 优先已生效${FONT_COLOR_SUFFIX}"
		echo -e ""
		echo -e "  当前 /etc/gai.conf 中的配置:"
		grep "^precedence" /etc/gai.conf | while read -r line; do
			echo -e "    $line"
		done
		echo -e ""
		if _is_interactive; then
			read -p "是否重新写入配置？[Y/n]: " confirm
			confirm=${confirm:-Y}
			if [[ "$confirm" =~ ^[Nn]$ ]]; then
				echo -e "${INFO} 操作已取消。"
				return 0
			fi
		fi
	fi

	# 写入 /etc/gai.conf
	# 先清除旧的 precedence 行 (避免重复)
	if [[ -f /etc/gai.conf ]]; then
		sed -i '/^precedence.*::ffff:0:0/d' /etc/gai.conf
	else
		touch /etc/gai.conf
	fi

	echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf

	echo -e "${INFO} 已写入 /etc/gai.conf:"
	echo -e "    precedence ::ffff:0:0/96  100"
	echo -e ""

	# 验证
	echo -e "${INFO} 正在验证 IPv4 优先是否生效..."
	local test_result=""
	if command -v getent >/dev/null 2>&1; then
		test_result=$(getent ahosts www.google.com 2>/dev/null | head -1 || echo "")
	fi

	if [[ -n "$test_result" ]]; then
		local first_addr
		first_addr=$(echo "$test_result" | awk '{print $1}')
		if [[ "$first_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo -e "${INFO} 验证通过: 系统优先解析 IPv4 地址 (${first_addr})"
		elif [[ "$first_addr" =~ : ]]; then
			echo -e "${TIP} 系统仍优先解析 IPv6 地址 (${first_addr})"
			echo -e "${TIP} 可能需要重启网络服务或重新登录 SSH 才能完全生效。"
		fi
	else
		echo -e "${TIP} 无法验证 (getent 不可用或网络不通)，配置已写入，重新登录后生效。"
	fi

	echo -e ""
	echo -e "${INFO} ================================================"
	echo -e "${INFO} IPv4 优先设置完成！"
	echo -e "${INFO} ================================================"
	echo -e "${TIP} 原理: /etc/gai.conf 的 precedence 规则让系统在双栈环境下优先使用 IPv4 出站。"
	echo -e "${TIP} 恢复默认: 删除 /etc/gai.conf 中的 precedence 行即可恢复 IPv6 优先。"

	_log "INFO" "IPv4 priority set via /etc/gai.conf"
}

# =================================================
#  一键DD系统 (调用 bin456789/reinstall)
# =================================================
reinstall_system() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 一键DD系统 (bin456789/reinstall)"
	echo -e "${INFO} ================================================"
	echo -e ""
	echo -e "${TIP} 此功能将调用第三方脚本重装系统，执行后当前系统数据将被清除！"
	echo -e "${TIP} 项目地址: https://github.com/bin456789/reinstall"
	echo -e ""

	# 多镜像源列表 (按优先级排列)
	local script_urls=()
	if [[ $IS_CN -eq 1 ]]; then
		script_urls=(
			"https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh"
			"https://ghfast.top/https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
			"https://gh-proxy.com/https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
			"https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
		)
	else
		script_urls=(
			"https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
			"https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh"
		)
	fi

	# 显示支持的系统列表
	echo -e " 支持的系统:"
	echo -e "  ─────────────────────────────────────────────"
	echo -e "  ${GREEN_FONT_PREFIX}Debian${FONT_COLOR_SUFFIX}:     9 | 10 | 11 | 12 | 13"
	echo -e "  ${GREEN_FONT_PREFIX}Ubuntu${FONT_COLOR_SUFFIX}:     18.04 | 20.04 | 22.04 | 24.04 | 26.04"
	echo -e "  ${GREEN_FONT_PREFIX}CentOS${FONT_COLOR_SUFFIX}:     9 | 10"
	echo -e "  ${GREEN_FONT_PREFIX}AlmaLinux${FONT_COLOR_SUFFIX}:  8 | 9 | 10"
	echo -e "  ${GREEN_FONT_PREFIX}Rocky${FONT_COLOR_SUFFIX}:      8 | 9 | 10"
	echo -e "  ${GREEN_FONT_PREFIX}Fedora${FONT_COLOR_SUFFIX}:     43 | 44"
	echo -e "  ${GREEN_FONT_PREFIX}Alpine${FONT_COLOR_SUFFIX}:     3.20 | 3.21 | 3.22 | 3.23"
	echo -e "  ${GREEN_FONT_PREFIX}Windows${FONT_COLOR_SUFFIX}:    需指定 --image-name"
	echo -e "  ${GREEN_FONT_PREFIX}DD${FONT_COLOR_SUFFIX}:         需指定 --img=URL"
	echo -e "  ─────────────────────────────────────────────"
	echo -e ""
	echo -e " 用法示例:"
	echo -e "   debian 12          — 重装为 Debian 12"
	echo -e "   ubuntu 24.04       — 重装为 Ubuntu 24.04"
	echo -e "   dd --img=http://x  — DD 自定义镜像"
	echo -e ""

	if ! _is_interactive; then
		echo -e "${ERROR} 此功能需要交互式终端，不支持管道模式。"
		return 1
	fi

	read -p " 请输入要安装的系统 (例: debian 12): " reinstall_args
	if [[ -z "$reinstall_args" ]]; then
		echo -e "${INFO} 操作已取消。"
		return 0
	fi

	echo -e ""
	echo -e "${RED_FONT_PREFIX}警告: 即将重装系统为 [${reinstall_args}]，当前系统所有数据将被清除！${FONT_COLOR_SUFFIX}"
	read -p " 确认执行？请输入 YES 继续: " confirm
	if [[ "$confirm" != "YES" ]]; then
		echo -e "${INFO} 操作已取消。"
		return 0
	fi

	# 多源下载脚本
	echo -e ""
	echo -e "${INFO} 正在下载 reinstall.sh 脚本..."
	local script_file="/tmp/reinstall_$$.sh"
	local download_ok=0

	for url in "${script_urls[@]}"; do
		echo -e "${INFO} 尝试: ${url%%/reinstall*}..."
		if curl -fsSL --max-time 15 -o "$script_file" "$url" 2>/dev/null && [[ -s "$script_file" ]]; then
			download_ok=1
			echo -e "${INFO} 下载成功！"
			break
		fi
		rm -f "$script_file"
	done

	if [[ $download_ok -eq 0 ]]; then
		echo -e "${ERROR} 所有镜像源下载失败，请检查网络后重试。"
		return 1
	fi

	# 执行重装
	echo -e "${INFO} 正在执行: bash reinstall.sh ${reinstall_args}"
	echo -e ""
	bash "$script_file" $reinstall_args
	local ret=$?

	rm -f "$script_file"

	if [[ $ret -ne 0 ]]; then
		echo -e "${ERROR} reinstall.sh 执行失败 (退出码: $ret)"
		return 1
	fi

	_log "INFO" "reinstall_system executed: ${reinstall_args}"
}

# =================================================
#  基础系统包安装与初始化
# =================================================
install_base_packages() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 安装基础系统包 & 初始化配置"
	echo -e "${INFO} ================================================"
	echo -e ""
	echo -e "${INFO} 将执行以下操作:"
	echo -e "  • 关闭 UFW 防火墙"
	echo -e "  • 安装常用工具包 (git/vim/wget/curl/htop/iperf3 等)"
	echo -e "  • 更新 CA 证书"
	echo -e "  • 设置时区为 Asia/Shanghai 并同步时间"
	echo -e "  • 清理系统日志 (保留 1 天 / 最大 10MB)"
	echo -e "  • 安装 NextTrace 路由追踪工具"
	echo -e ""
	if _is_interactive; then
		read -p "确认执行？(回车确认, n取消): " confirm
		[[ "$confirm" =~ ^[nN]$ ]] && { echo -e "${INFO} 已取消。"; return 0; }
	fi

	echo -e ""

	# 1. 关闭 UFW 防火墙
	echo -e "${INFO} [1/6] 关闭 UFW 防火墙..."
	if command -v ufw >/dev/null 2>&1; then
		ufw disable 2>/dev/null && echo -e "${INFO} UFW 已关闭。"
	else
		echo -e "${INFO} UFW 未安装，跳过。"
	fi

	# 2. 更新包索引并安装基础包
	echo -e ""
	echo -e "${INFO} [2/6] 安装基础系统包..."
	apt-get update

	# DEBIAN_FRONTEND=noninteractive 避免 iperf3 等包弹出交互式对话框
	# -o Dpkg::Options::="--force-confdef" 保持现有配置文件
	# -o Dpkg::Options::="--force-confold" 冲突时保留旧配置
	export DEBIAN_FRONTEND=noninteractive
	apt-get -y \
		-o Dpkg::Options::="--force-confdef" \
		-o Dpkg::Options::="--force-confold" \
		install \
		git vim wget unzip net-tools ca-certificates curl \
		chrony python3-pip sudo telnet iperf3 htop \
		dnsutils lsb-release jq

	local apt_ret=$?
	unset DEBIAN_FRONTEND

	if [[ $apt_ret -ne 0 ]]; then
		echo -e "${TIP} 部分包可能安装失败，但不影响核心功能。"
		echo -e "${TIP} 可手动重试: apt-get install -y <包名>"
	else
		echo -e "${INFO} 基础包安装完成！"
	fi

	# 3. 更新 CA 证书
	echo -e ""
	echo -e "${INFO} [3/6] 更新 CA 证书..."
	update-ca-certificates --fresh 2>/dev/null && echo -e "${INFO} CA 证书已更新。"

	# 4. 时区与时间同步
	echo -e ""
	echo -e "${INFO} [4/6] 配置时区与时间同步..."
	timedatectl set-timezone "Asia/Shanghai" 2>/dev/null && echo -e "${INFO} 时区已设置为 Asia/Shanghai"

	if systemctl is-active chrony >/dev/null 2>&1 || systemctl is-active chronyd >/dev/null 2>&1; then
		systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null
		echo -e "${INFO} Chrony 时间同步服务已重启。"
	fi
	timedatectl set-ntp true 2>/dev/null

	# 显示当前时间
	echo -e "${INFO} 当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"

	# 5. 清理系统日志
	echo -e ""
	echo -e "${INFO} [5/6] 清理系统日志..."
	journalctl --vacuum-size=10M 2>/dev/null
	journalctl --vacuum-time=1d 2>/dev/null
	echo -e "${INFO} 日志已清理 (保留: 最大 10MB / 最近 1 天)。"

	# 6. 安装 NextTrace
	echo -e ""
	echo -e "${INFO} [6/6] 安装 NextTrace 路由追踪工具..."
	if command -v nexttrace >/dev/null 2>&1; then
		echo -e "${INFO} NextTrace 已安装，跳过。"
	else
		if curl -fSL --max-time 30 https://nxtrace.org/nt | bash; then
			echo -e "${INFO} NextTrace 安装完成！"
		else
			echo -e "${TIP} NextTrace 安装失败 (不影响其他功能)。"
			echo -e "${TIP} 可手动安装: curl -fSL https://nxtrace.org/nt | bash"
		fi
	fi

	echo -e ""
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 基础系统包安装与初始化全部完成！"
	echo -e "${INFO} ================================================"
	_log "INFO" "Base packages installed"
}


# =================================================
#  Xanmod 内核安装引擎 (针对 Debian 10-13 / Ubuntu 20-26 深度优化)
# =================================================
#
# 优化要点:
# 1. 使用现代 DEB822 格式 (.sources) 配置源 (Debian 12+/Ubuntu 24+)
# 2. 旧版系统回退到传统 .list 格式
# 3. 密钥存放在 /etc/apt/keyrings/ (符合现代 APT 规范)
# 4. 正确处理各分支的 CPU 等级可用性:
#    - MAIN: x64v2, x64v3 (无 v1, 无 v4)
#    - EDGE: x64v2, x64v3 (无 v1, 无 v4)
#    - LTS:  x64v1, x64v2, x64v3 (无 v4)
#    - RT:   x64v2, x64v3 (无 v1, 无 v4)
# 5. Secure Boot 检测与警告
# 6. 安装前验证包是否存在于仓库
# 7. 安装后自动配置 BBRv3 (XanMod 内置)
#

# 检测 CPU 的 x86-64 psABI 等级
_detect_cpu_level() {
	local check_script="/tmp/check_x86-64_psabi_$$.sh"

	if ! curl -fsSL -o "$check_script" https://dl.xanmod.org/check_x86-64_psabi.sh 2>/dev/null; then
		echo -e "${TIP} 无法下载 CPU 等级检测脚本，尝试本地检测..." >&2
		# 本地回退检测: 通过 /proc/cpuinfo 判断
		if grep -q "avx2" /proc/cpuinfo && grep -q "bmi2" /proc/cpuinfo && grep -q "fma" /proc/cpuinfo; then
			echo "3"
		elif grep -q "sse4_2" /proc/cpuinfo && grep -q "popcnt" /proc/cpuinfo; then
			echo "2"
		else
			echo "1"
		fi
		return 0
	fi

	chmod +x "$check_script"
	local level
	level=$("$check_script" 2>/dev/null | grep -oE 'x86-64-v[0-9]+' | grep -oE '[0-9]+$' || echo "")
	rm -f "$check_script"

	if [[ -z "$level" ]]; then
		# 回退: 本地 cpuinfo 检测
		if grep -q "avx2" /proc/cpuinfo && grep -q "bmi2" /proc/cpuinfo && grep -q "fma" /proc/cpuinfo; then
			level="3"
		elif grep -q "sse4_2" /proc/cpuinfo && grep -q "popcnt" /proc/cpuinfo; then
			level="2"
		else
			level="1"
		fi
	fi

	[[ -z "$level" || "$level" -lt 1 ]] && level="2"
	echo "$level"
}

# 检测 Secure Boot 状态
_check_secure_boot() {
	if command -v mokutil >/dev/null 2>&1; then
		if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
			echo -e "${TIP} =============================================="
			echo -e "${TIP} 检测到 Secure Boot 已启用！"
			echo -e "${TIP} XanMod 内核未经 Microsoft 签名，Secure Boot"
			echo -e "${TIP} 环境下可能无法启动。建议在 BIOS/UEFI 中关闭"
			echo -e "${TIP} Secure Boot，或使用系统自带的签名内核。"
			echo -e "${TIP} =============================================="
			read -p "是否继续安装？(回车确认, n取消): " sb_confirm
			if ! _is_interactive; then sb_confirm=""; fi
			[[ "$sb_confirm" =~ ^[nN]$ ]] && return 1
		fi
	fi
	return 0
}

# 清理所有旧版 XanMod 源配置 (兼容各种历史遗留格式)
_cleanup_xanmod_sources() {
	# 移除旧的 .list 格式文件
	rm -f /etc/apt/sources.list.d/xanmod-kernel.list
	rm -f /etc/apt/sources.list.d/xanmod-release.list
	rm -f /etc/apt/sources.list.d/xanmod-kernel.sources
	rm -f /etc/apt/sources.list.d/xanmod.sources
	# 清理可能写入主 sources.list 的条目
	sed -i '/deb.xanmod.org/d' /etc/apt/sources.list 2>/dev/null
	sed -i '/dl.xanmod.org/d' /etc/apt/sources.list 2>/dev/null
	# 清理旧密钥位置
	rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
	rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg
}

# 配置 XanMod APT 源 (自动选择 DEB822 或传统格式)
_setup_xanmod_repo() {
	# 确保密钥目录存在
	install -m 0755 -d /etc/apt/keyrings

	# 导入 GPG 密钥 (多源回退)
	echo -e "${INFO} 正在导入 XanMod GPG 密钥..."
	local key_imported=0

	# 源1: 官方地址
	if curl -fsSL --max-time 10 https://dl.xanmod.org/archive.key 2>/dev/null | gpg --dearmor --yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>/dev/null; then
		key_imported=1
	fi

	# 源2: Ubuntu Keyserver
	if [[ $key_imported -eq 0 ]]; then
		echo -e "${TIP} 官方地址不可用，尝试 Ubuntu Keyserver..."
		if curl -fsSL --max-time 10 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x86F7D09EE734E623" 2>/dev/null | gpg --dearmor --yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>/dev/null; then
			key_imported=1
		fi
	fi

	# 源3: OpenPGP Keyserver
	if [[ $key_imported -eq 0 ]]; then
		echo -e "${TIP} Ubuntu Keyserver 不可用，尝试 OpenPGP..."
		if curl -fsSL --max-time 10 "https://keys.openpgp.org/vks/v1/by-fingerprint/D38D7D1DA1349567ADED882D86F7D09EE734E623" 2>/dev/null | gpg --dearmor --yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>/dev/null; then
			key_imported=1
		fi
	fi

	if [[ $key_imported -eq 0 ]]; then
		echo -e "${ERROR} GPG 密钥导入失败！所有源均不可用。"
		echo -e "${TIP} 可能原因: 网络被 CDN 拦截 (Cloudflare 403)"
		echo -e "${TIP} 解决方法: 配置代理或更换 IP 后重试"
		return 1
	fi
	chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg
	echo -e "${INFO} GPG 密钥导入成功。"

	# 获取系统代号
	local codename="${OS_VERSION_CODENAME}"
	# 回退获取代号
	if [[ -z "$codename" ]]; then
		if [[ "$OS_ID" == "debian" ]]; then
			case "$OS_VERSION_ID" in
			10) codename="buster" ;;
			11) codename="bullseye" ;;
			12) codename="bookworm" ;;
			13) codename="trixie" ;;
			*) codename="bookworm" ;;
			esac
		elif [[ "$OS_ID" == "ubuntu" ]]; then
			case "$OS_VERSION_ID" in
			20.04) codename="focal" ;;
			22.04) codename="jammy" ;;
			24.04) codename="noble" ;;
			24.10) codename="oracular" ;;
			25.04) codename="plucky" ;;
			26.04) codename="resolute" ;;
			*) codename="noble" ;;
			esac
		fi
	fi

	# 判断是否使用 DEB822 格式 (Debian 12+ / Ubuntu 24.04+)
	local use_deb822=0
	if [[ "$OS_ID" == "debian" && "${OS_VERSION_ID}" -ge 12 ]] 2>/dev/null; then
		use_deb822=1
	elif [[ "$OS_ID" == "ubuntu" ]]; then
		local ubuntu_major
		ubuntu_major=$(echo "$OS_VERSION_ID" | cut -d. -f1)
		[[ "$ubuntu_major" -ge 24 ]] 2>/dev/null && use_deb822=1
	fi

	# XanMod 仓库使用系统代号作为 Suite (不是 "releases")
	# 支持情况 (2025年实测):
	#   Debian: bookworm(LTS only), trixie(全部)
	#   Ubuntu: noble(全部), plucky(全部), resolute(全部)
	#   不支持: buster, bullseye, focal, jammy(空), oracular(空)
	local xanmod_suite="$codename"

	# 检查该代号是否被 XanMod 支持，不支持则尝试回退
	local supported_suites="bookworm trixie noble plucky resolute"
	if ! echo "$supported_suites" | grep -qw "$xanmod_suite"; then
		echo -e "${TIP} XanMod 仓库可能不支持当前系统代号: ${xanmod_suite}"
		# 尝试回退到最近的支持版本
		if [[ "$OS_ID" == "debian" ]]; then
			xanmod_suite="bookworm"
			echo -e "${INFO} 回退使用 bookworm 源 (仅 LTS 分支可用)"
		elif [[ "$OS_ID" == "ubuntu" ]]; then
			xanmod_suite="noble"
			echo -e "${INFO} 回退使用 noble 源"
		fi
	fi

	echo -e "${INFO} XanMod 源 Suite: ${xanmod_suite}"

	if [[ $use_deb822 -eq 1 ]]; then
		echo -e "${INFO} 使用 DEB822 格式配置 XanMod 源..."
		cat >/etc/apt/sources.list.d/xanmod.sources <<EOF
Types: deb
URIs: https://deb.xanmod.org
Suites: ${xanmod_suite}
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/xanmod-archive-keyring.gpg
EOF
	else
		echo -e "${INFO} 使用传统格式配置 XanMod 源..."
		echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg arch=amd64] https://deb.xanmod.org ${xanmod_suite} main" \
			>/etc/apt/sources.list.d/xanmod-release.list
	fi

	return 0
}

# 根据分支和 CPU 等级确定正确的包名
_resolve_xanmod_package() {
	local edition="$1"
	local cpu_level="$2"

	# 包名映射规则 (基于 2025 年 XanMod 仓库实测):
	#
	# bookworm (Debian 12): 仅 LTS
	#   linux-xanmod-lts-x64v1, linux-xanmod-lts-x64v2, linux-xanmod-lts-x64v3
	#
	# trixie/noble/plucky/resolute: 全部分支
	#   MAIN: linux-xanmod-x64v2, linux-xanmod-x64v3
	#   EDGE: linux-xanmod-edge-x64v2, linux-xanmod-edge-x64v3
	#   LTS:  linux-xanmod-lts-x64v1, linux-xanmod-lts-x64v2, linux-xanmod-lts-x64v3
	#   RT:   linux-xanmod-rt-x64v2, linux-xanmod-rt-x64v3
	#
	# 注意: 不存在 v4 包; MAIN/EDGE/RT 不存在 v1

	local pkg_base="linux-xanmod"
	[[ "$edition" != "main" ]] && pkg_base="linux-xanmod-${edition}"

	local target_level="$cpu_level"

	# 限制等级上限: 仓库不发布 v4 包
	[[ "$target_level" -ge 4 ]] && target_level=3

	# 限制等级下限: MAIN/EDGE/RT 不发布 v1
	if [[ "$edition" != "lts" && "$target_level" -le 1 ]]; then
		echo -e "${ERROR} 当前 CPU 仅支持 x86-64-v1，但 ${edition^^} 分支最低要求 v2。" >&2
		echo -e "${TIP} 你的 CPU 太旧，不支持 SSE4.2/POPCNT 指令集。" >&2
		echo -e "${TIP} 建议使用 LTS 分支 (支持 v1): 脚本会自动选择 LTS。" >&2
		pkg_base="linux-xanmod-lts"
		target_level=1
	fi

	# Debian 12 (bookworm) 仅支持 LTS 分支
	if [[ "${OS_VERSION_CODENAME}" == "bookworm" || "${OS_VERSION_ID}" == "12" ]] && [[ "$edition" != "lts" ]]; then
		echo -e "${TIP} Debian 12 (bookworm) 的 XanMod 仓库仅提供 LTS 分支！" >&2
		echo -e "${TIP} 自动切换到 LTS 分支安装。" >&2
		pkg_base="linux-xanmod-lts"
	fi

	echo "${pkg_base}-x64v${target_level}"
}

# 统一 Xanmod 安装引擎 (完全重写)
install_xanmod_generic() {
	local edition="$1"

	# 基本检查
	[[ "${OS_ARCH}" != "x86_64" ]] && {
		echo -e "${ERROR} XanMod 仅支持 x86_64 架构！"
		return 1
	}
	[[ "${OS_TYPE}" != "Debian" ]] && {
		echo -e "${ERROR} XanMod 仅支持 Debian/Ubuntu 系统！"
		return 1
	}

	# 系统版本支持检查
	local codename="${OS_VERSION_CODENAME}"
	if [[ -z "$codename" ]]; then
		if [[ "$OS_ID" == "debian" ]]; then
			case "$OS_VERSION_ID" in
			12) codename="bookworm" ;; 13) codename="trixie" ;;
			esac
		elif [[ "$OS_ID" == "ubuntu" ]]; then
			case "$OS_VERSION_ID" in
			24.04) codename="noble" ;; 25.04) codename="plucky" ;; 26.04) codename="resolute" ;;
			esac
		fi
	fi

	# 明确不支持的版本
	case "$codename" in
	buster|bullseye)
		echo -e "${ERROR} XanMod 不再支持 Debian ${OS_VERSION_ID} (${codename})！"
		echo -e "${TIP} 最低要求: Debian 12 (bookworm)"
		echo -e "${TIP} 建议先升级系统 (菜单 [9])，升级后即可安装 XanMod。"
		return 1
		;;
	focal|jammy)
		echo -e "${ERROR} XanMod 不再支持 Ubuntu ${OS_VERSION_ID} (${codename})！"
		echo -e "${TIP} 最低要求: Ubuntu 24.04 (noble)"
		echo -e "${TIP} 建议先升级系统 (菜单 [9])，升级后即可安装 XanMod。"
		return 1
		;;
	esac

	# Secure Boot 检测
	_check_secure_boot || return 0

	# 磁盘空间检查
	if ! _check_disk_space 500; then
		return 1
	fi

	echo -e "${INFO} ================================================"
	echo -e "${INFO} 开始安装 XanMod 内核 [${edition^^}] 分支"
	echo -e "${INFO} ================================================"

	# 显示分支说明
	case "$edition" in
	main)
		echo -e "${INFO} MAIN: 稳定主线版本，适合日常桌面/服务器使用"
		echo -e "${INFO} 特性: BBRv3, MGLRU, Cloudflare TCP优化, 低延迟调度"
		;;
	edge)
		echo -e "${INFO} EDGE: 滚动更新版本，包含最新补丁 (可能不稳定)"
		;;
	lts)
		echo -e "${INFO} LTS: 长期支持版本，适合生产环境"
		echo -e "${INFO} 特性: 更保守的更新策略，长期维护"
		;;
	rt)
		echo -e "${INFO} RT: 实时内核 (PREEMPT_RT)，适合音频/控制系统"
		echo -e "${INFO} 特性: 确定性延迟，适合对实时性要求高的场景"
		;;
	esac

	# 安装前置依赖
	echo -e "${INFO} 正在安装前置依赖..."
	apt-get update >/dev/null 2>&1
	apt-get install -y ca-certificates curl gpg >/dev/null 2>&1

	# 中国大陆网络提示
	if [[ $IS_CN -eq 1 ]]; then
		echo -e "${TIP} 检测到中国大陆网络，XanMod 源可能较慢。"
		echo -e "${TIP} 如遇下载缓慢，可先执行菜单 [5] 换源后再安装。"
	fi

	# 清理旧配置
	echo -e "${INFO} 正在清理旧的 XanMod 源配置..."
	_cleanup_xanmod_sources

	# 配置新源
	if ! _setup_xanmod_repo; then
		echo -e "${ERROR} XanMod 源配置失败！"
		return 1
	fi

	# 刷新包索引
	echo -e "${INFO} 正在刷新 APT 包索引..."
	if ! apt-get update 2>&1 | grep -v "^$"; then
		echo -e "${ERROR} APT 更新失败，请检查网络连接！"
		return 1
	fi

	# 检测 CPU 等级
	echo -e "${INFO} 正在检测 CPU x86-64 psABI 等级..."
	local cpu_level
	cpu_level=$(_detect_cpu_level)
	echo -e "${INFO} CPU 支持等级: ${GREEN_FONT_PREFIX}x86-64-v${cpu_level}${FONT_COLOR_SUFFIX}"

	# CPU 等级与性能说明
	case "$cpu_level" in
	1) echo -e "${TIP} v1 = 基础 x86_64 (2003年+)，性能优化有限" ;;
	2) echo -e "${INFO} v2 = SSE4.2/POPCNT (2009年+)，主流服务器/桌面" ;;
	3) echo -e "${INFO} v3 = AVX2/BMI2/FMA (2015年+)，现代处理器最佳选择" ;;
	4) echo -e "${INFO} v4 = AVX-512 (2017年+)，仓库无 v4 包，将使用 v3" ;;
	esac

	# 解析目标包名
	local target_pkg
	target_pkg=$(_resolve_xanmod_package "$edition" "$cpu_level")
	echo -e "${INFO} 目标安装包: ${GREEN_FONT_PREFIX}${target_pkg}${FONT_COLOR_SUFFIX}"

	# 验证包是否存在于仓库
	if ! apt-cache show "$target_pkg" >/dev/null 2>&1; then
		echo -e "${ERROR} 包 '${target_pkg}' 在仓库中不存在！"
		echo -e "${TIP} 可能原因:"
		echo -e "  1. 当前系统版本 (${OS_ID} ${OS_VERSION_ID}) 不在 XanMod 支持范围内"
		echo -e "  2. 该分支暂未发布对应 CPU 等级的包"
		echo -e "  3. 网络问题导致包索引不完整"
		echo ""
		echo -e "${INFO} 尝试列出可用的 XanMod 包:"
		apt-cache search "linux-xanmod" 2>/dev/null | grep -i "${edition}" | head -10
		return 1
	fi

	# 显示将要安装的版本
	local candidate_ver
	candidate_ver=$(apt-cache policy "$target_pkg" 2>/dev/null | grep "Candidate:" | awk '{print $2}')
	echo -e "${INFO} 候选版本: ${GREEN_FONT_PREFIX}${candidate_ver}${FONT_COLOR_SUFFIX}"

	# 执行安装
	echo -e "${INFO} 正在安装 ${target_pkg} ..."
	if ! apt-get install -y "$target_pkg"; then
		echo -e "${ERROR} 安装失败！尝试修复依赖..."
		apt-get install -f -y
		if ! apt-get install -y "$target_pkg"; then
			echo -e "${ERROR} 安装最终失败，请检查上方错误信息。"
			return 1
		fi
	fi

	# 安装后配置: 自动启用 BBRv3 (XanMod 内置)
	echo -e "${INFO} 正在配置 BBRv3 拥塞控制 (XanMod 内置)..."
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	[[ ! -f "$sysctl_conf" ]] && touch "$sysctl_conf"
	# 仅在未配置时写入，不覆盖用户已有的选择
	if ! grep -q "tcp_congestion_control" "$sysctl_conf" 2>/dev/null; then
		echo "" >>"$sysctl_conf"
		echo "# XanMod BBRv3 (自动配置)" >>"$sysctl_conf"
		echo "net.core.default_qdisc = fq" >>"$sysctl_conf"
		echo "net.ipv4.tcp_congestion_control = bbr" >>"$sysctl_conf"
	fi

	# 验证安装结果
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 安装完成！已安装的 XanMod 包:"
	dpkg -l | grep -i xanmod | awk '{printf "  %s %s\n", $2, $3}'
	echo -e "${INFO} ================================================"

	BBR_grub

	echo -e "${INFO} XanMod [${edition^^}] 内核安装完成！"
	echo -e "${TIP} 重启后生效。重启后可用 'uname -r' 确认是否切换成功。"
	echo -e "${TIP} XanMod 内置 BBRv3，重启后自动生效，无需额外配置。"
	echo -e ""
	echo -e "${INFO} 如需回退到原内核，可在 GRUB 高级选项中选择旧内核启动。"
}


# 自动选择 XanMod 分支安装
install_xanmod_auto() {
	local codename="${OS_VERSION_CODENAME}"
	if [[ -z "$codename" ]]; then
		if [[ "$OS_ID" == "debian" ]]; then
			case "$OS_VERSION_ID" in
			12) codename="bookworm" ;; 13) codename="trixie" ;;
			esac
		elif [[ "$OS_ID" == "ubuntu" ]]; then
			case "$OS_VERSION_ID" in
			24.04) codename="noble" ;; 25.04) codename="plucky" ;; 26.04) codename="resolute" ;;
			esac
		fi
	fi

	# 判断是否支持 MAIN 分支
	local main_supported="trixie noble plucky resolute"
	if echo "$main_supported" | grep -qw "$codename"; then
		echo -e "${INFO} 系统 ${OS_ID} ${OS_VERSION_ID} (${codename}) 支持 MAIN 分支"
		echo -e "${INFO} 将安装 XanMod MAIN (BBRv3 + Cloudflare TCP 优化 + 低延迟调度)"
		install_xanmod_generic "main"
	else
		echo -e "${TIP} 系统 ${OS_ID} ${OS_VERSION_ID} (${codename}) 仅支持 LTS 分支"
		echo -e "${INFO} 将安装 XanMod LTS (长期支持 + BBRv3)"
		install_xanmod_generic "lts"
	fi
}


# =================================================
#  状态检测
# =================================================
check_status() {
	kernel_version=$(uname -r | awk -F "-" '{print $1}')
	kernel_version_full=$(uname -r)
	net_congestion_control=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "unknown")
	net_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "unknown")

	# 检测内核类型
	local major minor
	major=$(echo "$kernel_version" | cut -d. -f1)
	minor=$(echo "$kernel_version" | cut -d. -f2)
	if [[ "$kernel_version_full" == *xanmod* ]]; then
		kernel_status="XanMod"
	elif [[ "$major" -ge 5 ]] || [[ "$major" -eq 4 && "$minor" -ge 9 ]]; then
		kernel_status="BBR"
	else
		kernel_status="noinstall"
	fi

	# 运行状态
	run_status="未启用"
	case "$net_congestion_control" in
	bbr) run_status="BBR 已启用" ;;
	bbr2) run_status="BBR2 已启用" ;;
	cubic) run_status="CUBIC (默认)" ;;
	*) run_status="${net_congestion_control}" ;;
	esac

	# Headers 状态
	headers_status="未安装"
	if dpkg -l 2>/dev/null | grep -q "linux-headers-${kernel_version_full}"; then
		headers_status="已匹配"
	elif dpkg -l 2>/dev/null | grep -q "linux-headers"; then
		headers_status="未匹配"
	fi
}

# =================================================
#  系统信息面板
# =================================================
get_system_info() {
	opsy="${OS_TYPE} ${OS_VERSION_ID}"
	arch="${OS_ARCH}"
	kern=$(uname -r)

	if command -v systemd-detect-virt >/dev/null 2>&1; then
		virtual=$(systemd-detect-virt 2>/dev/null)
	elif command -v virt-what >/dev/null 2>&1; then
		virtual=$(virt-what 2>/dev/null | head -n 1)
	else
		virtual="Unknown"
	fi
	[[ -z "$virtual" || "$virtual" == "none" ]] && virtual="Dedicated"
}

# =================================================
#  WARP IPv6 (通过 Cloudflare WARP 获取 IPv6)
# =================================================
install_warp_ipv6() {
	echo -e "${INFO} ================================================"
	echo -e "${INFO} 安装 Cloudflare WARP IPv6"
	echo -e "${INFO} ================================================"
	echo -e ""
	echo -e "${INFO} 通过 Cloudflare WARP WireGuard 隧道为服务器添加 IPv6 支持"
	echo -e "${INFO} 原有 IPv4 网络不受影响，仅 IPv6 流量走 WARP"
	echo -e ""

	# 检查是否已安装
	if systemctl is-active wg-quick@wgcf >/dev/null 2>&1; then
		echo -e "${TIP} WARP WireGuard 已在运行中。"
		echo -e "  状态: $(wg show wgcf 2>/dev/null | grep -c 'peer') 个对端连接"
		echo -e "  接口: $(ip -6 addr show wgcf 2>/dev/null | grep inet6 | awk '{print $2}')"
		echo -e ""
		echo -e "  如需重新安装，请先执行: systemctl disable --now wg-quick@wgcf"
		return 0
	fi

	# 检查架构
	local arch
	arch=$(uname -m)
	case "$arch" in
	x86_64) arch="amd64" ;;
	aarch64) arch="arm64" ;;
	*)
		echo -e "${ERROR} 不支持的架构: $arch"
		return 1
		;;
	esac

	echo -e "${INFO} [1/5] 安装 WireGuard 工具..."
	apt-get update >/dev/null 2>&1
	# wireguard-tools 提供 wg 和 wg-quick
	# 内核 >= 5.6 自带 wireguard 模块，不需要额外内核模块
	apt-get install -y wireguard-tools >/dev/null 2>&1

	# 低版本内核需要额外处理
	local kern_major kern_minor
	kern_major=$(uname -r | cut -d. -f1)
	kern_minor=$(uname -r | cut -d. -f2)
	if [[ "$kern_major" -lt 5 ]] || [[ "$kern_major" -eq 5 && "$kern_minor" -lt 6 ]]; then
		echo -e "${TIP} 内核版本 < 5.6，需要安装 wireguard 内核模块..."
		if [[ "$OS_ID" == "debian" && "$OS_VERSION_ID" == "10" ]]; then
			# Debian 10 需要 backports
			if ! grep -q "buster-backports" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
				echo "deb http://deb.debian.org/debian buster-backports main" > /etc/apt/sources.list.d/backports.list
				apt-get update >/dev/null 2>&1
			fi
			apt-get install -y -t buster-backports wireguard >/dev/null 2>&1
		else
			apt-get install -y wireguard >/dev/null 2>&1
		fi
	fi

	# 确保 wireguard 模块加载
	modprobe wireguard 2>/dev/null

	if ! command -v wg >/dev/null 2>&1; then
		echo -e "${ERROR} WireGuard 安装失败！"
		return 1
	fi
	echo -e "${INFO} WireGuard 安装完成。"

	echo -e ""
	echo -e "${INFO} [2/5] 安装 wgcf (WARP 注册工具)..."
	# 从 GitHub 下载 wgcf 二进制
	local wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${arch}"
	if ! safe_wget "$wgcf_url" "/usr/local/bin/wgcf"; then
		echo -e "${ERROR} wgcf 下载失败！"
		return 1
	fi
	chmod +x /usr/local/bin/wgcf
	echo -e "${INFO} wgcf 安装完成。"

	echo -e ""
	echo -e "${INFO} [3/5] 注册 WARP 账号并生成配置..."
	mkdir -p /etc/warp
	cd /etc/warp

	# 注册账号
	if [[ ! -f /etc/warp/wgcf-account.toml ]]; then
		local retry=0
		while [[ $retry -lt 3 ]]; do
			if yes | wgcf register 2>/dev/null; then
				break
			fi
			retry=$((retry + 1))
			sleep 3
		done
		if [[ ! -f wgcf-account.toml ]]; then
			echo -e "${ERROR} WARP 账号注册失败！可能是网络问题。"
			cd /root
			return 1
		fi
	fi

	# 生成配置
	if [[ ! -f /etc/warp/wgcf-profile.conf ]]; then
		wgcf generate 2>/dev/null
		if [[ ! -f wgcf-profile.conf ]]; then
			echo -e "${ERROR} WireGuard 配置生成失败！"
			cd /root
			return 1
		fi
	fi
	echo -e "${INFO} WARP 账号注册成功，配置已生成。"

	echo -e ""
	echo -e "${INFO} [4/5] 生成 WireGuard 配置文件..."

	# 读取 wgcf 生成的配置
	local private_key public_key wg_address
	private_key=$(grep "^PrivateKey" /etc/warp/wgcf-profile.conf | cut -d= -f2- | tr -d ' ')
	public_key=$(grep "^PublicKey" /etc/warp/wgcf-profile.conf | cut -d= -f2- | tr -d ' ')
	# Address 格式: 172.16.0.2/32,2606:4700:110:xxxx/128
	wg_address=$(grep "^Address" /etc/warp/wgcf-profile.conf | cut -d= -f2- | tr -d ' ')
	local address_v6
	address_v6=$(echo "$wg_address" | tr ',' '\n' | grep ':' | head -1)

	# 确保 IPv6 没有被系统禁用
	sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
	sed -i '/disable_ipv6/d' /etc/sysctl.conf /etc/sysctl.d/* 2>/dev/null

	# 获取当前 IPv6 地址 (如果有)
	local current_ipv6
	current_ipv6=$(ip -6 route get 2606:4700:4700::1001 2>/dev/null | grep -oE 'src [0-9a-f:]+' | awk '{print $2}')

	# 生成 WireGuard 配置 (仅 IPv6 流量走 WARP)
	local address_v6_bare
	address_v6_bare=$(echo "$address_v6" | cut -d/ -f1)

	# Ubuntu 可能没有 resolvconf，不设置 DNS 避免启动失败
	# WARP 仅走 IPv6 流量，DNS 用系统自带的即可
	cat > /etc/wireguard/wgcf.conf <<EOF
[Interface]
PrivateKey = ${private_key}
Address = ${address_v6}
MTU = 1280
Table = off

PostUp = ip -6 route add default dev wgcf table 51888
PostUp = ip -6 rule add from ${address_v6_bare} lookup 51888
PostUp = ip -6 rule add fwmark 51888 lookup 51888
${current_ipv6:+PostUp = ip -6 rule add from ${current_ipv6} lookup main prio 18}
PostDown = ip -6 route delete default dev wgcf table 51888
PostDown = ip -6 rule delete from ${address_v6_bare} lookup 51888
PostDown = ip -6 rule delete fwmark 51888 lookup 51888
${current_ipv6:+PostDown = ip -6 rule delete from ${current_ipv6} lookup main prio 18}

[Peer]
PublicKey = ${public_key}
AllowedIPs = ::/0
Endpoint = 162.159.192.1:2408
EOF

	echo -e "${INFO} WireGuard 配置已写入 /etc/wireguard/wgcf.conf"

	echo -e ""
	echo -e "${INFO} [5/5] 启动 WARP WireGuard..."
	systemctl enable wg-quick@wgcf --now 2>/dev/null

	# 等待接口启动
	sleep 3

	if systemctl is-active wg-quick@wgcf >/dev/null 2>&1; then
		echo -e "${INFO} WARP WireGuard 启动成功！"
	else
		echo -e "${ERROR} WARP WireGuard 启动失败！"
		echo -e "${TIP} 查看日志: journalctl -u wg-quick@wgcf --no-pager"
		cd /root
		return 1
	fi

	# 验证 IPv6
	sleep 2
	local warp_ipv6
	warp_ipv6=$(curl -s6 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "ip=" | cut -d= -f2)

	cd /root

	echo -e ""
	echo -e "${INFO} ================================================"
	echo -e "${INFO} WARP IPv6 安装完成！"
	echo -e "${INFO} ================================================"
	if [[ -n "$warp_ipv6" ]]; then
		echo -e "${INFO} WARP IPv6 地址: ${GREEN_FONT_PREFIX}${warp_ipv6}${FONT_COLOR_SUFFIX}"
	else
		echo -e "${TIP} IPv6 验证超时，可能需要几秒钟生效。"
		echo -e "${TIP} 手动验证: curl -6 ip.sb"
	fi
	echo -e "${INFO} 接口状态: wg show wgcf"
	echo -e "${INFO} 停止 WARP: systemctl stop wg-quick@wgcf"
	echo -e "${INFO} 卸载 WARP: systemctl disable --now wg-quick@wgcf && rm -f /etc/wireguard/wgcf.conf"

	# 设置 IPv4 优先 (防止系统默认走 IPv6 导致出站 IP 变化)
	echo -e ""
	echo -e "${INFO} 配置 IPv4 优先出站..."
	if [[ -f /etc/gai.conf ]]; then
		sed -i '/^precedence.*::ffff:0:0/d' /etc/gai.conf
	fi
	echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
	echo -e "${INFO} 已设置 IPv4 优先 (通过 /etc/gai.conf)"

	_log "INFO" "WARP IPv6 installed"
}

# =================================================
#  系统状态面板
# =================================================

# 菜单顶部简要状态显示
show_status_panel_brief() {
	check_status
	get_system_info

	# 系统基本信息
	local os_info mem_total mem_used mem_pct disk_info
	os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "$OS_ID $OS_VERSION_ID")
	mem_total=$(free -m | awk '/Mem:/ {print $2}')
	mem_used=$(free -m | awk '/Mem:/ {print $3}')
	mem_pct=$((mem_used * 100 / mem_total))
	disk_info=$(df -h / | awk 'NR==2 {printf "%s/%s(%s)", $3, $2, $5}')

	echo -e ""
	echo -e " ┌─────────────────────────────────────────────────────────┐"
	echo -e " │ 系统: ${GREEN_FONT_PREFIX}${os_info}${FONT_COLOR_SUFFIX} | $virtual | $(uname -m)"
	echo -e " │ 内核: ${GREEN_FONT_PREFIX}${kern}${FONT_COLOR_SUFFIX}"
	echo -e " │ 网络: 拥塞=${GREEN_FONT_PREFIX}${net_congestion_control}${FONT_COLOR_SUFFIX} 队列=${GREEN_FONT_PREFIX}${net_qdisc}${FONT_COLOR_SUFFIX} Headers=${GREEN_FONT_PREFIX}${headers_status}${FONT_COLOR_SUFFIX}"
	echo -e " │ 资源: 内存=${mem_used}/${mem_total}MB(${mem_pct}%) 磁盘=${disk_info}"

	# conntrack (如果有)
	if [[ -f /proc/sys/net/netfilter/nf_conntrack_count ]]; then
		local ct_count ct_max ct_pct
		ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
		ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
		if [[ -n "$ct_max" && "$ct_max" -gt 0 ]]; then
			ct_pct=$((ct_count * 100 / ct_max))
			echo -e " │ 连接: conntrack=${ct_count}/${ct_max}(${ct_pct}%)"
		fi
	fi

	echo -e " └─────────────────────────────────────────────────────────┘"
	echo -e ""
}

# =================================================
#  主菜单
# =================================================
start_menu() {
	clear
	show_status_panel_brief
	echo -e " TCP加速 一键安装管理脚本 ${RED_FONT_PREFIX}[v${SH_VER}]${FONT_COLOR_SUFFIX}
————————————————————————————————————————————————————————————————
 ———————————————————————————— 内核 —————————————————————————————
 ${GREEN_FONT_PREFIX}1.${FONT_COLOR_SUFFIX} 安装 XanMod 内核(自动选择)   ${GREEN_FONT_PREFIX}2.${FONT_COLOR_SUFFIX} 启用 BBR+FQ 加速
 ${GREEN_FONT_PREFIX}3.${FONT_COLOR_SUFFIX} 删除旧内核
 ———————————————————————————— 优化 —————————————————————————————
 ${GREEN_FONT_PREFIX}4.${FONT_COLOR_SUFFIX} 智能网络优化(自动适配)      ${GREEN_FONT_PREFIX}5.${FONT_COLOR_SUFFIX} 中国大陆换源(测速)
 ${GREEN_FONT_PREFIX}6.${FONT_COLOR_SUFFIX} 海外服务器换源(测速)        ${GREEN_FONT_PREFIX}7.${FONT_COLOR_SUFFIX} 腾讯云NFT转发优化
 ———————————————————————————— 系统 —————————————————————————————
 ${GREEN_FONT_PREFIX}8.${FONT_COLOR_SUFFIX} 安装基础系统包              ${GREEN_FONT_PREFIX}9.${FONT_COLOR_SUFFIX} 系统大版本升级
 ${GREEN_FONT_PREFIX}10.${FONT_COLOR_SUFFIX} 清理日志+定时任务          ${GREEN_FONT_PREFIX}11.${FONT_COLOR_SUFFIX} 安装WARP IPv6
 ${GREEN_FONT_PREFIX}12.${FONT_COLOR_SUFFIX} 添加虚拟内存(Swap)         ${GREEN_FONT_PREFIX}13.${FONT_COLOR_SUFFIX} 设置IPv4优先
 ${GREEN_FONT_PREFIX}14.${FONT_COLOR_SUFFIX} 一键DD系统                 ${GREEN_FONT_PREFIX}0.${FONT_COLOR_SUFFIX} 退出脚本
————————————————————————————————————————————————————————————————"
	echo ""
	read -p " 请输入数字: " num
	num=$(echo "$num" | tr -d '[:space:]')
	case "$num" in
	1) install_xanmod_auto ;;
	2) enable_acceleration "fq" "bbr" ;;
	3) delete_kernel_custom ;;
	4) optimizing_smart ;;
	5) optimizing_cn_network ;;
	6) optimizing_overseas_network ;;
	7) optimizing_nft_forward ;;
	8) install_base_packages ;;
	9) upgrade_system_version ;;
	10) clean_logs_and_schedule ;;
	11) install_warp_ipv6 ;;
	12) setup_swap ;;
	13) set_ipv4_priority ;;
	14) reinstall_system ;;
	0) exit 0 ;;
	*)
		echo -e "${ERROR}: 请输入正确数字"
		sleep 3
		start_menu
		;;
	esac
}

# =================================================
#  入口逻辑
# =================================================

# 帮助信息
show_help() {
	echo "用法: $0 [选项]"
	echo ""
	echo "选项:"
	echo "  --help, -h     显示此帮助信息"
	echo "  xanmod         安装 XanMod 内核"
	echo "  bbr            启用 BBR+FQ"
	echo "  op0            智能网络优化 (自动适配 CN/海外)"
	echo "  op5            中国大陆换源"
	echo "  op6            海外服务器换源"
	echo "  op7            腾讯云 NFT 转发优化"
	echo "  op8            安装基础系统包"
	echo "  op9            系统大版本升级"
	echo "  log            清理日志+定时任务"
	echo "  warp6          安装 WARP IPv6"
	echo "  swap           添加虚拟内存"
	echo "  ipv4prio       设置 IPv4 优先"
	echo "  reinstall      一键DD系统"
	echo ""
	echo "推荐流程: 8 → 1 → 4 → 重启"
	echo "  基础包 → XanMod 内核 → 智能优化 → 重启生效"
}

# 命令行参数解析
if [[ $# -gt 0 ]]; then
	case "$1" in
	--help | -h)
		show_help
		exit 0
		;;
	esac

	check_sys
	check_cn_status
	case "$1" in
	op0)
		optimizing_smart
		exit 0
		;;
	op5)
		optimizing_cn_network
		exit 0
		;;
	op6)
		optimizing_overseas_network
		exit 0
		;;
	op7)
		optimizing_nft_forward
		exit 0
		;;
	op8)
		install_base_packages
		exit 0
		;;
	op9)
		upgrade_system_version
		exit 0
		;;
	xanmod)
		install_xanmod_auto
		exit 0
		;;
	bbr)
		enable_acceleration "fq" "bbr"
		exit 0
		;;
	log)
		clean_logs_and_schedule
		exit 0
		;;
	warp6)
		install_warp_ipv6
		exit 0
		;;
	swap)
		setup_swap
		exit 0
		;;
	ipv4prio)
		set_ipv4_priority
		exit 0
		;;
	reinstall)
		reinstall_system
		exit 0
		;;
	*)
		echo -e "${ERROR} 未知选项: \"$1\"，使用 --help 查看帮助"
		exit 1
		;;
	esac
fi

# 交互式启动
check_sys
check_cn_status

if ! _is_interactive; then
	echo -e "${ERROR} 未指定操作参数，且当前为非交互模式 (管道)。"
	echo -e "${TIP} 管道模式请指定参数，例如: curl ... | bash -s op0"
	echo -e "${TIP} 交互模式请使用: bash <(curl ...)"
	echo -e ""
	show_help
	exit 1
fi

start_menu
