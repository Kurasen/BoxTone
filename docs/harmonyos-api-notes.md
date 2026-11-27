# 鸿蒙接口速查（盒音工坊）

> 只收这个项目实际用到的接口：怎么用、从哪个版本开始有、有什么限制、我们踩过的坑。
> 起始版本取自本地 SDK 的 `.d.ts` 注释（`D:\App\DevEco Studio\sdk\default`），坑来自项目代码注释和真机调试记录。
>
> 项目版本：`compatibleSdkVersion` = **6.1.0(23)**，`targetSdkVersion` = **26.0.0**。
> 凡是起始版本高于 23 的接口，在 23～25 的设备上调用会失败，必须 `try/catch` 或判断能力后再用。

---

## 目录

1. [启动页](#1-启动页)
2. [深浅色与系统栏](#2-深浅色与系统栏)
3. [沉浸光感与材质](#3-沉浸光感与材质)
4. [经典蓝牙 SPP](#4-经典蓝牙-spp)
5. [星闪](#5-星闪)
6. [音频解码（C API）](#6-音频解码c-api)
7. [试听播放](#7-试听播放)
8. [文件选择与沙箱](#8-文件选择与沙箱)
9. [隐私声明弹窗](#9-隐私声明弹窗)
10. [Release 混淆](#10-release-混淆)
11. [怎么查文档](#11-怎么查文档)

---

## 1. 启动页

**配置位置**：`entry/src/main/module.json5` 的 `abilities[]`

```json5
"startWindowIcon": "$media:startIcon",
"startWindowBackground": "$color:start_window_background",
```

| 要点 | 说明 |
|:--|:--|
| 图标按原始像素居中显示 | 不缩放、**不加圆角遮罩**。桌面图标的圆角是桌面加的，启动页不会加。`startIcon.png` 必须自己做成圆角透明的 RGBA 图 |
| 背景色跟随**系统**深浅色 | `resources/base` 与 `resources/dark` 各放一份 `start_window_background`，系统按自己的深浅色取，不看应用里的外观设置 |
| 增强启动页 `startWindow` | API 19 起。可配图标、插画、品牌图，但图标会被放到屏幕偏上并放大到 128vp 以上 |
| `startWindowColorModeType` | API 20 起，让启动页跟随应用深浅色。**只对进程内启动生效，冷启动仍跟随系统**，所以项目没用 |

**项目做法：启动衔接遮罩**（`pages/Index.ets` + `ThemeService.takeLaunchVeil()`）

应用外观和系统不一致时，首页最上层先铺一张"复刻启动页"的遮罩，再分三段过渡：

| 阶段 | 常量 | 当前值 |
|:--|:--|:--|
| 浅色停留 | `LAUNCH_VEIL_HOLD_MS` | 200ms |
| 底色换成应用底色，图标不动 | `LAUNCH_VEIL_COLOR_MS` | 250ms |
| 图标缩小淡出 | `LAUNCH_VEIL_ICON_MS` | 200ms |
| 遮罩淡出露出首页 | `LAUNCH_VEIL_FADE_MS` | 140ms |

**踩过的坑**

- 遮罩不能用 `.transition(TransitionEffect.OPACITY.animation(...))`：带 `animation` 的 transition 在**出现时也会淡入**，首帧遮罩是透明的，看起来就是闪一下。改为 `@State opacity = 1`，用 `animateTo` 驱动。
- 遮罩只有底色没有图标时，启动页退场那一刻图标凭空消失，看起来是白屏闪一下。遮罩里要放同样大小（216px）、居中的图标。
- 浅色遮罩直接淡出到深色首页，中间是发灰的雾面。要先把**底色**换过去，再露出首页。
- 图标和首页内容同时切换时，首页正中的亮色卡片会"顶掉"图标。要让图标先单独退场。
- 系统深浅色只能在**本进程第一次** `ThemeService.init` 时读，此时还没调过 `setColorMode`。Ability 重建后读到的可能是应用自己的设置。
- `Palette.START_WINDOW_LIGHT/DARK` 必须和两份 `start_window_background` 保持一致。

---

## 2. 深浅色与系统栏

| 接口 | 用途 |
|:--|:--|
| `ApplicationContext.setColorMode()` | 应用级深浅色，系统弹窗、半模态、HDS 底栏材质都会跟随 |
| `resourceManager.getConfigurationSync().colorMode` | 读当前深浅色 |
| `UIAbility.onConfigurationUpdate()` | 系统深浅色变化回调 |
| `window.setWindowLayoutFullScreen(true)` | 全屏布局，背景延伸到状态栏下方 |
| `window.setWindowSystemBarProperties()` | 状态栏、导航栏图标颜色 |
| `window.getWindowAvoidArea(TYPE_SYSTEM)` | 状态栏、手势条高度，用于留出安全区 |

**踩过的坑**

- 手动指定深色或浅色后，`onConfigurationUpdate` 不再派发；只有"跟随系统"模式能收到。
- 在 `onConfigurationUpdate` 里**绝不能再调 `setColorMode`**：会再次触发配置派发，形成死循环直至闪退。回调里只重算配色、重绘。
- 应用内配色由 `Palette` 的 getter 按 `ThemeService.isDark()` 返回，切换后自增 `AppStorage` 的 `themeEpoch` 触发重绘。组件要声明 `@StorageProp('themeEpoch')`，否则不会刷新。

---

## 3. 沉浸光感与材质

### 3.1 HDS 悬浮底栏（项目在用）

```ts
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';

.barFloatingStyle({
  systemMaterialEffect: {
    materialType: hdsMaterial.MaterialType.ADAPTIVE,
    materialLevel: level  // 支持 IMMERSIVE → GENTLE；否则 SMOOTH
  }
})
```

- 6.1.0(23) 起，HDS 组件支持沉浸光感材质。`UIDesignKit` 是闭源 Kit，只随 DevEco 分发，OpenHarmony 开源 SDK 里没有。
- 自定义材质等级前先调 `hdsMaterial.getSystemMaterialTypes()`：支持 `IMMERSIVE` 才用 `GENTLE`/`EXQUISITE`，不支持用 `SMOOTH`，以降低卡顿和发热风险。也可以直接用 `ADAPTIVE` 交给系统决定。

### 3.2 通用属性 `systemMaterial`（API 26 起）

```ts
import { uiMaterial } from '@kit.ArkUI';
.systemMaterial(new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR }))
```

**生效范围很窄**，只在这些地方有效：

- `Navigation` / `NavDestination` 的标题栏子树
- `barPosition` 为 `End` 的横向 `Tabs` 底栏子树
- `Slider`、`Toggle`
- 弹出类：`AlertDialog`、`CustomDialog`、`ActionSheet`、各类 PickerDialog、`Popup`、`Tips`、`Menu`、`bindSheet`、`Toast`、`Select` 下拉菜单、`SelectionMenu` 等

**页面里的普通卡片、按钮设置了也不生效。**

其他要点：

- `targetSdkVersion` ≥ 26 时，上面这些组件**默认就开启**沉浸光感，不用额外配置。
- 生效后会把组件已设置的 `backgroundColor` 恢复成透明、`borderWidth` 恢复成无边框，不要和这两个属性混用。
- 功耗建议：控制面积，不要嵌套，不要和 `backgroundBlurStyle` 叠加，不要盖在视频、动图等动态内容上，参数不要频繁修改。

**项目结论**：卡片、按钮的"玻璃感"用普通能力模拟：`GlassCard` 的半透明底色 `CARD_GLASS`，配合调亮的背景光斑 `HALO_*`。按钮按压回弹用 `clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })`。纯黑背景上的渐变描边方案试过，不好看，已撤回。

---

## 4. 经典蓝牙 SPP

**权限**：`ohos.permission.ACCESS_BLUETOOTH`。首次进入只用 `checkAccessToken` 查状态，用户点"去授权"时才调 `requestPermissionsFromUser`。

| 接口 | 起始版本 | 用途 |
|:--|:--|:--|
| `socket.sppConnect(address, options, cb)` | 10 | 建立 RFCOMM 串口 |
| `socket.sppWrite` / `sppWriteAsync` | — / **18** | 写数据；项目优先用异步版本 |
| `socket.getMaxTransmitDataSize(id)` | **22** | 协议栈建议的单次最大写入长度 |
| `socket.on('sppRead', ...)` | — | 接收数据 |
| `connection.connectAllowedProfiles` | **16** | 连接设备允许的 profile |
| `connection.disconnectAllowedProfiles` | **26.0.0** | 断开 profile。**高于最低兼容版本 23**，所有调用都已包在 `try/catch` 里，旧设备上失败只记日志 |
| `connection.getProfileConnectionState` | — | 查 A2DP/HFP 是否已连接 |
| `access.getState` / `enableBluetooth` / `on('stateChange')` | — | 蓝牙开关状态 |

```ts
const options: socket.SppOptions = {
  uuid: MbbSpec.SPP_UUID,
  secure: false,               // 见下方坑
  type: socket.SppType.SPP_RFCOMM
};
```

**踩过的坑**

- FreeClip 2 等机型多数只接受**非加密通道**，`secure: true` 经常直接返回 -1。项目会优先用上次成功的取值，其余取值作为兜底。加密通道传大包还会被耳机掐断。
- 耳机串口**静默约 4 秒就会被收掉**，要用定时器发保活包（`ToneClient.startKeepAlive`）。
- `getMaxTransmitDataSize` 查询失败或返回值小于 256 时，退回默认分片 `MbbSpec.SPP_WRITE_CHUNK`；正常情况下取 `min(max, 8192)`。协议栈拒收过大的包时，自动降级为逐帧写。
- 双耳放回盒里、手机没有任何播放时，系统仍可能把 A2DP 报成"已连接"。这时 `disconnectAllowedProfiles` 常返回 **2900099**（这条连接不是本应用发起的）。**不能当致命错误。**
  - 解法：先 `connectAllowedProfiles` 把连接"认领"到本应用名下，等约 250ms，再 `disconnectAllowedProfiles` 就能断开。
  - 擦写期间不要认领，因为认领本身会建立音频连接。
- 鸿蒙侧 SPP 实测约 23KB/s。单条音效超过约 106KB 后，耳机在擦写阶段会失去响应，所以音效上限定为 2.8 秒。详见 `docs/write-duration-gap.md`。

---

## 5. 星闪

| 接口 | 起始版本 | 说明 |
|:--|:--|:--|
| `manager.isNearLinkSupported()`（`@hms.nearlink.manager`） | 6.1.0(23) | 设备是否支持星闪 |
| `nearlinkConstant.ConnectionState` / `DeviceClass` | — | 连接状态、设备类型 |

- 只用来**识别**连接状态：系统音频走星闪时 A2DP 不再报告已连接，蓝牙侧会误判成"未连接"，要用星闪配对表补上真实状态。
- 星闪**没有对三方开放的串口通道**，写入盒音仍然只能走经典蓝牙 SPP。星闪连接时应用会提示用户切换。
- 回到前台、切回设备页时要主动刷新一次：星闪连接变化没有系统回调。

---

## 6. 音频解码（C API）

文件：`entry/src/main/cpp/audiodec.cpp`。链接 `libnative_media_avsource.so`、`avdemuxer`、`acodec`、`codecbase`、`core`。

**流程**：`OH_AVSource_CreateWithFD` → `OH_AVDemuxer_CreateWithSource` → `OH_AVDemuxer_SelectTrackByID` → `OH_AudioCodec_CreateByMime` → `Configure` → `Prepare` → `Start` → 循环调用 `QueryInputBuffer`/`PushInputBuffer`/`QueryOutputBuffer`/`FreeOutputBuffer`。

**踩过的坑**

- **必须显式开启同步模式**：

  ```cpp
  OH_AVFormat_SetIntValue(config.ptr, OH_MD_KEY_ENABLE_SYNC_MODE, 1);
  ```

  默认是异步回调模式。不设置的话，`QueryInputBuffer`/`QueryOutputBuffer` 一直返回 `AV_ERR_OPERATE_NOT_PERMIT`，表现为"没有解出音频数据"。开启后不能再注册回调。
- 解码放在 `napi_create_async_work` 里跑，不要阻塞 UI 线程。进度和取消通过全局 `std::atomic` 交换。
  - 已知问题：取消后马上发起下一次导入时，新任务会清掉取消标志，旧任务可能"复活"继续跑。待改为按任务编号判断取消。
- C++ 侧导出的函数名、返回对象的字段名都是运行时才有的，release 混淆必须保留，见第 10 节。

---

## 7. 试听播放

文件：`services/AudioPlayService.ets`

| 场景 | 接口 |
|:--|:--|
| 播放原始素材文件 | `media.createAVPlayer()`，传入 fd |
| 播放生成的盒音 | `audio.createAudioRenderer()`，48kHz、单声道、S16LE；由 16700Hz 精确升采样 |
| 音频焦点 | `audio.getAudioManager().getSessionManager().activateAudioSession()`（API 12 起） |

- 焦点先申请 `CONCURRENCY_DUCK_OTHERS`（压低其他应用音量），失败再改用 share 模式。
- `createAudioRenderer` + `start` 要几十到上百毫秒。渲染器实例会保留一段时间再释放，否则连续点击试听时延迟明显。
- 盒端解码器标定在 **16700Hz**，不是 16000Hz。用 16000Hz 素材，音调会整体升高约一个半音。

---

## 8. 文件选择与沙箱

| 接口 | 用途 |
|:--|:--|
| `picker.AudioViewPicker`（API 9 起） | 选择音频素材 |
| `picker.DocumentViewPicker` | 导出日志、导入导出备份 |
| `fileIo`（`fs`） | 沙箱读写 |
| `preferences.getPreferencesSync`（API 10 起） | 设置、反馈记录 |
| `taskpool.execute` | WAV 解析、格式转换等耗时计算 |
| `systemShare.ShareController` | 分享音效、反馈 |

**踩过的坑**

- **选择器返回的 URI 不能直接当路径**交给 `copyFileSync`：文档和媒体类 URI 是百分号编码的，中文名会变成 `%E9%97%AD…`，系统会按字面去打开，报 `13900002 No such file or directory`。正确做法是先 `fs.openSync(uri)` 拿到 fd，再按 fd 拷贝。
- `taskpool` 任务无法中断。取消导入时只能先置标志，任务返回后再丢弃结果。

---

## 9. 隐私声明弹窗

`@kit.AppGalleryKit` 的 `privacyManager`（`requestAppPrivacyConsent` 从 5.0.2(14) 起）

| 接口 | 用途 |
|:--|:--|
| `getAppPrivacyMgmtInfo()` | 是否接入了**全模式**（`FULL_MODE`） |
| `getAppPrivacyResult()` | 查询签署状态 |
| `requestAppPrivacyConsent()` | 拉起系统隐私弹窗 |

**规则**

- 弹窗在 `Index.onPageShow` 里拉起：放在 `onCreate` 时窗口还没就绪，拉不起来；放在 `aboutToAppear` 又早于首帧，会看到占位刚出现就被弹窗盖住。
- **不设超时**：超时只会把读得慢的用户误判成拒绝。
- **查询不到状态时，一律不当作已同意**。宁可多弹一次，也不能在用户未同意时收集信息，否则属于审核驳回项。
- 同意前只初始化基础能力（日志、设置、外观）。蓝牙、音效库、反馈这些业务服务由 `AppBootstrap.init` 在用户同意后统一启动。
- 不能自己画"同意"按钮，同意只能由系统弹窗给出。服务不可用时只给"重试 / 查看声明 / 退出"。

### 9.1 测试时弹不弹窗（11-27 实测）

隐私托管由云侧按**应用身份**识别，也就是签名 profile 里的 `appIdentifier`。身份对不上，或者这台设备还没拉到托管配置时，接口都报 `1006700003`（未接入）。这时代码看安装来源：`unknown`（侧载）放行，市场安装进重试页。

| 安装方式 | 签名身份 | 实测表现 |
|:--|:--|:--|
| DevEco 直接把 release 包装到本机 | DevEco 自动重签，身份变了（`appIdentifier=…3541`、`distributionType=none`） | 每次都报 1006700003 → 放行，**永远不弹** |
| debug 包（`signing/debug/` 手动调试证书） | 与 AGC 一致（`…6855`） | 首次启动就弹 |
| 云调试设备上安装正式签名包 | 与 AGC 一致（`…6855`、`app_gallery`） | **首次**报 1006700003 → 放行不弹；划掉重开才弹 |
| 应用市场安装（含邀请测试） | 与 AGC 一致 | 官方说明首次启动由系统自动弹窗（未实测） |

- **本机要测隐私弹窗**，用 debug 包或 `./tools/dev.sh build release debug`，不要用 DevEco 自动签名直接运行 release 包。
- **云调试设备首次不弹不是代码问题**。看起来是托管配置在首次启动之后才异步拉到本机，这一点是推断。不要据此给侧载包加等待重试：试过的方案已撤回。
- **市场包首次万一也报 1006700003**，`mustEnforce()` 为 true，会进重试页而不是放行。最差是用户点一次重试或重开应用，不会出现未同意就进入业务。
- 签名指纹对照：发布证书 `6DE3848E…C55293`，调试证书 `A6A5F557…87E4`，两者 `appIdentifier` 都是 `6917621682523596855`。
- **排查方法**：`PrivacyConsentService` 的流程日志用的是 `Logger.dev`，release 包不输出。排查时临时改成 `Logger.info`，再在启动时打印 `getBundleInfoForSelfSync(GET_BUNDLE_INFO_WITH_APPLICATION | GET_BUNDLE_INFO_WITH_SIGNATURE_INFO)` 里的 `appIdentifier`、`fingerprint`、`appDistributionType`、`installSource`，对比上表就能判断是哪一种。排查完改回去。

---

## 10. Release 混淆

配置：`entry/obfuscation-rules.txt`（目前 release 的 `obfuscation.enable` 为 `false`）

这些名字必须加进 `-keep-property-name`，否则 release 包会**静默失效**：

- **C++ 导出**：`decodeAudio`、`probeAudio`、`getDecodeProgress`、`cancelDecode`，以及返回对象的字段 `ok`、`error`、`frames`、`active`、`elapsedMs`……
- **与外界交换的 JSON 字段**：隐私弹窗回传的 `resultType`/`appIndex`、沙箱 `index.json`、`.boxtone` 备份清单、Preferences 里的反馈记录。混淆后 release 包会读不到 debug 包或旧版本写下的数据。

CI 里的 `tools/check-release.sh static` 会检查原生接口名是否都已保留。新增 NAPI 接口时记得同步更新这份规则。

---

## 11. 怎么查文档

| 想查什么 | 去哪查 |
|:--|:--|
| 某个接口的参数、起始版本 | DevEco 里 `Ctrl+Q`，或 `Ctrl` 加点击跳到 `.d.ts` 看注释和 `@since` |
| 在本地 SDK 里全文搜 | `openharmony/ets/api`（开源 API）、`openharmony/ets/component`（ArkUI 组件，通用属性在 `common.d.ts`）、`hms/ets/api`（华为独有，如 `@hms.nearlink.*`、`@hms.core.appgalleryservice.*`）、`hms/ets/kits/@kit.UIDesignKit.d.ts` |
| 开发指南、示例、限制 | 华为开发者官网，下面是本项目查过的页面 |

**官网页面**

- [配置应用启动页](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/launch-page-config)
- [启动页资源配置（深色模式）](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/launch-page-resource-config)
- [UI Design Kit · 沉浸光感](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/ui-design-hds-component-material)
- [@ohos.arkui.uiMaterial（系统材质）](https://developer.huawei.com/consumer/en/doc/harmonyos-references/arkts-apis-uimaterial)
- [开启沉浸光感（生效范围）](https://developer.huawei.com/consumer/es/doc/harmonyos-guides/arkts-immersive-light-sense-enable)
- [沉浸式系统材质视效](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/arkts-immersive-light-sense-common-capability)
- [沉浸光感功耗优化](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/arkts-immersive-light-sense-constraints)
