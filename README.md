# 盒音工坊 · BoxTone

> 为华为蓝牙耳机定制**充电盒开盖音效**的 HarmonyOS 应用。
> 导入素材 → 按充电盒解码规格转换 → 导出 RAW → 在华为智慧音频 App 中替换。

底部导航使用官方 **HdsTabs 沉浸光感悬浮底栏**（HDS 6.1.0 / API 23 起提供）
（`barOverlap` + `barFloatingStyle.systemMaterialEffect`），
参考官方文档 [沉浸光感悬浮底栏](https://developer.huawei.com/consumer/cn/doc/doccenter-advanced-features/bpta-spatiality-immersive)。

---

## 一、功能

| 页面 | 能力 |
|:--|:--|
| **设备** | 蓝牙开关/权限状态、已配对设备（自动识别音频类设备）、附近设备扫描与配对、跳转系统蓝牙设置 |
| **音效** | 导入 WAV、6 种内置音色合成、波形可视化与选区、起始/时长/增益调节、峰值归一化、淡入淡出、**原声 / 盒音双引擎试听**、规格实时校验、生成入库或直接导出 |
| **音效库** | 音效列表、试听、导出、重命名、删除，统计总数/占用/最近生成 |
| **我的** | 盒端规格说明与技术原理、偏好设置、日志中心入口、一键导出/清空日志 |
| **日志中心** | 全量诊断日志、按级别筛选、复制到剪贴板、导出 txt 报告 |

---

## 二、目标格式（严格对齐充电盒解码标准）

| 参数 | 值 |
|:--|:--|
| 编码 | Signed 16-bit PCM（小端） |
| 声道 | Mono 单通道 |
| 采样率 | **16700 Hz** |
| 容器 | 无文件头 RAW（`.pcm` / `.raw`） |
| 时长 | ≤ 2 秒 |
| 体积 | 每秒固定 **33400 字节**，上限 66800 字节 |

> 盒端解码器标定在约 16700Hz 而非标准 16000Hz。放入 16000Hz 素材播放时音调会整体升高约一个半音；
> 按 16700Hz 导出才能保持原本听感。

---

## 三、工程结构

```
BoxTone/
├── AppScope/                     应用级配置与图标
├── entry/src/main/
│   ├── module.json5              模块配置（含蓝牙权限声明）
│   ├── ets/
│   │   ├── entryability/EntryAbility.ets      启动、沉浸式布局、服务初始化
│   │   ├── common/
│   │   │   ├── constants/        AppConstants（音频规格）/ ThemeConstants（设计令牌）
│   │   │   └── utils/            Logger / DateUtils / FormatUtils / EventBus
│   │   ├── models/               DeviceModel / ToneModel / LogModel
│   │   ├── services/
│   │   │   ├── AudioSourceService.ets      WAV 解析（PCM 8/16/24/32、Float32、EXTENSIBLE）
│   │   │   ├── AudioConvertService.ets     DSP 核心：下混/裁剪/归一化/重采样/增益/量化
│   │   │   ├── ToneSynthesizerService.ets  内置音色合成
│   │   │   ├── AudioPlayService.ets        AVPlayer 原声 + AudioRenderer 盒音
│   │   │   ├── ToneRepositoryService.ets   音效库持久化与导出
│   │   │   ├── BluetoothService.ets        设备发现/配对/连接状态
│   │   │   ├── LogService.ets              日志收集/落盘/导出
│   │   │   └── SettingsService.ets         偏好设置
│   │   ├── components/           GlassCard / WaveformView / ToneCard / DeviceRow 等 9 个复用组件
│   │   └── pages/
│   │       ├── Index.ets         HdsTabs 沉浸光感悬浮底栏 + 日志浮层
│   │       ├── main/             DevicePage / TonePage / LibraryPage
│   │       └── settings/         ProfilePage / LogPage
│   └── resources/                图标（SVG）、配色、字符串（中/英）
├── tools/format-lab.html         格式验证台（浏览器直接打开，跑同一套 DSP）
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

重采样采用 Blackman 窗加权 sinc 插值（单边 12 taps），降采样时把截止频率收紧到 `ratio × 0.9`：

- **10kHz 混叠抑制 -78dB**（理想核截止点正好压在 8350Hz 上，不留过渡带余量时只有 -57dB；
  留 10% 余量后截止落在 7515Hz，而提示音内容几乎都在 5kHz 内，通带零代价）
- 频率保持精确：8k/16k/22.05k/32k/44.1k/48k → 16700Hz，1kHz 正弦输出仍是 1kHz
- 三角函数与窗函数改为查表插值（误差 < 1e-7），单次 5 秒立体声转换 **约 81ms**
- 已用等价 JS 实现做过程序化验证：**26 条断言全部通过**（长度 / 字节数 / 音高 / 幅度 /
  抗混叠 / 通带 / 下混 / WAV 往返 / 5 秒截断 / 8bit 与 24bit 解析）

### 3. 双引擎试听

| 引擎 | 用途 | 实现 |
|:--|:--|:--|
| 原声 | 听素材本身 | `AVPlayer` + `fd://` |
| 盒音 16.7kHz | 听写入耳机后的真实效果 | 由 16700Hz 精确升采样到 48kHz，`AudioRenderer` 渲染 |

> 升采样到 48kHz 播放而不是直接以 16700Hz 渲染，既保证音高与写入后一致，
> 又避开 `AudioSamplingRate` 枚举不含 16700 的类型限制。

### 4. 蓝牙

- `ohos.permission.ACCESS_BLUETOOTH`（user_grant），页面内按需申请，拒绝时给出恢复入口
- `classOfDevice` 的 major class 位判断音频类设备（`(cod >> 8) & 0x1F === 4`），不依赖枚举命名
- 已配对 / 附近设备 / 配对 / A2DP 通道状态全覆盖
- **说明**：HarmonyOS 未开放"程序化连接指定 A2DP 设备"的接口，配对由应用发起，音频通道的建立与切换跳转系统蓝牙设置完成（页面有明确入口）

### 5. 日志与导出

- `Logger` 统一出口（hilog + 内存日志中心），所有 `catch` 都记录 `code` / `message`
- 日志按天落盘 `files/logs/boxtone-yyyyMMdd.log`，内存保留最近 600 条
- 导出报告把**错误条目置顶**，再用 `DocumentViewPicker` 让用户选择保存位置；也支持复制到剪贴板

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
- 一键跑 9 条内置自检，结果直接打印在页面上

> 它验证的是**字节流是否合规**这件最容易出错的事；界面本身仍需真机看。

**首次使用**：设备页授予蓝牙权限 → 配对耳机 → 音效页导入 WAV 或选内置音色 → 生成并导出 →
在华为智慧音频 App 中替换提示音。

---

## 六、已知限制

| 限制 | 说明 |
|:--|:--|
| 仅支持 WAV 导入 | 目标格式是无损 RAW，导入环节要求无损源；MP3/AAC 等有损容器需先转 WAV（应用会给出明确提示）。AVCodec 解码路径可在 `AudioSourceService` 中扩展 |
| 单次分析上限 60 秒 | 控制内存占用，音效本身只需 ≤2 秒素材 |
| 自定义音效 ≤2 秒 | 实测 5 秒包能完整传到耳机，但盒端擦写闪存会停在半途、播放只剩约 1 秒，2 秒是当前固件下的安全上限 |
| 无法程序化连接 A2DP | 系统未开放该接口，需跳转系统蓝牙设置 |
| 无法直接写入充电盒 | 写入走华为智慧音频 App 的文件替换流程，本应用负责生成合规文件并导出 |
| 电量不显示 | 耳机私有协议未公开 |

---

## 七、符合开发规范

- 目录分层遵循 `common / components / models / pages / services`，文件命名为 `PascalCase` + 语义后缀
- 全部使用 `@kit.*` 导入，未使用任何已废弃 `@ohos.*` 接口（`router` / `fileio` / `console` / `globalThis` 均无）
- 严格类型：无 `any`、无 `var`、无解构赋值、无函数表达式、无 `@ts-ignore`、无嵌套函数
- 所有组件参数名避开与基类链式方法冲突（`cardPadding` / `waveHeight` / `btnLabel` 等）
- 每个 `catch` 都做类型收窄并记录日志；资源（播放器、文件句柄、渲染器）在 `aboutToDisappear` 中释放
- 长列表使用 `ForEach` + 稳定 key，`ListItem` 设 `cachedCount`
- 无障碍与深色模式：全局暗色主题，正文对比度 ≥ 4.5:1；中英文资源分离（`base` / `en_US`）
---

## 八、敏感信息与提交检查

- `.env`、`signing/`、`.pem`、`.p12`、`.jks`、`.keystore` 等本地文件和目录不会进入 Git。
- `server/.env.example` 只保留占位值；真实 SMTP 授权码和反馈 Token 放在本地 `server/.env` 或服务器环境变量中。
- `build-profile.json5` 不保存签名密码，两套签名配置的密码字段都为空，由 `hvigorfile.ts` 在构建时注入：
  - debug：`signing/debug-password.txt`（备用通道 `signing/debug-password.enc`，可直接放 DevEco 生成的密文）
  - release：`signing/keystore-password.txt`
- 签名材料全部在本地 `signing/` 下，路径相对工程根目录，不含机器绝对路径：
  - `signing/debug/`：`boxtone-debug.p12`、`boxtone-debug_cer.cer`、`boxtone_profileDebug.p7b`、`material/`
  - `signing/`：`boxtone-release.p12`、`boxtone-release_cer.cer`、`boxtone_profileRelease.p7b`、`material/`
- **material 必须与 `.p12` 同级**：hvigor 解密密码时固定取 `storeFile` 同目录下的 `material/`（见 `hvigor-ohos-plugin/src/utils/decipher-util.js`），所以调试与发布的材料不能混用。
- 若在 DevEco 里重新生成过调试签名，密钥库密码会变，需把新密码补回 `signing/debug-password.txt`；否则签名密码为空，构建报 `00303116`（长度小于 32）。
- 启用本地 pre-commit 检查：

```bash
git config core.hooksPath .githooks
```

提交前会自动扫描 staged 文件中的敏感文件名、私钥和常见 Token。也可以手动执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\check-sensitive-staged.ps1
```
