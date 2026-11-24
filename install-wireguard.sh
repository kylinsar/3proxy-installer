#!/usr/bin/env bash
#
# WireGuard 一键安装 / 管理脚本
#
# 与 SOCKS5/HTTP 代理不同，WireGuard 在 IP 层转发数据包：TCP 连接由你自己的设备发起，
# 网站看到的 TCP 指纹与设备的操作系统一致，不会出现"代理转发"特征。
#
# 支持系统：Debian 11+ / Ubuntu 20.04+ / RHEL·Rocky·Alma 8+ / Fedora（需 systemd，内核 5.6+ 或已装 WireGuard 模块）
# 不支持：OpenVZ / LXC 等无法加载内核模块的容器型 VPS
#
# 用法：
#   bash install-wireguard.sh                # 交互式菜单
#   bash install-wireguard.sh <命令>         # 直接执行
#   curl -fsSL <脚本链接> | bash -s <命令>   # 通过管道执行
#
# 命令：
#   install            安装（并创建第一个客户端）
#   check              检查运行状态（有异常时退出码为 1）
#   add <名称>         添加客户端
#   remove <名称>      删除客户端
#   list               列出客户端及最近连接时间
#   show <名称>        显示客户端配置和二维码
#   restart            重启服务
#   uninstall          卸载
#
# 安装参数（环境变量，均可选）：
#   WG_PORT=51820            UDP 端口，默认随机（20000-60000）
#   WG_SUBNET=10.66.66       VPN 内网网段前三段（/24）
#   CLIENT_DNS="1.1.1.1, 8.8.8.8"   客户端使用的 DNS
#   FIRST_CLIENT=phone       第一个客户端的名称

set -euo pipefail

WG_IF="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
CLIENT_DIR="${WG_DIR}/clients"
PARAMS_FILE="${WG_DIR}/params"
SYSCTL_FILE="/etc/sysctl.d/99-wireguard-forward.conf"
SERVICE="wg-quick@${WG_IF}"

WG_PORT="${WG_PORT:-r}"
WG_SUBNET="${WG_SUBNET:-10.66.66}"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1, 8.8.8.8}"
FIRST_CLIENT="${FIRST_CLIENT:-phone}"

# ---------- 输出工具 ----------
info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }

HAS_TTY=0
if { : </dev/tty; } 2>/dev/null; then HAS_TTY=1; fi

ask() {
  local __a=""
  if [[ $HAS_TTY == 1 ]]; then
    read -r -p "$1" __a </dev/tty || true
  fi
  printf -v "$2" '%s' "$__a"
}

require_root() {
  [[ $EUID -eq 0 ]] || error "请使用 root 或 sudo 运行此脚本"
}

require_installed() {
  [[ -f "$WG_CONF" && -f "$PARAMS_FILE" ]] || error "WireGuard 未安装，请先安装"
  # shellcheck disable=SC1090
  source "$PARAMS_FILE"
}

get_public_ip() {
  local ip
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  echo "$ip"
}

random_udp_port() {
  local p listen
  listen="$(ss -lnu 2>/dev/null || netstat -lnu 2>/dev/null || true)"
  while :; do
    p=$(( ((RANDOM << 15) | RANDOM) % 40000 + 20000 ))
    if ! grep -qE ":${p}[[:space:]]" <<<"$listen"; then break; fi
  done
  echo "$p"
}

ago() {
  local s=$1
  if   (( s < 60 ));    then echo "${s} 秒前"
  elif (( s < 3600 ));  then echo "$(( s / 60 )) 分钟前"
  elif (( s < 86400 )); then echo "$(( s / 3600 )) 小时前"
  else                       echo "$(( s / 86400 )) 天前"
  fi
}

# =====================================================================
#                               安装
# =====================================================================
install_pkgs() {
  info "安装 WireGuard 及依赖..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y wireguard-tools iptables curl iproute2
    apt-get install -y qrencode || warn "qrencode 安装失败，将无法显示二维码"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release >/dev/null 2>&1 || true
    dnf install -y wireguard-tools iptables curl iproute
    dnf install -y qrencode || warn "qrencode 安装失败，将无法显示二维码"
  else
    error "不支持的系统，请使用 Debian/Ubuntu/RHEL 系发行版"
  fi
}

check_kernel() {
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ "$virt" == "openvz" || "$virt" == "lxc" ]]; then
    error "检测到 ${virt} 容器型 VPS，无法使用内核版 WireGuard，请更换 KVM 架构的 VPS"
  fi
  modprobe wireguard 2>/dev/null || true
  if ip link add wgtest0 type wireguard 2>/dev/null; then
    ip link del wgtest0
  else
    error "当前内核不支持 WireGuard（需要 5.6+ 内核）。请升级内核或更换系统镜像"
  fi
}

open_firewall_port() {
  local port=$1 fw
  fw="$(ufw status 2>/dev/null || true)"
  if [[ "$fw" == *"Status: active"* ]]; then
    ufw allow "${port}/udp" >/dev/null
    info "已在 ufw 放行 UDP ${port}"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null
    firewall-cmd --permanent --add-masquerade >/dev/null
    firewall-cmd --permanent --zone=trusted --add-interface="$WG_IF" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null
    info "已在 firewalld 放行 UDP ${port} 并开启转发"
  fi
}

close_firewall_port() {
  local port=$1 fw
  fw="$(ufw status 2>/dev/null || true)"
  if [[ "$fw" == *"Status: active"* ]]; then
    ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${port}/udp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=trusted --remove-interface="$WG_IF" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

do_install() {
  require_root
  command -v systemctl >/dev/null 2>&1 || error "未检测到 systemd"
  [[ -f "$WG_CONF" ]] && error "WireGuard 已安装（${WG_CONF} 已存在）。如需重装请先卸载"
  [[ "$WG_SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || error "WG_SUBNET 格式应为三段，如 10.66.66"

  install_pkgs
  check_kernel

  local nic server_ip server_priv server_pub
  nic="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [[ -n "$nic" ]] || error "无法检测出口网卡"
  server_ip="$(get_public_ip)"
  [[ -n "$server_ip" ]] || error "无法获取服务器公网 IPv4"

  if [[ "$WG_PORT" == [rR] ]]; then WG_PORT="$(random_udp_port)"; fi
  [[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT > 0 && WG_PORT <= 65535 )) || error "端口无效：$WG_PORT"

  umask 077
  mkdir -p "$WG_DIR" "$CLIENT_DIR"
  server_priv="$(wg genkey)"
  server_pub="$(wg pubkey <<<"$server_priv")"

  cat >"$WG_CONF" <<EOF
# 由 install-wireguard.sh 生成于 $(date '+%F %T')
[Interface]
Address = ${WG_SUBNET}.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${server_priv}
PostUp = iptables -t nat -A POSTROUTING -s ${WG_SUBNET}.0/24 -o ${nic} -j MASQUERADE; iptables -I FORWARD -i %i -j ACCEPT; iptables -I FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET}.0/24 -o ${nic} -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
EOF

  {
    printf 'SERVER_IP=%q\n'   "$server_ip"
    printf 'SERVER_PUB=%q\n'  "$server_pub"
    printf 'WG_PORT=%q\n'     "$WG_PORT"
    printf 'WG_SUBNET=%q\n'   "$WG_SUBNET"
    printf 'CLIENT_DNS=%q\n'  "$CLIENT_DNS"
    printf 'NIC=%q\n'         "$nic"
  } >"$PARAMS_FILE"

  echo "net.ipv4.ip_forward = 1" >"$SYSCTL_FILE"
  sysctl -q -p "$SYSCTL_FILE"

  open_firewall_port "$WG_PORT"
  systemctl enable --now "$SERVICE"
  sleep 1
  systemctl is-active --quiet "$SERVICE" || {
    journalctl -u "$SERVICE" -n 20 --no-pager >&2 || true
    error "WireGuard 服务启动失败"
  }
  info "WireGuard 已启动：UDP ${WG_PORT}，网卡 ${nic}"

  # 服务器在 NAT 后（家用路由器 / 部分云厂商）时提醒端口转发
  if ! ip -4 addr show 2>/dev/null | grep -q "inet ${server_ip}/"; then
    warn "服务器网卡上没有公网 IP ${server_ip}（处于 NAT 后）：云服务器请在安全组放行 UDP ${WG_PORT}；家用网络请在路由器上转发 UDP ${WG_PORT} 到本机"
  fi

  add_client "$FIRST_CLIENT"
}

# =====================================================================
#                             客户端管理
# =====================================================================
valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || error "客户端名称只能包含字母、数字、_ -，最长 32 位"
}

client_exists() {
  grep -qxF "### BEGIN client $1" "$WG_CONF"
}

reload_wg() {
  if systemctl is-active --quiet "$SERVICE"; then
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")
  fi
}

add_client() {
  require_root
  require_installed
  local name="${1:-}"
  if [[ -z "$name" ]]; then ask "客户端名称（如 phone、laptop）: " name; fi
  [[ -n "$name" ]] || error "名称不能为空"
  valid_name "$name"
  client_exists "$name" && error "客户端 ${name} 已存在"

  local i ip=""
  for i in $(seq 2 254); do
    if ! grep -qE "^AllowedIPs = ${WG_SUBNET//./\\.}\.${i}/32$" "$WG_CONF"; then ip="${WG_SUBNET}.${i}"; break; fi
  done
  [[ -n "$ip" ]] || error "地址池已满"

  umask 077
  local priv pub psk
  priv="$(wg genkey)"
  pub="$(wg pubkey <<<"$priv")"
  psk="$(wg genpsk)"

  cat >>"$WG_CONF" <<EOF

### BEGIN client ${name}
[Peer]
PublicKey = ${pub}
PresharedKey = ${psk}
AllowedIPs = ${ip}/32
### END client ${name}
EOF

  # AllowedIPs 包含 ::/0：让设备的 IPv6 流量也进入隧道（服务器无 IPv6 时会被丢弃），
  # 防止通过 IPv6 泄露真实所在地
  cat >"${CLIENT_DIR}/${name}.conf" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${ip}/32
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${psk}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  reload_wg
  info "已添加客户端 ${name}（${ip}）"
  show_client "$name"
}

remove_client() {
  require_root
  require_installed
  local name="${1:-}" rest
  if [[ -z "$name" ]]; then list_clients; ask "要删除的客户端名称: " name; fi
  [[ -n "$name" ]] || error "名称不能为空"
  client_exists "$name" || error "客户端 ${name} 不存在"
  rest="$(awk -v n="$name" '
    $0 == "### BEGIN client " n { skip = 1 }
    !skip { print }
    $0 == "### END client " n { skip = 0 }' "$WG_CONF")"
  printf '%s\n' "$rest" >"$WG_CONF"
  rm -f "${CLIENT_DIR}/${name}.conf"
  reload_wg
  info "已删除客户端 ${name}"
}

show_client() {
  require_installed
  local name="${1:-}" file
  if [[ -z "$name" ]]; then list_clients; ask "要显示的客户端名称: " name; fi
  file="${CLIENT_DIR}/${name}.conf"
  [[ -f "$file" ]] || error "找不到客户端配置：${file}"
  echo
  echo "========== 客户端 ${name} 配置（${file}）=========="
  cat "$file"
  echo "=================================================="
  if command -v qrencode >/dev/null 2>&1; then
    echo "手机 WireGuard App 扫描下方二维码即可导入："
    qrencode -t ansiutf8 <"$file"
  fi
  echo "电脑端：把上面的配置保存为 ${name}.conf，在 WireGuard 客户端中「导入隧道」"
}

list_clients() {
  require_installed
  local names name pub ip ts hs now st
  names="$(grep -E '^### BEGIN client ' "$WG_CONF" | sed 's/^### BEGIN client //' || true)"
  if [[ -z "$names" ]]; then
    echo "暂无客户端"
    return 0
  fi
  hs="$(wg show "$WG_IF" latest-handshakes 2>/dev/null || true)"
  now="$(date +%s)"
  echo
  printf ' %-20s %-16s %s\n' "名称" "地址" "最近握手"
  while read -r name; do
    pub="$(awk -v n="$name" '$0 == "### BEGIN client " n {f=1} f && $1 == "PublicKey" {print $3; exit}' "$WG_CONF")"
    ip="$(awk -v n="$name" '$0 == "### BEGIN client " n {f=1} f && $1 == "AllowedIPs" {print $3; exit}' "$WG_CONF")"
    ts="$(awk -v k="$pub" '$1 == k {print $2}' <<<"$hs")"
    if [[ -z "$ts" || "$ts" == "0" ]]; then st="从未连接"; else st="$(ago $(( now - ts )))"; fi
    printf ' %-20s %-16s %s\n' "$name" "${ip%/32}" "$st"
  done <<<"$names"
}

# =====================================================================
#                                检查
# =====================================================================
CHECK_FAIL=0
chk_ok()   { echo -e "  \033[32m✓\033[0m $*"; }
chk_bad()  { echo -e "  \033[31m✗\033[0m $*"; CHECK_FAIL=$((CHECK_FAIL + 1)); }
chk_warn() { echo -e "  \033[33m!\033[0m $*"; }

check_status() {
  CHECK_FAIL=0
  echo
  echo "=============== WireGuard 状态检查 ==============="

  if command -v wg >/dev/null 2>&1; then chk_ok "wireguard-tools 已安装"; else chk_bad "wireguard-tools 未安装"; fi

  if [[ -f "$WG_CONF" && -f "$PARAMS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PARAMS_FILE"
    chk_ok "配置文件存在：${WG_CONF}"
  else
    chk_bad "配置文件不存在，WireGuard 未安装"
    echo "================================================="
    return 0
  fi

  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then chk_ok "服务运行中"; else chk_bad "服务未运行"; fi
  if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then chk_ok "已设为开机自启"; else chk_warn "未设为开机自启"; fi

  if ip link show "$WG_IF" >/dev/null 2>&1; then chk_ok "网卡 ${WG_IF} 已启用"; else chk_bad "网卡 ${WG_IF} 不存在"; fi

  local listen
  listen="$(ss -lnu 2>/dev/null || true)"
  if grep -qE ":${WG_PORT}[[:space:]]" <<<"$listen"; then chk_ok "UDP ${WG_PORT} 正在监听"; else chk_bad "UDP ${WG_PORT} 未监听"; fi

  if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]]; then
    chk_ok "IP 转发已开启"
  else
    chk_bad "IP 转发未开启（可执行 sysctl -w net.ipv4.ip_forward=1）"
  fi

  local nat
  nat="$(iptables -t nat -S POSTROUTING 2>/dev/null || true)"
  if grep -q -- "-s ${WG_SUBNET}.0/24 .*MASQUERADE" <<<"$nat"; then
    chk_ok "NAT 转发规则存在"
  else
    chk_bad "缺少 NAT 规则，客户端能连上但无法上网（可尝试重启服务）"
  fi

  local fw
  fw="$(ufw status 2>/dev/null || true)"
  if [[ "$fw" == *"Status: active"* ]]; then
    if grep -qE "^${WG_PORT}/udp[[:space:]].*ALLOW" <<<"$fw"; then chk_ok "ufw 已放行 UDP ${WG_PORT}"; else chk_bad "ufw 未放行 UDP ${WG_PORT}"; fi
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if firewall-cmd --query-port="${WG_PORT}/udp" >/dev/null 2>&1; then chk_ok "firewalld 已放行 UDP ${WG_PORT}"; else chk_bad "firewalld 未放行 UDP ${WG_PORT}"; fi
  else
    chk_ok "系统防火墙未启用（云服务器请确认安全组已放行 UDP ${WG_PORT}）"
  fi

  local cur_ip
  cur_ip="$(get_public_ip)"
  if [[ -z "$cur_ip" ]]; then
    chk_warn "无法获取当前公网 IP"
  elif [[ "$cur_ip" == "$SERVER_IP" ]]; then
    chk_ok "公网 IP 未变化：${cur_ip}"
  else
    chk_bad "公网 IP 已变化（配置中 ${SERVER_IP}，当前 ${cur_ip}），客户端 Endpoint 需要更新"
  fi

  echo "-------------------------------------------------"
  list_clients
  echo "-------------------------------------------------"
  if (( CHECK_FAIL == 0 )); then
    echo -e " 结论：\033[32m一切正常\033[0m"
  else
    echo -e " 结论：\033[31m发现 ${CHECK_FAIL} 项异常\033[0m"
  fi
  echo "================================================="
  return 0
}

# =====================================================================
#                                卸载
# =====================================================================
uninstall() {
  require_root
  local ans=""
  ask "确认卸载 WireGuard？所有客户端配置都会被删除 [y/N] " ans
  if [[ $HAS_TTY == 1 && ! "$ans" =~ ^[Yy]$ ]]; then
    info "已取消"
    return 0
  fi
  if [[ -f "$PARAMS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PARAMS_FILE"
    close_firewall_port "$WG_PORT"
  fi
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -rf "$WG_DIR"
  rm -f "$SYSCTL_FILE"
  info "WireGuard 已卸载（软件包保留，如需删除可执行 apt remove wireguard-tools）"
}

# =====================================================================
#                                菜单
# =====================================================================
status_text() {
  if [[ ! -f "$WG_CONF" ]]; then
    echo -e "\033[33m未安装\033[0m"
  elif systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    echo -e "\033[32m运行中\033[0m"
  else
    echo -e "\033[31m已停止\033[0m"
  fi
}

menu() {
  require_root
  local choice="" _
  while true; do
    echo
    echo "========== WireGuard 管理菜单 =========="
    echo -e " 当前状态：$(status_text)"
    echo "----------------------------------------"
    echo "  1. 安装 WireGuard"
    echo "  2. 检查运行状态"
    echo "  3. 添加客户端"
    echo "  4. 删除客户端"
    echo "  5. 列出客户端"
    echo "  6. 显示客户端配置 / 二维码"
    echo "  7. 重启服务"
    echo "  8. 卸载 WireGuard"
    echo "  0. 退出"
    echo "========================================"
    ask "请输入选项 [0-8]: " choice
    case "$choice" in
      1) do_install ;;
      2) check_status ;;
      3) add_client ;;
      4) remove_client ;;
      5) list_clients ;;
      6) show_client ;;
      7) require_root; systemctl restart "$SERVICE"; info "已重启" ;;
      8) uninstall ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选项：${choice}" ;;
    esac
    ask "按回车键返回菜单..." _
  done
}

usage() {
  echo "用法: $0 [install|check|add <名称>|remove <名称>|list|show <名称>|restart|uninstall]"
  echo "不带参数运行时进入交互式菜单"
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    if [[ $HAS_TTY == 1 ]]; then cmd="menu"; else cmd="install"; fi
  fi
  case "$cmd" in
    menu)           menu ;;
    install)        do_install ;;
    check|status)   check_status; exit $(( CHECK_FAIL > 0 ? 1 : 0 )) ;;
    add)            add_client "${2:-}" ;;
    remove|del)     remove_client "${2:-}" ;;
    list)           list_clients ;;
    show)           show_client "${2:-}" ;;
    restart)        require_root; systemctl restart "$SERVICE"; info "已重启" ;;
    uninstall)      uninstall ;;
    -h|--help|help) usage ;;
    *)              usage; exit 1 ;;
  esac
}

main "$@"
