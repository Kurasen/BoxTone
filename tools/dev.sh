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
#
# 可覆盖的环境变量：
#   DEVECO_HOME   DevEco Studio 安装目录，默认 D:/App/DevEco Studio
#   DEVECO_SDK_HOME  SDK 目录，默认 $DEVECO_HOME/sdk
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

need_device() {
  [[ -n "$HDC" ]] || { die "未找到 hdc（在 $DEVECO_SDK_HOME/default/openharmony/toolchains 下）"; exit 1; }
  local targets
  targets=$("$HDC" list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Empty\]$' | grep -v '^$')
  if [[ -z "$targets" ]]; then
    die "没有已连接设备"
    echo "    1. 手机开启「开发者选项 → USB 调试」"
    echo "    2. 数据线连接后，手机上点「允许调试」"
    echo "    3. 确认：${DIM}\"$HDC\" list targets${NC}"
    exit 1
  fi
  ok "设备：$(echo "$targets" | head -1)"
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
  need_device
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
  need_device
  info "启动应用"
  "$HDC" shell aa start -a "$ABILITY" -b "$BUNDLE" >/dev/null 2>&1 \
    && ok "已启动（没反应就检查 ability 名是否正确）" \
    || warn "aa start 返回非零，手动点图标试试"
}

do_reinstall() {
  need_device
  warn "卸载会清空应用数据（音效库、设置、日志），仅在签名变更后必须重装时使用"
  info "卸载旧包"
  "$HDC" uninstall "$BUNDLE" 2>&1 | tr -d '\r' | tail -1
  do_install
}

do_log() {
  need_device
  info "应用日志（Ctrl-C 退出）　${DIM}只看 $LOG_TAG 相关${NC}"
  "$HDC" shell hilog 2>/dev/null | tr -d '\r' | grep --line-buffered -E "$LOG_TAG|JSAPP|jscrash" || true
}

do_stop() {
  need_device
  "$HDC" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 && ok "已停止" || warn "停止失败"
}

do_devices() {
  [[ -n "$HDC" ]] || { die "未找到 hdc"; exit 1; }
  info "hdc list targets"
  "$HDC" list targets 2>&1 | tr -d '\r'
}

case "$MODE" in
  build)     do_build ;;
  install)   do_install ;;
  run)       do_run ;;
  reinstall) do_reinstall ;;
  log)       do_log ;;
  stop)      do_stop ;;
  devices)   do_devices ;;
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
