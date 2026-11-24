#!/usr/bin/env bash
# 把手机录的梗音效批量处理成盒端规格
#
# 用法：
#   1. 手机录音（m4a/mp3/wav 都行），文件按想要的顺序命名，如 01-那咋了.m4a
#   2. 全部丢进 tools/recordings/ 目录
#   3. 运行：./tools/tones-from-recordings.sh
#   4. 产物在 tools/recordings/out/，直接拷进 entry/src/main/resources/rawfile/
#
# 处理内容：裁首尾静音 → 超长截到 2.5s → 峰值对齐 -2dB → 转 16700Hz 单声道 16bit
set -u

RATE=16700
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="$ROOT/tools/recordings"
OUT="$IN/out"

FF="$(command -v ffmpeg 2>/dev/null || true)"
[ -z "$FF" ] && [ -x "/c/Windows/System32/ffmpeg.exe" ] && FF="/c/Windows/System32/ffmpeg.exe"
if [ -z "$FF" ]; then
  echo "找不到 ffmpeg，请先确认 ffmpeg 在 PATH 里" >&2
  exit 1
fi

if [ ! -d "$IN" ]; then
  mkdir -p "$IN"
  echo "已创建 $IN"
  echo "把录音放进去，再运行一次本脚本。"
  exit 0
fi

mkdir -p "$OUT"
shopt -s nullglob nocaseglob
files=("$IN"/*.m4a "$IN"/*.mp3 "$IN"/*.wav "$IN"/*.ogg "$IN"/*.aac "$IN"/*.flac)
if [ ${#files[@]} -eq 0 ]; then
  echo "$IN 里没有音频文件（支持 m4a/mp3/wav/ogg/aac/flac）"
  exit 0
fi

# 取峰值（dB），无输出时给 -99
peak_of() {
  "$FF" -hide_banner -i "$1" -af volumedetect -f null - 2>&1 \
    | grep -oE 'max_volume: *-?[0-9.]+' | sed -E 's/.*: *//' | head -1
}

printf "%-26s %8s %8s %8s\n" "文件" "原始" "成品" "峰值"
count=0
for src in "${files[@]}"; do
  base="$(basename "$src")"
  name="${base%.*}"
  dst="$OUT/${name}.wav"
  tmp="$OUT/.tmp-${name}.wav"

  # 1) 裁首尾静音（-40dB 以下视为静音）2) 截断到 2.5s
  if ! "$FF" -v error -y -i "$src" \
    -af "silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.05,\
areverse,silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.12,areverse,\
atrim=0:2.5" \
    -ar "$RATE" -ac 1 -c:a pcm_s16le "$tmp"; then
    echo "处理失败：$base"
    rm -f "$tmp"
    continue
  fi

  # 2) 峰值对齐到 -2dB：双向调整，提升上限 12dB 免得把底噪抬起来
  peak=$(peak_of "$tmp")
  gain=$(awk -v p="${peak:--99}" 'BEGIN{
    g = -2.0 - p;
    if (g > 12) g = 12;
    if (g < -12) g = -12;
    printf "%.1f", g
  }')
  if [ "$(awk -v g="$gain" 'BEGIN{print (g > 0.05 || g < -0.05) ? 1 : 0}')" = "1" ]; then
    "$FF" -v error -y -i "$tmp" -af "volume=${gain}dB,alimiter=limit=0.98" \
      -c:a pcm_s16le "$dst" && rm -f "$tmp"
  else
    mv "$tmp" "$dst"
  fi

  # 时长按 WAV 头后数据量算，不依赖外部解释器
  dur_src=$("$FF" -hide_banner -i "$src" -f null - 2>&1 \
    | grep -oE 'time=[0-9]+:[0-9]+:[0-9.]+' | tail -1 | cut -d= -f2)
  bytes=$(stat -c%s "$dst" 2>/dev/null || echo 44)
  dur=$(awk -v b="$bytes" -v r="$RATE" 'BEGIN{ printf "%.2fs", (b-44)/2/r }')
  peak_out=$(peak_of "$dst")
  printf "%-26s %8s %8s %8s\n" "$base" "${dur_src:--}" "$dur" "${peak_out:--}dB"
  count=$((count+1))
done

echo ""
echo "完成 $count 个，产物在：$OUT"
echo "已统一为 16700Hz / 16bit / 单声道，峰值约 -2dB，最长 2.5 秒。"
