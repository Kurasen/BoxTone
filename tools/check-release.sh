#!/usr/bin/env bash
#
# 盒音工坊 · release 混淆体检
#
# 判断「release 包少东西」是不是混淆把名字改坏了：native 函数名或返回字段名被
# 改成短名后，运行时要么 throw 被 catch 吞掉，要么读成 undefined，界面上就是
# 「功能没了」，而 debug 包因为不混淆永远复现不了。
#
# 用法：
#   ./tools/check-release.sh           构建 release → 静态检查 → 产物检查（默认）
#   ./tools/check-release.sh static    只做静态检查（秒出，不构建）
#   ./tools/check-release.sh verify    只检查现有 HAP 产物，不构建
#   ./tools/check-release.sh build     只构建 release HAP
#   ./tools/check-release.sh list      列出会被检查的名字及其来源
#
# 检查什么：
#   1. 静态：libaudiodec.so 在 .d.ts 里导出的函数名、以及原生返回对象的字段名，
#      是否都写进了 obfuscation-rules.txt 的 -keep-property-name；源码里实际
#      import 的名字也一并核对。这层不用构建，新加原生接口忘了写规则当场就能发现。
#   2. 产物：从 HAP 取出 ets/modules.abc（混淆后的字节码），逐个搜名字。
#      搜不到就是被改名了，release 运行时会失败。
#
# 可覆盖的环境变量：
#   DEVECO_HOME      DevEco Studio 安装目录，默认 D:/App/DevEco Studio
#   DEVECO_SDK_HOME  SDK 目录，默认 $DEVECO_HOME/sdk
#
# 退出码：0 全部通过；1 有名字丢失或构建失败。
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; NC=$'\033[0m'
info() { printf '%s==>%s %s\n' "$CYAN" "$NC" "$1"; }
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '%s  !%s %s\n' "$YELLOW" "$NC" "$1"; }
bad()  { printf '%s  ✗%s %s\n' "$RED" "$NC" "$1"; }
die()  { bad "$1"; exit 1; }

MODE="${1:-all}"

RULES="entry/obfuscation-rules.txt"
HAP="entry/build/default/outputs/default/entry-default-signed.hap"
DTS="entry/src/main/cpp/types/libaudiodec/index.d.ts"
ETS_DIR="entry/src/main/ets"

PROBLEMS=0
TMP_DIR=""
cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -f "$TMP_DIR"/* 2>/dev/null; rmdir "$TMP_DIR" 2>/dev/null; }
trap cleanup EXIT

mkdir_tmp() {
  [[ -n "$TMP_DIR" ]] && return 0
  TMP_DIR="$(mktemp -d 2>/dev/null || echo "entry/build/.check-release.$$")"
  mkdir -p "$TMP_DIR"
}

# ---------------- 规则文件里 keep 了哪些名字 ----------------
# -keep-property-name / -keep-global-name 的值可以换行写，逗号分隔。
keep_names() {
  awk '
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    /^[ \t]*-/ {
      cur = $0
      sub(/^[ \t]*-/, "", cur)
      sub(/[ \t].*$/, "", cur)
      next
    }
    {
      if (cur == "keep-property-name" || cur == "keep-global-name") {
        n = split($0, a, ",")
        for (i = 1; i <= n; i++) {
          gsub(/[ \t]/, "", a[i])
          if (a[i] != "") print a[i]
        }
      }
    }
  ' "$RULES"
}

# ---------------- .d.ts 里的运行时常量 / 函数名 ----------------
dts_exports() {
  grep -oE '^export (const|function) [A-Za-z0-9_]+' "$DTS" | awk '{ print $3 }'
}

# ---------------- .d.ts 里各 interface 的字段名 ----------------
# 这些字段由 C++ 侧 napi_set_named_property 写入，必须保持原名。
dts_fields() {
  awk '
    /^export interface/ { inif = 1; next }
    inif && /^[ \t]*\}/ { inif = 0; next }
    inif {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line ~ /^[A-Za-z0-9_]+\??[ \t]*:/) {
        sub(/[ \t]*:.*$/, "", line)
        sub(/\?$/, "", line)
        print line
      }
    }
  ' "$DTS" | awk '!seen[$0]++'
}

# ---------------- .d.ts 里的类型名（只用于排除，不是运行时名字） ----------------
dts_types() {
  grep -oE '^export (interface|type) [A-Za-z0-9_]+' "$DTS" | awk '{ print $3 }'
}

# ---------------- 源码快照 ----------------
# 一次性把 .ets 拼成一份文本，后面查 import 和查拼写都在这份上做，
# 免得每个名字都去扫一遍目录（Windows 上很慢）。
src_dump() {
  local out="$1"
  grep -rh --include='*.ets' '' "$ETS_DIR" > "$out" 2>/dev/null
}

# ---------------- 从源码快照里取 lib*.so 的导入名 ----------------
# 支持跨行 import：攒到 } 出现为止，再判断语句里有没有 libxxx.so。
ets_so_imports() {
  awk '
    function flush(   inner, n, a, i, p) {
      if (buf ~ /lib[^ ]*\.so/) {
        inner = buf
        sub(/^[^{]*\{/, "", inner)
        sub(/\}.*$/, "", inner)
        n = split(inner, a, ",")
        for (i = 1; i <= n; i++) {
          p = a[i]
          gsub(/^[ \t]+|[ \t]+$/, "", p)
          sub(/^type /, "", p)
          sub(/[ \t]+as[ \t]+.*$/, "", p)
          if (p != "") print p
        }
      }
      buf = ""
      collecting = 0
    }
    {
      if (!collecting) {
        if (index($0, "import") == 0) next
        buf = $0
        collecting = 1
      } else {
        buf = buf " " $0
      }
      if (index(buf, "}") > 0) flush()
    }
  ' "$1" | sort -u
}

in_keep() { printf '%s\n' "$KEEP_LIST" | grep -qxF -- "$1"; }

# ---------------- 静态检查 ----------------
run_static() {
  info "静态检查：原生接口名字是否都写进了 keep 名单"

  [[ -f "$RULES" ]] || die "找不到 $RULES"
  [[ -f "$DTS" ]] || die "找不到 $DTS"
  [[ -d "$ETS_DIR" ]] || die "找不到源码目录 $ETS_DIR"

  mkdir_tmp
  local dump="$TMP_DIR/src.txt"
  src_dump "$dump"

  KEEP_LIST="$(keep_names)"
  ok "keep 名单 $(printf '%s\n' "$KEEP_LIST" | grep -c .) 个名字"

  local types runtime fields imported
  types="$(dts_types)"
  runtime="$(dts_exports | sort -u)"
  fields="$(dts_fields)"
  imported="$(ets_so_imports "$dump")"

  check_group() {
    local label="$1" list="$2" missing=0 name
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      if ! in_keep "$name"; then
        bad "$label $name 没 keep"
        missing=$((missing + 1))
      fi
    done <<< "$list"
    if [[ $missing -eq 0 ]]; then
      ok "$label 全部 $(printf '%s\n' "$list" | grep -c .) 个名字都在 keep 名单"
    else
      PROBLEMS=$((PROBLEMS + missing))
    fi
  }

  check_group "原生函数" "$runtime"
  check_group "原生字段" "$fields"

  # 源码里 import 的名字：排除纯类型（类型不参与运行时）
  local imported_runtime=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qxF -- "$name" <<< "$types" && continue
    imported_runtime+="$name"$'\n'
  done <<< "$imported"
  if [[ -n "${imported_runtime//[$'\n']/}" ]]; then
    check_group "源码导入" "$imported_runtime"
  else
    warn "没扫到从 lib*.so 导入的名字（或全是类型），确认 $ETS_DIR"
  fi

  # keep 名单里的名字在源码里根本不存在：多半是拼错或历史残留
  local ghosts=0 name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in AppStorage|LocalStorage|PersistentStorage) continue ;; esac
    if ! grep -qwF -- "$name" "$dump"; then
      warn "keep 名单里的 $name 在源码里找不到，确认是否拼错"
      ghosts=$((ghosts + 1))
    fi
  done <<< "$KEEP_LIST"
  [[ $ghosts -eq 0 ]] && ok "keep 名单没有拼错或残留项"
}

# ---------------- 构建 release ----------------
run_build() {
  info "构建 release HAP"

  DEVECO_HOME="${DEVECO_HOME:-D:/App/DevEco Studio}"
  export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"

  local NODE="$DEVECO_HOME/tools/node/node.exe"
  local HVIGOR="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
  [[ -x "$NODE" ]] || die "未找到 node：$NODE（用 DEVECO_HOME 指定 DevEco 目录）"
  [[ -f "$HVIGOR" ]] || die "未找到 hvigor：$HVIGOR"

  local log status
  log="$("$NODE" "$HVIGOR" --mode module -p product=default -p buildMode=release \
        -p requiredDeviceType=phone assembleHap --no-daemon 2>&1)"
  status=$?

  if [[ $status -ne 0 ]]; then
    # 最常见的两种失败直接给出处理办法，省得翻 build.log
    if grep -q 'SAFE_DELETE_BULK_CONFIRM_REQUIRED' <<< "$log"; then
      warn "hvigor 清理编译缓存被批量删除保护拦住了，把缓存挪走再试："
      printf '%s    mv entry/build/default/cache/default/default@CompileArkTS/esmodule/release \\\n' "$DIM"
      printf '       entry/build/default/cache/default/default@CompileArkTS/esmodule/release.stale%s\n' "$NC"
    elif grep -q 'CompileArkTS' <<< "$log"; then
      warn "CompileArkTS 失败，详细堆栈见 .hvigor/outputs/build-logs/build.log"
    fi
    bad "release 构建失败"
    printf '%s\n' "$log" | grep -E 'ERROR|error:' | tail -8
    PROBLEMS=$((PROBLEMS + 1))
    return 1
  fi

  ok "release 构建成功"
}

# ---------------- 产物检查 ----------------
run_artifact() {
  info "产物检查：HAP 内 ets/modules.abc 的名字完整性"

  [[ -f "$HAP" ]] || die "找不到 $HAP（先构建，或去掉 verify 参数）"
  [[ -f "$DTS" ]] || die "找不到 $DTS"

  [[ "$HAP" -ot "$RULES" ]] && warn "HAP 比 $RULES 旧，规则改完还没重新构建，结果可能过期"
  if [[ -n "$(find "$ETS_DIR" -name '*.ets' -newer "$HAP" 2>/dev/null | head -1)" ]]; then
    warn "有 .ets 比 HAP 新，产物可能不是最新代码"
  fi

  # debug:false 才是 release 包；debug 包本来就不混淆，查了没意义
  if unzip -p "$HAP" module.json 2>/dev/null | grep -q '"debug":false'; then
    ok "HAP 是 release 构建（module.json 里 debug:false）"
  else
    warn "HAP 不是 release 构建（module.json 里 debug 不为 false）"
  fi

  mkdir_tmp
  local abc="$TMP_DIR/modules.abc"
  if ! unzip -p "$HAP" ets/modules.abc > "$abc" 2>/dev/null || [[ ! -s "$abc" ]]; then
    die "从 HAP 里取不到 ets/modules.abc"
  fi

  local names name total=0 lost=0
  names="$( { dts_exports; dts_fields; } | sort -u )"

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    total=$((total + 1))
    if ! LC_ALL=C grep -aqF -- "$name" "$abc"; then
      bad "$name 在字节码里不存在 —— 已被改名，运行时会失败"
      lost=$((lost + 1))
    fi
  done <<< "$names"

  if [[ $total -eq 0 ]]; then
    warn "没解析出要检查的名字，确认 $DTS 内容"
    PROBLEMS=$((PROBLEMS + 1))
  elif [[ $lost -gt 0 ]]; then
    PROBLEMS=$((PROBLEMS + lost))
    bad "$lost/$total 个名字被混淆改掉，补进 $RULES 的 -keep-property-name 后重打"
  else
    ok "$total/$total 个原生名字都保留了"
  fi
}

# ---------------- list ----------------
run_list() {
  [[ -f "$DTS" ]] || die "找不到 $DTS"
  mkdir_tmp
  src_dump "$TMP_DIR/src.txt"
  info "原生函数（$DTS）"
  dts_exports | sed 's/^/    /'
  info "原生字段（$DTS 的 interface）"
  dts_fields | sed 's/^/    /'
  info "源码里从 lib*.so 导入的名字"
  ets_so_imports "$TMP_DIR/src.txt" | sed 's/^/    /'
  info "当前 keep 名单"
  keep_names | paste -sd, - | fold -s -w 96 | sed 's/^/    /'
}

# ---------------- 主流程 ----------------
printf '%s\n' "${CYAN}盒音工坊 · release 混淆体检${NC}"

case "$MODE" in
  all)
    run_static
    run_build && run_artifact
    ;;
  static) run_static ;;
  build)  run_build ;;
  verify) run_artifact ;;
  list)   run_list ;;
  -h|--help|help)
    sed -n '5,28p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    die "未知参数：$MODE（可用：static / verify / build / list）"
    ;;
esac

printf '\n'
if [[ $PROBLEMS -gt 0 ]]; then
  bad "体检未通过：$PROBLEMS 处问题"
  exit 1
fi
ok "体检通过"
if [[ -f "$HAP" ]]; then
  printf '%s装到机器上实测：%s\n' "$DIM" "$NC"
  printf '  hdc shell bm uninstall -n com.boxtone.audiokit   # 会清数据，先导出备份\n'
  printf '  hdc install %s\n' "$HAP"
fi
exit 0
