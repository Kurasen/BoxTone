# 盒音工坊 · BoxTone

> 为华为蓝牙耳机定制**充电盒开盖音效**的 HarmonyOS 应用（当前版本 v1.2.0，中英文界面）。
> 连接耳机 → 导入素材 → 按充电盒解码规格转换 → 通过蓝牙 SPP **直接写入充电盒**。

底部导航使用官方 **HdsTabs 沉浸光感悬浮底栏**（HDS 6.1.0 / API 23 起提供）
（`barOverlap` + `barFloatingStyle.systemMaterialEffect`），
参考官方文档 [沉浸光感悬浮底栏](https://developer.huawei.com/consumer/cn/doc/doccenter-advanced-features/bpta-spatiality-immersive)。

---

## 一、功能

| 页面 | 能力 |
|:--|:--|
| **设备** | 蓝牙开关/权限状态、已配对设备（自动识别音频类设备）、附近设备扫描与配对、A2DP 与星闪连接状态、星闪连接时写入前拦截、机型支持列表 |
| **音效** | 导入 MP3 / M4A / AAC / FLAC / OGG / WAV、9 种内置音色合成（含雨声 / 风铃 / 晨鸟）、波形可视化与选区、起始/时长/增益调节、峰值归一化、淡入淡出、**原声 / 盒音双引擎试听**、规格实时校验、**生成并写入耳机盒**、生成入库或直接导出 |
| **音效库** | 音效列表、**按名称/来源搜索**、试听、**蓝牙直写**、**盒内当前音效标记**、**批量删除（写入中的音效锁定删除）**、**恢复默认开盒音**、内置音效切换、导出、重命名、删除，按时间或名称排序，统计总数/占用/最近生成；**顶部区域固定，仅列表滚动** |
| **我的** | 外观设置（深色/浅色/跟随系统）、中英文自动切换（按系统地区）、**备份与导入**、盒端规格说明与技术原理、机型支持、反馈入口、更新日志、日志中心 |
| **日志中心** | 全量诊断日志、按级别筛选、复制到剪贴板、导出 txt 报告；启动时自动清理历史日志 |

---

## 二、目标格式（严格对齐充电盒解码标准）

| 参数 | 值 |
|:--|:--|
| 编码 | Signed 16-bit PCM（小端） |
| 声道 | Mono 单通道 |
| 采样率 | **16700 Hz** |
| 容器 | 无文件头 RAW（`.pcm` / `.raw`） |
| 时长 | ≤ 2.5 秒（3.2 秒压线，4 秒以上固件不接） |
| 体积 | 每秒固定 **33400 字节**，上限 83500 字节 |

> 盒端缓冲区本身是 192000 字节，但**鸿蒙侧 SPP 实测只有约 23KB/s**（480 字节 / 20ms），
> 单个音效超过约 106KB（3.2 秒）后，耳机在擦写第二阶段会失去响应并自行重启，
> 数据即使传完也存不进去。因此应用把上限收敛到 **2.5 秒 / 83500 字节**，
> 实测数据与逐项否决的方向见 [`docs/write-duration-gap.md`](docs/write-duration-gap.md)。

> 盒端解码器标定在约 16700Hz 而非标准 16000Hz。放入 16000Hz 素材播放时音调会整体升高约一个半音；
> 按 16700Hz 导出才能保持原本听感。

---

## 三、工程结构

```
BoxTone/
├── AppScope/                     应用级配置与图标
├── entry/src/main/
│   ├── module.json5              模块配置（蓝牙 / 星闪 / 网络权限声明）
│   ├── cpp/                      原生音频解码（NDK AVSource + AudioCodec）
│   │   ├── audiodec.cpp
│   │   └── CMakeLists.txt
│   ├── ets/
│   │   ├── entryability/EntryAbility.ets      启动、沉浸式布局、服务初始化
│   │   ├── common/
│   │   │   ├── constants/        AppConstants（音频规格/机型库）/ ThemeConstants（设计令牌）
│   │   │   ├── i18n/             I18n 服务与中英双语文案表
│   │   │   └── utils/            Logger / DateUtils / FormatUtils / EventBus / ByteUtils / NearLinkAlert
│   │   ├── models/               DeviceModel / ToneModel / LogModel
│   │   ├── services/
│   │   │   ├── AudioSourceService.ets      WAV 解析 + 系统解码器（MP3/AAC/FLAC/OGG…）
│   │   │   ├── AudioConvertService.ets     DSP 核心：下混/裁剪/归一化/重采样/增益/量化
│   │   │   ├── audio/ConvertTask.ets       TaskPool 工作线程入口与异步转换
│   │   │   ├── AudioPlayService.ets        AVPlayer 原声 + AudioRenderer 盒音
│   │   │   ├── ToneSynthesizerService.ets  内置音色合成
│   │   │   ├── ToneRepositoryService.ets   音效库持久化、原子索引、导出与导入
│   │   │   ├── ToneBackupService.ets       整库备份（.boxtone 容器）、恢复与 .pcm 导入
│   │   │   ├── CaseWriteService.ets        写入/恢复默认的检查、重试与诊断
│   │   │   ├── bluetooth/
│   │   │   │   ├── ToneClient.ets          SPP 会话、协议探测、分包上传、冷却与重试
│   │   │   │   └── MbbProtocol.ets         MBB 帧 / TLV / 状态与错误码
│   │   │   ├── BluetoothService.ets        设备发现/配对/连接状态（事件去抖）
│   │   │   ├── NearLinkService.ets         星闪能力探测与连接识别
│   │   │   ├── LogService.ets              日志收集/落盘/清理/导出
│   │   │   ├── SettingsService.ets         偏好设置
│   │   │   ├── ThemeService.ets            深浅色与系统栏
│   │   │   ├── LanguageService.ets         应用语言（系统文案）
│   │   │   ├── FeedbackService.ets         反馈整理/分享/本机记录
│   │   │   ├── FeedbackApiService.ets      在线反馈客户端（当前未启用）
│   │   │   ├── PrivacyConsentService.ets   AGC 隐私托管与启动开关
│   │   │   └── AppBootstrap.ets            服务启动入口
│   │   ├── components/           11 个复用组件（GlassCard / ToneCard / DeviceRow / WaveformView 等）
│   │   └── pages/
│   │       ├── Index.ets         HdsTabs 沉浸光感悬浮底栏 + 全局浮层
│   │       ├── main/             DevicePage / TonePage / LibraryPage
│   │       └── settings/         ProfilePage / LogPage / FeedbackPage / SupportedDevicesPage / ChangelogPage / BackupPage
│   └── resources/                图标（SVG）、配色、字符串（中/英系统文案）
├── server/                       反馈转发服务（当前 App 侧停用）
├── tools/format-lab.html         格式验证台（浏览器直接打开，跑同一套 DSP）
├── tools/check-sensitive-staged.ps1  提交前敏感信息扫描
├── .github/workflows/ci.yml       CI：离线自检 + 敏感信息扫描（不需 SDK）
├── build.sh                      构建辅助：环境预检 + 触发 hvigor 构建
└── design-preview.html           界面预览（浏览器直接打开）
```

---

## 四、关键实现

### 1. 沉浸光感悬浮底栏

```typescript
HdsTabs({ controller: this.tabsController }) { /* 4 个 TabContent */ }
  .scrollable(false)
  .barOverlap(true)              // 页签栏脱离布局流，悬浮于内容之上
  .vertical(false)
  .barPosition(BarPosition.End)  // 只有 End 位置才触发沉浸光感
  .barFloatingStyle({
    barBottomMargin: this.naviIndicatorHeight > 0 ? this.naviIndicatorHeight : 12,
    adaptToHandedness: true,
    systemMaterialEffect: {
      materialType: hdsMaterial.MaterialType.ADAPTIVE,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
    }
  })
```

配套处理：

- **背景分层**：底色渐变 + 三个高斯模糊光斑，让材质有可折射的内容层次
- **内容留白**：每页 `bottom: 108vp`，避免被悬浮栏遮挡
- **安全区**：`setWindowLayoutFullScreen(true)` 后读取 `AvoidArea` 的 `topRect` / `bottomRect`，顶部给内容加 padding，底部作为 `barBottomMargin`

### 2. 音频转换（DSP）

处理链：**下混单声道 → 时间裁剪 → 峰值归一化 → 窗口化 sinc 重采样 → 增益与淡入淡出 → 16bit 量化**

- 重采样采用 Blackman 窗加权 sinc 插值（单边 12 taps），降采样时把截止频率收紧到 `ratio × 0.9`：
  10kHz 混叠抑制约 -78dB，6kHz 以下无衰减
- 频率保持精确：8k/16k/22.05k/32k/44.1k/48k → 16700Hz，1kHz 正弦输出仍是 1kHz
- 三角函数与窗函数改为查表插值（误差 < 1e-7）；**转换整体在 TaskPool 工作线程执行**，
  只把当前时间窗口的采样复制过去，主线程不再被 1 秒以上的计算冻住；TaskPool 不可用时自动回退同步实现
- 转换结果按参数签名缓存，参数不变时重复试听/生成直接复用

### 3. 双引擎试听

| 引擎 | 用途 | 实现 |
|:--|:--|:--|
| 原声 | 听素材本身 | `AVPlayer` + `fd://` |
| 盒音 16.7kHz | 听写入耳机后的真实效果 | 由 16700Hz 精确升采样到 48kHz，`AudioRenderer` 渲染 |

> 升采样到 48kHz 播放而不是直接以 16700Hz 渲染，既保证音高与写入后一致，
> 又避开 `AudioSamplingRate` 枚举不含 16700 的类型限制。

### 4. 蓝牙与直写

- 权限：`ohos.permission.ACCESS_BLUETOOTH`（user_grant）与 `ohos.permission.ACCESS_NEARLINK`；
  星闪权限仅作连接识别，拒绝不影响经典蓝牙主流程
- 设备识别：`classOfDevice` major class 位判断音频类设备，不依赖枚举命名；
  A2DP 已连接设备列表作为“音频通道”的判据（全局 `getProfileConnectionState()` 会回缓存值，只作兜底），
  星闪状态用于补位
- 写入链路：建立 RFCOMM/SPP 会话 → 读取当前音效状态 → 探测固件协议（两套）→ 预选自定义槽位 →
  按耳机给出的大小分包传输 → 等待闪存擦写（传完不再改动槽位，避免撞上耳机收口）
- 优先直接建串口，**不再预先断开音频**：只有耳机回“通道忙/未准备好”时才尝试断开一次 A2DP，
  且断开被系统拒绝（2900099）也继续建链——音频通道是系统自己连的时候常常断不掉，
  把它当致命错误会把“耳机在盒里、没有任何播放”误判成被占用
- 断开被拒时先用 `connectAllowedProfiles` 把这台设备的 profile 认领到本应用名下再断，
  之后同一条音频连接就能被断开（实测系统连的连接直接断必然 2900099，认领后 6ms 断开）
- 建链重试按 700ms 的节拍走：真机上耳机往往要到第 6 次请求才肯开串口，
  原来的 1.3s 间隔把这 6 次拖成 14 秒
- 可靠性：链路中断自动重试；数据已完整落盘但“选中”失败时只补发选中命令，不重传整包；
  写入后耳机闪存需要收尾，应用会等待沉降期（15 秒）再开始下一次传输
- **会话复用**：一次操作结束后 SPP 通道不立即关闭，留 90 秒热连接给下一次操作。
  真机上一次 `sppConnect` 约 2~3 秒（要先做 SDP 再握手），连续切内置音时这一步完全是重复劳动。
  两个安全边界：**写完闪存不保留**（耳机会在几秒后自己收掉通道）、
  **复用前先发一条只读查询探活**（沉降期内保活是停发的，光看 socket 状态会误判）；
  通道空闲时每 3 秒一条查询保活，掉线（合盖/休眠）只降级重连、不再额外加冷却
- 星闪连接下没有对三方开放的串口通道：写入前直接拦截，并给出切换到经典蓝牙的指引
- 恢复默认：只发查询与“选中默认”两条命令，不重新上传音频
- 机型判断：优先使用耳机自报型号（0107 tag 15），名称仅作兜底；未收录机型只提醒不拦截，
  真正的门槛是协议能力探测；每次写入记录 `DEVICE_MATRIX` 便于后续验证
- 状态刷新：系统蓝牙/星闪事件成组到达时合并成一次刷新；写入前后仍强制读取最新快照

### 5. 日志与反馈

- `Logger` 统一出口（hilog + 内存日志中心），所有 `catch` 都记录 `code` / `message`
- 日志按天落盘 `files/logs/boxtone-yyyyMMdd.log`，内存保留最近 600 条
- 启动时自动清理：仅保留最近 7 天、总量不超过 2MB；“清空日志”会删除全部历史文件
- 设备地址在日志与诊断信息中统一打码，不读取、不记录设备 SN
- 导出报告把**错误条目置顶**，再用 `DocumentViewPicker` 让用户选择保存位置；也支持复制到剪贴板
- 在线反馈当前未启用，提交走系统分享（自带诊断日志附件）；截图副本在提交/删除/退出后立即清理

### 6. 界面语言

- 启动时按系统地区选择语言：CN / HK / MO / TW → 简体中文，其余地区 → English
- 全部用户可见文案集中在 `common/i18n/Strings.ets`，通过 `I18n.t(key)` / `I18n.f(key, args)` 取值，
  支持 `{0}` 插值；数据类内容（机型、音色、反馈类型等）存 key，展示时再按当前语言解析
- 依赖中文文案做逻辑判断的地方已改为错误码 / `ToneErrorReason`，切换语言不会影响重试与补发选中
- 旧版本保存的音效名称与反馈记录属于用户数据，不做回写翻译；诊断日志正文保持中文，便于排查

### 7. 备份与导入

- **备份容器**：`.boxtone` = 魔数 `BOXTONE1` + 清单长度（u32 小端）+ JSON 清单 +
  按清单顺序拼接的原始 PCM。不依赖 zip 等额外能力，导出/解析完全在应用内完成；
  恢复时总长度必须与清单严格相等，否则整份拒绝，不会写出半条数据。
- **导入上限**：备份恢复与 `.pcm` / `.raw` 导入允许到 192000 字节（兼容旧版本生成的长音效），
  真正写入仍受 2.5 秒 / 83500 字节上限约束，超限时由写入前置检查拦下。
### 8. 音效库的删除保护

- 单条删除：写入进行中时，该音效的删除入口直接置灰（`CaseWriteService.isToneWriting(id)`），
  避免把正在下发的文件从索引里拿掉。
- 批量删除：进入选择模式前检查 `CaseWriteService.isBusy()`；删除循环里再次跳过正在写入的音效。
  若删掉的正好是「盒内」标记的那条，标记同步清空，音效库不会留下已不存在的音效名。

---

## 五、构建与运行

### 为什么仓库里没有现成的 `.hap`

HAP 是压缩包，但里面装的不是源码，而是两样**只能由 SDK 产出**的东西：

| 内容 | 生产者 | 作用 |
|:--|:--|:--|
| `ets/modules.abc` | ArkTS 编译器 `es2abc` | 全部 `.ets` 编译后的字节码 |
| `resources.index` | 资源编译器 `restool` | 编译后的图片/字符串/尺寸索引表 |

手工改 zip 拼不出可安装的 HAP —— 缺 `.abc` 装机即失败。而这个工程还额外依赖
**闭源的 `@kit.UIDesignKit`**（`HdsTabs` / `hdsMaterial`），它只随 DevEco 的
HarmonyOS SDK 分发（需登录华为账号并同意协议），OpenHarmony 开源 SDK 里没有。
所以 `assembleHap` 必须在装有 HarmonyOS 7 SDK 的机器上跑一次。

### 命令行构建

```bash
./build.sh check    # 只做环境预检：node / hvigorw / SDK / 图片资源引用 / 源文件数
./build.sh          # 预检通过则执行 hvigor assembleHap
./build.sh clean    # 清理 entry/build、.hvigor
```

`hvigorw` 包装器由 DevEco Studio **首次打开工程时自动生成**，所以第一次仍需先用 IDE 打开一次。
产物：`entry/build/default/outputs/default/entry-default-signed.hap`，装真机 `hdc install -r <hap>`。

### 测试

| 层级 | 命令 | 覆盖范围 |
|:--|:--|:--|
| L0 静态门禁 | `./build.sh`（或 `hvigorw assembleHap`） | 编译 + ArkTS 类型检查 |
| L1 单元测试 | `hvigorw test -p module=entry@default -p product=default` | 协议编解码、规格常量、机型匹配，用例在 `entry/src/test/` |
| 离线逻辑自检 | `node tools/verify-logic.mjs` | 纯逻辑断言，不依赖设备 |
| CI | `.github/workflows/ci.yml` | push / PR 自动跑离线自检与敏感信息扫描 |

单测依赖 `@ohos/hypium`（已写入 `entry/oh-package.json5` 的 `devDependencies`），
首次拉取后执行一次 `ohpm install` 即可。

### IDE 构建

1. **DevEco Studio 26.0 及以上**，安装 **HarmonyOS 7 SDK（API 26）**用于编译
   —— 沉浸光感底栏依赖闭源 `@kit.UIDesignKit`，只有 HarmonyOS SDK 才有；
   工程 `compatibleSdkVersion: "6.1.0(23)"`，产物可运行在 HarmonyOS 6.1（API 23）及以上设备
2. 打开工程根目录 `BoxTone/`，等待 `Sync` 完成（若提示 `modelVersion` 迁移，按向导确认即可）
3. `File → Project Structure → Signing Configs` 勾选 **Automatically generate signature**（需登录华为账号）
4. 若 Sync 提示 SDK 版本不一致，在 `Project Structure → Modules` 里选本机安装的 API 26 SDK（编译用），
   保持 `compatibleSdkVersion` 为 `6.1.0(23)` 不变（API 10–25 必须用 `x.y.z(n)` 格式）
5. 连接真机（蓝牙与音频能力模拟器不可用）→ Run

### 不装 SDK 也能先验证

`tools/format-lab.html` 用浏览器打开即可 —— 它与 App 共用同一套 DSP，能：

- 导入 WAV（8/16/24/32bit PCM、Float32、EXTENSIBLE）或生成一段带衰减的测试提示音
- 拖波形手柄裁剪、调增益/淡入淡出/归一化
- 转换后显示字节数、帧数、时长、峰值，并用十六进制确认**没有 RIFF 文件头**
- 试听原声与「盒音」（16700Hz 升采样到 48kHz 播放，音高与写入耳机后一致）
- 导出 `.pcm`（交付格式，与 App 输出同一串字节）和 `.wav`（仅供播放器核对）
- 一键跑内置自检，结果直接打印在页面上

> 它验证的是**字节流是否合规**这件最容易出错的事；界面本身仍需真机看。

**首次使用**：设备页授予蓝牙权限 → 配对耳机 → 双耳入盒开盖 → 音效页导入素材或选择内置音色 →
生成后在「音效库」点写入；不满意可在音效库一键**恢复默认开盒音**。

---

## 六、已知限制

| 限制 | 说明 |
|:--|:--|
| 自定义音效 ≤2.5 秒 | 鸿蒙 SPP 约 23KB/s，超过约 106KB（3.2 秒）后耳机擦写第二阶段会卡死；2.5 秒 / 83500 字节是当前固件的稳定上限，详见 `docs/write-duration-gap.md` |
| 仅经典蓝牙可写 | 星闪链路没有对三方开放的串口通道；星闪连接时应用会识别并提示切换到经典蓝牙 |
| 机型覆盖有限 | FreeClip 2（BTFT0027）、FreeBuds Pro 5（BTFT0023）、FreeBuds 7（BTFT0028）已实测通过；FreeBuds 6（BTFT0020）属官方支持开盒提示音的机型，盒音自定义仍待实测 |
| 依赖固件协议 | 私有协议可能随固件升级变化；应用会做能力探测，失败时给出诊断信息而不是盲目写入 |
| 界面语言 | 完整界面按系统地区自动切换中英文；旧版本保存的音效名称与反馈记录保持原文，不自动翻译 |
| 在线反馈未启用 | 联网备案与后端启用前，反馈走系统分享；应用内不保存 SMTP 凭据 |
| 无法读取耳机当前音效与电量 | 私有协议未公开读取接口；恢复默认通过“选中默认槽位”完成 |
| 单次分析上限 60 秒 | 控制内存占用，音效本身只需 ≤2.5 秒素材 |
| 备份文件未压缩 | `.boxtone` 存的是原始 PCM，体积与音效库占用量相当；这样不依赖 zip 能力，离线也能解析 |
| 仅 arm64-v8a | 原生解码与目标机型均为 64 位 ARM |

---

## 七、符合开发规范

- 目录分层遵循 `common / components / models / pages / services`，文件命名为 `PascalCase` + 语义后缀
- 全部使用 `@kit.*` 导入，未使用任何已废弃 `@ohos.*` 接口（`router` / `fileio` / `console` / `globalThis` 均无）
- 严格类型：无 `any`、无 `var`、无解构赋值、无函数表达式、无 `@ts-ignore`、无嵌套函数
- 所有组件参数名避开与基类链式方法冲突（`cardPadding` / `waveHeight` / `btnLabel` 等）
- 每个 `catch` 都做类型收窄并记录日志；资源（播放器、文件句柄、渲染器）在 `aboutToDisappear` 中释放
- 长列表使用 `ForEach` + 稳定 key，`ListItem` 设 `cachedCount`
- 重计算任务使用 `TaskPool`，并保留同步回退路径
- 无障碍与深色模式：全局主题，正文对比度 ≥ 4.5:1；中英文界面使用集中式双语字典，系统文案由 `base` / `en_US` 资源提供
- 音效索引采用临时文件 + rename 原子写，进程中断后可自动恢复索引外的音频文件

---

## 八、敏感信息与提交检查

- `.env`、`signing/`、`.pem`、`.p12`、`.jks`、`.keystore` 等本地文件和目录不会进入 Git。
- `server/.env.example` 只保留占位值；真实 SMTP 授权码和反馈 Token 放在本地 `server/.env` 或服务器环境变量中。
- 应用内不保存 SMTP 凭据；当前 `FeedbackApiConfig.ENDPOINT` 与 `TOKEN` 均为空，反馈走系统分享。
- 客户端内嵌的 Bearer Token 可以被反编译提取，只能当弱门禁使用：
  启用在线反馈前，必须在服务端做限流（按来源 IP / 时间窗）、请求体上限与 token 轮换，不能只依赖 Token。
- `build-profile.json5` 不保存签名密码，两套签名配置的密码字段都为空，由 `hvigorfile.ts` 在构建时注入：
  - debug：`signing/debug-password.txt`（备用通道 `signing/debug-password.enc`，可直接放 DevEco 生成的密文）
  - release：`signing/keystore-password.txt`
- 签名材料全部在本地 `signing/` 下，路径相对工程根目录，不含机器绝对路径：
  - `signing/debug/`：`boxtone-debug.p12`、`boxtone-debug_cer.cer`、`boxtone_profileDebug.p7b`、`material/`
  - `signing/`：`boxtone-release.p12`、`boxtone-release_cer.cer`、`boxtone_profileRelease.p7b`、`material/`
- **material 必须与 `.p12` 同级**：hvigor 解密密码时固定取 `storeFile` 同目录下的 `material/`（见 `hvigor-ohos-plugin/src/utils/decipher-util.js`），所以调试与发布的材料不能混用。
- 若在 DevEco 里重新生成过调试签名，密钥库密码会变，需把新密码补回 `signing/debug-password.txt`；否则签名密码为空，构建报 `00303116`（长度小于 32）。
- 隐私：不读取设备 SN；日志中的蓝牙地址统一打码；反馈内容由用户在提交前确认。
- 启用本地 pre-commit 检查：

```bash
git config core.hooksPath .githooks
```

提交前会自动扫描 staged 文件中的敏感文件名、私钥和常见 Token。也可以手动执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\check-sensitive-staged.ps1
```
