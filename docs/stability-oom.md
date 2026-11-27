# 稳定性：1.2.1 上架测试 OOM（JS Crash + 内存泄漏）

> 2026-11-26 华为上架稳定性测试，Pura 80 Pro+ / Pura 80 Ultra，HarmonyOS 6.1.1.120，包 1.2.1（1000201）。**送测包不是 `refactor/write-engine` 构建的**：测试在 11-26 14:12~15:05 运行，本分支 18:30 才从 main 拉出；崩溃栈 `TonePage.ets:917:5` 与 main@`4a46b638`（11-26 12:48）第 917 行的 `GlassCard`（第 5 列）吻合。本分支与 main 在非写入路径上几乎一致（`DevicePage`、`AudioPlayService`、组件库都没改），所以 main 上的问题本分支大概率同样存在，需对照验证（6.4）。
> 结论先行：**两条「内存泄漏」和一条「JS Crash」是同一件事**——JS 堆持续增长，打满后在回前台时 OOM。主泄漏点尚未定位，本文记录已知证据、已修的确定问题和打点用法。

---

## 1. 现场

| 项 | 值 | 解读 |
|:--|:--|:--|
| 崩溃 | `OutOfMemoryError ... Heap::AllocateHugeObject, local heap oom` | 不是业务异常，是堆满 |
| 栈 | `stateMgmt.js propagateToChildren / setActiveInternal` ← `TonePage.ets:917` ← `PagePattern::OnShow` | 回前台时框架给组件树下发激活状态，最后一次分配失败；**不是根因** |
| JS 堆 | used 386MB / committed 394MB | 到上限 |
| Full GC 后存活率 | 97% | 回收不掉 = 真泄漏 |
| GC | CompressGC 54 次，平均 463ms，最长 1.4s | 崩之前早已严重卡顿 |
| 对象 | Function 48.8 万、Set 44.9 万、WeakRef 40.1 万、LexicalEnv 24.8 万、Map 9.4 万、Proxy 2.36 万 | **组件 / 状态变量**在累积（V1 状态管理的依赖集合、弱引用、代理），不是音频数据 |
| ArrayBuffer 原生 | 12KB | PCM 不在泄漏里 |
| RSS | 4.9GB（JS 堆只占约 0.4GB） | 另有大量原生 / 图形内存，对应 PSS_MEMORY 那条 |
| 场景 | 进程存活 3197 秒，每 5~10 秒进出前台（反复打开系统蓝牙设置再返回），设备页、音效页来回切 | |

---

## 2. 已修（确定的问题）

| # | 位置 | 问题 | 修正 |
|:--|:--|:--|:--|
| 1 | `TonePage.scheduleBuiltinPreload` | 隐私放行监听触发后只把字段置空、不调 `EventBus.off`；`aboutToDisappear` 见字段为空就跳过注销 → EventBus 永久持有闭包 → 持有整个 TonePage 子树（含 Canvas） | 触发即 `releasePrivacyHandler()` 真正注销；卸载时走同一个方法 |
| 2 | `AudioPlayService.playFile` | `await createAVPlayer()` 后不核对代号，连点时新一轮覆盖 `player / playerFile`，旧 AVPlayer 与文件句柄无人释放；`createAVPlayer` 抛错时已打开的文件也不关 | 每轮自增代号；被取代的一轮 `disposePlayer` 自行释放；未托管前出错一并释放；状态回调核对代号；`stop()` 释放前先 `off` 回调 |
| 3 | `AudioPlayService.ensureRenderer` | 两次试听交错时各建一个 AudioRenderer，后者覆盖前者，前一个永不 release | 加 `rendererPending`，并发调用共用同一个创建中的 Promise |
| 4 | `BluetoothService.onDeviceFound` | 原地改共享快照、每发现一台就通知一次；设备多的环境 15 秒内设备页整页重算上百次；列表无上限 | 改快照前 `cloneSnapshot`；400ms 合批通知；上限 50 台 |
| 5 | `BluetoothService.startScan` | 超时定时器不保存，停了再开时旧定时器会把新一轮提前停掉 | 保存 `scanTimer`，开始 / 停止时清理 |
| 6 | `Index` 页签预加载 | `preloadItems()` 返回 Promise（本地 SDK `tabs.d.ts`，`HdsTabsController extends TabsController`），`try/catch` 接不住异步失败 | 挂 `.catch` |

1、2、3 是泄漏；4 是 GC 压力；5、6 是顺手修的正确性问题。**它们都不足以单独解释几十万个状态对象**，主泄漏见第 4 节。

---

## 3. 打点（`common/utils/MemProbe.ets`）

release 包同样记录，不含用户数据。接口全部按本地 SDK `@ohos.hidebug.d.ts` / `@ohos.hiviewdfx.jsLeakWatcher.d.ts` 核对，最低 API 都 ≤ 工程 `compatibleSdkVersion` 23：

| 接口 | since | 用途 |
|:--|--:|:--|
| `hidebug.getAppVMMemoryInfo()` | 12 | JS 堆 used / total（KB） |
| `hidebug.getAppMemoryLimit().vmHeapLimit` | 12 | JS 堆上限（KB） |
| `hidebug.getAppNativeMemInfoAsync()` | 20 | RSS / PSS（读 smaps_rollup，SDK 要求不在主线程同步读） |
| `hidebug.getGraphicsMemory()` | 14 | 显存（KB） |
| `jsLeakWatcher.enable / watch / check` | 12 | debug 包确认「卸载后没被回收」 |

`hidebug.getRssInfo()` 是 API 24，工程兼容 23，不用。

### 日志关键字

| 关键字 | 含义 | 怎么看 |
|:--|:--|:--|
| `MEM_SAMPLE reason=create/fg/bg heap=used/totalMB limit= rss= pss= gfx= live=... created=...` | 进程内存 + 各组件存活 / 累计创建数 | 节流：30 秒一条，或堆涨 16MB 立即一条；堆超上限 60% 改 warn、5 秒一条 |
| `MEM_MOUNT / MEM_UNMOUNT 名字 live= created=` | 页面级组件挂载 / 卸载 | `created` 远大于 1 = 页面在被反复销毁重建 |
| `MEM_DUP 名字 live= max=` | 同时存活数超过预期 | 页面 max=1；`WaveformView` max=1；`DeviceRow` 200、`GlassCard` 120（只计数不逐条记） |
| `MEM_LEAK [...]`（仅 debug 包） | 已卸载、GC 后仍未回收的组件实例 | 切后台时检查，60 秒节流；完整列表看 hilog |

已接入：`Index`、`DevicePage`、`TonePage`、`LibraryPage`、`ProfilePage`、`LogPage`、`FeedbackPage`、`BackupPage`、`WaveformView`、`DeviceRow`、`GlassCard`；`EntryAbility` 在 onCreate（基线）/ onForeground / onBackground 采样。

---

## 4. 主泄漏：待定位

### 头号怀疑：页签切换是否在销毁重建子页

- 本地 SDK `tabs.d.ts`：系统 `Tabs` 不设 `cachedMaxCount` 时**默认缓存全部子页、不释放**。
- 但 `TonePage` 注释写「切 tab 会走 aboutToDisappear→aboutToAppear」，`DevicePage` 注释写「TabContent 不会销毁子页」——两处矛盾；`HdsTabs` 闭源，SDK 里看不到实现。
- 若会重建，再叠加任何一个外部引用（第 2 节 #1 就是一例），每次重建漏一整棵页面树。`WaveformView` 的 Canvas 约 1276×286px×4B ≈ 1.4MB，漏几千个即可对上 4.9GB RSS（估算，未验证）。

打点后看 `MEM_SAMPLE` 里 `created=TonePage:N`：切页签 N 次后 N 随之增长即坐实重建；`live` 同时增长即坐实泄漏。

### 其他待查

- 回前台的 `OnShow → setActiveInternal` 会遍历整棵树：树越大越慢、分配越多，与「越用越卡」吻合。
- `TonePage` 的 `@State source` 带整段 PCM（最长 5 分钟），V1 会给它套代理；建议 PCM 移到普通字段。
- `DevicePage` 的 ForEach 键含连接状态，状态一变整行销毁重建。

---

## 5. 验证清单

1. **构建**：`hvigorw assembleHap` debug / release 各一次（本次改动未在本机编译）。
2. **debug 包自测**（hdc + `hilog | grep MemProbe`）：
   - 设备页 → 打开系统蓝牙设置 → 返回，重复 50 次；
   - 四个页签来回切 50 次；
   - 扫描附近设备 2 次；
   - 音效页连点「原声」「盒音」各 20 次。
   - 期望：`live` 各页面恒为 1，没有 `MEM_DUP`、`MEM_LEAK`；`heap` 稳定在一个平台上（不单调上涨）。
3. **拿 OOM 快照**：测试平台「日志文件」页签下载 heapsnapshot（日志里有 `DumpHeapSnapshotBeforeOOM`），DevEco Profiler 按构造器看 `TonePage / GlassCard / SliderBlock / DeviceRow / WaveformView` 实例数与引用链。
4. **sourcemap**：本次栈 `Cannot get SourceMap info`。上架包对应的 `sourceMaps.map` 需要留档（或上传 AGC 崩溃服务），否则以后的栈对不上行号。

---

## 6. 复现记录

### 6.1 第 1 轮（11-27 00:35，debug 包，约 1.5 分钟）

编译、启动、打点都正常。日志只覆盖了「首次启动 → 同意隐私 → 进出日志 / 反馈 / 备份浮层」，**没走到测试现场的场景**：

| 看到的 | 结论 |
|:--|:--|
| `heap 2.2 → 10.4MB`、`rss 57 → 163MB`（启动后 30 秒） | 冷启动正常水位，作为基线 |
| 4 个页签页各 `created=1` | 启动时全部构建一次；这一轮没切页签，**重建问题还没验证** |
| 浮层页 `LogPage created=7`、每次都 `live` 回 0 | 浮层是 `if` 条件渲染，按设计每次销毁重建，计数成对，正常 |
| 没有 `DeviceRow` 计数 | 新装包没授蓝牙权限，设备页是空的；测试现场设备页是满的，复现必须先授权 |
| 没有任何 `MEM_LEAK` | 唯一一次切后台（00:35:30）早于所有卸载，检查白做了还占掉 60 秒节流——**已修**：没有新卸载就不查，查过没泄漏记 `MEM_LEAK_NONE` |

### 6.2 复现工具

| 工具 | 做什么 | 回答什么 |
|:--|:--|:--|
| 调试菜单「内存压测：自动切页签 200 次」 | `tabsController.changeIndex` 0→1→2→3 循环，每 20 步强制采样，结束查泄漏 | HdsTabs 切页签是否销毁重建子页（看 `created=TonePage:N`） |
| 调试菜单「内存压测：切换内置音效 100 次」 | 在音效页循环点内置音效，每 10 次试听一下原声再打断 | 截图里「音效页反复点音效」那段是否涨内存 |
| 调试菜单「内存：立即采样并检查泄漏」 | 不受节流 | 任意时刻打一个点 |
| `tools/mem-repro.sh [轮数] [前台秒] [后台秒]` | hdc 驱动 Home → `aa start` 循环，hilog 里的 MemProbe 行存到 `dist/mem-repro-*.log` | 崩溃路径本身：反复回前台 `OnShow` 是否单调涨堆 |

调试菜单：「我的」页连点版本号 3 次（仅 debug 包）。

### 6.3 第 2 轮步骤

1. 授予蓝牙权限，确认设备页能看到已配对耳机。
2. 调试菜单 →「立即采样」，记下基线。
3. 调试菜单 →「切页签 200 次」，等 `STRESS_TABS end` 后约 1 秒的 `MEM_SAMPLE reason=stress-tabs-end`。
4. 切到音效页 → 调试菜单 →「切换内置音效 100 次」（菜单在「我的」页，点完切到音效页也行，压测在音效页实例里跑）。
5. 停在设备页，跑 `./tools/mem-repro.sh 100`（约 10 分钟）。
6. 导出日志中心日志 + `dist/mem-repro-*.log`。

判读：任何页面 `live` > 1 或出现 `MEM_LEAK` → 直接定位到组件；`created` 涨而 `live` 不涨 → 在重建但能回收，看堆是否回落；`heap` 每轮单调上涨且 Full GC 不回落 → 泄漏还在，用 Profiler 抓两次快照对比。

### 6.4 第 2 轮（11-27 08:52~09:09，本分支 debug 包，已含第 2 节修复）

**三种场景都没有复现出持续增长。**

| 场景 | JS 堆 | RSS | 组件计数 | 判读 |
|:--|:--|:--|:--|:--|
| 切页签 200 次（70 秒） | 10.7 → 16.5MB，线性涨 | 139 → 147MB | 各页面 `created=1` 始终不变 | **HdsTabs 切页签不会重建子页**（第 4 节头号怀疑排除）；涨的是短命对象，08:58 已回落到 10.8MB |
| 切换内置音效 100 次 | 16.5 → 24.5 → 15.5 → 17.2MB，锯齿 | 148 → 179MB | `WaveformView live=1` | GC 能回收；RSS +31MB 是试听缓冲 / 渲染器，之后稳定 |
| 前后台 100 轮（`mem-repro.sh`，11 分钟） | 10.0~11.1MB 来回 | 155.5 → 159.6MB | 全程不变 | 无泄漏 |

唯一异常：08:55:02 `MEM_LEAK DeviceRow ×1`（连接状态变化导致一行按新 key 重建，旧行 GC 后仍在）。之后没再有卸载，旧逻辑下手动检查直接跳过，无法确认它后来是否回收——**已改**：手动 / 压测结束的检查总是执行。单个实例，量级解释不了 OOM。

**对比测试现场**：现场 53 分钟涨到 386MB，平均约 120KB/s，且 Full GC 后存活 97%；本轮最快的增长（切页签约 80KB/s）是可回收的。说明**触发条件还没覆盖到**。现场与本轮的差别：

| | 测试现场 | 本轮 |
|:--|:--|:--|
| 包 | main@4a46b638（推断） | 本分支 + 第 2 节修复 |
| 已配对设备 | 0 台（截图「还没有配对设备」） | 2 台 |
| 安装状态 | 新装 → 隐私弹窗 → 同意 | 同 |
| 时长 | 53 分钟 | 约 17 分钟 |
| 操作 | monkey 随机点击（截图里有导入、扫描入口、系统蓝牙设置） | 固定脚本，没点导入、没扫描 |

### 6.5 下一步

1. **对照**：main@4a46b638 用 debug 签名构建（`git checkout 4a46b638 && ./tools/dev.sh build release debug`），装机后同样跑 `mem-repro.sh 100`（旧包没有 MemProbe，脚本每 10 轮用 hidumper 记一次）。旧包能涨、本分支不涨 → 第 2 节修复已覆盖；旧包也不涨 → 复现手段没碰到触发条件。
2. **拿现场快照**（最直接）：测试平台「日志文件」页签里的 heapsnapshot，看几十万个 Function / Set 挂在谁身上。
3. 补没覆盖的路径：清空已配对设备、扫描（周围设备越多越好）、导入音频（系统文件选择器会让应用进出前台）、跑满 50 分钟以上。

### 6.6 对照（11-27 09:39~09:51，main@4a46b638 旧包，前后台 100 轮）

旧包没有 MemProbe，数据来自脚本每 10 轮一次的 `hidumper --mem`（单位换算成 MB）：

| 轮 | ArkTS 堆 PSS | 原生堆 PSS | 原生堆已分配 | 进程总 PSS |
|--:|--:|--:|--:|--:|
| 10 | 9.0 | 43.1 | 72.9 | 69.5 |
| 50 | 9.2 | 43.2 | 73.0 | 70.5 |
| 100 | 8.8 | 43.2 | 73.0 | 69.8 |

12 分钟同一个进程（pid 48633），ArkTS 堆在 8.5~9.5MB 之间波动，总 PSS 69~70.5MB，**完全平稳**。

结论：

- **单纯前后台切换在旧包上也不泄漏。**崩溃栈落在回前台的 `OnShow`，只说明最后一次分配发生在那里，不说明前后台切换就是泄漏源。
- 本分支（6.4）和 main 表现一致，所以**第 2 节的修复还不能算验证有效**：两边都没触发，比不出差别。
- 触发条件在 6.4 表里列的差异中：没有已配对设备、扫描（周围设备多）、导入音频、monkey 随机点击、时长 53 分钟。

`mem-repro.sh` 的 hidumper 输出已改成 `pss= ark= native= nativeAlloc=` 几个数字（原来是整段表格拼接，日志里一行看不全）。

---

## 7. 根因（11-27，现场 hilog 定位）

测试平台「日志文件」下载的是整机 hilog（`dist/hilog-20261126-141232`，885MB、650 万行），不是堆快照。
筛出本应用 13 万行（`dist/hilog-20261126-141232-boxtone.txt`），崩溃进程 pid 32537 占 8.2 万行。

### 7.1 证据链

| # | 现象 | 数据 |
|:--|:--|:--|
| 1 | JS 堆从开测起线性上涨，GC 后残留一路走高 | GC 后：14:16 16MB → 14:30 105MB → 14:50 244MB → 15:05 369MB，约 7MB/分钟 |
| 2 | 一张图被反复加载 | `ImageLoadSuccess resource:///16777240.svg` **12280 次**；16777240 = 0x01000018 = `ic_tab_device` |
| 3 | 成批出现，每批是一整列设备行 | 221 批、每批 37~85 张、几毫秒内建完；相邻两张 nodeId 恒差 12 = 一个 `DeviceRow` 子树的节点数 |
| 4 | 每批都紧跟一次回前台 | 221 批里 210 批在 `onForeground` 后 1.5 秒内 |
| 5 | 回前台之前，人在系统蓝牙设置页 | `OnScanModeChanged mode:4 → mode:1` 共 212 对，即每轮都进出一次系统蓝牙页 |
| 6 | 应用自己只扫描过 2 次 | `开始扫描附近设备` 仅 14:13:56、14:15:34；之后 50 分钟应用没有发起过扫描 |
| 7 | 已配对设备始终为 0 | `GetPairedDevices` 全部 `vector size: 0`；已配对列表是空的，设备行只可能来自「附近设备」 |
| 8 | 对象数量与行数吻合 | OOM 时 WeakRef 40.1 万 / Set 44.9 万 / Function 48.8 万，除以 12280 行 ≈ 每行 33 / 37 / 40 个，量级一致 |
| 9 | 崩溃点 | `setActiveInternal → propagateToChildren` 回前台时遍历全部子组件，`NewTaggedArray` 申请 1.5MB（约 19.6 万项）失败 |

### 7.2 结论

**不是传统意义的泄漏，是「附近设备」列表无上限增长**，这些行一直挂在设备页上、是活对象，所以 GC 回收不掉（存活率 97%）。

1. 设备页订阅了 `connection.on('bluetoothDeviceFind')`，回调里**不判断是不是自己发起的扫描**，收到就加进 `nearbyDevices`；
2. 测试反复进「系统设置 → 蓝牙」页，那个页面会自己扫描；扫描结果同样推给了本应用的订阅（推断：时序与 #4 #5 #6 吻合，SDK 文档没写是否跨应用分发）；
3. 本地 SDK `@ohos.bluetooth.connection.d.ts`：没有 `GET_BLUETOOTH_PEERS_MAC` 权限时，回调给的是**虚拟地址**。同一台设备每次扫描可能拿到不同的地址，按 deviceId 去重失效，列表每轮多出几十项；
4. 旧代码 `nearbyDevices` 没有上限，只在应用自己 `startScan` 时清空；设备页用 `Scroll + ForEach` 一次性建出所有行；
5. 应用在后台时组件冻结、不刷新，回前台时一次补建这一轮新增的几十行（#3 #4）；50 分钟累计 1.2 万行，JS 堆打满、RSS 4.9GB。

第 2 轮复现与 main 对照都没触发，是因为脚本只按 Home 回桌面，**从没进过系统蓝牙页**。

### 7.3 第 2 节修复覆盖了多少

| 修复 | 作用 |
|:--|:--|
| `NEARBY_MAX = 50` | 把增长封顶在 50 行，**单独就足以避免 OOM** |
| 合批通知 / 快照拷贝 | 减少重建与临时对象 |
| 还缺的 | 不是自己发起的扫描结果直接丢弃——这才是根因 |

### 7.4 待做

1. **验证**（不改代码就能做）：main 旧包跑 `./tools/mem-repro.sh 30 4 8 settings`（切后台改成打开系统蓝牙页），预期堆每轮上涨、RSS 明显增长。
2. **修复**（`refactor/write-engine`）：`onDeviceFound` 只在本应用扫描期间（`snapshot.scanning`）接收结果，其余计数后丢弃（日志 `DEVICE_FOUND_IGNORED`）；保留上限 50；设备页附近设备改用 `List + LazyForEach`。
3. 本分支 `4f09a2e3` 漏提交了 `MemProbe.ets`、`tools/mem-repro.sh`、`docs/stability-oom.md`，单独 checkout 这个提交编译会失败，需补提交。

### 7.5 验证与修复（11-27 10:04~10:10）

**main 旧包 `mem-repro.sh 30 4 8 settings`：没涨。** 30 轮 ArkTS 堆 11.6 → 7.8 → 8.3MB、总 PSS 74.5 → 70.3MB。
这轮的日志只有 hidumper 数字，看不出系统蓝牙页到底有没有打开、扫描结果有没有推过来，所以既不能证实也不能推翻 7.2。可能的原因：

1. `aa start -U bluetooth_entry` 没进到蓝牙页（命令写法在本地 SDK 里没查到文档）；
2. 周围设备少、或这台手机上虚拟地址每次都一样，按地址去重兜住了，列表只涨到周围设备数就停；
3. 旧包当时停的不是设备页、或没授蓝牙权限（没权限不会订阅发现事件）。

现场每次回前台新增 37~85 行，远多于截图里系统蓝牙页显示的 8 台左右设备，**虚拟地址每次扫描都换**的推断（7.2 第 3 条）比较站得住，但仍然没有验证。

**本分支修复**（`BluetoothService.onDeviceFound`）：

| 项 | 做法 |
|:--|:--|
| 根因 | 只在 `snapshot.scanning`（本应用 startScan → stopScan 之间）时收；其余丢弃，`DEVICE_FOUND_IGNORED total= distinct=` 第一条立即记，之后 30 秒汇总一条 |
| 兜底 | 保留 `NEARBY_MAX = 50` |
| 诊断 | 每次扫描结束 `SCAN_SUMMARY found= distinct= kept=`；distinct 明显多于周围实际设备数 = 虚拟地址每次在换 |
| 不做 | 附近设备改 `List + LazyForEach`：上限 50 行，一次性构建的代价可以接受，不值得为此引入 IDataSource |

`mem-repro.sh` 额外抓 `DEVICE_FOUND_IGNORED / SCAN_SUMMARY` 和本应用进程里的 `OnScanModeChanged`（mode: 4 = 系统蓝牙页把手机设成了可被发现，用来确认确实进了蓝牙页）。

**判读**（本分支 `mem-repro.sh 30 4 8 settings`）：

| 结果 | 含义 |
|:--|:--|
| 有 `mode: 4`，也有 `DEVICE_FOUND_IGNORED`、total 每轮涨 | 7.2 成立，修复正好挡住根因 |
| 有 `mode: 4`，没有 `DEVICE_FOUND_IGNORED` | 系统页的扫描不会推给本应用，7.2 第 2 条不成立，需要另找新增行的来源 |
| 没有 `mode: 4` | 脚本没进到蓝牙页，先手动进一次确认 |

### 7.6 本分支验证（11-27 10:16~10:23，`mem-repro.sh 30 4 8 settings`）

| 项 | 结果 |
|:--|:--|
| 进到系统蓝牙页 | 是：本进程 `OnScanModeChanged mode: 4` 共 90 条（人工也确认停在蓝牙页） |
| 系统页的扫描结果推给本应用 | **是**：本应用全程没扫描，仍收到 `DEVICE_FOUND_IGNORED total=45 distinct=2`（6 分钟，第一条 10:21:19）→ **7.2 第 2 条证实** |
| 内存 | JS 堆 9.9~11.5MB、PSS 76~81MB，各组件 `live` 全程不变，`DeviceRow:2`（只有已配对的两行） |

**为什么 6.6 / 7.5 的旧包没涨**：家里只有 2 台设备，而且这台手机上同一台设备每次拿到的虚拟地址相同（distinct=2），
旧代码按地址去重就兜住了，列表最多涨到 2 行。测试机房周围设备多（截图里系统蓝牙页同名设备成排出现），每次回前台新增 37~85 行、
50 分钟 1.2 万行，说明那里每次扫描都是新地址（7.2 第 3 条）。**这个条件在家里复现不了**，旧包涨不涨取决于环境，新包不受环境影响。

结论：根因链中「系统页扫描推给本应用」已证实，「地址每次都换」由现场数据推出；修复在入口处丢弃非本应用扫描的结果，外加 50 行上限，两个条件任意一个不成立都不会再无限增长。

其他：

- `MEM_LEAK GlassCard ×2`（10:17:03，脚本启动前的那次切后台）：上一轮是 `DeviceRow ×1`，都是设备页里被 `if` 移除的一次性节点（权限卡、空态切换），数量不随轮数增长，不是这次问题；留作后续排查（手动「立即采样并检查泄漏」看是否最终回收）。
- `mem-repro.sh`：hilog 那路改为 `>>` 追加写，修复 HIDUMPER 行被覆盖。
