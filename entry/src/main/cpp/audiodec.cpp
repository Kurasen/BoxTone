/*
 * 音频解码（MP3 / AAC / M4A / FLAC / OGG / AMR / WAV…）
 *
 * HarmonyOS 的 ArkTS 侧没有开放 AVCodec / AVSource 接口，只有 NDK 提供，
 * 所以这里用 AVSource + AVDemuxer + AudioCodec 把任意受系统支持的音频容器
 * 解成交错排列的 Float32 PCM，交给 ArkTS 侧复用原有的重采样与音效合成链路。
 *
 * 两个必须守住的约束（都是真机踩过的）：
 * 1. 解码放在 napi_async_work 里跑。同步解码会占住 JS 线程，长文件直接把 UI 冻死，
 *    系统判定无响应后杀进程，表现就是"卡死闪退、日志里什么都没有"。
 * 2. 循环必须有"无进展"退出条件。某些情况下解码器会一直吐空输出缓冲而不给 EOS，
 *    只判断"有没有拿到缓冲"会永远转下去。
 */

#include <fcntl.h>
#include <unistd.h>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avdemuxer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avsource.h>

#include "napi/native_api.h"

namespace {

/** 解封装缓冲：单帧压缩数据远小于这个值，留足余量 */
constexpr int32_t SAMPLE_BUFFER_BYTES = 1024 * 512;
/** 连续这么久没有新样本就收手，避免死循环把 UI 拖死 */
constexpr int64_t STALL_LIMIT_MS = 4000;
/** 单次解码的总时间上限 */
constexpr int64_t DECODE_LIMIT_MS = 20000;
/** 循环次数上限，双保险 */
constexpr int64_t ITERATION_LIMIT = 500000;

int64_t NowMs()
{
  return std::chrono::duration_cast<std::chrono::milliseconds>(
           std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct FdGuard {
  int fd = -1;
  ~FdGuard()
  {
    if (fd >= 0) {
      close(fd);
    }
  }
};

struct SourceGuard {
  OH_AVSource *ptr = nullptr;
  ~SourceGuard()
  {
    if (ptr != nullptr) {
      OH_AVSource_Destroy(ptr);
    }
  }
};

struct DemuxerGuard {
  OH_AVDemuxer *ptr = nullptr;
  ~DemuxerGuard()
  {
    if (ptr != nullptr) {
      OH_AVDemuxer_Destroy(ptr);
    }
  }
};

struct CodecGuard {
  OH_AVCodec *ptr = nullptr;
  bool started = false;
  ~CodecGuard()
  {
    if (ptr != nullptr) {
      if (started) {
        OH_AudioCodec_Stop(ptr);
      }
      OH_AudioCodec_Destroy(ptr);
    }
  }
};

struct FormatGuard {
  OH_AVFormat *ptr = nullptr;
  ~FormatGuard()
  {
    if (ptr != nullptr) {
      OH_AVFormat_Destroy(ptr);
    }
  }
};

struct BufferGuard {
  OH_AVBuffer *ptr = nullptr;
  ~BufferGuard()
  {
    if (ptr != nullptr) {
      OH_AVBuffer_Destroy(ptr);
    }
  }
};

struct DecodeResult {
  bool ok = false;
  std::string error;
  std::string stage = "init";
  std::vector<float> samples;
  int32_t sampleRate = 0;
  int32_t channels = 0;
  int64_t frameCount = 0;
  bool truncated = false;
};

int32_t BytesPerSample(int32_t format)
{
  switch (format) {
    case SAMPLE_U8:
      return 1;
    case SAMPLE_S16LE:
      return 2;
    case SAMPLE_S24LE:
      return 3;
    case SAMPLE_S32LE:
    case SAMPLE_F32LE:
      return 4;
    default:
      return 2;
  }
}

/** 把解码器输出缓冲转成 [-1, 1] 的 Float32，按交错顺序追加 */
void AppendSamples(const uint8_t *addr, int32_t size, int32_t format, std::vector<float> &out)
{
  const int32_t unit = BytesPerSample(format);
  if (addr == nullptr || size <= 0 || unit <= 0) {
    return;
  }
  const int32_t count = size / unit;
  if (count <= 0) {
    return;
  }
  if (format == SAMPLE_S16LE) {
    const int16_t *p = reinterpret_cast<const int16_t *>(addr);
    for (int32_t i = 0; i < count; i++) {
      out.push_back(static_cast<float>(p[i]) / 32768.0f);
    }
  } else if (format == SAMPLE_F32LE) {
    const float *p = reinterpret_cast<const float *>(addr);
    for (int32_t i = 0; i < count; i++) {
      out.push_back(p[i]);
    }
  } else if (format == SAMPLE_S32LE) {
    const int32_t *p = reinterpret_cast<const int32_t *>(addr);
    for (int32_t i = 0; i < count; i++) {
      out.push_back(static_cast<float>(static_cast<double>(p[i]) / 2147483648.0));
    }
  } else if (format == SAMPLE_S24LE) {
    for (int32_t i = 0; i < count; i++) {
      const uint8_t *b = addr + i * 3;
      int32_t value = (b[2] << 16) | (b[1] << 8) | b[0];
      if ((value & 0x800000) != 0) {
        value -= 0x1000000;
      }
      out.push_back(static_cast<float>(value) / 8388608.0f);
    }
  } else if (format == SAMPLE_U8) {
    for (int32_t i = 0; i < count; i++) {
      out.push_back((static_cast<float>(addr[i]) - 128.0f) / 128.0f);
    }
  }
}

/** 在容器里挑第一条音轨 */
bool PickAudioTrack(OH_AVSource *source, uint32_t &trackIndex, std::string &mime,
                    int32_t &sampleRate, int32_t &channels)
{
  FormatGuard sourceFormat;
  sourceFormat.ptr = OH_AVSource_GetSourceFormat(source);
  int32_t trackCount = 0;
  if (sourceFormat.ptr == nullptr ||
      !OH_AVFormat_GetIntValue(sourceFormat.ptr, OH_MD_KEY_TRACK_COUNT, &trackCount) ||
      trackCount <= 0) {
    return false;
  }
  for (int32_t i = 0; i < trackCount; i++) {
    FormatGuard trackFormat;
    trackFormat.ptr = OH_AVSource_GetTrackFormat(source, static_cast<uint32_t>(i));
    if (trackFormat.ptr == nullptr) {
      continue;
    }
    const char *codecMime = nullptr;
    if (!OH_AVFormat_GetStringValue(trackFormat.ptr, OH_MD_KEY_CODEC_MIME, &codecMime) ||
        codecMime == nullptr) {
      continue;
    }
    if (std::strncmp(codecMime, "audio/", 6) != 0) {
      continue;
    }
    trackIndex = static_cast<uint32_t>(i);
    mime = codecMime;
    sampleRate = 44100;
    channels = 2;
    OH_AVFormat_GetIntValue(trackFormat.ptr, OH_MD_KEY_AUD_SAMPLE_RATE, &sampleRate);
    OH_AVFormat_GetIntValue(trackFormat.ptr, OH_MD_KEY_AUD_CHANNEL_COUNT, &channels);
    if (sampleRate <= 0 || sampleRate > 384000) {
      sampleRate = 44100;
    }
    if (channels <= 0 || channels > 8) {
      channels = 2;
    }
    return true;
  }
  return false;
}

DecodeResult DecodeFile(const std::string &path, int32_t maxSeconds)
{
  DecodeResult result;
  FdGuard fd;
  fd.fd = open(path.c_str(), O_RDONLY);
  if (fd.fd < 0) {
    result.error = "无法打开音频文件";
    result.stage = "open";
    return result;
  }
  const off_t fileSize = lseek(fd.fd, 0, SEEK_END);
  lseek(fd.fd, 0, SEEK_SET);
  if (fileSize <= 0) {
    result.error = "音频文件为空";
    result.stage = "open";
    return result;
  }

  result.stage = "source";
  SourceGuard source;
  source.ptr = OH_AVSource_CreateWithFD(fd.fd, 0, fileSize);
  if (source.ptr == nullptr) {
    result.error = "无法识别这个音频格式，请换一个文件试试";
    return result;
  }

  result.stage = "track";
  uint32_t trackIndex = 0;
  std::string mime;
  int32_t sampleRate = 44100;
  int32_t channels = 2;
  if (!PickAudioTrack(source.ptr, trackIndex, mime, sampleRate, channels)) {
    result.error = "这个文件里没有可用的音轨";
    return result;
  }

  result.stage = "codec";
  CodecGuard codec;
  codec.ptr = OH_AudioCodec_CreateByMime(mime.c_str(), false);
  if (codec.ptr == nullptr) {
    result.error = "系统没有这款格式的解码器（" + mime + "）";
    return result;
  }

  // 直接把轨道格式拷进配置：AAC/FLAC 需要 csd（编解码器私有数据）才能解
  FormatGuard trackFormat;
  trackFormat.ptr = OH_AVSource_GetTrackFormat(source.ptr, trackIndex);
  if (trackFormat.ptr == nullptr) {
    result.error = "读取音轨信息失败";
    result.stage = "format";
    return result;
  }
  FormatGuard config;
  config.ptr = OH_AVFormat_Create();
  if (config.ptr == nullptr || !OH_AVFormat_Copy(config.ptr, trackFormat.ptr)) {
    result.error = "准备解码参数失败";
    result.stage = "format";
    return result;
  }
  // 统一要 16bit 整型，兼容性最好；实际输出格式以输出描述为准
  OH_AVFormat_SetIntValue(config.ptr, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);

  // 关键：显式启用同步模式。默认是 0（异步/回调模式），
  // 若不在配置阶段置 1，QueryInputBuffer / QueryOutputBuffer 会一直返回
  // AV_ERR_OPERATE_NOT_PERMIT（"不允许在异步模式下调用"），
  // 表现就是输入送不进去、输出收不到、最终"没有解出音频数据"。
  // 启用后不能再注册回调（本实现本来就没注册），只用 buffer query API。
  OH_AVFormat_SetIntValue(config.ptr, OH_MD_KEY_ENABLE_SYNC_MODE, 1);

  result.stage = "configure";
  if (OH_AudioCodec_Configure(codec.ptr, config.ptr) != AV_ERR_OK) {
    result.error = "配置解码器失败（该格式可能不受支持）";
    return result;
  }
  result.stage = "prepare";
  if (OH_AudioCodec_Prepare(codec.ptr) != AV_ERR_OK) {
    result.error = "启动解码器失败";
    return result;
  }
  result.stage = "start";
  if (OH_AudioCodec_Start(codec.ptr) != AV_ERR_OK) {
    result.error = "启动解码器失败";
    return result;
  }
  codec.started = true;

  // 输出格式（采样率/通道/位深）留到第一个输出帧时再读一次。
  // 注意 OH_AudioCodec_GetOutputDescription 返回的 OH_AVFormat 由调用方释放，
  // 所以全程只取一次，避免重复调用后旧实例被二次释放。
  int32_t outFormat = SAMPLE_S16LE;
  result.sampleRate = sampleRate;
  result.channels = channels;

  result.stage = "demuxer";
  DemuxerGuard demuxer;
  demuxer.ptr = OH_AVDemuxer_CreateWithSource(source.ptr);
  if (demuxer.ptr == nullptr) {
    result.error = "初始化解封装失败";
    return result;
  }
  if (OH_AVDemuxer_SelectTrackByID(demuxer.ptr, trackIndex) != AV_ERR_OK) {
    result.error = "选择音轨失败";
    return result;
  }

  BufferGuard sample;
  sample.ptr = OH_AVBuffer_Create(SAMPLE_BUFFER_BYTES);
  if (sample.ptr == nullptr) {
    result.error = "申请解码缓冲失败";
    return result;
  }

  result.stage = "decode";
  int64_t maxFrames = static_cast<int64_t>(maxSeconds > 0 ? maxSeconds : 30) * sampleRate;
  const int64_t startedAt = NowMs();
  int64_t lastProgressAt = startedAt;
  size_t lastSampleCount = 0;
  int64_t iterations = 0;
  bool inputDone = false;
  bool outputDone = false;
  bool formatRead = false;

  while (!outputDone) {
    iterations++;
    if (iterations > ITERATION_LIMIT) {
      result.truncated = true;
      break;
    }
    if (NowMs() - startedAt > DECODE_LIMIT_MS) {
      result.truncated = true;
      break;
    }

    // ---- 送输入 ----
    if (!inputDone) {
      uint32_t inputIndex = 0;
      const OH_AVErrCode inputQuery = OH_AudioCodec_QueryInputBuffer(codec.ptr, &inputIndex, 0);
      if (inputQuery == AV_ERR_OPERATE_NOT_PERMIT) {
        // 同步模式没生效：返回 2 表示"不允许在异步模式下调用"。
        // 立即报错而不是空转，方便定位。
        result.error = "解码器未进入同步模式，无法读取输入缓冲";
        result.stage = "sync";
        return result;
      }
      if (inputQuery == AV_ERR_OK) {
        OH_AVBuffer *inputBuffer = OH_AudioCodec_GetInputBuffer(codec.ptr, inputIndex);
        uint8_t *inputAddr = inputBuffer != nullptr ? OH_AVBuffer_GetAddr(inputBuffer) : nullptr;
        if (inputBuffer != nullptr && inputAddr != nullptr) {
          const int32_t capacity = OH_AVBuffer_GetCapacity(inputBuffer);
          if (capacity <= 0) {
            result.error = "解码器没有提供可用的输入缓冲";
            result.stage = "input";
            return result;
          }
          OH_AVCodecBufferAttr attr;
          std::memset(&attr, 0, sizeof(attr));
          const OH_AVErrCode read = OH_AVDemuxer_ReadSampleBuffer(demuxer.ptr, trackIndex, sample.ptr);
          if (read == AV_ERR_OK) {
            OH_AVCodecBufferAttr sampleAttr;
            std::memset(&sampleAttr, 0, sizeof(sampleAttr));
            OH_AVBuffer_GetBufferAttr(sample.ptr, &sampleAttr);
            const int32_t sampleCapacity = OH_AVBuffer_GetCapacity(sample.ptr);
            const uint8_t *sampleAddr = OH_AVBuffer_GetAddr(sample.ptr);
            int32_t sampleOffset = sampleAttr.offset > 0 ? sampleAttr.offset : 0;
            if (sampleOffset > sampleCapacity) {
              sampleOffset = 0;
            }
            int32_t copySize = sampleAttr.size > 0 ? sampleAttr.size : 0;
            if (copySize > sampleCapacity - sampleOffset) {
              copySize = sampleCapacity - sampleOffset;
            }
            if (copySize > capacity) {
              copySize = capacity;
            }
            if (sampleAddr != nullptr && copySize > 0) {
              std::memcpy(inputAddr, sampleAddr + sampleOffset, static_cast<size_t>(copySize));
              attr.size = copySize;
            } else {
              attr.size = 0;
            }
            attr.pts = sampleAttr.pts;
            attr.offset = 0;
            attr.flags = sampleAttr.flags &
              (AVCODEC_BUFFER_FLAGS_EOS | AVCODEC_BUFFER_FLAGS_CODEC_DATA |
               AVCODEC_BUFFER_FLAGS_SYNC_FRAME);
            if ((sampleAttr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
              inputDone = true;
            }
          } else {
            // 读到文件末尾：送一个 EOS 帧，让解码器把缓冲里的数据吐完
            attr.size = 0;
            attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
            inputDone = true;
          }
          OH_AVBuffer_SetBufferAttr(inputBuffer, &attr);
          if (OH_AudioCodec_PushInputBuffer(codec.ptr, inputIndex) != AV_ERR_OK) {
            inputDone = true;
          }
        }
      }
    }

    // ---- 收输出 ----
    bool drained = false;
    uint32_t outputIndex = 0;
    while (OH_AudioCodec_QueryOutputBuffer(codec.ptr, &outputIndex, 0) == AV_ERR_OK) {
      drained = true;
      OH_AVBuffer *outputBuffer = OH_AudioCodec_GetOutputBuffer(codec.ptr, outputIndex);
      if (outputBuffer == nullptr) {
        break;
      }
      OH_AVCodecBufferAttr attr;
      std::memset(&attr, 0, sizeof(attr));
      OH_AVBuffer_GetBufferAttr(outputBuffer, &attr);
      if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
        OH_AudioCodec_FreeOutputBuffer(codec.ptr, outputIndex);
        outputDone = true;
        break;
      }
      if (attr.size > 0) {
        // 真实输出格式要到第一个输出帧才稳定（AAC 的 SBR 会让采样率翻倍）。
        // 只取一次：GetOutputDescription 返回的 OH_AVFormat 由调用方释放，
        // 反复调用后旧实例的归属容易出问题。
        if (!formatRead) {
          formatRead = true;
          int32_t actualFormat = outFormat;
          int32_t actualRate = sampleRate;
          int32_t actualChannels = channels;
          FormatGuard outDesc;
          outDesc.ptr = OH_AudioCodec_GetOutputDescription(codec.ptr);
          if (outDesc.ptr != nullptr) {
            OH_AVFormat_GetIntValue(outDesc.ptr, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &actualFormat);
            OH_AVFormat_GetIntValue(outDesc.ptr, OH_MD_KEY_AUD_SAMPLE_RATE, &actualRate);
            OH_AVFormat_GetIntValue(outDesc.ptr, OH_MD_KEY_AUD_CHANNEL_COUNT, &actualChannels);
          }
          if (actualRate > 0 && actualRate <= 384000) {
            sampleRate = actualRate;
            result.sampleRate = actualRate;
            maxFrames = static_cast<int64_t>(maxSeconds > 0 ? maxSeconds : 30) * sampleRate;
          }
          if (actualChannels > 0 && actualChannels <= 8) {
            channels = actualChannels;
            result.channels = actualChannels;
          }
          outFormat = actualFormat;
        }
        const uint8_t *addr = OH_AVBuffer_GetAddr(outputBuffer);
        if (addr != nullptr) {
          const int32_t capacity = OH_AVBuffer_GetCapacity(outputBuffer);
          int32_t offset = attr.offset > 0 ? attr.offset : 0;
          int32_t size = attr.size;
          if (offset > capacity) {
            offset = 0;
          }
          if (size > capacity - offset) {
            size = capacity - offset;
          }
          AppendSamples(addr + offset, size, outFormat, result.samples);
        }
      }
      OH_AudioCodec_FreeOutputBuffer(codec.ptr, outputIndex);
      if (static_cast<int64_t>(result.samples.size()) >= maxFrames * channels) {
        outputDone = true;
        result.truncated = true;
        break;
      }
    }

    // ---- 无进展检测：不管这次有没有拿到缓冲，只要样本数不再增长就开始计时 ----
    if (result.samples.size() != lastSampleCount) {
      lastSampleCount = result.samples.size();
      lastProgressAt = NowMs();
    } else if (NowMs() - lastProgressAt > STALL_LIMIT_MS) {
      break;
    }
    if (!drained) {
      usleep(2000);
    }
  }

  result.stage = "done";
  if (result.samples.empty()) {
    result.error = "没有解出音频数据，请换一个文件试试";
    return result;
  }
  const int64_t channelCount = channels > 0 ? channels : 1;
  result.frameCount = static_cast<int64_t>(result.samples.size()) / channelCount;
  if (result.frameCount > maxFrames) {
    result.samples.resize(static_cast<size_t>(maxFrames * channelCount));
    result.frameCount = maxFrames;
    result.truncated = true;
  }
  result.ok = true;
  return result;
}

napi_value BuildResult(napi_env env, const DecodeResult &decoded)
{
  napi_value result = nullptr;
  napi_create_object(env, &result);

  napi_value ok = nullptr;
  napi_get_boolean(env, decoded.ok, &ok);
  napi_set_named_property(env, result, "ok", ok);

  napi_value rate = nullptr;
  napi_create_int32(env, decoded.ok ? decoded.sampleRate : 0, &rate);
  napi_set_named_property(env, result, "sampleRate", rate);

  napi_value channelValue = nullptr;
  napi_create_int32(env, decoded.ok ? decoded.channels : 0, &channelValue);
  napi_set_named_property(env, result, "channels", channelValue);

  napi_value framesCount = nullptr;
  napi_create_int64(env, decoded.ok ? decoded.frameCount : 0, &framesCount);
  napi_set_named_property(env, result, "frameCount", framesCount);

  napi_value truncated = nullptr;
  napi_get_boolean(env, decoded.truncated, &truncated);
  napi_set_named_property(env, result, "truncated", truncated);

  napi_value stage = nullptr;
  napi_create_string_utf8(env, decoded.stage.c_str(), NAPI_AUTO_LENGTH, &stage);
  napi_set_named_property(env, result, "stage", stage);

  if (!decoded.ok) {
    napi_value message = nullptr;
    napi_create_string_utf8(env, decoded.error.c_str(), NAPI_AUTO_LENGTH, &message);
    napi_set_named_property(env, result, "error", message);
  }

  const size_t sampleCount = decoded.ok ? decoded.samples.size() : 0;
  void *raw = nullptr;
  napi_value arrayBuffer = nullptr;
  napi_create_arraybuffer(env, sampleCount * sizeof(float), &raw, &arrayBuffer);
  if (sampleCount > 0 && raw != nullptr) {
    std::memcpy(raw, decoded.samples.data(), sampleCount * sizeof(float));
  }
  napi_value frames = nullptr;
  napi_create_typedarray(env, napi_float32_array, sampleCount, arrayBuffer, 0, &frames);
  napi_set_named_property(env, result, "frames", frames);
  return result;
}

struct DecodeTask {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string path;
  int32_t maxSeconds = 60;
  DecodeResult result;
};

void ExecuteDecode(napi_env env, void *data)
{
  DecodeTask *task = static_cast<DecodeTask *>(data);
  if (task == nullptr) {
    return;
  }
  try {
    task->result = DecodeFile(task->path, task->maxSeconds);
  } catch (const std::exception &error) {
    task->result.ok = false;
    task->result.error = std::string("解码过程异常：") + error.what();
  } catch (...) {
    task->result.ok = false;
    task->result.error = "解码过程异常";
  }
}

void CompleteDecode(napi_env env, napi_status status, void *data)
{
  DecodeTask *task = static_cast<DecodeTask *>(data);
  if (task == nullptr) {
    return;
  }
  if (status != napi_ok) {
    task->result.ok = false;
    task->result.error = "解码任务被取消";
  }
  napi_value value = BuildResult(env, task->result);
  napi_resolve_deferred(env, task->deferred, value);
  napi_delete_async_work(env, task->work);
  delete task;
}

napi_value DecodeAudio(napi_env env, napi_callback_info info)
{
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  char path[2048] = {0};
  size_t pathLen = 0;
  if (argc < 1 ||
      napi_get_value_string_utf8(env, args[0], path, sizeof(path) - 1, &pathLen) != napi_ok ||
      pathLen == 0) {
    DecodeResult failed;
    failed.error = "缺少音频文件路径";
    failed.stage = "args";
    return BuildResult(env, failed);
  }
  int32_t maxSeconds = 60;
  if (argc > 1) {
    napi_get_value_int32(env, args[1], &maxSeconds);
  }
  if (maxSeconds <= 0 || maxSeconds > 600) {
    maxSeconds = 60;
  }

  napi_value promise = nullptr;
  napi_deferred deferred = nullptr;
  napi_create_promise(env, &deferred, &promise);

  DecodeTask *task = new DecodeTask();
  task->deferred = deferred;
  task->path = std::string(path);
  task->maxSeconds = maxSeconds;

  napi_value resourceName = nullptr;
  napi_create_string_utf8(env, "decodeAudio", NAPI_AUTO_LENGTH, &resourceName);
  napi_create_async_work(env, nullptr, resourceName, ExecuteDecode, CompleteDecode, task, &task->work);
  napi_queue_async_work(env, task->work);
  return promise;
}

/**
 * 轻量探测：只建 AVSource、读轨道信息，不做解码。
 * 返回的信息会写进应用日志，便于区分「容器打不开」和「解码器出问题」。
 */
napi_value ProbeAudio(napi_env env, napi_callback_info info)
{
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  napi_value result = nullptr;
  napi_create_object(env, &result);

  char path[2048] = {0};
  size_t pathLen = 0;
  bool ok = false;
  std::string error;
  std::string stage = "open";
  std::string mime;
  int32_t rate = 0;
  int32_t channelCount = 0;
  int64_t durationMs = 0;

  if (argc < 1 || napi_get_value_string_utf8(env, args[0], path, sizeof(path) - 1, &pathLen) != napi_ok ||
      pathLen == 0) {
    error = "缺少音频文件路径";
  } else {
    FdGuard fd;
    fd.fd = open(path, O_RDONLY);
    if (fd.fd < 0) {
      error = "无法打开音频文件";
    } else {
      const off_t fileSize = lseek(fd.fd, 0, SEEK_END);
      lseek(fd.fd, 0, SEEK_SET);
      if (fileSize <= 0) {
        error = "音频文件为空";
      } else {
        stage = "source";
        SourceGuard source;
        source.ptr = OH_AVSource_CreateWithFD(fd.fd, 0, fileSize);
        if (source.ptr == nullptr) {
          error = "无法识别这个音频格式，请换一个文件试试";
        } else {
          FormatGuard sourceFormat;
          sourceFormat.ptr = OH_AVSource_GetSourceFormat(source.ptr);
          if (sourceFormat.ptr != nullptr) {
            int64_t duration = 0;
            if (OH_AVFormat_GetLongValue(sourceFormat.ptr, OH_MD_KEY_DURATION, &duration) && duration > 0) {
              durationMs = duration / 1000;
            }
          }
          stage = "track";
          uint32_t trackIndex = 0;
          if (PickAudioTrack(source.ptr, trackIndex, mime, rate, channelCount)) {
            ok = true;
            stage = "done";
          } else {
            error = "这个文件里没有可用的音轨";
          }
        }
      }
    }
  }

  napi_value okValue = nullptr;
  napi_get_boolean(env, ok, &okValue);
  napi_set_named_property(env, result, "ok", okValue);
  napi_value mimeValue = nullptr;
  napi_create_string_utf8(env, mime.c_str(), NAPI_AUTO_LENGTH, &mimeValue);
  napi_set_named_property(env, result, "mime", mimeValue);
  napi_value rateValue = nullptr;
  napi_create_int32(env, rate, &rateValue);
  napi_set_named_property(env, result, "sampleRate", rateValue);
  napi_value channelValue = nullptr;
  napi_create_int32(env, channelCount, &channelValue);
  napi_set_named_property(env, result, "channels", channelValue);
  napi_value durationValue = nullptr;
  napi_create_int64(env, durationMs, &durationValue);
  napi_set_named_property(env, result, "durationMs", durationValue);
  napi_value stageValue = nullptr;
  napi_create_string_utf8(env, stage.c_str(), NAPI_AUTO_LENGTH, &stageValue);
  napi_set_named_property(env, result, "stage", stageValue);
  if (!ok) {
    napi_value message = nullptr;
    napi_create_string_utf8(env, error.c_str(), NAPI_AUTO_LENGTH, &message);
    napi_set_named_property(env, result, "error", message);
  }
  return result;
}

napi_value Init(napi_env env, napi_value exports)
{
  napi_property_descriptor desc[] = {
    {"decodeAudio", nullptr, DecodeAudio, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"probeAudio", nullptr, ProbeAudio, nullptr, nullptr, nullptr, napi_default, nullptr}
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

napi_module module = {
  .nm_version = 1,
  .nm_flags = 0,
  .nm_filename = nullptr,
  .nm_register_func = Init,
  .nm_modname = "audiodec",
  .nm_priv = nullptr,
  .reserved = {0}
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterAudioDecModule(void)
{
  napi_module_register(&module);
}
