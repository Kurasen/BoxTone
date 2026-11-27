#!/usr/bin/env bash
#
# 盒音工坊 · 内存复现：自动反复切前后台（docs/stability-oom.md 第 5 节）
#
# 上架测试崩溃前的场景：进程存活 53 分钟，每 5~10 秒进出前台一次（打开系统蓝牙设置再返回），
# 崩溃点在回前台的 OnShow。App 内部模拟不了「切到别的应用再回来」，这里用 hdc 驱动：
#   回桌面（Home 键）→ 等 BG 秒 → aa start 拉回前台 → 等 FG 秒，循环 N 次。
# 同时把 hilog 里的 MemProbe 行（MEM_SAMPLE / MEM_DUP / MEM_LEAK）存到 dist/mem-repro-时间.log。
# 另记两类：DEVICE_FOUND_IGNORED / SCAN_SUMMARY（蓝牙发现结果统计）；OnScanModeChanged ... mode: 4
# （系统蓝牙设置页打开时手机进入可被发现模式——settings 模式下没有这行，说明根本没进到蓝牙页）。
#
# 用法：
#   ./tools/mem-repro.sh            默认 100 轮，前台 4 秒、后台 2 秒（约 10 分钟）
#   ./tools/mem-repro.sh 300 3 2    300 轮，前台 3 秒、后台 2 秒
#   ./tools/mem-repro.sh 30 4 8 settings
#                                   切后台时打开「系统设置 → 蓝牙」页停 8 秒再回来（上架测试现场的真实路径，见 docs/stability-oom.md 第 2 节）。
#                                   系统蓝牙页会自己扫描附近设备；旧包会把这些扫描结果也收进「附近设备」列表。
#                                   aa start 的 -U（uri）参数按 OpenHarmony 惯例写，本地 SDK 未查到文档，首轮先看手机是否真的进了蓝牙页
#
# 没有 MemProbe 的包（例如 main 上的旧版本，用来做对照）：每 10 轮额外用 hidumper 记一次进程内存，
# 写进同一个日志（HIDUMPER 开头）。hidumper 的参数和输出格式在本地 SDK 里没有文档，
# 是按 OpenHarmony 惯例写的：第一次跑先看日志里这几行是不是真的有数字。
#
# 前提：已用 ./tools/dev.sh 装好 debug 包、隐私已同意、蓝牙权限已授予、手机上有已配对耳机
#      （设备页要有设备行，DeviceRow 才会被计数；测试平台截图里设备页就是满的）。
# 停在设备页开始最接近测试现场；中途按 Ctrl-C 结束，日志文件保留。
#
# 注意：模拟按键的 uitest 命令没有在本地 SDK 文档里查到，首次运行先看一轮是否真的回到了桌面；
#       不行就改用 HOME_FALLBACK（uinput 注入 KEYCODE_HOME=1）。
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ROUNDS="${1:-100}"
FG_SEC="${2:-4}"
BG_SEC="${3:-2}"
# home：Home 键回桌面；settings：打开系统蓝牙设置页
BG_MODE="${4:-home}"

BUNDLE="com.boxtone.audiokit"
ABILITY="EntryAbility"
DEVECO_HOME="${DEVECO_HOME:-D:/App/DevEco Studio}"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"

HDC=""
for p in "$DEVECO_SDK_HOME"/default/openharmony/toolchains/hdc.exe \
         "$DEVECO_SDK_HOME"/default/hms/toolchains/hdc.exe; do
  [[ -x "$p" ]] && HDC="$p" && break
done
[[ -z "$HDC" ]] && command -v hdc >/dev/null 2>&1 && HDC="$(command -v hdc)"
[[ -n "$HDC" ]] || { echo "未找到 hdc"; exit 1; }

if [[ -z "$("$HDC" list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Empty\]$' | grep -v '^$')" ]]; then
  echo "设备未连接：先跑一次 ./tools/dev.sh reconnect"
  exit 1
fi

press_home() {
  "$HDC" shell uitest uiInput keyEvent Home >/dev/null 2>&1 && return 0
  # HOME_FALLBACK
  "$HDC" shell uinput -K -d 1 -u 1 >/dev/null 2>&1
}

mkdir -p dist
OUT="dist/mem-repro-$(date +%Y%m%d-%H%M%S).log"
echo "日志写到 $OUT（只保留 MemProbe 行）"
# 两个写入方都必须用追加（O_APPEND）：之前 hilog 这路用 >，它按自己的偏移写，
# 会把循环里 >> 追加的 HIDUMPER 行覆盖掉（11-27 10:16 那轮 10、20 轮的记录就是这样丢的）
: > "$OUT"

# 后台持续抓 hilog；退出时一并结束
"$HDC" shell hilog 2>/dev/null | tr -d '\r' | grep --line-buffered -E 'MemProbe|STRESS_|DEVICE_FOUND_IGNORED|SCAN_SUMMARY|audiokit.*OnScanModeChanged|jscrash|OutOfMemory' >> "$OUT" &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null; echo; echo "结束，日志：$OUT"; exit 0' INT TERM EXIT

"$HDC" shell aa start -a "$ABILITY" -b "$BUNDLE" >/dev/null 2>&1
sleep "$FG_SEC"

open_bt_settings() {
  # 与 BluetoothService.openSystemBluetoothSettings 用同一个 Want
  "$HDC" shell aa start -b com.huawei.hmos.settings -a com.huawei.hmos.settings.MainAbility -U bluetooth_entry >/dev/null 2>&1
}

for ((i = 1; i <= ROUNDS; i++)); do
  if [[ "$BG_MODE" == "settings" ]]; then
    open_bt_settings
  else
    press_home
  fi
  sleep "$BG_SEC"
  "$HDC" shell aa start -a "$ABILITY" -b "$BUNDLE" >/dev/null 2>&1
  sleep "$FG_SEC"
  if (( i % 10 == 0 )); then
    pid=$("$HDC" shell pidof "$BUNDLE" 2>/dev/null | tr -d '\r' | awk '{print $1}')
    if [[ -n "$pid" ]]; then
      # hidumper --mem 的表头（11-27 实测）：Pss Total | Shared Clean | Shared Dirty | Private Clean | Private Dirty |
      # Swap Total | SwapPss Total | Heap Size | Heap Alloc | Heap Free，单位 KB。只取每类的第一行，后面的明细段也带同名行
      dump=$("$HDC" shell hidumper --mem "$pid" 2>/dev/null | tr -d '\r' | awk '
        !a && /^[[:space:]]*ark ts heap[[:space:]]+[0-9]/ { ark = $4; a = 1 }
        !n && /^[[:space:]]*native heap[[:space:]]+[0-9]/ { nat = $3; nalloc = $(NF - 1); n = 1 }
        !t && /^[[:space:]]*Total[[:space:]]+[0-9]/ { tot = $2; t = 1 }
        END {
          if (t) printf "pss=%.1fMB ark=%.1fMB native=%.1fMB nativeAlloc=%.1fMB", tot / 1024, ark / 1024, nat / 1024, nalloc / 1024
        }')
      printf '%s HIDUMPER round=%s pid=%s %s\n' "$(date +%H:%M:%S)" "$i" "$pid" "${dump:-（无输出）}" >> "$OUT"
    else
      printf '%s HIDUMPER round=%s 进程不在（崩了？）\n' "$(date +%H:%M:%S)" "$i" >> "$OUT"
    fi
    last=$(grep 'MEM_SAMPLE' "$OUT" | tail -1 | grep -oE 'heap=[^ ]+ limit=[^ ]+ rss=[^ ]+' || true)
    # 旧包没有 MemProbe：终端里退回显示 hidumper 的数字
    [[ -z "$last" ]] && last=$(grep 'HIDUMPER' "$OUT" | tail -1 | grep -oE 'pss=.*' || true)
    printf '第 %s/%s 轮  %s\n' "$i" "$ROUNDS" "${last:-（还没有采样）}"
  fi
done
