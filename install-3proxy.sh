#!/usr/bin/env bash
#
# 3proxy 一键安装 / 管理脚本（源码编译 + systemd 服务）
#
# 支持系统：Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux / Fedora（需 systemd）
#
# 用法：
#   bash install-3proxy.sh              # 交互式菜单
#   bash install-3proxy.sh <命令>       # 直接执行某个命令
#
# 命令：
#   install     安装 / 重装
#   check       检查运行状态（有异常时退出码为 1）
#   info        查看账号与连接信息
#   port [S] [H] 修改端口：S=SOCKS5 端口，H=HTTP 端口（r 随机，0 关闭，不填则交互询问）
#   start | stop | restart
#   log         查看日志
#   uninstall   卸载
#
# 通过 curl 管道运行时，用 "bash -s <命令>" 传命令，例如：
#   curl -fsSL <脚本链接> | bash              # 菜单
#   curl -fsSL <脚本链接> | bash -s check     # 直接检查
#
# 安装参数可通过环境变量指定（均为可选）：
#   VERSION=0.9.4          3proxy 版本，默认自动获取 GitHub 最新 release
#   PROXY_USER=myuser      代理用户名，默认 proxyuser
#   PROXY_PASS=secret      代理密码，默认随机生成 16 位
#   SOCKS_PORT=23456       SOCKS5 端口，默认随机（20000-60000），设为 0 则不启用
#   HTTP_PORT=34567        HTTP/HTTPS 代理端口，默认随机，设为 0 则不启用
#   FORCE_CONFIG=1         覆盖已存在的 /etc/3proxy/3proxy.cfg

set -euo pipefail

# ---------- 默认参数 ----------
VERSION="${VERSION:-}"
FALLBACK_VERSION="0.9.4"
PROXY_USER="${PROXY_USER:-proxyuser}"
PROXY_PASS="${PROXY_PASS:-}"
# 默认使用随机端口（r），避开 1080/3128 等常被服务商封禁的代理端口
SOCKS_PORT="${SOCKS_PORT:-r}"
HTTP_PORT="${HTTP_PORT:-r}"
FORCE_CONFIG="${FORCE_CONFIG:-0}"

BIN_PATH="/usr/local/bin/3proxy"
CONF_DIR="/etc/3proxy"
CONF_FILE="${CONF_DIR}/3proxy.cfg"
VERSION_FILE="${CONF_DIR}/.version"
LOG_DIR="/var/log/3proxy"
SERVICE_FILE="/etc/systemd/system/3proxy.service"
RUN_USER="3proxy"

# ---------- 输出工具 ----------
info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }

# 是否有可交互的终端（curl | bash 时 stdin 是管道，需从 /dev/tty 读取）
HAS_TTY=0
if { : </dev/tty; } 2>/dev/null; then HAS_TTY=1; fi

# ask "提示" 变量名 —— 从终端读取一行输入，无终端时返回空
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

# ---------- 读取现有配置 ----------
# 设置 CFG_USER / CFG_PASS / CFG_HTTP / CFG_SOCKS，配置不存在时返回 1
read_config() {
  CFG_USER=""; CFG_PASS=""; CFG_HTTP=""; CFG_SOCKS=""
  [[ -f "$CONF_FILE" ]] || return 1
  local line
  line="$(grep -m1 -E '^[[:space:]]*users[[:space:]]' "$CONF_FILE" | awk '{print $2}' || true)"
  if [[ -n "$line" ]]; then
    CFG_USER="${line%%:*}"
    CFG_PASS="${line##*:}"
  fi
  line="$(grep -m1 -E '^[[:space:]]*proxy([[:space:]]|$)' "$CONF_FILE" || true)"
  if [[ -n "$line" ]]; then
    CFG_HTTP="$(grep -oE -- '-p[0-9]+' <<<"$line" | head -n1 | cut -c3- || true)"
    CFG_HTTP="${CFG_HTTP:-3128}"
  fi
  line="$(grep -m1 -E '^[[:space:]]*socks([[:space:]]|$)' "$CONF_FILE" || true)"
  if [[ -n "$line" ]]; then
    CFG_SOCKS="$(grep -oE -- '-p[0-9]+' <<<"$line" | head -n1 | cut -c3- || true)"
    CFG_SOCKS="${CFG_SOCKS:-1080}"
  fi
  return 0
}

PUBLIC_IP=""
get_ip() {
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="<服务器IP>"
  fi
  echo "$PUBLIC_IP"
}

# =====================================================================
#                               安装
# =====================================================================
check_env() {
  require_root
  command -v systemctl >/dev/null 2>&1 || error "未检测到 systemd，本脚本仅支持 systemd 系统"

  # r = 随机端口
  if [[ "$SOCKS_PORT" == [rR] ]]; then SOCKS_PORT="$(random_port)"; fi
  if [[ "$HTTP_PORT" == [rR] ]]; then
    HTTP_PORT="$(random_port)"
    while [[ "$HTTP_PORT" == "$SOCKS_PORT" ]]; do HTTP_PORT="$(random_port)"; done
  fi

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
  echo "$VERSION" >"$VERSION_FILE"
}

write_config() {
  if [[ -f "$CONF_FILE" && "$FORCE_CONFIG" != "1" ]]; then
    warn "配置文件已存在，保留原配置：${CONF_FILE}（如需覆盖请设置 FORCE_CONFIG=1）"
    return
  fi

  if [[ -z "$PROXY_PASS" ]]; then
    PROXY_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  fi

  if [[ -f "$CONF_FILE" ]]; then
    cp -a "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi

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
    if (( HTTP_PORT  > 0 )); then echo "proxy -p${HTTP_PORT}"; fi
    if (( SOCKS_PORT > 0 )); then echo "socks -p${SOCKS_PORT}"; fi
  } >"$CONF_FILE"

  # 配置中含明文密码，仅允许 root 与运行用户读取
  chown root:"$RUN_USER" "$CONF_FILE"
  chmod 640 "$CONF_FILE"
  info "已生成配置文件：${CONF_FILE}"
}

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

open_firewall() {
  read_config || return 0
  local ports=() p fw
  if [[ -n "$CFG_SOCKS" ]]; then ports+=("$CFG_SOCKS"); fi
  if [[ -n "$CFG_HTTP"  ]]; then ports+=("$CFG_HTTP");  fi
  (( ${#ports[@]} > 0 )) || return 0

  fw="$(ufw status 2>/dev/null || true)"
  if [[ "$fw" == *"Status: active"* ]]; then
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

do_install() {
  check_env
  install_deps
  resolve_version
  build_3proxy
  setup_user_dirs
  write_config
  write_service
  open_firewall
  echo
  info "安装完成！"
  show_info
}

# 菜单中的安装：交互式询问参数
menu_install() {
  local v=""
  if [[ -f "$CONF_FILE" ]]; then
    ask "检测到已有配置，是否重新生成（会覆盖账号和端口）？[y/N] " v
    if [[ "$v" =~ ^[Yy]$ ]]; then FORCE_CONFIG=1; fi
  fi
  if [[ ! -f "$CONF_FILE" || "$FORCE_CONFIG" == "1" ]]; then
    ask "代理用户名 [${PROXY_USER}]: " v;              if [[ -n "$v" ]]; then PROXY_USER="$v"; fi
    ask "代理密码（留空随机生成）: " v;                if [[ -n "$v" ]]; then PROXY_PASS="$v"; fi
    ask "SOCKS5 端口（回车随机，0 不启用）: " v; SOCKS_PORT="${v:-r}"
    ask "HTTP 端口（回车随机，0 不启用）: " v;   HTTP_PORT="${v:-r}"
  fi
  do_install
}

# =====================================================================
#                              信息与检查
# =====================================================================
show_info() {
  if ! read_config; then
    warn "未找到配置文件 ${CONF_FILE}，请先安装"
    return 0
  fi
  local ip
  ip="$(get_ip)"
  echo
  echo "================ 3proxy 连接信息 ================"
  echo " 版本      : $(cat "$VERSION_FILE" 2>/dev/null || echo 未知)"
  echo " 配置文件  : ${CONF_FILE}"
  echo " 日志目录  : ${LOG_DIR}"
  echo " 用户名    : ${CFG_USER}"
  echo " 密码      : ${CFG_PASS}"
  if [[ -n "$CFG_SOCKS" ]]; then echo " SOCKS5    : socks5://${CFG_USER}:${CFG_PASS}@${ip}:${CFG_SOCKS}"; fi
  if [[ -n "$CFG_HTTP"  ]]; then echo " HTTP      : http://${CFG_USER}:${CFG_PASS}@${ip}:${CFG_HTTP}"; fi
  echo "================================================="
}

CHECK_FAIL=0
chk_ok()   { echo -e "  \033[32m✓\033[0m $*"; }
chk_bad()  { echo -e "  \033[31m✗\033[0m $*"; CHECK_FAIL=$((CHECK_FAIL + 1)); }
chk_warn() { echo -e "  \033[33m!\033[0m $*"; }

check_status() {
  CHECK_FAIL=0
  echo
  echo "================ 3proxy 状态检查 ================"

  # 1. 程序
  if [[ -x "$BIN_PATH" ]]; then
    chk_ok "程序已安装：${BIN_PATH}（版本 $(cat "$VERSION_FILE" 2>/dev/null || echo 未知)）"
  else
    chk_bad "程序未安装：${BIN_PATH} 不存在"
  fi

  # 2. 配置
  if read_config; then
    chk_ok "配置文件存在：${CONF_FILE}"
    if [[ -z "$CFG_HTTP" && -z "$CFG_SOCKS" ]]; then
      chk_bad "配置中没有 proxy / socks 监听项"
    fi
  else
    chk_bad "配置文件不存在：${CONF_FILE}"
  fi

  # 3. 服务
  if systemctl is-active --quiet 3proxy 2>/dev/null; then
    local since
    since="$(systemctl show 3proxy -p ActiveEnterTimestamp --value 2>/dev/null || true)"
    chk_ok "服务运行中（启动于 ${since:-未知}）"
  else
    chk_bad "服务未运行（$(systemctl is-active 3proxy 2>/dev/null || true)）"
  fi
  if systemctl is-enabled --quiet 3proxy 2>/dev/null; then
    chk_ok "已设为开机自启"
  else
    chk_warn "未设为开机自启（可执行 systemctl enable 3proxy）"
  fi

  # 4. 端口监听
  local listen p name
  listen="$(ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null || true)"
  for name in SOCKS5 HTTP; do
    if [[ $name == SOCKS5 ]]; then p="${CFG_SOCKS:-}"; else p="${CFG_HTTP:-}"; fi
    [[ -n "$p" ]] || continue
    if grep -qE ":${p}[[:space:]]" <<<"$listen"; then
      chk_ok "${name} 端口 ${p} 正在监听"
    else
      chk_bad "${name} 端口 ${p} 未监听"
    fi
  done

  # 5. 本机代理连通性
  if [[ -n "${CFG_USER:-}" ]]; then
    local out
    for name in SOCKS5 HTTP; do
      if [[ $name == SOCKS5 ]]; then
        p="${CFG_SOCKS:-}"; [[ -n "$p" ]] || continue
        out="$(curl -sS --max-time 10 -x "socks5h://127.0.0.1:${p}" -U "${CFG_USER}:${CFG_PASS}" https://api.ipify.org 2>&1 || echo "__FAIL__ $?")"
      else
        p="${CFG_HTTP:-}"; [[ -n "$p" ]] || continue
        out="$(curl -sS --max-time 10 -x "http://127.0.0.1:${p}" -U "${CFG_USER}:${CFG_PASS}" https://api.ipify.org 2>&1 || echo "__FAIL__ $?")"
      fi
      if [[ "$out" == *__FAIL__* ]]; then
        chk_bad "${name} 代理测试失败：$(head -n1 <<<"$out")"
      else
        chk_ok "${name} 代理可用，出口 IP：${out}"
      fi
    done
  fi

  # 6. 防火墙
  local fw ports=()
  if [[ -n "${CFG_SOCKS:-}" ]]; then ports+=("$CFG_SOCKS"); fi
  if [[ -n "${CFG_HTTP:-}"  ]]; then ports+=("$CFG_HTTP");  fi
  fw="$(ufw status 2>/dev/null || true)"
  if [[ "$fw" == *"Status: active"* ]]; then
    for p in ${ports[@]+"${ports[@]}"}; do
      if grep -qE "^${p}(/tcp)?[[:space:]].*ALLOW" <<<"$fw"; then
        chk_ok "ufw 已放行端口 ${p}"
      else
        chk_bad "ufw 未放行端口 ${p}（可执行 ufw allow ${p}/tcp）"
      fi
    done
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in ${ports[@]+"${ports[@]}"}; do
      if firewall-cmd --query-port="${p}/tcp" >/dev/null 2>&1; then
        chk_ok "firewalld 已放行端口 ${p}"
      else
        chk_bad "firewalld 未放行端口 ${p}"
      fi
    done
  else
    chk_ok "系统防火墙未启用（云服务器请确认安全组已放行端口 ${ports[*]:-}）"
  fi

  # 7. 日志
  local latest
  latest="$(ls -t "${LOG_DIR}"/3proxy.log* 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest" ]]; then
    chk_ok "最新访问日志：${latest}（$(wc -l <"$latest" | tr -d ' ') 条记录）"
  else
    chk_warn "暂无访问日志（还没有人使用过代理时属于正常）"
  fi

  echo "-------------------------------------------------"
  if (( CHECK_FAIL == 0 )); then
    echo -e " 结论：\033[32m一切正常\033[0m"
  else
    echo -e " 结论：\033[31m发现 ${CHECK_FAIL} 项异常\033[0m"
    if ! systemctl is-active --quiet 3proxy 2>/dev/null && [[ -x "$BIN_PATH" ]]; then
      echo " 最近的服务日志："
      journalctl -u 3proxy -n 10 --no-pager 2>/dev/null | sed 's/^/   /' || true
    fi
  fi
  echo "================================================="
  return 0
}

show_log() {
  echo "------ 服务日志（最近 30 行）------"
  journalctl -u 3proxy -n 30 --no-pager 2>/dev/null || true
  local latest
  latest="$(ls -t "${LOG_DIR}"/3proxy.log* 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest" ]]; then
    echo
    echo "------ 访问日志 ${latest}（最近 20 行）------"
    tail -n 20 "$latest"
  fi
}

# ---------- 修改端口 ----------
random_port() {
  local p listen
  listen="$(ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null || true)"
  while :; do
    p=$(( ((RANDOM << 15) | RANDOM) % 40000 + 20000 ))
    if ! grep -qE ":${p}[[:space:]]" <<<"$listen"; then break; fi
  done
  echo "$p"
}

# change_ports [新SOCKS端口] [新HTTP端口]；不传参数时交互式询问
# 端口值：数字 = 新端口，r = 随机，0 = 关闭，留空 = 保持不变
change_ports() {
  require_root
  read_config || error "未找到配置文件 ${CONF_FILE}，请先安装"
  local new_socks="${1:-}" new_http="${2:-}" p listen backup
  if [[ -z "$new_socks" && -z "$new_http" ]]; then
    echo "当前端口：SOCKS5=${CFG_SOCKS:-未启用}  HTTP=${CFG_HTTP:-未启用}"
    ask "新的 SOCKS5 端口（回车保持不变，r 随机，0 关闭）: " new_socks
    ask "新的 HTTP 端口（回车保持不变，r 随机，0 关闭）: " new_http
  fi
  [[ -n "$new_socks" ]] || new_socks="${CFG_SOCKS:-0}"
  [[ -n "$new_http"  ]] || new_http="${CFG_HTTP:-0}"
  if [[ "$new_socks" == [rR] ]]; then new_socks="$(random_port)"; fi
  if [[ "$new_http"  == [rR] ]]; then new_http="$(random_port)"; fi

  for p in "$new_socks" "$new_http"; do
    [[ "$p" =~ ^[0-9]+$ ]] && (( p <= 65535 )) || error "端口无效：$p"
  done
  (( new_socks > 0 || new_http > 0 )) || error "SOCKS5 和 HTTP 不能同时关闭"
  (( new_socks != new_http )) || error "SOCKS5 与 HTTP 端口不能相同"

  listen="$(ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null || true)"
  for p in "$new_socks" "$new_http"; do
    (( p > 0 )) || continue
    [[ "$p" == "${CFG_SOCKS:-}" || "$p" == "${CFG_HTTP:-}" ]] && continue
    if grep -qE ":${p}[[:space:]]" <<<"$listen"; then
      error "端口 ${p} 已被其他程序占用，请换一个"
    fi
  done

  if [[ "$new_socks" == "${CFG_SOCKS:-0}" && "$new_http" == "${CFG_HTTP:-0}" ]]; then
    info "端口没有变化"
    return 0
  fi

  backup="${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$CONF_FILE" "$backup"
  local rest
  rest="$(grep -vE '^[[:space:]]*(proxy|socks)([[:space:]]|$)' "$CONF_FILE" || true)"
  printf '%s\n' "$rest" >"$CONF_FILE"
  if (( new_http  > 0 )); then echo "proxy -p${new_http}"  >>"$CONF_FILE"; fi
  if (( new_socks > 0 )); then echo "socks -p${new_socks}" >>"$CONF_FILE"; fi
  chown root:"$RUN_USER" "$CONF_FILE"
  chmod 640 "$CONF_FILE"

  systemctl restart 3proxy
  sleep 1
  if ! systemctl is-active --quiet 3proxy; then
    journalctl -u 3proxy -n 10 --no-pager >&2 || true
    cp -a "$backup" "$CONF_FILE"
    systemctl restart 3proxy || true
    error "使用新端口启动失败，已恢复原配置"
  fi
  info "端口已修改：SOCKS5=$( (( new_socks > 0 )) && echo "$new_socks" || echo 关闭)  HTTP=$( (( new_http > 0 )) && echo "$new_http" || echo 关闭)"
  open_firewall
  show_info
  warn "云服务器请记得在安全组放行新端口，并同步修改客户端设置"
}

service_ctl() {
  require_root
  [[ -f "$SERVICE_FILE" ]] || error "3proxy 未安装"
  systemctl "$1" 3proxy
  sleep 1
  if systemctl is-active --quiet 3proxy; then
    info "3proxy 当前状态：运行中"
  else
    info "3proxy 当前状态：已停止"
  fi
}

# =====================================================================
#                               卸载
# =====================================================================
uninstall() {
  require_root
  local ans=""
  ask "确认卸载 3proxy？[y/N] " ans
  if [[ $HAS_TTY == 1 && ! "$ans" =~ ^[Yy]$ ]]; then
    info "已取消"
    return 0
  fi
  info "卸载 3proxy..."
  systemctl disable --now 3proxy 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$BIN_PATH"
  systemctl daemon-reload 2>/dev/null || true
  ask "是否同时删除配置 ${CONF_DIR} 和日志 ${LOG_DIR}？[y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    rm -rf "$CONF_DIR" "$LOG_DIR"
    userdel "$RUN_USER" 2>/dev/null || true
    info "已删除配置、日志和运行用户"
  fi
  info "卸载完成"
}

# =====================================================================
#                               菜单
# =====================================================================
status_text() {
  if [[ ! -x "$BIN_PATH" ]]; then
    echo -e "\033[33m未安装\033[0m"
  elif systemctl is-active --quiet 3proxy 2>/dev/null; then
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
    echo "=========== 3proxy 管理菜单 ==========="
    echo -e " 当前状态：$(status_text)"
    echo "---------------------------------------"
    echo "  1. 安装 / 重装 3proxy"
    echo "  2. 检查运行状态"
    echo "  3. 查看账号与连接信息"
    echo "  4. 修改端口"
    echo "  5. 启动服务"
    echo "  6. 停止服务"
    echo "  7. 重启服务"
    echo "  8. 查看日志"
    echo "  9. 卸载 3proxy"
    echo "  0. 退出"
    echo "======================================="
    ask "请输入选项 [0-9]: " choice
    case "$choice" in
      1) menu_install ;;
      2) check_status ;;
      3) show_info ;;
      4) change_ports ;;
      5) service_ctl start ;;
      6) service_ctl stop ;;
      7) service_ctl restart ;;
      8) show_log ;;
      9) uninstall ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选项：${choice}" ;;
    esac
    ask "按回车键返回菜单..." _
  done
}

usage() {
  echo "用法: $0 [install|check|info|port|start|stop|restart|log|uninstall]"
  echo "      $0 port <SOCKS5端口> <HTTP端口>   # 端口填 r 随机、0 关闭"
  echo "不带参数运行时进入交互式菜单"
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    # 无终端（如自动化环境）时保持旧行为：直接安装
    if [[ $HAS_TTY == 1 ]]; then cmd="menu"; else cmd="install"; fi
  fi

  case "$cmd" in
    menu)            menu ;;
    install)         do_install ;;
    check|status)    check_status; exit $(( CHECK_FAIL > 0 ? 1 : 0 )) ;;
    info)            show_info ;;
    port|ports)      change_ports "${2:-}" "${3:-}" ;;
    start|stop|restart) service_ctl "$cmd" ;;
    log|logs)        show_log ;;
    uninstall)       uninstall ;;
    -h|--help|help)  usage ;;
    *)               usage; exit 1 ;;
  esac
}

main "$@"
