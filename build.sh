#!/usr/bin/env bash
#
# 盒音工坊 · 构建辅助脚本
#
# 说明：HAP 必须由 HarmonyOS SDK 工具链产出（ArkTS 编译器 es2abc + 资源编译器 restool），
#      纯 shell 无法替代。本脚本做三件事：环境预检、按需触发构建、打印产物路径。
#
# 用法：
#   ./build.sh            预检并构建 debug HAP
#   ./build.sh check      只做预检，不构建
#   ./build.sh clean      清理构建产物
#
set -uo pipefail
cd "$(dirname "$0")" || exit 1

CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; NC=$'\033[0m'

info() { printf '%s==>%s %s\n' "$CYAN" "$NC" "$1"; }
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '%s  !%s %s\n' "$YELLOW" "$NC" "$1"; }
die()  { printf '%s  ✗%s %s\n' "$RED" "$NC" "$1"; }

MODE="${1:-build}"

if [[ "$MODE" == "clean" ]]; then
  rm -rf entry/build build .hvigor .cxx
  ok "已清理 entry/build、build、.hvigor"
  exit 0
fi

echo
info "环境预检"

# ---- Node（hvigor 依赖）----
if command -v node >/dev/null 2>&1; then
  ok "node $(node -v)"
else
  die "未找到 node —— hvigor 需要 Node.js 18+"
  exit 1
fi

# ---- hvigor 包装器（DevEco 首次打开工程时生成）----
HAS_WRAPPER=0
[[ -x ./hvigorw ]] && HAS_WRAPPER=1

if [[ $HAS_WRAPPER -eq 1 ]]; then
  ok "找到 hvigorw 包装器"
else
  warn "未找到 hvigorw —— 这是 DevEco Studio 首次打开工程时自动生成的，需要先打开一次"
fi

# ---- SDK ----
SDK_HINT=""
for p in "$HOME/Library/Huawei/Sdk" "$HOME/Huawei/Sdk" "$HOME/.huawei/sdk" "/opt/harmonyos-sdk" "${LOCALAPPDATA:-$HOME/AppData/Local}/Huawei/Sdk"; do
  [[ -d "$p" ]] && SDK_HINT="$p" && break
done

if [[ -n "$SDK_HINT" ]]; then
  ok "SDK 目录：$SDK_HINT"
  if [[ -d "$SDK_HINT"/*/HarmonyOS-NEXT-DB* || -d "$SDK_HINT"/*/openharmony ]]; then
    ok "检测到 API 26 候选目录（请确认版本为 7.0.0 及以上）"
  fi
else
  warn "未在常见路径找到 HarmonyOS SDK"
fi

# ---- 工程完整性快检 ----
PROBLEMS=0
for f in AppScope/app.json5 build-profile.json5 entry/src/main/module.json5 \
         entry/src/main/ets/pages/Index.ets entry/src/main/resources/base/profile/main_pages.json; do
  [[ -f "$f" ]] || { die "缺少文件：$f"; PROBLEMS=1; }
done

MEDIA_DIR="entry/src/main/resources/base/media"
if [[ -d "$MEDIA_DIR" ]]; then
  MISSING=""
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    ls "$MEDIA_DIR/$name".* >/dev/null 2>&1 || MISSING="$MISSING $name"
  done < <(grep -rhoE 'app\.media\.[A-Za-z0-9_]+' entry/src/main --include='*.ets' \
             | sed 's/app\.media\.//' | sort -u)
  if [[ -z "$MISSING" ]]; then
    ok "图片资源引用完整（$(ls "$MEDIA_DIR" | wc -l | tr -d ' ') 个文件）"
  else
    die "缺少图片资源：$MISSING"
    PROBLEMS=1
  fi
fi

ETS_COUNT=$(find entry/src/main/ets -name '*.ets' | wc -l | tr -d ' ')
ok "ArkTS 源文件 $ETS_COUNT 个"

if [[ $PROBLEMS -ne 0 ]]; then
  echo
  die "预检未通过，请先修复上述问题"
  exit 1
fi

[[ "$MODE" == "check" ]] && { echo; ok "预检通过（未构建）"; exit 0; }

echo
# 优先用工程内的 hvigorw 包装器；没有就直接用 DevEco 自带的 node + hvigor
if [[ $HAS_WRAPPER -eq 1 ]]; then
  BUILD_CMD=(./hvigorw)
else
  DEVECO_HOME="${DEVECO_HOME:-D:/App/DevEco Studio}"
  export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"
  if [[ -x "$DEVECO_HOME/tools/node/node.exe" && -f "$DEVECO_HOME/tools/hvigor/bin/hvigorw.js" ]]; then
    BUILD_CMD=("$DEVECO_HOME/tools/node/node.exe" "$DEVECO_HOME/tools/hvigor/bin/hvigorw.js")
    ok "使用 DevEco 自带 hvigor：$DEVECO_HOME"
  else
    info "无法在命令行构建，请用 DevEco Studio 打开工程后："
    echo "    ${DIM}Build → Build Hap(s) / APP(s) → Build Hap(s)${NC}"
    echo "    ${DIM}或右键 entry → Build → Build Hap${NC}"
    echo
    echo "  首次构建必须先在 IDE 内完成签名配置（需登录华为账号）："
    echo "    ${DIM}File → Project Structure → Signing Configs → 勾选 Automatically generate signature${NC}"
    echo
    echo "  产物位置："
    echo "    ${DIM}entry/build/default/outputs/default/entry-default-signed.hap${NC}"
    exit 0
  fi
fi

info "构建 debug HAP"
if "${BUILD_CMD[@]}" --mode module -p product=default -p buildMode=debug -p requiredDeviceType=phone assembleHap --no-daemon; then
  echo
  HAP=$(ls -1 entry/build/default/outputs/default/*.hap 2>/dev/null | head -1)
  if [[ -n "$HAP" ]]; then
    ok "构建成功：$HAP ($(du -h "$HAP" | cut -f1))"
    echo
    echo "  安装到真机：${DIM}hdc install -r \"$HAP\"${NC}"
  else
    warn "构建命令返回成功，但未找到 .hap 产物"
  fi
else
  echo
  die "构建失败 —— 常见原因：SDK 未安装 API 26 / 签名未配置 / hvigor 依赖未同步（先执行 ohpm install）"
  exit 1
fi
