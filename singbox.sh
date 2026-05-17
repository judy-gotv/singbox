#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
#  sing-box 一体化管理脚本
#  功能: 安装 / 卸载 / 服务管理 / 代理测试 / 配置查看
# ══════════════════════════════════════════════════════════════════════
set -uo pipefail

# ── 颜色 ──────────────────────────────────────────────────────────────
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'  B='\033[0;34m'
C='\033[0;36m'  M='\033[0;35m'  W='\033[1;37m'  DIM='\033[2m'
BOLD='\033[1m'  NC='\033[0m'

# ── 常量 ──────────────────────────────────────────────────────────────
# 兼容 bash <(curl ...) 方式运行：$0 为 /dev/stdin 时自动下载到临时文件
if [[ "$0" == "/dev/stdin" || "$0" == "bash" ]]; then
  _TMP_SELF=$(mktemp /tmp/singbox_XXXXXX.sh)
  curl -sL "https://raw.githubusercontent.com/judy-gotv/singbox/main/singbox.sh" -o "$_TMP_SELF"
  chmod +x "$_TMP_SELF"
  SCRIPT_PATH="$_TMP_SELF"
else
  SCRIPT_PATH="$(realpath "$0")"
fi
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
LOG_DIR="/var/log/sing-box"
LOG_FILE="${LOG_DIR}/sing-box.log"
SERVICE_NAME="sing-box"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ALIAS_MARKER="/etc/profile.d/singbox-cmd.sh"
ALIAS_SKIP_FLAG="/etc/sing-box/.alias_skipped"
CMD_LOWER="/usr/local/bin/x"
CMD_UPPER="/usr/local/bin/X"

# ══════════════════════════════════════════════════════════════════════
#  ██  配置生成 / 安全工具
# ══════════════════════════════════════════════════════════════════════
# 用 jq 安全生成 base config（入站 SOCKS5 + HTTP），避免拼接注入
_gen_base_config() {
  local s5p=$1 htp=$2 s5u=$3 s5pw=$4 htu=$5 htpw=$6 listen=$7 out=$8
  jq -n \
    --arg log_out "$LOG_FILE" \
    --arg listen  "$listen" \
    --argjson s5p "$s5p" --argjson htp "$htp" \
    --arg s5u "$s5u" --arg s5pw "$s5pw" \
    --arg htu "$htu" --arg htpw "$htpw" \
    '{
      log: { level:"info", output:$log_out, timestamp:true },
      inbounds: [
        { type:"socks", tag:"socks5-in",
          listen:$listen, listen_port:$s5p,
          users:[{username:$s5u, password:$s5pw}],
          sniff:true, sniff_override_destination:false, udp:true },
        { type:"http", tag:"http-in",
          listen:$listen, listen_port:$htp,
          users:[{username:$htu, password:$htpw}],
          sniff:true, sniff_override_destination:false }
      ],
      outbounds: [
        { type:"direct", tag:"direct" },
        { type:"block",  tag:"block"  }
      ],
      route: {
        rules:[{ geoip:["private"], outbound:"direct" }],
        final:"direct", auto_detect_interface:true
      }
    }' > "$out"
}

# 收紧含密码文件的权限
_secure_perms() {
  [[ -d "$CONFIG_DIR" ]]  && chmod 700 "$CONFIG_DIR"
  [[ -f "$CONFIG_FILE" ]] && chmod 600 "$CONFIG_FILE"
  [[ -d "$LOG_DIR" ]]     && chmod 750 "$LOG_DIR"
  [[ -f "$LOG_FILE" ]]    && chmod 640 "$LOG_FILE"
}

# 安装/修改配置前备份
_backup_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  local bak="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -p "$CONFIG_FILE" "$bak"
  echo "$bak"
}

# 防火墙：放行端口
_fw_open() {
  local port=$1 proto=$2
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    ufw allow "${port}/${proto}" >/dev/null 2>&1
  elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
    _FW_FD_DIRTY=1
  fi
}

# 防火墙：撤销端口
_fw_close() {
  local port=$1 proto=$2
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    ufw delete allow "${port}/${proto}" >/dev/null 2>&1
  elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1
    _FW_FD_DIRTY=1
  fi
}

_fw_reload() {
  command -v firewall-cmd &>/dev/null && [[ "${_FW_FD_DIRTY:-0}" == "1" ]] && \
    firewall-cmd --reload >/dev/null 2>&1
  _FW_FD_DIRTY=0
}

# ══════════════════════════════════════════════════════════════════════
#  基础工具
# ══════════════════════════════════════════════════════════════════════
ok()    { echo -e "  ${G}✓${NC}  $*"; }
fail()  { echo -e "  ${R}✗${NC}  $*"; }
info()  { echo -e "  ${C}›${NC}  $*"; }
warn()  { echo -e "  ${Y}⚠${NC}  $*"; }
die()   { echo -e "\n  ${R}✗  错误: $*${NC}\n"; exit 1; }
sep()   { echo -e "  ${DIM}$(printf '─%.0s' {1..54})${NC}"; }
blank() { echo ""; }

need_root() {
  [[ $EUID -ne 0 ]] && die "此操作需要 root 权限，请使用: sudo bash $0"
}

pause() {
  blank
  read -rp "  按回车键返回菜单..." _
}

# ── Spinner ────────────────────────────────────────────────────────────
_SPIN_PID=""
spin_start() {
  local msg="$1"
  ( local f=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
    while true; do
      printf "\r  ${C}%s${NC}  %s  " "${f[$((i%10))]}" "$msg"; ((i++)); sleep 0.08
    done ) &
  _SPIN_PID=$!
}
spin_stop() {
  [[ -n "$_SPIN_PID" ]] && { kill "$_SPIN_PID" 2>/dev/null; wait "$_SPIN_PID" 2>/dev/null || true; }
  _SPIN_PID=""; printf "\r\033[K"
}

# ══════════════════════════════════════════════════════════════════════
#  Banner & 状态栏
# ══════════════════════════════════════════════════════════════════════
print_banner() {
  clear
  echo -e "${C}${BOLD}"
  echo '        _____ _____ _   _  _____     ____   ____  _  __'
  echo '       / ____|_   _| \ | |/ ____|   |  _ \ / __ \| |/ /'
  echo '      | (___   | | |  \| | |  __ __ | |_) | |  | |   / '
  echo '       \___ \  | | | . ` | | |_ |__||  _ <| |  | |  <  '
  echo '       ____) |_| |_| |\  | |__| |   | |_) | |__| |   \ '
  echo '      |_____/|_____|_| \_|\_____|   |____/ \____/|_|\_\'
  echo -e "${NC}"
  echo -e "      ${DIM}SOCKS5 + HTTP 一键代理  ·  管理脚本  v1.0${NC}"
  blank
}

status_bar() {
  local svc_color svc_txt pid_txt ver_txt
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    svc_color="$G"; svc_txt="运行中"
    local pid; pid=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || echo "-")
    pid_txt="PID ${pid}"
  else
    svc_color="$R"; svc_txt="未运行"; pid_txt="─"
  fi

  if command -v sing-box &>/dev/null; then
    ver_txt=$(sing-box version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "未安装")
  else
    ver_txt="未安装"
  fi

  local s5_port="-" ht_port="-"
  if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
    s5_port=$(jq -r '.inbounds[]|select(.type=="socks")|.listen_port' "$CONFIG_FILE" 2>/dev/null || echo "-")
    ht_port=$(jq -r '.inbounds[]|select(.type=="http")|.listen_port'  "$CONFIG_FILE" 2>/dev/null || echo "-")
  fi

  sep
  printf "  状态: ${svc_color}${BOLD}%-8s${NC}  版本: ${W}%-10s${NC}  %s\n" \
         "$svc_txt" "v${ver_txt}" "${DIM}${pid_txt}${NC}"
  printf "  ${DIM}SOCKS5: %-6s   HTTP: %-6s   配置: %s${NC}\n" \
         "$s5_port" "$ht_port" "$( [[ -f $CONFIG_FILE ]] && echo '已配置' || echo '未配置' )"
  sep
}

# ══════════════════════════════════════════════════════════════════════
#  读取当前代理配置（用于测试）
# ══════════════════════════════════════════════════════════════════════
load_proxy_config() {
  SOCKS5_PORT=1080; HTTP_PORT=1081
  SOCKS5_USER="";   SOCKS5_PASS=""
  HTTP_USER="";     HTTP_PASS=""
  if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
    SOCKS5_PORT=$(jq -r '.inbounds[]|select(.type=="socks")|.listen_port'         "$CONFIG_FILE" 2>/dev/null || echo 1080)
    HTTP_PORT=$(jq  -r '.inbounds[]|select(.type=="http")|.listen_port'           "$CONFIG_FILE" 2>/dev/null || echo 1081)
    SOCKS5_USER=$(jq -r '.inbounds[]|select(.type=="socks")|.users[0].username//""' "$CONFIG_FILE" 2>/dev/null || echo "")
    SOCKS5_PASS=$(jq -r '.inbounds[]|select(.type=="socks")|.users[0].password//""' "$CONFIG_FILE" 2>/dev/null || echo "")
    HTTP_USER=$(jq  -r '.inbounds[]|select(.type=="http")|.users[0].username//""'  "$CONFIG_FILE" 2>/dev/null || echo "")
    HTTP_PASS=$(jq  -r '.inbounds[]|select(.type=="http")|.users[0].password//""'  "$CONFIG_FILE" 2>/dev/null || echo "")
  fi
}

# ══════════════════════════════════════════════════════════════════════
#  ██  安装模块
# ══════════════════════════════════════════════════════════════════════
do_install() {
  need_root
  print_banner
  echo -e "  ${BOLD}${C}── 安装配置向导 ──────────────────────────────────────${NC}"
  blank

  # ── 交互式配置 ──
  local s5_port ht_port s5_user s5_pass ht_user ht_pass allow_lan

  read -rp "  SOCKS5 端口 [默认 1080]: " s5_port;  s5_port=${s5_port:-1080}
  read -rp "  HTTP   端口 [默认 1081]: " ht_port;  ht_port=${ht_port:-1081}
  blank

  # SOCKS5 账号密码（必填，空则重新输入）
  while true; do
    read -rp "  SOCKS5 用户名: " s5_user
    [[ -n "$s5_user" ]] && break
    warn "用户名不能为空，请重新输入"
  done
  while true; do
    read -rp "  SOCKS5 密码:   " s5_pass
    [[ -n "$s5_pass" ]] && break
    warn "密码不能为空，请重新输入"
  done
  blank

  # HTTP 账号密码（必填，空则重新输入）
  while true; do
    read -rp "  HTTP   用户名: " ht_user
    [[ -n "$ht_user" ]] && break
    warn "用户名不能为空，请重新输入"
  done
  while true; do
    read -rp "  HTTP   密码:   " ht_pass
    [[ -n "$ht_pass" ]] && break
    warn "密码不能为空，请重新输入"
  done
  blank
  read -rp "  允许局域网访问? [y/N]: " lan_ans
  [[ "${lan_ans,,}" == "y" ]] && allow_lan=true || allow_lan=false

  # ── 参数校验 ──
  blank; sep
  [[ "$s5_port" =~ ^[0-9]+$ ]] && (( s5_port>=1 && s5_port<=65535 )) || die "SOCKS5 端口无效: $s5_port"
  [[ "$ht_port" =~ ^[0-9]+$ ]] && (( ht_port>=1 && ht_port<=65535 )) || die "HTTP 端口无效: $ht_port"
  [[ "$s5_port" == "$ht_port" ]] && die "两个端口不能相同"

  # ── 显示确认摘要 ──
  echo -e "  ${BOLD}安装参数确认:${NC}"
  echo -e "    SOCKS5  127.0.0.1:${W}${s5_port}${NC}  用户: ${W}${s5_user}${NC}  密码: ${W}${s5_pass}${NC}"
  echo -e "    HTTP    127.0.0.1:${W}${ht_port}${NC}  用户: ${W}${ht_user}${NC}  密码: ${W}${ht_pass}${NC}"
  echo -e "    局域网  $( $allow_lan && echo "${G}开启${NC}" || echo "${DIM}关闭${NC}" )"
  blank
  read -rp "  确认开始安装? [Y/n]: " go
  [[ "${go,,}" == "n" ]] && { info "已取消安装。"; pause; return; }

  # ════════════════ 安装流程 ════════════════
  local TOTAL=6; local STEP=1
  _hdr() { blank; echo -e "  ${BOLD}${B}[${STEP}/${TOTAL}]${NC}${BOLD} $*${NC}"; ((STEP++)) || true; }

  # Step 1: 检测系统
  _hdr "检测系统环境"
  local arch os
  case "$(uname -m)" in
    x86_64)        arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l)        arch="armv7" ;;
    s390x)         arch="s390x" ;;
    *)             die "不支持的架构: $(uname -m)" ;;
  esac
  [[ -f /etc/os-release ]] && { . /etc/os-release; os="$ID"; } || os=$(uname -s | tr '[:upper:]' '[:lower:]')
  ok "系统: ${W}${os}${NC}  架构: ${W}${arch}${NC}"

  # Step 2: 安装依赖
  _hdr "检查依赖"
  local need=()
  for cmd in curl tar jq; do command -v "$cmd" &>/dev/null || need+=("$cmd"); done
  if (( ${#need[@]} > 0 )); then
    spin_start "安装 ${need[*]}"
    case "$os" in
      ubuntu|debian)              apt-get update -qq && apt-get install -y -qq "${need[@]}" >/dev/null 2>&1 ;;
      centos|rhel|rocky|almalinux) yum install -y -q "${need[@]}" >/dev/null 2>&1 || dnf install -y -q "${need[@]}" >/dev/null 2>&1 ;;
      fedora)                     dnf install -y -q "${need[@]}" >/dev/null 2>&1 ;;
      alpine)                     apk add --quiet "${need[@]}" >/dev/null 2>&1 ;;
      *)                          spin_stop; warn "未知发行版，请手动确保 curl/tar/jq 已安装" ;;
    esac
    spin_stop; ok "依赖安装完成: ${need[*]}"
  else
    ok "依赖已就绪"
  fi

  # Step 3: 获取版本
  _hdr "获取最新版本"
  spin_start "查询 GitHub Releases"
  local latest=""
  latest=$(curl -sf --max-time 10 \
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    | jq -r '.tag_name' 2>/dev/null) || latest=""
  if [[ -z "$latest" ]]; then
    spin_stop; warn "GitHub API 限速，切换备用..."
    spin_start "备用方式获取版本"
    latest=$(curl -sfI --max-time 10 "https://github.com/SagerNet/sing-box/releases/latest" \
             | grep -i '^location:' | sed 's|.*/tag/||;s/[[:space:]]//g')
  fi
  spin_stop
  [[ -z "$latest" ]] && die "无法获取版本信息，请检查网络"
  local version="${latest#v}"
  ok "最新版本: ${W}${latest}${NC}"

  # 检查是否已安装同版本
  if command -v sing-box &>/dev/null; then
    local cur; cur=$(sing-box version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
    if [[ "$cur" == "$version" ]]; then
      warn "sing-box ${version} 已是最新版，跳过下载"
      ((STEP++)) || true
    else
      _install_binary "$version" "$latest" "$arch"
    fi
  else
    _install_binary "$version" "$latest" "$arch"
  fi

  # Step 5: 写配置
  _hdr "生成代理配置"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR"
  local listen_addr="127.0.0.1"; $allow_lan && listen_addr="0.0.0.0"

  _gen_base_config "$s5_port" "$ht_port" \
    "$s5_user" "$s5_pass" "$ht_user" "$ht_pass" \
    "$listen_addr" "$CONFIG_FILE"

  _secure_perms
  sing-box check -c "$CONFIG_FILE" 2>/dev/null || die "配置校验失败，请检查 $CONFIG_FILE"
  ok "配置文件已就绪 (已通过语法校验)"

  # Step 6: 注册服务
  _hdr "注册并启动服务"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box proxy (SOCKS5 + HTTP)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStartPre=${INSTALL_DIR}/sing-box check -c ${CONFIG_FILE}
ExecStart=${INSTALL_DIR}/sing-box run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  spin_start "启动 sing-box"
  systemctl restart "$SERVICE_NAME"; sleep 2
  spin_stop
  systemctl is-active --quiet "$SERVICE_NAME" \
    && ok "服务已启动  ${DIM}(PID: $(systemctl show -p MainPID --value $SERVICE_NAME))${NC}" \
    || die "服务启动失败，请运行: journalctl -u ${SERVICE_NAME} -n 30"

  # ── 防火墙 ──
  if $allow_lan; then
    _fw_open "$s5_port" tcp; _fw_open "$s5_port" udp
    _fw_open "$ht_port" tcp
    _fw_reload
    ok "防火墙端口已放行"
  fi

  # ── 安装完成摘要 ──
  local server_ip
  server_ip=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
              || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
              || hostname -I | awk '{print $1}')
  blank
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${G}║${NC}        ${BOLD}${G}sing-box v${version}  安装完成！${NC}              ${G}║${NC}"
  echo -e "  ${G}╠══════════════════════════════════════════════════════╣${NC}"
  printf   "  ${G}║${NC}  SOCKS5  ${W}%-20s${NC}  用户: ${W}%-16s${NC}${G}║${NC}\n" \
           "${server_ip}:${s5_port}" "${s5_user}"
  printf   "  ${G}║${NC}          %-20s   密码: ${W}%-16s${NC}${G}║${NC}\n" "" "${s5_pass}"
  printf   "  ${G}║${NC}  HTTP    ${W}%-20s${NC}  用户: ${W}%-16s${NC}${G}║${NC}\n" \
           "${server_ip}:${ht_port}" "${ht_user}"
  printf   "  ${G}║${NC}          %-20s   密码: ${W}%-16s${NC}${G}║${NC}\n" "" "${ht_pass}"
  printf   "  ${G}║${NC}  局域网  %-46s${G}║${NC}\n" \
           "$( $allow_lan && echo "${G}已开启${NC}" || echo "${DIM}已关闭（仅本机）${NC}" )"
  echo -e "  ${G}╚══════════════════════════════════════════════════════╝${NC}"
  blank
  pause
}

# 下载并安装二进制（子函数，避免重复）
_install_binary() {
  local version="$1" latest="$2" arch="$3"
  _hdr "下载 sing-box ${latest}"
  local filename="sing-box-${version}-linux-${arch}.tar.gz"
  local dl_url="https://github.com/SagerNet/sing-box/releases/download/${latest}/${filename}"
  info "${DIM}${dl_url}${NC}"
  local tmpdir; tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN
  curl -L --progress-bar --max-time 120 "$dl_url" -o "${tmpdir}/${filename}" \
    || die "下载失败，请检查网络"
  tar -xzf "${tmpdir}/${filename}" -C "$tmpdir"
  local bin; bin=$(find "$tmpdir" -name "sing-box" -type f | head -1)
  [[ -z "$bin" ]] && die "解压失败：未找到可执行文件"
  install -m 755 "$bin" "${INSTALL_DIR}/sing-box"
  ok "已安装到 ${W}${INSTALL_DIR}/sing-box${NC}"
}

# ══════════════════════════════════════════════════════════════════════
#  ██  升级模块
# ══════════════════════════════════════════════════════════════════════
do_upgrade() {
  need_root
  print_banner
  echo -e "  ${BOLD}${C}── 升级 sing-box ──────────────────────────────────────${NC}"
  blank

  command -v sing-box &>/dev/null || die "sing-box 尚未安装，请先执行安装"

  local cur_ver; cur_ver=$(sing-box version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "未知")
  info "当前版本: ${W}v${cur_ver}${NC}"

  # 检测架构
  local arch
  case "$(uname -m)" in
    x86_64)        arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l)        arch="armv7" ;;
    s390x)         arch="s390x" ;;
    *)             die "不支持的架构: $(uname -m)" ;;
  esac

  # 获取最新版本
  spin_start "查询最新版本"
  local latest=""
  latest=$(curl -sf --max-time 10 \
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    | jq -r '.tag_name' 2>/dev/null) || latest=""
  if [[ -z "$latest" ]]; then
    spin_stop; warn "GitHub API 限速，切换备用..."
    spin_start "备用方式获取版本"
    latest=$(curl -sfI --max-time 10 "https://github.com/SagerNet/sing-box/releases/latest" \
             | grep -i '^location:' | sed 's|.*/tag/||;s/[[:space:]]//g')
  fi
  spin_stop
  [[ -z "$latest" ]] && die "无法获取版本信息，请检查网络"

  local new_ver="${latest#v}"
  info "最新版本: ${W}${latest}${NC}"

  # 比较版本
  if [[ "$cur_ver" == "$new_ver" ]]; then
    ok "已是最新版本 ${W}v${cur_ver}${NC}，无需升级"
    blank; pause; return
  fi

  blank
  echo -e "  ${Y}将从 ${W}v${cur_ver}${NC} ${Y}升级到 ${W}v${new_ver}${NC}"
  blank
  read -rp "  确认升级? [Y/n]: " go
  [[ "${go,,}" == "n" ]] && { info "已取消。"; pause; return; }
  blank

  # 下载新版本
  local filename="sing-box-${new_ver}-linux-${arch}.tar.gz"
  local dl_url="https://github.com/SagerNet/sing-box/releases/download/${latest}/${filename}"
  info "${DIM}${dl_url}${NC}"
  local tmpdir; tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN
  curl -L --progress-bar --max-time 120 "$dl_url" -o "${tmpdir}/${filename}" \
    || die "下载失败，请检查网络"
  tar -xzf "${tmpdir}/${filename}" -C "$tmpdir"
  local bin; bin=$(find "$tmpdir" -name "sing-box" -type f | head -1)
  [[ -z "$bin" ]] && die "解压失败：未找到可执行文件"

  # 停止服务、替换二进制、重启
  spin_start "停止服务"
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  spin_stop

  install -m 755 "$bin" "${INSTALL_DIR}/sing-box"
  ok "二进制已替换: ${W}v${cur_ver}${NC} → ${W}v${new_ver}${NC}"

  spin_start "重启服务"
  systemctl start "$SERVICE_NAME"; sleep 2
  spin_stop

  systemctl is-active --quiet "$SERVICE_NAME" \
    && ok "服务已恢复运行" \
    || fail "服务启动失败，请检查: journalctl -u ${SERVICE_NAME} -n 20"
  blank; pause
}

# ══════════════════════════════════════════════════════════════════════
#  ██  卸载模块
# ══════════════════════════════════════════════════════════════════════
do_uninstall() {
  need_root
  print_banner
  echo -e "  ${BOLD}${R}── 卸载 sing-box ──────────────────────────────────────${NC}"
  blank
  warn "此操作将删除 sing-box 二进制、配置文件、服务、快捷命令"
  warn "及防火墙规则，不可撤销！"
  blank
  read -rp "  输入 YES 确认卸载: " confirm
  [[ "$confirm" != "YES" ]] && { info "已取消。"; pause; return; }
  blank

  # 防火墙：移除当前监听端口的放行规则
  if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
    local _s5p _htp
    _s5p=$(jq -r '.inbounds[]|select(.type=="socks")|.listen_port' "$CONFIG_FILE" 2>/dev/null)
    _htp=$(jq -r '.inbounds[]|select(.type=="http")|.listen_port'  "$CONFIG_FILE" 2>/dev/null)
    [[ -n "$_s5p" ]] && { _fw_close "$_s5p" tcp; _fw_close "$_s5p" udp; }
    [[ -n "$_htp" ]] && _fw_close "$_htp" tcp
    _fw_reload
    info "已撤销防火墙端口放行"
  fi

  spin_start "停止服务"
  systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  spin_stop; ok "服务已停止"

  rm -f "$SERVICE_FILE"; systemctl daemon-reload
  rm -f "${INSTALL_DIR}/sing-box"
  rm -rf "$CONFIG_DIR" "$LOG_DIR"

  # 清理快捷命令 x / X 及标记
  rm -f "$CMD_LOWER" "$CMD_UPPER" "$ALIAS_MARKER" "$ALIAS_SKIP_FLAG"
  ok "快捷命令 x / X 已清理"
  ok "文件已清理"

  blank
  echo -e "  ${G}sing-box 已完全卸载。${NC}"
  pause
}

# ══════════════════════════════════════════════════════════════════════
#  ██  服务管理
# ══════════════════════════════════════════════════════════════════════
svc_action() {
  need_root
  local action="$1" label="$2"
  systemctl "$action" "$SERVICE_NAME" 2>/dev/null \
    && ok "${label}成功" || fail "${label}失败，请检查日志"
  sleep 1
}

do_svc_status() {
  blank
  echo -e "  ${BOLD}服务详细状态${NC}"
  sep
  systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || warn "sing-box 服务不存在"
  pause
}

do_view_log() {
  print_banner
  echo -e "  ${BOLD}实时日志${NC}  ${DIM}(Ctrl+C 退出)${NC}"
  sep
  blank
  if [[ -f "$LOG_FILE" ]]; then
    tail -n 30 "$LOG_FILE"
    blank; sep
    echo -e "  ${DIM}── 以下为实时输出 ──${NC}"; blank
    tail -f "$LOG_FILE" 2>/dev/null
  else
    journalctl -u "$SERVICE_NAME" -f --no-pager 2>/dev/null \
      || warn "暂无日志文件"
  fi
}

# ══════════════════════════════════════════════════════════════════════
#  ██  测试模块
# ══════════════════════════════════════════════════════════════════════
TIMEOUT=10
IP_URL="https://ifconfig.me"

_curl_s5() {
  load_proxy_config
  local auth=""
  [[ -n "$SOCKS5_USER" ]] && auth="-U ${SOCKS5_USER}:${SOCKS5_PASS}"
  # shellcheck disable=SC2086
  curl -sf --max-time "$TIMEOUT" --socks5-hostname "127.0.0.1:${SOCKS5_PORT}" $auth "$@"
}
_curl_ht() {
  load_proxy_config
  local px="http://127.0.0.1:${HTTP_PORT}"
  [[ -n "$HTTP_USER" ]] && px="http://${HTTP_USER}:${HTTP_PASS}@127.0.0.1:${HTTP_PORT}"
  curl -sf --max-time "$TIMEOUT" --proxy "$px" "$@"
}
_ms() {
  local s e; s=$(date +%s%3N)
  "$@" -o /dev/null 2>/dev/null || true
  e=$(date +%s%3N); echo $(( e - s ))
}
_ms_color() {
  (( $1 < 200 )) && echo "$G" || { (( $1 < 600 )) && echo "$Y" || echo "$R"; }
}

# 快速连通性
test_quick() {
  load_proxy_config
  blank
  echo -e "  ${BOLD}快速连通性测试${NC}"
  sep

  for type in socks5 http; do
    local label port
    [[ $type == socks5 ]] && { label="SOCKS5"; port=$SOCKS5_PORT; } || { label="HTTP  "; port=$HTTP_PORT; }
    printf "  %-8s  127.0.0.1:%-6s  " "$label" "$port"

    local out ms
    if [[ $type == socks5 ]]; then
      out=$(_curl_s5 "$IP_URL" 2>/dev/null) || out=""
    else
      out=$(_curl_ht "$IP_URL" 2>/dev/null) || out=""
    fi

    if [[ -n "$out" ]]; then
      if [[ $type == socks5 ]]; then
        ms=$(_ms _curl_s5 "$IP_URL")
      else
        ms=$(_ms _curl_ht "$IP_URL")
      fi
      local mc; mc=$(_ms_color "$ms")
      echo -e "${G}✓ 连通${NC}  出口 IP: ${W}${out}${NC}  延迟: ${mc}${ms}ms${NC}"
    else
      echo -e "${R}✗ 不通${NC}"
    fi
  done
  blank; pause
}

# 延迟基准
test_latency() {
  load_proxy_config
  blank
  echo -e "  ${BOLD}延迟基准测试${NC}  ${DIM}(每目标测 3 次取均值)${NC}"
  sep
  local targets=("https://ifconfig.me" "https://www.cloudflare.com" "https://httpbin.org/ip")

  for type in socks5 http; do
    echo -e "  ${C}▶ ${type^^} 代理${NC}"
    for url in "${targets[@]}"; do
      local sum=0 cnt=0
      for _ in 1 2 3; do
        local t
        if [[ $type == socks5 ]]; then t=$(_ms _curl_s5 "$url")
        else                            t=$(_ms _curl_ht "$url"); fi
        (( t < 9000 )) && { sum=$((sum+t)); cnt=$((cnt+1)); }
      done
      printf "    %-36s" "${url#https://}"
      if (( cnt > 0 )); then
        local avg=$(( sum / cnt )) mc; mc=$(_ms_color "$avg")
        echo -e "${mc}${avg}ms${NC}  ${DIM}(${cnt}/3 成功)${NC}"
      else
        echo -e "${R}超时${NC}"
      fi
    done
    blank
  done
  pause
}

# 认证测试
test_auth() {
  load_proxy_config
  blank
  echo -e "  ${BOLD}认证配置验证${NC}"
  sep

  echo -e "  ${C}▶ SOCKS5${NC}"
  info "用户名: ${W}${SOCKS5_USER}${NC}  密码: ${W}${SOCKS5_PASS}${NC}"
  printf "    %-30s" "正确凭据 → 应成功"
  _curl_s5 "$IP_URL" -o /dev/null 2>/dev/null && ok "通过" || fail "失败"
  printf "    %-30s" "错误凭据 → 应拒绝"
  local bad; bad=$(curl -sf --max-time 5 --socks5-hostname "127.0.0.1:${SOCKS5_PORT}" \
    -U "bad:bad" "$IP_URL" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
  [[ "$bad" == "000" || "$bad" == "407" ]] && ok "已拒绝" || warn "未拒绝 (HTTP ${bad})"

  blank
  echo -e "  ${C}▶ HTTP${NC}"
  info "用户名: ${W}${HTTP_USER}${NC}  密码: ${W}${HTTP_PASS}${NC}"
  printf "    %-30s" "正确凭据 → 应成功"
  _curl_ht "$IP_URL" -o /dev/null 2>/dev/null && ok "通过" || fail "失败"
  printf "    %-30s" "错误凭据 → 应拒绝"
  local bad2; bad2=$(curl -sf --max-time 5 \
    --proxy "http://bad:bad@127.0.0.1:${HTTP_PORT}" \
    "$IP_URL" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
  [[ "$bad2" == "000" || "$bad2" == "407" ]] && ok "已拒绝" || warn "未拒绝 (HTTP ${bad2})"
  blank; pause
}

# 完整诊断
test_full() {
  load_proxy_config
  blank
  echo -e "  ${BOLD}完整诊断报告${NC}"
  sep

  # 服务
  echo -e "  ${C}▶ 服务状态${NC}"
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    ok "sing-box 运行中"
    local pid; pid=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || echo "?")
    info "PID: ${pid}"
  else
    fail "sing-box 未运行"
    info "尝试: systemctl start sing-box"
  fi
  blank

  # 端口监听
  echo -e "  ${C}▶ 端口监听${NC}"
  for port in "$SOCKS5_PORT" "$HTTP_PORT"; do
    printf "    端口 %-8s" "$port"
    ss -tlnp 2>/dev/null | grep -q ":${port} " \
      || netstat -tlnp 2>/dev/null | grep -q ":${port} "
    (( $? == 0 )) && ok "监听中" || fail "未监听"
  done
  blank

  # 连通性
  echo -e "  ${C}▶ 连通性${NC}"
  for type in socks5 http; do
    local label; [[ $type == socks5 ]] && label="SOCKS5" || label="HTTP  "
    printf "    %-8s" "$label"
    local out
    [[ $type == socks5 ]] && out=$(_curl_s5 "$IP_URL" 2>/dev/null) \
                           || out=$(_curl_ht "$IP_URL" 2>/dev/null)
    [[ -n "$out" ]] && ok "出口 IP: ${W}${out}${NC}" || fail "无法连接"
  done
  blank

  # 配置文件
  echo -e "  ${C}▶ 配置文件${NC}"
  [[ -f "$CONFIG_FILE" ]] && ok "$CONFIG_FILE" || fail "配置文件不存在"
  sep
  blank; pause
}

# ══════════════════════════════════════════════════════════════════════
#  ██  修改配置（端口 / 账号 / 密码）
# ══════════════════════════════════════════════════════════════════════
do_edit_config() {
  need_root
  [[ ! -f "$CONFIG_FILE" ]] && die "配置文件不存在，请先执行安装（选项 1）"

  print_banner
  echo -e "  ${BOLD}${C}── 修改代理配置 ──────────────────────────────────────${NC}"
  blank

  # 读取当前值
  load_proxy_config
  local cur_listen
  cur_listen=$(jq -r '.inbounds[0].listen' "$CONFIG_FILE" 2>/dev/null || echo "127.0.0.1")
  local cur_allow_lan=false
  [[ "$cur_listen" == "0.0.0.0" ]] && cur_allow_lan=true

  # 展示当前配置
  echo -e "  ${BOLD}当前配置:${NC}"
  printf "    %-22s ${W}%s${NC}\n"  "SOCKS5 端口:"  "$SOCKS5_PORT"
  printf "    %-22s ${W}%s${NC}\n"  "HTTP   端口:"  "$HTTP_PORT"
  printf "    %-22s ${W}%s${NC}\n"  "SOCKS5 用户名:" "$SOCKS5_USER"
  printf "    %-22s ${W}%s${NC}\n"  "HTTP   用户名:" "$HTTP_USER"
  printf "    %-22s ${W}%s${NC}\n"  "局域网访问:"   "$( $cur_allow_lan && echo '已开启' || echo '已关闭' )"
  blank
  sep
  echo -e "  ${DIM}直接回车保留当前值，输入新值则覆盖；账号密码为必填项${NC}"
  blank

  # ── SOCKS5 端口 ──
  printf "  SOCKS5 端口 [当前: ${W}%s${NC}]: " "$SOCKS5_PORT"
  read -r inp
  local new_s5_port="${inp:-$SOCKS5_PORT}"

  # ── HTTP 端口 ──
  printf "  HTTP   端口 [当前: ${W}%s${NC}]: " "$HTTP_PORT"
  read -r inp
  local new_ht_port="${inp:-$HTTP_PORT}"

  blank

  # ── SOCKS5 账号（必填，回车保留原值，但不能最终为空）──
  local new_s5_user new_s5_pass
  while true; do
    printf "  SOCKS5 用户名 [当前: ${W}%s${NC}]: " "$SOCKS5_USER"
    read -r inp
    new_s5_user="${inp:-$SOCKS5_USER}"
    [[ -n "$new_s5_user" ]] && break
    warn "用户名不能为空，请重新输入"
  done
  while true; do
    printf "  SOCKS5 密码   [当前: ${W}%s${NC}]: " "$SOCKS5_PASS"
    read -r inp
    new_s5_pass="${inp:-$SOCKS5_PASS}"
    [[ -n "$new_s5_pass" ]] && break
    warn "密码不能为空，请重新输入"
  done

  blank

  # ── HTTP 账号（必填，回车保留原值，但不能最终为空）──
  local new_ht_user new_ht_pass
  while true; do
    printf "  HTTP   用户名 [当前: ${W}%s${NC}]: " "$HTTP_USER"
    read -r inp
    new_ht_user="${inp:-$HTTP_USER}"
    [[ -n "$new_ht_user" ]] && break
    warn "用户名不能为空，请重新输入"
  done
  while true; do
    printf "  HTTP   密码   [当前: ${W}%s${NC}]: " "$HTTP_PASS"
    read -r inp
    new_ht_pass="${inp:-$HTTP_PASS}"
    [[ -n "$new_ht_pass" ]] && break
    warn "密码不能为空，请重新输入"
  done

  blank

  # ── 局域网 ──
  printf "  允许局域网访问 [当前: ${W}%s${NC}] (y/n 切换，回车保留): " \
         "$( $cur_allow_lan && echo '已开启' || echo '已关闭' )"
  read -rn1 lan_inp; echo ""
  local new_allow_lan=$cur_allow_lan
  [[ "${lan_inp,,}" == "y" ]] && new_allow_lan=true
  [[ "${lan_inp,,}" == "n" ]] && new_allow_lan=false

  # ── 端口校验 ──
  [[ "$new_s5_port" =~ ^[0-9]+$ ]] && (( new_s5_port>=1 && new_s5_port<=65535 )) \
    || die "SOCKS5 端口无效: $new_s5_port"
  [[ "$new_ht_port" =~ ^[0-9]+$ ]] && (( new_ht_port>=1 && new_ht_port<=65535 )) \
    || die "HTTP 端口无效: $new_ht_port"
  [[ "$new_s5_port" == "$new_ht_port" ]] && die "SOCKS5 与 HTTP 端口不能相同"

  # ── 确认摘要 ──
  blank; sep
  echo -e "  ${BOLD}修改预览:${NC}"
  printf "    %-22s ${Y}%s${NC} → ${G}%s${NC}\n" "SOCKS5 端口:" "$SOCKS5_PORT" "$new_s5_port"
  printf "    %-22s ${Y}%s${NC} → ${G}%s${NC}\n" "HTTP   端口:" "$HTTP_PORT"   "$new_ht_port"
  printf "    %-22s ${Y}%s${NC} → ${G}%s${NC}\n" "SOCKS5 用户名:" "$SOCKS5_USER" "$new_s5_user"
  printf "    %-22s ${Y}%s${NC} → ${G}%s${NC}\n" "SOCKS5 密码:"   "$SOCKS5_PASS" "$new_s5_pass"
  printf "    %-22s ${Y}%s${NC} → ${G}%s${NC}\n" "HTTP   用户名:" "$HTTP_USER"   "$new_ht_user"
  printf "    %-22s ${Y}%s${NC} → ${G}%s${NC}\n" "HTTP   密码:"   "$HTTP_PASS"   "$new_ht_pass"
  printf "    %-22s ${Y}%s${NC} → ${G}%s${NC}\n" "局域网访问:" \
    "$( $cur_allow_lan && echo '开启' || echo '关闭' )" \
    "$( $new_allow_lan && echo '开启' || echo '关闭' )"
  blank
  read -rp "  确认保存并重启服务? [Y/n]: " go
  [[ "${go,,}" == "n" ]] && { info "已取消，配置未变更。"; pause; return; }

  # 备份当前配置（用于失败回退）
  local bak; bak=$(_backup_config)
  [[ -n "$bak" ]] && info "已备份原配置: ${DIM}${bak}${NC}"

  # ── 写入新配置（保留 outbounds / route）──
  local new_listen="127.0.0.1"; $new_allow_lan && new_listen="0.0.0.0"

  local tmp="${CONFIG_FILE}.new"
  if ! jq \
      --arg listen "$new_listen" \
      --argjson s5p "$new_s5_port" --argjson htp "$new_ht_port" \
      --arg s5u "$new_s5_user" --arg s5pw "$new_s5_pass" \
      --arg htu "$new_ht_user" --arg htpw "$new_ht_pass" \
      '.inbounds = [
        { type:"socks", tag:"socks5-in", listen:$listen, listen_port:$s5p,
          users:[{username:$s5u, password:$s5pw}],
          sniff:true, sniff_override_destination:false, udp:true },
        { type:"http", tag:"http-in", listen:$listen, listen_port:$htp,
          users:[{username:$htu, password:$htpw}],
          sniff:true, sniff_override_destination:false }
      ]' "$CONFIG_FILE" > "$tmp"; then
    rm -f "$tmp"
    die "jq 写入失败，原配置未变更"
  fi

  if ! sing-box check -c "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "新配置校验失败，已取消变更"
  fi

  mv "$tmp" "$CONFIG_FILE"
  _secure_perms
  ok "配置文件已更新"

  spin_start "重启 sing-box 服务"
  systemctl restart "$SERVICE_NAME" 2>/dev/null; sleep 2
  spin_stop

  systemctl is-active --quiet "$SERVICE_NAME" \
    && ok "服务已重启，新配置生效" \
    || fail "服务重启失败，请运行: journalctl -u ${SERVICE_NAME} -n 20"

  # ── 防火墙同步：撤销旧端口、放行新端口 ──
  # 旧端口撤销（仅当原本是 LAN 模式或端口变化时）
  if $cur_allow_lan && [[ "$SOCKS5_PORT" != "$new_s5_port" || ! $new_allow_lan ]]; then
    _fw_close "$SOCKS5_PORT" tcp; _fw_close "$SOCKS5_PORT" udp
  fi
  if $cur_allow_lan && [[ "$HTTP_PORT" != "$new_ht_port" || ! $new_allow_lan ]]; then
    _fw_close "$HTTP_PORT" tcp
  fi
  # 新端口放行
  if $new_allow_lan; then
    _fw_open "$new_s5_port" tcp; _fw_open "$new_s5_port" udp
    _fw_open "$new_ht_port" tcp
  fi
  _fw_reload
  ok "防火墙规则已同步"

  blank; pause
}

# ══════════════════════════════════════════════════════════════════════
#  ██  出站节点模块
# ══════════════════════════════════════════════════════════════════════

# ── 工具：判断是否为 IP（IPv4 / IPv6）──────────────────────────────────
_is_ip() {
  local h="$1"
  [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
  [[ "$h" =~ ^\[?[0-9a-fA-F:]+\]?$           ]] && return 0
  return 1
}

# ── 工具：用 jq 追加出站并自动激活 ─────────────────────────────────────
# $1 = 节点 JSON  $2 = tag
_apply_outbound() {
  local node_json="$1" tag="$2"
  [[ ! -f "$CONFIG_FILE" ]] && die "配置文件不存在，请先安装 sing-box"

  local bak; bak=$(_backup_config)
  local tmp="${CONFIG_FILE}.new"

  if ! jq --argjson nb "$node_json" --arg t "$tag" \
      '.outbounds = ([.outbounds[] | select(.tag != $t)] + [$nb]) |
       .route.final = $t' \
      "$CONFIG_FILE" > "$tmp"; then
    rm -f "$tmp"; die "jq 写入失败"
  fi

  if ! sing-box check -c "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "新配置校验失败，原配置已备份: ${bak}"
  fi

  mv "$tmp" "$CONFIG_FILE"
  _secure_perms
}

# 移除指定 tag 的出站，若它是当前激活节点则改为 direct
_remove_outbound_by_tag() {
  local tag="$1"
  local tmp="${CONFIG_FILE}.new"

  if ! jq --arg t "$tag" \
      '.outbounds = [.outbounds[] | select(.tag != $t)] |
       (if .route.final == $t then .route.final = "direct" else . end)' \
      "$CONFIG_FILE" > "$tmp"; then
    rm -f "$tmp"; die "jq 写入失败"
  fi

  if ! sing-box check -c "$tmp" 2>/dev/null; then
    rm -f "$tmp"; die "新配置校验失败"
  fi

  mv "$tmp" "$CONFIG_FILE"
  _secure_perms
}

# 切换激活的出站节点
_switch_outbound() {
  local tag="$1"
  local tmp="${CONFIG_FILE}.new"
  jq --arg t "$tag" '.route.final = $t' "$CONFIG_FILE" > "$tmp" \
    && sing-box check -c "$tmp" 2>/dev/null \
    && mv "$tmp" "$CONFIG_FILE" \
    && _secure_perms \
    || { rm -f "$tmp"; die "切换失败"; }
}

# 列出所有非内置出站（不含 direct/block）
_list_outbounds() {
  jq -r '.outbounds[] | select(.tag != "direct" and .tag != "block")
         | "\(.tag)\t\(.type)\t\(.server // "-"):\(.server_port // "-")"' \
    "$CONFIG_FILE" 2>/dev/null
}

# 生成唯一 tag: proxy-{type}-{shortid}
_gen_tag() {
  local type="$1"
  echo "proxy-${type}-$(date +%s | tail -c 5)$(( RANDOM % 1000 ))"
}

_restart_service() {
  spin_start "重启 sing-box"
  systemctl restart "$SERVICE_NAME" 2>/dev/null; sleep 2
  spin_stop
  systemctl is-active --quiet "$SERVICE_NAME" \
    && ok "服务已重启，节点配置已生效" \
    || fail "服务启动失败，请检查: journalctl -u ${SERVICE_NAME} -n 20"
}

# ── 获取本地代理地址 ────────────────────────────────────────────────────
do_get_proxy_addr() {
  [[ ! -f "$CONFIG_FILE" ]] && die "配置文件不存在，请先安装 sing-box"
  load_proxy_config
  local server_ip
  server_ip=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
              || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
              || hostname -I | awk '{print $1}')
  local listen
  listen=$(jq -r '.inbounds[0].listen' "$CONFIG_FILE" 2>/dev/null || echo "127.0.0.1")
  [[ "$listen" == "0.0.0.0" ]] && local addr="$server_ip" || local addr="127.0.0.1"

  # 出站节点信息
  local proxy_tag proxy_type proxy_server proxy_port
  proxy_tag=$(jq -r '.route.final' "$CONFIG_FILE" 2>/dev/null || echo "direct")
  if [[ "$proxy_tag" != "direct" && "$proxy_tag" != "block" ]]; then
    proxy_type=$(jq -r --arg t "$proxy_tag" '.outbounds[] | select(.tag==$t) | .type' "$CONFIG_FILE" 2>/dev/null)
    proxy_server=$(jq -r --arg t "$proxy_tag" '.outbounds[] | select(.tag==$t) | .server' "$CONFIG_FILE" 2>/dev/null)
    proxy_port=$(jq -r --arg t "$proxy_tag" '.outbounds[] | select(.tag==$t) | .server_port' "$CONFIG_FILE" 2>/dev/null)
  fi

  blank
  echo -e "  ${G}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${G}║${NC}           ${BOLD}本地代理地址${NC}                             ${G}║${NC}"
  echo -e "  ${G}╠══════════════════════════════════════════════════════╣${NC}"
  printf   "  ${G}║${NC}  ${C}SOCKS5${NC}  ${W}%-22s${NC}  %-20s${G}║${NC}\n" \
           "${addr}:${SOCKS5_PORT}" "用户: ${SOCKS5_USER}"
  printf   "  ${G}║${NC}          %-44s${G}║${NC}\n" "密码: ${SOCKS5_PASS}"
  echo -e  "  ${G}║${NC}                                                      ${G}║${NC}"
  printf   "  ${G}║${NC}  ${C}HTTP  ${NC}  ${W}%-22s${NC}  %-20s${G}║${NC}\n" \
           "${addr}:${HTTP_PORT}" "用户: ${HTTP_USER}"
  printf   "  ${G}║${NC}          %-44s${G}║${NC}\n" "密码: ${HTTP_PASS}"
  echo -e  "  ${G}╠══════════════════════════════════════════════════════╣${NC}"
  if [[ "${proxy_tag:-direct}" != "direct" ]]; then
    printf "  ${G}║${NC}  ${M}出站节点${NC}  %-43s${G}║${NC}\n" "${proxy_type^^}  ${proxy_server}:${proxy_port}"
  else
    printf "  ${G}║${NC}  ${DIM}出站节点  直连（无上游代理）%-24s${NC}${G}║${NC}\n" ""
  fi
  echo -e  "  ${G}╚══════════════════════════════════════════════════════╝${NC}"
  blank

  # curl 命令示例
  echo -e "  ${BOLD}curl 验证示例:${NC}"
  echo -e "  ${DIM}# SOCKS5${NC}"
  echo -e "  curl --socks5 ${SOCKS5_USER}:${SOCKS5_PASS}@${addr}:${SOCKS5_PORT} https://ifconfig.me"
  blank
  echo -e "  ${DIM}# HTTP${NC}"
  echo -e "  curl --proxy http://${HTTP_USER}:${HTTP_PASS}@${addr}:${HTTP_PORT} https://ifconfig.me"
  blank
  pause
}

# ── 添加 Hysteria2 ──────────────────────────────────────────────────────
do_add_hysteria2() {
  need_root
  [[ ! -f "$CONFIG_FILE" ]] && die "请先安装 sing-box（选项 1）"
  print_banner
  echo -e "  ${BOLD}${C}── 添加 Hysteria2 出站节点 ───────────────────────────${NC}"
  blank

  local server port password sni insecure up_mbps down_mbps

  while true; do
    read -rp "  服务器地址 (IP 或域名): " server
    [[ -n "$server" ]] && break; warn "不能为空"
  done
  while true; do
    read -rp "  端口 [默认 443]: " port; port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ ]] && (( port>=1 && port<=65535 )) && break; warn "端口无效"
  done
  while true; do
    read -rp "  密码 (password): " password
    [[ -n "$password" ]] && break; warn "不能为空"
  done

  # SNI：有域名自动填入，否则手动输入
  if _is_ip "$server"; then
    read -rp "  TLS SNI [留空跳过]: " sni
  else
    sni="$server"
    info "SNI 自动使用域名: ${W}${sni}${NC}"
  fi

  read -rp "  跳过 TLS 证书验证? [y/N]: " ins
  [[ "${ins,,}" == "y" ]] && insecure=true || insecure=false

  read -rp "  上行带宽 Mbps [默认 100]: " up_mbps;   up_mbps=${up_mbps:-100}
  read -rp "  下行带宽 Mbps [默认 100]: " down_mbps; down_mbps=${down_mbps:-100}

  blank; sep
  echo -e "  ${BOLD}配置预览:${NC}"
  echo -e "    类型:    Hysteria2"
  echo -e "    服务器:  ${W}${server}:${port}${NC}"
  echo -e "    密码:    ${W}${password}${NC}"
  [[ -n "$sni" ]] && echo -e "    SNI:     ${W}${sni}${NC}"
  echo -e "    忽略证书: $( $insecure && echo "${Y}是${NC}" || echo "否" )"
  echo -e "    带宽:    上行 ${W}${up_mbps}Mbps${NC}  下行 ${W}${down_mbps}Mbps${NC}"
  blank
  read -rp "  确认添加? [Y/n]: " go
  [[ "${go,,}" == "n" ]] && { info "已取消"; pause; return; }

  # 构建 JSON
  local tag; tag=$(_gen_tag hysteria2)
  local tls_block
  tls_block=$(jq -n \
    --argjson ins "$insecure" \
    --arg sni "$sni" \
    '{enabled:true, insecure:$ins} +
     (if $sni == "" then {} else {server_name:$sni} end)')

  local out_json
  out_json=$(jq -n \
    --arg tag "$tag" \
    --arg server "$server" \
    --argjson port "$port" \
    --arg pass "$password" \
    --argjson up "$up_mbps" \
    --argjson dn "$down_mbps" \
    --argjson tls "$tls_block" \
    '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,
      password:$pass,up_mbps:$up,down_mbps:$dn,tls:$tls}')

  _apply_outbound "$out_json" "$tag"
  ok "Hysteria2 节点已添加并激活  ${DIM}(tag: ${tag})${NC}"
  _restart_service
  blank; pause
}

# ── 添加 TUIC ──────────────────────────────────────────────────────────
do_add_tuic() {
  need_root
  [[ ! -f "$CONFIG_FILE" ]] && die "请先安装 sing-box（选项 1）"
  print_banner
  echo -e "  ${BOLD}${C}── 添加 TUIC 出站节点 ────────────────────────────────${NC}"
  blank

  local server port uuid password sni insecure cc

  while true; do
    read -rp "  服务器地址 (IP 或域名): " server
    [[ -n "$server" ]] && break; warn "不能为空"
  done
  while true; do
    read -rp "  端口 [默认 443]: " port; port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ ]] && (( port>=1 && port<=65535 )) && break; warn "端口无效"
  done
  while true; do
    read -rp "  UUID: " uuid
    [[ -n "$uuid" ]] && break; warn "不能为空"
  done
  while true; do
    read -rp "  密码 (password): " password
    [[ -n "$password" ]] && break; warn "不能为空"
  done

  if _is_ip "$server"; then
    read -rp "  TLS SNI [留空跳过]: " sni
  else
    sni="$server"
    info "SNI 自动使用域名: ${W}${sni}${NC}"
  fi

  read -rp "  跳过 TLS 证书验证? [y/N]: " ins
  [[ "${ins,,}" == "y" ]] && insecure=true || insecure=false

  read -rp "  拥塞控制算法 [bbr/cubic/new_reno，默认 bbr]: " cc; cc=${cc:-bbr}

  blank; sep
  echo -e "  ${BOLD}配置预览:${NC}"
  echo -e "    类型:    TUIC v5"
  echo -e "    服务器:  ${W}${server}:${port}${NC}"
  echo -e "    UUID:    ${W}${uuid}${NC}"
  echo -e "    密码:    ${W}${password}${NC}"
  [[ -n "$sni" ]] && echo -e "    SNI:     ${W}${sni}${NC}"
  echo -e "    拥塞控制: ${W}${cc}${NC}"
  echo -e "    忽略证书: $( $insecure && echo "${Y}是${NC}" || echo "否" )"
  blank
  read -rp "  确认添加? [Y/n]: " go
  [[ "${go,,}" == "n" ]] && { info "已取消"; pause; return; }

  local tag; tag=$(_gen_tag tuic)
  local tls_block
  tls_block=$(jq -n \
    --argjson ins "$insecure" \
    --arg sni "$sni" \
    '{enabled:true, insecure:$ins} +
     (if $sni == "" then {} else {server_name:$sni} end)')

  local out_json
  out_json=$(jq -n \
    --arg tag "$tag" \
    --arg server "$server" \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg pass "$password" \
    --arg cc "$cc" \
    --argjson tls "$tls_block" \
    '{type:"tuic",tag:$tag,server:$server,server_port:$port,
      uuid:$uuid,password:$pass,congestion_control:$cc,
      udp_relay_mode:"native",tls:$tls}')

  _apply_outbound "$out_json" "$tag"
  ok "TUIC 节点已添加并激活  ${DIM}(tag: ${tag})${NC}"
  _restart_service
  blank; pause
}

# ── 添加 vless+reality ─────────────────────────────────────────────────
do_add_vless_reality() {
  need_root
  [[ ! -f "$CONFIG_FILE" ]] && die "请先安装 sing-box（选项 1）"
  print_banner
  echo -e "  ${BOLD}${C}── 添加 vless+reality 出站节点 ───────────────────────${NC}"
  blank

  local server port uuid flow pubkey shortid sni fp

  while true; do
    read -rp "  服务器 (域名 或 IP): " server
    [[ -n "$server" ]] && break; warn "不能为空"
  done
  while true; do
    read -rp "  端口 [默认 443]: " port; port=${port:-443}
    [[ "$port" =~ ^[0-9]+$ ]] && (( port>=1 && port<=65535 )) && break; warn "端口无效"
  done
  while true; do
    read -rp "  UUID: " uuid
    [[ -n "$uuid" ]] && break; warn "不能为空"
  done

  read -rp "  Flow [默认 xtls-rprx-vision]: " flow; flow=${flow:-xtls-rprx-vision}

  while true; do
    read -rp "  Reality 公钥 (publicKey): " pubkey
    [[ -n "$pubkey" ]] && break; warn "不能为空"
  done
  read -rp "  Short ID [留空则为空]: " shortid

  # SNI：有域名自动填入，否则提示输入（通常填一个真实网站）
  if _is_ip "$server"; then
    info "检测到 IP 地址，Reality SNI 需填写伪装域名（如 www.microsoft.com）"
    while true; do
      read -rp "  SNI 伪装域名: " sni
      [[ -n "$sni" ]] && break; warn "不能为空"
    done
  else
    sni="$server"
    info "SNI 自动使用域名: ${W}${sni}${NC}"
  fi

  read -rp "  uTLS 指纹 [chrome/firefox/safari/ios，默认 chrome]: " fp
  fp=${fp:-chrome}

  blank; sep
  echo -e "  ${BOLD}配置预览:${NC}"
  echo -e "    类型:    vless + reality"
  echo -e "    服务器:  ${W}${server}:${port}${NC}"
  echo -e "    UUID:    ${W}${uuid}${NC}"
  echo -e "    Flow:    ${W}${flow}${NC}"
  echo -e "    公钥:    ${W}${pubkey}${NC}"
  [[ -n "$shortid" ]] && echo -e "    ShortID: ${W}${shortid}${NC}"
  echo -e "    SNI:     ${W}${sni}${NC}"
  echo -e "    指纹:    ${W}${fp}${NC}"
  blank
  read -rp "  确认添加? [Y/n]: " go
  [[ "${go,,}" == "n" ]] && { info "已取消"; pause; return; }

  local tag; tag=$(_gen_tag vless)
  local reality_block
  reality_block=$(jq -n \
    --arg pk "$pubkey" \
    --arg sid "$shortid" \
    '{enabled:true, public_key:$pk, short_id:$sid}')

  local tls_block
  tls_block=$(jq -n \
    --arg sni "$sni" \
    --arg fp "$fp" \
    --argjson real "$reality_block" \
    '{enabled:true, server_name:$sni,
      utls:{enabled:true, fingerprint:$fp},
      reality:$real}')

  local out_json
  out_json=$(jq -n \
    --arg tag "$tag" \
    --arg server "$server" \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg flow "$flow" \
    --argjson tls "$tls_block" \
    '{type:"vless",tag:$tag,server:$server,server_port:$port,
      uuid:$uuid,flow:$flow,tls:$tls}')

  _apply_outbound "$out_json" "$tag"
  ok "vless+reality 节点已添加并激活  ${DIM}(tag: ${tag})${NC}"
  _restart_service
  blank; pause
}

# ── 多节点管理 ──────────────────────────────────────────────────────────
do_manage_outbound() {
  need_root
  [[ ! -f "$CONFIG_FILE" ]] && die "配置文件不存在"
  print_banner
  echo -e "  ${BOLD}${C}── 出站节点管理 ──────────────────────────────────────${NC}"
  blank

  local final_tag
  final_tag=$(jq -r '.route.final' "$CONFIG_FILE" 2>/dev/null || echo "direct")

  # 收集所有非内置出站
  local -a tags types addrs
  while IFS=$'\t' read -r tg ty ad; do
    [[ -z "$tg" ]] && continue
    tags+=("$tg"); types+=("$ty"); addrs+=("$ad")
  done < <(_list_outbounds)

  if (( ${#tags[@]} == 0 )); then
    warn "暂无任何出站节点（当前为直连模式）"
    info "请先通过菜单 6 / 7 / 8 添加节点"
    blank; pause; return
  fi

  echo -e "  ${BOLD}已配置的出站节点:${NC}"
  blank
  local i n=${#tags[@]} marker
  for ((i=0; i<n; i++)); do
    if [[ "${tags[$i]}" == "$final_tag" ]]; then
      marker="${G}●${NC}"   # 激活
    else
      marker="${DIM}○${NC}"
    fi
    printf "  %s  ${W}%d${NC}  %-8s  ${DIM}%-26s${NC}  ${DIM}%s${NC}\n" \
      "$marker" $((i+1)) "${types[$i]^^}" "${addrs[$i]}" "${tags[$i]}"
  done
  blank
  if [[ "$final_tag" == "direct" ]]; then
    info "当前状态: ${Y}直连（无激活节点）${NC}"
  fi

  blank; sep
  echo -e "  ${W}s${NC}  切换激活节点"
  echo -e "  ${W}d${NC}  删除节点"
  echo -e "  ${W}r${NC}  切回直连模式"
  echo -e "  ${W}0${NC}  返回"
  blank
  printf "  请选择 [s/d/r/0]: "
  read -rn1 op; echo ""

  case "${op,,}" in
    s)
      read -rp "  输入要激活的节点编号 [1-${n}]: " idx
      [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=n )) || { warn "无效编号"; sleep 1; return; }
      _switch_outbound "${tags[$((idx-1))]}"
      ok "已切换激活节点为: ${tags[$((idx-1))]}"
      _restart_service ;;
    d)
      read -rp "  输入要删除的节点编号 [1-${n}]: " idx
      [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=n )) || { warn "无效编号"; sleep 1; return; }
      local del_tag="${tags[$((idx-1))]}"
      read -rp "  确认删除节点 ${del_tag}? [y/N]: " c
      if [[ "${c,,}" == "y" ]]; then
        _remove_outbound_by_tag "$del_tag"
        ok "节点已删除"
        _restart_service
      else
        info "已取消"
      fi ;;
    r)
      read -rp "  确认切回直连? [y/N]: " c
      if [[ "${c,,}" == "y" ]]; then
        _switch_outbound "direct"
        ok "已切回直连模式"
        _restart_service
      else
        info "已取消"
      fi ;;
    0) return ;;
    *) warn "无效操作"; sleep 1 ;;
  esac
  pause
}

# ══════════════════════════════════════════════════════════════════════
#  ██  配置查看
# ══════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════
#  ██  备份 / 恢复
# ══════════════════════════════════════════════════════════════════════
BACKUP_DIR="/var/backups/sing-box"

do_backup() {
  need_root
  [[ ! -d "$CONFIG_DIR" ]] && die "配置目录不存在，无可备份内容"
  mkdir -p "$BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  local file="${BACKUP_DIR}/singbox-${ts}.tar.gz"
  print_banner
  echo -e "  ${BOLD}${C}── 配置备份 ──────────────────────────────────────────${NC}"
  blank
  spin_start "正在打包配置"
  tar -czf "$file" -C / "etc/sing-box" 2>/dev/null
  spin_stop
  chmod 600 "$file"
  ok "备份完成"
  info "文件: ${W}${file}${NC}"
  info "大小: ${DIM}$(du -h "$file" | awk '{print $1}')${NC}"
  blank

  # 列出现有备份
  local cnt; cnt=$(ls -1 "$BACKUP_DIR"/singbox-*.tar.gz 2>/dev/null | wc -l)
  echo -e "  ${BOLD}所有备份（共 ${cnt} 份）:${NC}"
  ls -lh "$BACKUP_DIR"/singbox-*.tar.gz 2>/dev/null | awk '{printf "    %s  %6s  %s %s %s\n",$NF,$5,$6,$7,$8}' || true
  blank; pause
}

do_restore() {
  need_root
  print_banner
  echo -e "  ${BOLD}${C}── 配置恢复 ──────────────────────────────────────────${NC}"
  blank

  local -a backups=()
  while IFS= read -r f; do backups+=("$f"); done < <(ls -1t "$BACKUP_DIR"/singbox-*.tar.gz 2>/dev/null)

  if (( ${#backups[@]} == 0 )); then
    warn "未找到任何备份文件  ${DIM}(${BACKUP_DIR})${NC}"
    info "请先使用「备份配置」生成备份"
    blank; pause; return
  fi

  echo -e "  ${BOLD}可用备份:${NC}"
  local i n=${#backups[@]}
  for ((i=0; i<n; i++)); do
    local fname size mtime
    fname=$(basename "${backups[$i]}")
    size=$(du -h "${backups[$i]}" | awk '{print $1}')
    mtime=$(stat -c %y "${backups[$i]}" 2>/dev/null | cut -d. -f1)
    printf "    ${W}%d${NC}  %-30s  ${DIM}%s  %s${NC}\n" $((i+1)) "$fname" "$size" "$mtime"
  done
  blank
  read -rp "  选择要恢复的备份编号 [1-${n}, 0=取消]: " idx
  [[ "$idx" == "0" || -z "$idx" ]] && { info "已取消"; pause; return; }
  [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=n )) || { warn "无效编号"; sleep 1; return; }

  local sel="${backups[$((idx-1))]}"
  warn "恢复将覆盖当前配置，建议先备份当前配置"
  read -rp "  输入 YES 确认恢复: " c
  [[ "$c" != "YES" ]] && { info "已取消"; pause; return; }

  # 先备份当前
  _backup_config >/dev/null
  spin_start "停止服务并恢复配置"
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  tar -xzf "$sel" -C / 2>/dev/null
  _secure_perms
  spin_stop

  if sing-box check -c "$CONFIG_FILE" 2>/dev/null; then
    systemctl start "$SERVICE_NAME"; sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      ok "恢复完成，服务已启动"
    else
      fail "服务启动失败，请检查日志"
    fi
  else
    fail "恢复的配置校验失败"
  fi
  blank; pause
}

# ══════════════════════════════════════════════════════════════════════
#  ██  订阅链接 / URI 生成
# ══════════════════════════════════════════════════════════════════════
# urlencode helper（兼容无 python 环境）
_urlencode() {
  local s="$1" out="" c i
  for ((i=0; i<${#s}; i++)); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

do_show_uri() {
  [[ ! -f "$CONFIG_FILE" ]] && die "配置文件不存在"
  print_banner
  echo -e "  ${BOLD}${C}── 订阅链接 / 节点 URI ───────────────────────────────${NC}"
  blank

  # 提取本地 SOCKS5/HTTP 供本机使用
  load_proxy_config
  local server_ip
  server_ip=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
              || hostname -I | awk '{print $1}')
  local listen
  listen=$(jq -r '.inbounds[0].listen' "$CONFIG_FILE" 2>/dev/null || echo "127.0.0.1")
  local local_host="127.0.0.1"
  [[ "$listen" == "0.0.0.0" ]] && local_host="$server_ip"

  echo -e "  ${BOLD}本地代理 URI:${NC}"
  echo -e "  ${DIM}# SOCKS5${NC}"
  echo -e "  ${W}socks5://$(_urlencode "$SOCKS5_USER"):$(_urlencode "$SOCKS5_PASS")@${local_host}:${SOCKS5_PORT}${NC}"
  blank
  echo -e "  ${DIM}# HTTP${NC}"
  echo -e "  ${W}http://$(_urlencode "$HTTP_USER"):$(_urlencode "$HTTP_PASS")@${local_host}:${HTTP_PORT}${NC}"
  blank; sep
  blank

  # 列出所有出站节点的客户端导入链接
  local has_any=false
  while IFS=$'\t' read -r tag type addr; do
    [[ -z "$tag" ]] && continue
    has_any=true
    local node
    node=$(jq --arg t "$tag" '.outbounds[] | select(.tag == $t)' "$CONFIG_FILE")

    case "$type" in
      hysteria2)
        local h_server h_port h_pass h_sni h_ins
        h_server=$(echo "$node" | jq -r '.server')
        h_port=$(echo "$node"   | jq -r '.server_port')
        h_pass=$(echo "$node"   | jq -r '.password')
        h_sni=$(echo "$node"    | jq -r '.tls.server_name // ""')
        h_ins=$(echo "$node"    | jq -r '.tls.insecure // false')
        local uri="hy2://$(_urlencode "$h_pass")@${h_server}:${h_port}/?"
        [[ -n "$h_sni" ]] && uri+="sni=${h_sni}&"
        [[ "$h_ins" == "true" ]] && uri+="insecure=1&"
        uri+="#${tag}"
        echo -e "  ${C}▶ Hysteria2${NC}  ${DIM}${tag}${NC}"
        echo -e "  ${W}${uri}${NC}"
        blank ;;
      tuic)
        local t_server t_port t_uuid t_pass t_sni t_cc t_ins
        t_server=$(echo "$node" | jq -r '.server')
        t_port=$(echo "$node"   | jq -r '.server_port')
        t_uuid=$(echo "$node"   | jq -r '.uuid')
        t_pass=$(echo "$node"   | jq -r '.password')
        t_sni=$(echo "$node"    | jq -r '.tls.server_name // ""')
        t_cc=$(echo "$node"     | jq -r '.congestion_control // "bbr"')
        t_ins=$(echo "$node"    | jq -r '.tls.insecure // false')
        local uri="tuic://${t_uuid}:$(_urlencode "$t_pass")@${t_server}:${t_port}/?congestion_control=${t_cc}"
        [[ -n "$t_sni" ]] && uri+="&sni=${t_sni}"
        [[ "$t_ins" == "true" ]] && uri+="&allow_insecure=1"
        uri+="#${tag}"
        echo -e "  ${C}▶ TUIC${NC}  ${DIM}${tag}${NC}"
        echo -e "  ${W}${uri}${NC}"
        blank ;;
      vless)
        local v_server v_port v_uuid v_flow v_sni v_pk v_sid v_fp
        v_server=$(echo "$node" | jq -r '.server')
        v_port=$(echo "$node"   | jq -r '.server_port')
        v_uuid=$(echo "$node"   | jq -r '.uuid')
        v_flow=$(echo "$node"   | jq -r '.flow // ""')
        v_sni=$(echo "$node"    | jq -r '.tls.server_name // ""')
        v_pk=$(echo "$node"     | jq -r '.tls.reality.public_key // ""')
        v_sid=$(echo "$node"    | jq -r '.tls.reality.short_id // ""')
        v_fp=$(echo "$node"     | jq -r '.tls.utls.fingerprint // "chrome"')
        local uri="vless://${v_uuid}@${v_server}:${v_port}?encryption=none&security=reality&type=tcp"
        [[ -n "$v_flow" ]] && uri+="&flow=${v_flow}"
        [[ -n "$v_sni" ]]  && uri+="&sni=${v_sni}"
        [[ -n "$v_pk" ]]   && uri+="&pbk=${v_pk}"
        [[ -n "$v_sid" ]]  && uri+="&sid=${v_sid}"
        uri+="&fp=${v_fp}#${tag}"
        echo -e "  ${C}▶ VLESS Reality${NC}  ${DIM}${tag}${NC}"
        echo -e "  ${W}${uri}${NC}"
        blank ;;
    esac
  done < <(_list_outbounds)

  if ! $has_any; then
    info "暂无出站节点 URI（仅显示本地代理）"
    blank
  fi

  # 二维码（可选）
  if command -v qrencode &>/dev/null; then
    info "提示: 终端支持 qrencode，可手动用以下命令生成二维码:"
    echo -e "  ${DIM}  echo \"链接\" | qrencode -t ANSIUTF8${NC}"
  else
    info "${DIM}如需二维码，可安装: apt install qrencode 或 yum install qrencode${NC}"
  fi
  blank; pause
}

# ══════════════════════════════════════════════════════════════════════
#  ██  配置查看
# ══════════════════════════════════════════════════════════════════════
do_view_config() {
  blank
  echo -e "  ${BOLD}当前配置文件${NC}  ${DIM}${CONFIG_FILE}${NC}"
  sep
  if [[ -f "$CONFIG_FILE" ]]; then
    cat -n "$CONFIG_FILE"
  else
    warn "配置文件不存在: $CONFIG_FILE"
  fi
  pause
}

# ══════════════════════════════════════════════════════════════════════
#  ██  快捷命令模块
# ══════════════════════════════════════════════════════════════════════
_alias_is_set() {
  [[ -f "$CMD_LOWER" ]] || [[ -f "$CMD_UPPER" ]]
}

setup_alias_prompt() {
  _alias_is_set && return
  [[ -f "$ALIAS_SKIP_FLAG" ]] && return
  [[ $EUID -ne 0 ]] && return

  clear
  echo ""
  echo -e "  ${C}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${C}║${NC}           ${BOLD}设置快捷命令${NC}                             ${C}║${NC}"
  echo -e "  ${C}╠══════════════════════════════════════════════════════╣${NC}"
  echo -e "  ${C}║${NC}                                                      ${C}║${NC}"
  echo -e "  ${C}║${NC}  检测到尚未设置全局快捷命令。                        ${C}║${NC}"
  echo -e "  ${C}║${NC}                                                      ${C}║${NC}"
  echo -e "  ${C}║${NC}  设置后，SSH 登录任意目录直接输入                    ${C}║${NC}"
  echo -e "  ${C}║${NC}  （大写小写均可）：                                  ${C}║${NC}"
  echo -e "  ${C}║${NC}                                                      ${C}║${NC}"
  echo -e "  ${C}║${NC}      ${W}${BOLD}x${NC}   或   ${W}${BOLD}X${NC}                                  ${C}║${NC}"
  echo -e "  ${C}║${NC}                                                      ${C}║${NC}"
  echo -e "  ${C}║${NC}  即可打开此管理菜单，无需记住脚本路径。              ${C}║${NC}"
  echo -e "  ${C}║${NC}                                                      ${C}║${NC}"
  echo -e "  ${C}╠══════════════════════════════════════════════════════╣${NC}"
  echo -e "  ${C}║${NC}  ${W}Y${NC}  立即设置  ${DIM}(推荐)${NC}                             ${C}║${NC}"
  echo -e "  ${C}║${NC}  ${W}N${NC}  本次跳过                                      ${C}║${NC}"
  echo -e "  ${C}║${NC}  ${W}S${NC}  不再提示                                      ${C}║${NC}"
  echo -e "  ${C}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  printf "  请选择 [Y/n/s]: "
  read -rn1 ans; echo ""

  case "${ans,,}" in
    y|"") _do_setup_alias ;;
    s)
      mkdir -p "$(dirname "$ALIAS_SKIP_FLAG")"
      touch "$ALIAS_SKIP_FLAG"
      info "已记住，下次不再提示。"
      sleep 1
      ;;
    *) info "已跳过，下次运行时仍会提示。"; sleep 1 ;;
  esac
}

_do_setup_alias() {
  # 同时创建小写 x 和大写 X 两个命令
  cp -f "$SCRIPT_PATH" "$CMD_LOWER" && chmod +x "$CMD_LOWER"
  cp -f "$SCRIPT_PATH" "$CMD_UPPER" && chmod +x "$CMD_UPPER"

  # profile.d 标记（登录时无需额外操作，直接靠 PATH 里的可执行文件生效）
  cat > "$ALIAS_MARKER" <<'EOF'
# sing-box 快捷命令标记（由 singbox.sh 自动生成，勿手动删除）
EOF

  blank
  ok "快捷命令已设置！"
  info "已安装: ${W}${CMD_LOWER}${NC}  和  ${W}${CMD_UPPER}${NC}"
  blank
  echo -e "  ${G}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "  ${G}║${NC}  现在起，SSH 登录后直接输入:                  ${G}║${NC}"
  echo -e "  ${G}║${NC}                                                ${G}║${NC}"
  echo -e "  ${G}║${NC}      ${W}${BOLD}x${NC}   或   ${W}${BOLD}X${NC}   （大小写均可）           ${G}║${NC}"
  echo -e "  ${G}║${NC}                                                ${G}║${NC}"
  echo -e "  ${G}║${NC}  即可打开管理菜单                              ${G}║${NC}"
  echo -e "  ${G}╚══════════════════════════════════════════════════╝${NC}"
  blank
  sleep 2
}

do_manage_alias() {
  print_banner
  echo -e "  ${BOLD}${C}── 快捷命令管理 ──────────────────────────────────────${NC}"
  blank

  if _alias_is_set; then
    ok "快捷命令已设置"
    [[ -f "$CMD_LOWER" ]] && info "命令: ${W}x${NC}  →  ${DIM}${CMD_LOWER}${NC}"
    [[ -f "$CMD_UPPER" ]] && info "命令: ${W}X${NC}  →  ${DIM}${CMD_UPPER}${NC}"
    blank
    echo -e "  ${W}1${NC}  更新命令（同步当前脚本到 x / X）"
    echo -e "  ${W}2${NC}  移除快捷命令"
    echo -e "  ${W}0${NC}  返回"
    blank; sep
    printf "  请选择 [0-2]: "
    read -rn1 sub; echo ""
    case "$sub" in
      1) need_root; _do_setup_alias ;;
      2)
        need_root
        read -rp "  确认移除快捷命令 x / X? [y/N]: " c
        if [[ "${c,,}" == "y" ]]; then
          rm -f "$CMD_LOWER" "$CMD_UPPER" "$ALIAS_MARKER" "$ALIAS_SKIP_FLAG"
          ok "快捷命令 x / X 已移除"
        else
          info "已取消"
        fi
        sleep 1 ;;
      *) return ;;
    esac
  else
    warn "快捷命令尚未设置"
    blank
    read -rp "  立即设置 x / X 命令? [Y/n]: " c
    [[ "${c,,}" != "n" ]] && { need_root; _do_setup_alias; }
  fi
  pause
}

# ══════════════════════════════════════════════════════════════════════
#  ██  主菜单
# ══════════════════════════════════════════════════════════════════════
main_menu() {
  # 首次运行时弹出快捷键设置提示
  setup_alias_prompt

  while true; do
    print_banner
    status_bar
    blank

    echo -e "  ${BOLD}${W}  安装管理${NC}"
    echo -e "  ${W}  1${NC}  安装 sing-box"
    echo -e "  ${W}  2${NC}  修改端口 / 账号 / 密码"
    echo -e "  ${W}  3${NC}  升级到最新版本"
    echo -e "  ${W}  4${NC}  卸载 sing-box"
    blank

    # 出站节点状态
    local _proxy_tag _proxy_label _nodes_count=0
    if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
      _proxy_tag=$(jq -r '.route.final' "$CONFIG_FILE" 2>/dev/null || echo "direct")
      _nodes_count=$(jq '[.outbounds[]|select(.tag!="direct" and .tag!="block")]|length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    else
      _proxy_tag="direct"
    fi
    if [[ "$_proxy_tag" != "direct" && "$_proxy_tag" != "block" && -f "$CONFIG_FILE" ]]; then
      local _ptype _pserver _pport
      _ptype=$(jq -r --arg t "$_proxy_tag" '.outbounds[]|select(.tag==$t)|.type' "$CONFIG_FILE" 2>/dev/null)
      _pserver=$(jq -r --arg t "$_proxy_tag" '.outbounds[]|select(.tag==$t)|.server' "$CONFIG_FILE" 2>/dev/null)
      _pport=$(jq -r --arg t "$_proxy_tag" '.outbounds[]|select(.tag==$t)|.server_port' "$CONFIG_FILE" 2>/dev/null)
      _proxy_label="${G}● ${_ptype^^} ${_pserver}:${_pport}${NC} ${DIM}(共 ${_nodes_count} 个节点)${NC}"
    elif (( _nodes_count > 0 )); then
      _proxy_label="${Y}○ 直连${NC} ${DIM}(已配置 ${_nodes_count} 个节点未激活)${NC}"
    else
      _proxy_label="${DIM}直连（未配置出站节点）${NC}"
    fi

    echo -e "  ${BOLD}${W}  出站节点${NC}  $_proxy_label"
    echo -e "  ${W}  5${NC}  获取本地代理地址"
    echo -e "  ${W}  6${NC}  添加 Hysteria2 节点"
    echo -e "  ${W}  7${NC}  添加 TUIC 节点"
    echo -e "  ${W}  8${NC}  添加 vless+reality 节点"
    echo -e "  ${W}  9${NC}  节点管理（列表 / 切换 / 删除）"
    blank

    echo -e "  ${BOLD}${W}  服务控制${NC}"
    echo -e "  ${W} 10${NC}  启动服务"
    echo -e "  ${W} 11${NC}  停止服务"
    echo -e "  ${W} 12${NC}  重启服务"
    echo -e "  ${W} 13${NC}  查看服务状态"
    blank

    echo -e "  ${BOLD}${W}  代理测试${NC}"
    echo -e "  ${W} 14${NC}  快速连通性测试        ${DIM}检测代理可用性及出口 IP${NC}"
    echo -e "  ${W} 15${NC}  延迟基准测试          ${DIM}多目标延迟量化评估${NC}"
    echo -e "  ${W} 16${NC}  认证配置验证          ${DIM}验证用户名密码是否生效${NC}"
    echo -e "  ${W} 17${NC}  完整诊断报告          ${DIM}服务/端口/连通/认证全检${NC}"
    blank

    echo -e "  ${BOLD}${W}  其他${NC}"
    echo -e "  ${W} 18${NC}  查看当前配置文件"
    echo -e "  ${W} 19${NC}  查看实时日志"
    echo -e "  ${W} 20${NC}  导出节点 URI / 订阅链接"
    echo -e "  ${W} 21${NC}  备份当前配置"
    echo -e "  ${W} 22${NC}  从备份恢复"
    if _alias_is_set; then
      echo -e "  ${W} 23${NC}  快捷命令管理             ${DIM}x / X 命令: ${G}已设置${NC}"
    else
      echo -e "  ${W} 23${NC}  设置快捷命令             ${Y}⚠ 尚未设置，输入 x 或 X 可快速打开${NC}"
    fi
    blank

    echo -e "  ${W}  0${NC}  退出"
    blank
    sep
    printf "  请选择 [0-23]: "
    read -r choice

    case "$choice" in
      1)  do_install ;;
      2)  do_edit_config ;;
      3)  do_upgrade ;;
      4)  do_uninstall ;;
      5)  print_banner; do_get_proxy_addr ;;
      6)  do_add_hysteria2 ;;
      7)  do_add_tuic ;;
      8)  do_add_vless_reality ;;
      9)  do_manage_outbound ;;
      10) svc_action start   "启动" ;;
      11) svc_action stop    "停止" ;;
      12) svc_action restart "重启" ;;
      13) do_svc_status ;;
      14) print_banner; test_quick ;;
      15) print_banner; test_latency ;;
      16) print_banner; test_auth ;;
      17) print_banner; test_full ;;
      18) print_banner; do_view_config ;;
      19) do_view_log ;;
      20) do_show_uri ;;
      21) do_backup ;;
      22) do_restore ;;
      23) do_manage_alias ;;
      0)  blank; echo -e "  ${DIM}再见。${NC}"; blank; exit 0 ;;
      *)  warn "无效选项「${choice}」，请输入 0-23"; sleep 1 ;;
    esac
  done
}

main_menu
