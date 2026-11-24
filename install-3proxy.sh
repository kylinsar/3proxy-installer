#!/usr/bin/env bash
#
# 3proxy 一键安装脚本（源码编译 + systemd 服务）
#
# 支持系统：Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux / Fedora（需 systemd）
#
# 用法：
#   sudo bash install-3proxy.sh              # 安装（默认）
#   sudo bash install-3proxy.sh uninstall    # 卸载
#
# 可通过环境变量自定义（均为可选）：
#   VERSION=0.9.4          3proxy 版本，默认自动获取 GitHub 最新 release
#   PROXY_USER=myuser      代理用户名，默认 proxyuser
#   PROXY_PASS=secret      代理密码，默认随机生成 16 位
#   SOCKS_PORT=1080        SOCKS5 端口，设为 0 则不启用
#   HTTP_PORT=3128         HTTP/HTTPS 代理端口，设为 0 则不启用
#   FORCE_CONFIG=1         覆盖已存在的 /etc/3proxy/3proxy.cfg
#
# 示例：
#   sudo PROXY_USER=alice PROXY_PASS='S3cret!' SOCKS_PORT=1080 HTTP_PORT=0 bash install-3proxy.sh

set -euo pipefail

# ---------- 默认参数 ----------
VERSION="${VERSION:-}"
FALLBACK_VERSION="0.9.4"
PROXY_USER="${PROXY_USER:-proxyuser}"
PROXY_PASS="${PROXY_PASS:-}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-3128}"
FORCE_CONFIG="${FORCE_CONFIG:-0}"

BIN_PATH="/usr/local/bin/3proxy"
CONF_DIR="/etc/3proxy"
CONF_FILE="${CONF_DIR}/3proxy.cfg"
LOG_DIR="/var/log/3proxy"
SERVICE_FILE="/etc/systemd/system/3proxy.service"
RUN_USER="3proxy"

# ---------- 输出工具 ----------
info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }

# ---------- 前置检查 ----------
check_env() {
  [[ $EUID -eq 0 ]] || error "请使用 root 或 sudo 运行此脚本"
  command -v systemctl >/dev/null 2>&1 || error "未检测到 systemd，本脚本仅支持 systemd 系统"

  for p in "$SOCKS_PORT" "$HTTP_PORT"; do
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 0 && p <= 65535 )) || error "端口无效：$p"
  done
  (( SOCKS_PORT > 0 || HTTP_PORT > 0 )) || error "SOCKS_PORT 和 HTTP_PORT 不能同时为 0"
  (( SOCKS_PORT != HTTP_PORT )) || error "SOCKS_PORT 与 HTTP_PORT 不能相同"

  # 3proxy 配置中用户名/密码以 ':' 分隔，且不能含空白
  [[ "$PROXY_USER" =~ ^[A-Za-z0-9._-]+$ ]] || error "PROXY_USER 只能包含字母、数字、. _ -"
  if [[ -n "$PROXY_PASS" && ( "$PROXY_PASS" == *:* || "$PROXY_PASS" =~ [[:space:]] ) ]]; then
    error "PROXY_PASS 不能包含冒号或空白字符"
  fi
}

# ---------- 安装编译依赖 ----------
install_deps() {
  info "安装编译依赖..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y build-essential curl ca-certificates tar libssl-dev
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y gcc make curl ca-certificates tar openssl-devel
  elif command -v yum >/dev/null 2>&1; then
    yum install -y gcc make curl ca-certificates tar openssl-devel
  else
    error "不支持的包管理器，请手动安装 gcc、make、curl、tar"
  fi
}

# ---------- 确定版本 ----------
resolve_version() {
  if [[ -z "$VERSION" ]]; then
    info "获取 3proxy 最新版本..."
    VERSION="$(curl -fsSL --max-time 15 https://api.github.com/repos/3proxy/3proxy/releases/latest 2>/dev/null \
      | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)"
    if [[ -z "$VERSION" ]]; then
      warn "无法获取最新版本，使用默认版本 ${FALLBACK_VERSION}"
      VERSION="$FALLBACK_VERSION"
    fi
  fi
  info "将安装 3proxy ${VERSION}"
}

# ---------- 下载并编译 ----------
build_3proxy() {
  local workdir
  workdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" EXIT

  local url="https://github.com/3proxy/3proxy/archive/refs/tags/${VERSION}.tar.gz"
  info "下载源码：${url}"
  curl -fL --retry 3 -o "${workdir}/3proxy.tar.gz" "$url" || error "下载失败，请检查版本号或网络"

  tar -xzf "${workdir}/3proxy.tar.gz" -C "$workdir"
  local srcdir
  srcdir="$(find "$workdir" -mindepth 1 -maxdepth 1 -type d -name '3proxy*' | head -n1)"
  [[ -n "$srcdir" ]] || error "解压后未找到源码目录"

  info "编译中（可能需要一两分钟）..."
  # 主程序先于插件编译；插件缺少可选依赖时编译失败不影响主程序
  if ! make -C "$srcdir" -f Makefile.Linux -j"$(nproc)" >"${workdir}/build.log" 2>&1; then
    warn "部分组件（通常是可选插件）编译失败，日志见下方末尾："
    tail -n 20 "${workdir}/build.log" >&2 || true
  fi

  local built="${srcdir}/bin/3proxy"
  [[ -x "$built" ]] || error "编译失败：未生成 3proxy 可执行文件"

  # 若服务正在运行，先停止，避免 "Text file busy"
  systemctl stop 3proxy 2>/dev/null || true
  install -m 0755 "$built" "$BIN_PATH"
  info "已安装可执行文件：${BIN_PATH}"
}

# ---------- 创建运行用户与目录 ----------
setup_user_dirs() {
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    local nologin
    nologin="$(command -v nologin || echo /sbin/nologin)"
    useradd --system --no-create-home --shell "$nologin" "$RUN_USER"
    info "已创建系统用户：${RUN_USER}"
  fi
  mkdir -p "$CONF_DIR" "$LOG_DIR"
  chown "$RUN_USER":"$RUN_USER" "$LOG_DIR"
  chmod 750 "$LOG_DIR"
}

# ---------- 生成配置文件 ----------
write_config() {
  if [[ -f "$CONF_FILE" && "$FORCE_CONFIG" != "1" ]]; then
    warn "配置文件已存在，保留原配置：${CONF_FILE}（如需覆盖请设置 FORCE_CONFIG=1）"
    CONFIG_KEPT=1
    return
  fi
  CONFIG_KEPT=0

  if [[ -z "$PROXY_PASS" ]]; then
    PROXY_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  fi

  [[ -f "$CONF_FILE" ]] && cp -a "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"

  {
    echo "# 由 install-3proxy.sh 生成于 $(date '+%F %T')"
    echo "nserver 1.1.1.1"
    echo "nserver 8.8.8.8"
    echo "nscache 65536"
    echo "timeouts 1 5 30 60 180 1800 15 60"
    echo ""
    echo "log ${LOG_DIR}/3proxy.log D"
    echo 'logformat "L%Y-%m-%d %H:%M:%S %N.%p %E %U %C:%c %R:%r %O %I %h %T"'
    echo "rotate 30"
    echo ""
    echo "users ${PROXY_USER}:CL:${PROXY_PASS}"
    echo "auth strong"
    echo "allow ${PROXY_USER}"
    echo ""
    (( HTTP_PORT  > 0 )) && echo "proxy -p${HTTP_PORT}"
    (( SOCKS_PORT > 0 )) && echo "socks -p${SOCKS_PORT}"
    true
  } >"$CONF_FILE"

  # 配置中含明文密码，仅允许 root 与运行用户读取
  chown root:"$RUN_USER" "$CONF_FILE"
  chmod 640 "$CONF_FILE"
  info "已生成配置文件：${CONF_FILE}"
}

# ---------- systemd 服务 ----------
write_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=3proxy tiny proxy server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
ExecStart=${BIN_PATH} ${CONF_FILE}
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
# 允许以非 root 用户监听 1024 以下端口
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now 3proxy
  sleep 1
  systemctl is-active --quiet 3proxy || {
    journalctl -u 3proxy -n 20 --no-pager >&2 || true
    error "3proxy 服务启动失败"
  }
  info "3proxy 服务已启动并设为开机自启"
}

# ---------- 防火墙放行 ----------
open_firewall() {
  [[ "${CONFIG_KEPT:-0}" == "1" ]] && return  # 保留旧配置时不确定端口，跳过
  local ports=()
  (( SOCKS_PORT > 0 )) && ports+=("$SOCKS_PORT")
  (( HTTP_PORT  > 0 )) && ports+=("$HTTP_PORT")

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "${ports[@]}"; do ufw allow "${p}/tcp" >/dev/null; done
    info "已在 ufw 放行端口：${ports[*]}"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in "${ports[@]}"; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null; done
    firewall-cmd --reload >/dev/null
    info "已在 firewalld 放行端口：${ports[*]}"
  else
    info "未检测到启用中的 ufw/firewalld，跳过防火墙配置（云服务器请记得在安全组放行端口）"
  fi
}

# ---------- 安装结果 ----------
print_summary() {
  local ip
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo '<服务器IP>')"

  echo
  echo "================ 3proxy 安装完成 ================"
  echo " 版本      : ${VERSION}"
  echo " 配置文件  : ${CONF_FILE}"
  echo " 日志目录  : ${LOG_DIR}"
  echo " 服务管理  : systemctl {start|stop|restart|status} 3proxy"
  if [[ "${CONFIG_KEPT:-0}" == "1" ]]; then
    echo " （沿用已有配置，账号与端口请查看 ${CONF_FILE}）"
  else
    echo " 用户名    : ${PROXY_USER}"
    echo " 密码      : ${PROXY_PASS}"
    (( SOCKS_PORT > 0 )) && echo " SOCKS5    : socks5://${PROXY_USER}:${PROXY_PASS}@${ip}:${SOCKS_PORT}"
    (( HTTP_PORT  > 0 )) && echo " HTTP      : http://${PROXY_USER}:${PROXY_PASS}@${ip}:${HTTP_PORT}"
    echo
    echo " 测试命令："
    (( SOCKS_PORT > 0 )) && echo "   curl -x socks5h://${PROXY_USER}:${PROXY_PASS}@${ip}:${SOCKS_PORT} https://ifconfig.me"
    (( HTTP_PORT  > 0 )) && echo "   curl -x http://${PROXY_USER}:${PROXY_PASS}@${ip}:${HTTP_PORT} https://ifconfig.me"
  fi
  echo "================================================="
}

# ---------- 卸载 ----------
uninstall() {
  [[ $EUID -eq 0 ]] || error "请使用 root 或 sudo 运行此脚本"
  info "卸载 3proxy..."
  systemctl disable --now 3proxy 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$BIN_PATH"
  systemctl daemon-reload 2>/dev/null || true
  read -r -p "是否同时删除配置 ${CONF_DIR} 和日志 ${LOG_DIR}？[y/N] " ans || ans=""
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    rm -rf "$CONF_DIR" "$LOG_DIR"
    userdel "$RUN_USER" 2>/dev/null || true
    info "已删除配置、日志和运行用户"
  fi
  info "卸载完成"
}

main() {
  case "${1:-install}" in
    install)
      check_env
      install_deps
      resolve_version
      build_3proxy
      setup_user_dirs
      write_config
      write_service
      open_firewall
      print_summary
      ;;
    uninstall)
      uninstall
      ;;
    *)
      echo "用法: $0 [install|uninstall]"
      exit 1
      ;;
  esac
}

main "$@"
