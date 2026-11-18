#!/usr/bin/env bash
#
# 盒音工坊 · 真机调试循环
#
# 一条命令走完「构建 → 安装 → 启动 → 看日志」，不用开 IDE。
#
# 用法：
#   ./tools/dev.sh            构建 + 安装 + 启动 + 跟日志
#   ./tools/dev.sh build      只构建 debug HAP
#   ./tools/dev.sh install    只安装已有产物（增量覆盖）
#   ./tools/dev.sh run        只启动已安装的应用
#   ./tools/dev.sh reinstall  卸载后重装（会清空应用数据，换签名后必须用）
#   ./tools/dev.sh log        只看应用日志（Ctrl-C 退出）
#   ./tools/dev.sh stop       强制停止应用
#   ./tools/dev.sh devices    列出已连接设备
#   ./tools/dev.sh reconnect  只重连无线调试（不构建不安装）
#
# 可覆盖的环境变量：
#   DEVECO_HOME      DevEco Studio 安装目录，默认 D:/App/DevEco Studio
#   DEVECO_SDK_HOME  SDK 目录，默认 $DEVECO_HOME/sdk
#   BOX_HDC_TARGET   无线调试地址 ip:port；不设则用 tools/.hdc-target 里记的上一次地址
#   BOX_HDC_RETRY    自动重连的轮数，默认 6（每轮 1 秒）
#
# 无线调试地址平时会自动记住：任何一次连上后都写进 tools/.hdc-target，
# 断了以后下次运行会自动 tconn 回去。端口变了就用 BOX_HDC_TARGET 指定一次即可。
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; NC=$'\033[0m'
info() { printf '%s==>%s %s\n' "$CYAN" "$NC" "$1"; }
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '%s  !%s %s\n' "$YELLOW" "$NC" "$1"; }
die()  { printf '%s  ✗%s %s\n' "$RED" "$NC" "$1"; }

MODE="${1:-all}"

BUNDLE="com.boxtone.audiokit"
ABILITY="EntryAbility"
HAP="entry/build/default/outputs/default/entry-default-signed.hap"
LOG_TAG="BoxTone"

# ---------------- 工具链定位 ----------------
DEVECO_HOME="${DEVECO_HOME:-D:/App/DevEco Studio}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"

NODE="$DEVECO_HOME/tools/node/node.exe"
HVIGOR="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
HDC=""

for p in "$DEVECO_SDK_HOME"/default/openharmony/toolchains/hdc.exe \
         "$DEVECO_SDK_HOME"/default/hms/toolchains/hdc.exe; do
  [[ -x "$p" ]] && HDC="$p" && break
done
[[ -z "$HDC" ]] && command -v hdc >/dev/null 2>&1 && HDC="$(command -v hdc)"

need_build_tools() {
  [[ -x "$NODE" ]] || { die "未找到 node：$NODE（用 DEVECO_HOME 指定 DevEco 目录）"; exit 1; }
  [[ -f "$HVIGOR" ]] || { die "未找到 hvigor：$HVIGOR"; exit 1; }
  [[ -d "$DEVECO_SDK_HOME" ]] || { die "未找到 SDK：$DEVECO_SDK_HOME"; exit 1; }
}

# ---------------- 设备连接（含无线调试自动重连） ----------------
# 记住上一次连上的 ip:port。无线调试断开后 hdc 不会自己重连，
# 每次都要手动 tconn 很烦，这里把地址缓存下来并自动重试。
TARGET_CACHE="$PWD/tools/.hdc-target"

targets_now() {
  "$HDC" list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Empty\]$' | grep -v '^$'
}

remember_target() {
  local t="$1"
  [[ "$t" == *:* ]] || return 0
  printf '%s\n' "$t" > "$TARGET_CACHE" 2>/dev/null || true
}

ensure_device() {
  [[ -n "$HDC" ]] || { die "未找到 hdc（在 $DEVECO_SDK_HOME/default/openharmony/toolchains 下）"; exit 1; }

  local current
  current=$(targets_now)
  if [[ -n "$current" ]]; then
    remember_target "$(echo "$current" | head -1)"
    ok "设备：$(echo "$current" | head -1)"
    return 0
  fi

  # 没连上：拿候选地址自动 tconn 回去
  local candidates=()
  [[ -n "${BOX_HDC_TARGET:-}" ]] && candidates+=("$BOX_HDC_TARGET")
  if [[ -f "$TARGET_CACHE" ]]; then
    local cached
    cached=$(tr -d '\r\n' < "$TARGET_CACHE" 2>/dev/null)
    [[ -n "$cached" ]] && candidates+=("$cached")
  fi

  if [[ ${#candidates[@]} -gt 0 ]]; then
    info "设备未连接，尝试自动重连无线调试"
    local round tries="${BOX_HDC_RETRY:-6}"
    for ((round = 1; round <= tries; round++)); do
      local key
      for key in "${candidates[@]}"; do
        [[ -n "$key" ]] || continue
        printf '%s  .%s tconn %s（第 %s/%s 轮）%s\n' "$DIM" "$NC" "$key" "$round" "$tries" "$NC"
        "$HDC" tconn "$key" >/dev/null 2>&1 || true
        current=$(targets_now)
        if [[ -n "$current" ]]; then
          remember_target "$(echo "$current" | head -1)"
          ok "已自动连上：$(echo "$current" | head -1)"
          return 0
        fi
      done
      [[ "$round" -lt "$tries" ]] && sleep 1
    done
  fi

  die "没有已连接设备"
  echo "    1. 手机开启「开发者选项 → 无线调试」，或插 USB 数据线"
  echo "    2. 无线调试的端口每次重开都会变；拿到新地址后指定一次："
  echo "       ${DIM}BOX_HDC_TARGET=192.168.x.x:xxxxx ./tools/dev.sh install${NC}"
  echo "    3. 之后会自动记住（${DIM}$TARGET_CACHE${NC}）"
  echo "    4. 手动确认：${DIM}\"$HDC\" list targets${NC}"
  exit 1
}

# ---------------- 各步骤 ----------------
do_build() {
  need_build_tools
  info "构建 debug HAP"
  local start=$SECONDS
  if "$NODE" "$HVIGOR" --mode module -p product=default -p buildMode=debug \
      -p requiredDeviceType=phone assembleHap --no-daemon; then
    ok "构建成功，用时 $((SECONDS - start))s"
    [[ -f "$HAP" ]] || { warn "未找到产物 $HAP"; return 1; }
    ok "产物：$HAP ($(du -h "$HAP" | cut -f1))"
  else
    die "构建失败"
    echo "    debug↔release 来回切换后首次可能报 00308018，原样重跑一次即可"
    echo "    签名密码缺失会报 00303116 → 检查 signing/debug-password.txt"
    return 1
  fi
}

do_install() {
  ensure_device
  [[ -f "$HAP" ]] || { die "产物不存在，先执行 ./tools/dev.sh build"; exit 1; }
  info "安装到设备"
  local out
  out=$("$HDC" install -r "$HAP" 2>&1 | tr -d '\r')
  echo "$out" | tail -2
  if echo "$out" | grep -qi "success"; then
    ok "安装完成"
  else
    die "安装失败"
    echo "    常见原因：签名与设备不匹配 / 设备空间不足 / 已安装更高版本（先卸载）"
    echo "    卸载：${DIM}\"$HDC\" uninstall $BUNDLE${NC}"
    exit 1
  fi
}

do_run() {
  ensure_device
  info "启动应用"
  "$HDC" shell aa start -a "$ABILITY" -b "$BUNDLE" >/dev/null 2>&1 \
    && ok "已启动（没反应就检查 ability 名是否正确）" \
    || warn "aa start 返回非零，手动点图标试试"
}

do_reinstall() {
  ensure_device
  warn "卸载会清空应用数据（音效库、设置、日志），仅在签名变更后必须重装时使用"
  info "卸载旧包"
  "$HDC" uninstall "$BUNDLE" 2>&1 | tr -d '\r' | tail -1
  do_install
}

do_log() {
  ensure_device
  info "应用日志（Ctrl-C 退出）　${DIM}只看 $LOG_TAG 相关${NC}"
  "$HDC" shell hilog 2>/dev/null | tr -d '\r' | grep --line-buffered -E "$LOG_TAG|JSAPP|jscrash" || true
}

do_stop() {
  ensure_device
  "$HDC" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 && ok "已停止" || warn "停止失败"
}

do_devices() {
  [[ -n "$HDC" ]] || { die "未找到 hdc"; exit 1; }
  info "hdc list targets"
  "$HDC" list targets 2>&1 | tr -d '\r'
  if [[ -f "$TARGET_CACHE" ]]; then
    echo "    ${DIM}缓存地址：$(tr -d '\r\n' < "$TARGET_CACHE")${NC}"
  fi
}

do_reconnect() {
  [[ -n "$HDC" ]] || { die "未找到 hdc"; exit 1; }
  info "重连无线调试"
  # 先断开缓存里的旧连接，再走一轮完整重连
  local cached=""
  [[ -f "$TARGET_CACHE" ]] && cached=$(tr -d '\r\n' < "$TARGET_CACHE" 2>/dev/null)
  [[ -n "$cached" ]] && "$HDC" tconn "$cached" -remove >/dev/null 2>&1 || true
  ensure_device
}

case "$MODE" in
  build)     do_build ;;
  install)   do_install ;;
  run)       do_run ;;
  reinstall) do_reinstall ;;
  log)       do_log ;;
  stop)      do_stop ;;
  devices)   do_devices ;;
  reconnect) do_reconnect ;;
  all)
    do_build || exit 1
    do_install
    do_run
    do_log
    ;;
  *)
    die "未知参数：$MODE"
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
