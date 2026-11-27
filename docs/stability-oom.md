# 稳定性：1.2.1 上架测试 OOM（JS Crash + 内存泄漏）

> **状态（11-27）**：根因已定位并修复（`refactor/write-engine`），本地真机与模拟验证通过；待 1.2.2 重新送测确认。
> 第 1~7 节是结论；排查过程按时间顺序保留在附录 A1~A10，其中有几处结论后来被推翻，见第 6 节。

---

## 1. 现象

- 11-26 14:12~15:05 华为上架稳定性测试，Pura 80 Pro+ / Pura 80 Ultra，HarmonyOS 6.1.1.120，包 1.2.1（1000201）。
- 送测包构建自 **main@4a46b638**（11-26 12:48），不是本分支：本分支 18:30 才拉出；崩溃栈 `TonePage.ets:917:5` 与该提交第 917 行吻合。
- 两条「内存泄漏」（JS_LEAK、PSS_MEMORY）和一条「JS Crash」是同一件事：JS 堆 53 分钟线性涨到 386MB（上限），
  回前台 `OnShow → setActiveInternal → propagateToChildren` 遍历组件树时 `OutOfMemoryError`；进程 RSS 4.9GB。

## 2. 根因

**「附近设备」列表无上限增长，不是传统意义的泄漏**——那些行一直挂在设备页上，是活对象（Full GC 后存活 97%）。

1. 设备页订阅 `connection.on('bluetoothDeviceFind')`，回调不区分扫描来源，收到就加进 `nearbyDevices`；
2. 测试反复进出「系统设置 → 蓝牙」，**系统页的扫描结果同样推给本应用**（A7.6 真机证实：本应用没扫描，30 轮收到 45 条）；
3. 没有 `GET_BLUETOOTH_PEERS_MAC` 时回调给虚拟地址（本地 SDK `@ohos.bluetooth.connection.d.ts`）；机房里每次扫描地址都换，按地址去重失效
   （由现场数据推出：每次回前台新增 37~85 行，远多于周围实际设备；家里 distinct=2，复现不了）；
4. 列表没有上限，设备页用 `Scroll + ForEach` 一次建出全部行；后台冻结、回前台补建；
5. 50 分钟累计约 1.2 万行设备行。

量化吻合（A9.1、A9.2）：

| | 本地模拟（1200 行） | 现场（12280 行） |
|:--|--:|--:|
| 每行 JS 堆 | 33KB | 30KB |
| 每行 RSS | 408~430KB | 399KB |
| 清空后 | 全部回收，JS 堆回到 10MB | — |

## 3. 修复

| 位置 | 改动 | 针对 |
|:--|:--|:--|
| `BluetoothService.onDeviceFound` | 只收本应用 `startScan → stopScan` 期间的结果，其余计数后丢弃 | **根因** |
| 同上 | `NEARBY_MAX = 50`；400ms 合批通知；改快照前 `cloneSnapshot`；扫描超时定时器保存并清理 | 兜底；减少重建 |
| `DevicePage` | 拿到真实蓝牙状态前不画权限卡 | 冷启动闪一下 |
| `TonePage` | 隐私放行监听触发后真正 `EventBus.off` | 页面被 EventBus 永久持有 |
| `AudioPlayService` | `playFile` 核对播放代号，被取代 / 失败时释放 AVPlayer 与文件句柄；`ensureRenderer` 并发共用一个创建中的 Promise | 原生资源泄漏 |
| `Index` | `tabsController.preloadItems()` 挂 `.catch` | 未处理的 rejection |

后四项是排查中发现的真实问题，但**不是这次 OOM 的原因**（A6.6：旧包前后台 100 轮不涨）。

## 4. 验证

| 项 | 结果 | 出处 |
|:--|:--|:--|
| 真机反复进出系统蓝牙页 30 轮 | 45 条非本应用扫描结果全部丢弃，JS 堆 10~11MB 平稳 | A7.6 |
| 模拟①：非本应用扫描 500 台（随机地址） | 全部丢弃，设备行不变 | A9.1 |
| 模拟②：本应用扫描中涌入 500 台 | 停在 50 行 | A9.1 |
| 旧逻辑对照 1200 行 | 每行占用与现场吻合；清空后全部回收 | A9.1、A9.2 |
| 前后台 100 轮 / 切页签 200 次 / 切内置音效 100 次 | 无持续增长；切页签不会重建子页 | A6.4 |
| 零星「未回收」（GlassCard、DeviceRow） | 32 个全部回收，只是晚（1~3 分钟） | A8.4 |
| **未做** | release 包验证；重新送测 | — |

## 5. 留在代码里的诊断与工具

| 名称 | 生效 | 说明 |
|:--|:--|:--|
| `MemProbe` 页面级计数 | 都有 | `Index`、四个页签页、日志 / 反馈 / 备份浮层；同时存活超预期记 `MEM_DUP` |
| `DeviceRow` 哨兵 | 都有 | 同时存活超过 100 行记 `MEM_DUP`（已配对 + 附近上限 50，正常到不了） |
| `MEM_SAMPLE` | debug：前后台切换时 30 秒一条；release：只在 JS 堆比上次涨 16MB、或超过上限一半时 | release 不挤占日志中心（600 条） |
| `MEM_AUDIT / MEM_RETAINED / MEM_LEAK_CONFIRMED` | debug | 卸载实例留 `WeakRef`，GC 后复查；卸载超 5 分钟仍在才报 `MEM_RETAINED`，超 10 分钟报 `MEM_LEAK_CONFIRMED` |
| `DEVICE_FOUND_IGNORED` | debug 30 秒、release 5 分钟一条 | 被丢弃的非本应用扫描结果；`distinct` 为距上一条的不同地址数 |
| `SCAN_SUMMARY` | 都有 | 每次本应用扫描结束：`found / distinct / kept` |
| 调试菜单「模拟机房①②」「立即采样并检查泄漏」 | debug | 回归用。入口：「我的」连点版本号 3 次 |
| `tools/mem-repro.sh [轮数] [前台秒] [后台秒] [home\|settings]` | — | hdc 驱动前后台 / 系统蓝牙页循环；旧包（无 MemProbe）每 10 轮用 hidumper 记内存 |

**已删除**（附录里提到但已不存在）：切页签 / 切内置音效压测（A6.2）、旧逻辑对照组（A9）、设备行拆分实验（A10）、
`GlassCard` / `WaveformView` 的实例计数（A3、A8）。

## 6. 已推翻或修正的结论

附录保留原文，下表为准：

| 附录 | 原结论 | 更正 |
|:--|:--|:--|
| A2 末尾 | 第 2 节几处修复「不足以单独解释」，主泄漏另有其因 | 主泄漏就是附近设备列表（A7）；A2 只有 `NEARBY_MAX` 与之相关，碰巧兜住 |
| A4 | 头号怀疑：HdsTabs 切页签销毁重建子页 | 排除：切 200 次各页 `created` 始终为 1（A6.4） |
| A7.2 第 2 条 | 系统页扫描推给本应用（推断） | 已证实（A7.6） |
| A7.4 | 附近设备改 `List + LazyForEach` | 不做：有 50 行上限，代价可接受（A7.5） |
| A8.2 | 卸载超 60 秒仍在记 `MEM_RETAINED` | 改为 5 分钟：实测正常回收要 1~3 分钟（A8.4） |
| A8.3 | 「关于」半模态每次 3 张 GlassCard | 实际 8 张（A8.4） |
| A10 | 设备行原生内存大，怀疑 SVG 图标 | 图标只占 11%，大头是普通布局本身；不优化（A10.2） |

## 7. 遗留（下个版本）

- 设备页 `ForEach` 键里带连接状态：写入时 A2DP 来回切，一行被重建多次（A8.4 一次写入 6 次）。
- 音效页 `@State source` 带整段 PCM（最长 5 分钟），V1 会套代理；建议移到普通字段。
- 每个设备行约 380KB 原生内存，是 ArkUI 普通布局的开销（A10.2），有上限后最多约 19MB。
- 上架包的 `sourceMaps.map` 要留档：这次崩溃栈 `Cannot get SourceMap info`。

---

# 附录：排查记录

> 按时间顺序保留原文，只把章节号改成 A1~A10；文中「第 N 节」「N.M」都指附录 AN、AN.M。
> 原文开头「本分支与 main 差不多、需对照验证」的说法已由 A6.6 完成；结论以正文第 1~7 节为准。

## A1. 现场

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

## A2. 已修（确定的问题）

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

## A3. 打点（`common/utils/MemProbe.ets`）

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

## A4. 主泄漏：待定位

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

## A5. 验证清单

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

## A6. 复现记录

### A6.1 第 1 轮（11-27 00:35，debug 包，约 1.5 分钟）

编译、启动、打点都正常。日志只覆盖了「首次启动 → 同意隐私 → 进出日志 / 反馈 / 备份浮层」，**没走到测试现场的场景**：

| 看到的 | 结论 |
|:--|:--|
| `heap 2.2 → 10.4MB`、`rss 57 → 163MB`（启动后 30 秒） | 冷启动正常水位，作为基线 |
| 4 个页签页各 `created=1` | 启动时全部构建一次；这一轮没切页签，**重建问题还没验证** |
| 浮层页 `LogPage created=7`、每次都 `live` 回 0 | 浮层是 `if` 条件渲染，按设计每次销毁重建，计数成对，正常 |
| 没有 `DeviceRow` 计数 | 新装包没授蓝牙权限，设备页是空的；测试现场设备页是满的，复现必须先授权 |
| 没有任何 `MEM_LEAK` | 唯一一次切后台（00:35:30）早于所有卸载，检查白做了还占掉 60 秒节流——**已修**：没有新卸载就不查，查过没泄漏记 `MEM_LEAK_NONE` |

### A6.2 复现工具

| 工具 | 做什么 | 回答什么 |
|:--|:--|:--|
| 调试菜单「内存压测：自动切页签 200 次」 | `tabsController.changeIndex` 0→1→2→3 循环，每 20 步强制采样，结束查泄漏 | HdsTabs 切页签是否销毁重建子页（看 `created=TonePage:N`） |
| 调试菜单「内存压测：切换内置音效 100 次」 | 在音效页循环点内置音效，每 10 次试听一下原声再打断 | 截图里「音效页反复点音效」那段是否涨内存 |
| 调试菜单「内存：立即采样并检查泄漏」 | 不受节流 | 任意时刻打一个点 |
| `tools/mem-repro.sh [轮数] [前台秒] [后台秒]` | hdc 驱动 Home → `aa start` 循环，hilog 里的 MemProbe 行存到 `dist/mem-repro-*.log` | 崩溃路径本身：反复回前台 `OnShow` 是否单调涨堆 |

调试菜单：「我的」页连点版本号 3 次（仅 debug 包）。

### A6.3 第 2 轮步骤

1. 授予蓝牙权限，确认设备页能看到已配对耳机。
2. 调试菜单 →「立即采样」，记下基线。
3. 调试菜单 →「切页签 200 次」，等 `STRESS_TABS end` 后约 1 秒的 `MEM_SAMPLE reason=stress-tabs-end`。
4. 切到音效页 → 调试菜单 →「切换内置音效 100 次」（菜单在「我的」页，点完切到音效页也行，压测在音效页实例里跑）。
5. 停在设备页，跑 `./tools/mem-repro.sh 100`（约 10 分钟）。
6. 导出日志中心日志 + `dist/mem-repro-*.log`。

判读：任何页面 `live` > 1 或出现 `MEM_LEAK` → 直接定位到组件；`created` 涨而 `live` 不涨 → 在重建但能回收，看堆是否回落；`heap` 每轮单调上涨且 Full GC 不回落 → 泄漏还在，用 Profiler 抓两次快照对比。

### A6.4 第 2 轮（11-27 08:52~09:09，本分支 debug 包，已含第 2 节修复）

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

### A6.5 下一步

1. **对照**：main@4a46b638 用 debug 签名构建（`git checkout 4a46b638 && ./tools/dev.sh build release debug`），装机后同样跑 `mem-repro.sh 100`（旧包没有 MemProbe，脚本每 10 轮用 hidumper 记一次）。旧包能涨、本分支不涨 → 第 2 节修复已覆盖；旧包也不涨 → 复现手段没碰到触发条件。
2. **拿现场快照**（最直接）：测试平台「日志文件」页签里的 heapsnapshot，看几十万个 Function / Set 挂在谁身上。
3. 补没覆盖的路径：清空已配对设备、扫描（周围设备越多越好）、导入音频（系统文件选择器会让应用进出前台）、跑满 50 分钟以上。

### A6.6 对照（11-27 09:39~09:51，main@4a46b638 旧包，前后台 100 轮）

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

## A7. 根因（11-27，现场 hilog 定位）

测试平台「日志文件」下载的是整机 hilog（`dist/hilog-20261126-141232`，885MB、650 万行），不是堆快照。
筛出本应用 13 万行（`dist/hilog-20261126-141232-boxtone.txt`），崩溃进程 pid 32537 占 8.2 万行。

### A7.1 证据链

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

### A7.2 结论

**不是传统意义的泄漏，是「附近设备」列表无上限增长**，这些行一直挂在设备页上、是活对象，所以 GC 回收不掉（存活率 97%）。

1. 设备页订阅了 `connection.on('bluetoothDeviceFind')`，回调里**不判断是不是自己发起的扫描**，收到就加进 `nearbyDevices`；
2. 测试反复进「系统设置 → 蓝牙」页，那个页面会自己扫描；扫描结果同样推给了本应用的订阅（推断：时序与 #4 #5 #6 吻合，SDK 文档没写是否跨应用分发）；
3. 本地 SDK `@ohos.bluetooth.connection.d.ts`：没有 `GET_BLUETOOTH_PEERS_MAC` 权限时，回调给的是**虚拟地址**。同一台设备每次扫描可能拿到不同的地址，按 deviceId 去重失效，列表每轮多出几十项；
4. 旧代码 `nearbyDevices` 没有上限，只在应用自己 `startScan` 时清空；设备页用 `Scroll + ForEach` 一次性建出所有行；
5. 应用在后台时组件冻结、不刷新，回前台时一次补建这一轮新增的几十行（#3 #4）；50 分钟累计 1.2 万行，JS 堆打满、RSS 4.9GB。

第 2 轮复现与 main 对照都没触发，是因为脚本只按 Home 回桌面，**从没进过系统蓝牙页**。

### A7.3 第 2 节修复覆盖了多少

| 修复 | 作用 |
|:--|:--|
| `NEARBY_MAX = 50` | 把增长封顶在 50 行，**单独就足以避免 OOM** |
| 合批通知 / 快照拷贝 | 减少重建与临时对象 |
| 还缺的 | 不是自己发起的扫描结果直接丢弃——这才是根因 |

### A7.4 待做

1. **验证**（不改代码就能做）：main 旧包跑 `./tools/mem-repro.sh 30 4 8 settings`（切后台改成打开系统蓝牙页），预期堆每轮上涨、RSS 明显增长。
2. **修复**（`refactor/write-engine`）：`onDeviceFound` 只在本应用扫描期间（`snapshot.scanning`）接收结果，其余计数后丢弃（日志 `DEVICE_FOUND_IGNORED`）；保留上限 50；设备页附近设备改用 `List + LazyForEach`。
3. 本分支 `4f09a2e3` 漏提交了 `MemProbe.ets`、`tools/mem-repro.sh`、`docs/stability-oom.md`，单独 checkout 这个提交编译会失败，需补提交。

### A7.5 验证与修复（11-27 10:04~10:10）

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

### A7.6 本分支验证（11-27 10:16~10:23，`mem-repro.sh 30 4 8 settings`）

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

---

## A8. 零星未回收实例（GlassCard ×2、DeviceRow ×1）

### A8.1 现有证据不足以判泄漏

| 报告 | 何时卸载 | 何时检查 | 之后 |
|:--|:--|:--|:--|
| `DeviceRow ×1`（08:55:02） | 08:54:44~08:55:02 之间（连接状态变了，ForEach 键里带连接状态，整行按新键重建） | ≤ 18 秒后 | 之后没有新卸载，旧逻辑不再检查 |
| `GlassCard ×2`（10:17:03） | 冷启动时（created 17 / live 15） | 几秒后 | 同上 |
| 对照：`LogPage ×1`（08:53:04） | 关闭日志浮层 | 16 秒后 | 已回收 `MEM_LEAK_NONE` |

三次都只有**卸载后几秒的一次观测**；数量不随轮数增长（第 2、3 轮各 30~100 轮，计数全程不变）。
分不清「框架还没来得及销毁节点」和「真被挂住」。另外 SDK 对 `jsLeakWatcher.check()` 只说「GC 后未回收即标记泄漏」，
没说报过的对象下次是否还会报，所以靠它反复查也不可靠。

GlassCard 的来源：冷启动首帧 `DevicePage` 的初始快照 `authorized=false`，先画出「需要蓝牙权限」卡（`tinted` 的 GlassCard），
`refresh()` 回来再移除——已授权用户**每次冷启动都会看到它闪一下**。另一张推测是音效库空态卡（同样是先空态、数据到了再换）。

### A8.2 改动

| 项 | 做法 |
|:--|:--|
| 判定方式 | `MemProbe` 在 unmount 时给实例留一个 `WeakRef`（只用于诊断，不影响回收）；卸载 20 秒后首次复查，之后每 60 秒，先借 `jsLeakWatcher.check()` 触发 GC 再逐个 `deref()` |
| 日志 | `MEM_AUDIT reclaimed= pending=[…] retained=[…]`；卸载超 5 分钟仍在 → `MEM_RETAINED`（初版 60 秒，8.4 实测误报后放宽）；超 10 分钟 → `MEM_LEAK_CONFIRMED` 并停止跟踪 |
| 实例标签 | `GlassCard#17(tinted)`、`GlassCard#20(pad16)`、`DeviceRow#3(paired,on)`：序号 + 样式 / 类别，不含地址 |
| 根源 | 设备页没拿到真实蓝牙状态前不画权限卡（`loaded`），去掉冷启动闪烁和这次 GlassCard 的建/毁 |

`WeakRef`：ArkTS 编译用的 TS lib 是 es2021（`ets-loader/tsconfig.json`），含 `lib.es2021.weakref.d.ts`；
ArkTS 标准库限制清单（`LIMITED_STD_*`）里没有它。未在本机编译验证。

DeviceRow 按连接状态换键重建这次没动：只在连接 / 断开时发生，一次一两行；改键要依赖 V1 在键不变时对 @Prop 的更新行为，没法在这里验证。

### A8.3 验证步骤（debug 包，约 5 分钟）

1. 冷启动停在设备页 30 秒：不应再出现 `GlassCard(tinted)`。
2. 对照：打开 / 关闭日志浮层两次。
3. GlassCard：「我的 → 关于」半模态打开 / 关闭 3 次（每次 3 张 GlassCard）。
4. DeviceRow：耳机放回盒里再取出（连接状态变化 → 行重建）。
5. 前台停 2 分钟以上，调试菜单「立即采样并检查泄漏」，导出日志。

判读：全部进 `reclaimed`、没有 `MEM_RETAINED` → 只是延迟销毁，不是泄漏；有 `MEM_RETAINED`（尤其 `MEM_LEAK_CONFIRMED`）→ 用 DevEco Profiler 抓堆快照看它的引用链。

### A8.4 结果（11-27 10:37~10:42，debug 包，新装）：不是泄漏，结案

32 个已卸载实例**全部回收**，JS 堆 10.5MB，各组件 `live` 回到基线（GlassCard 15、DeviceRow 2）。

| 实例 | 来源 | 数量 | 回收用时 |
|:--|:--|--:|:--|
| GlassCard(pad16 / pad8) | 「关于」半模态开关 3 次（每次 8 张，不是 8.3 写的 3 张） | 24 | 20 秒 ~ 80 秒 |
| GlassCard(tinted) | 设备页权限卡：10:38:56 用户授予蓝牙权限后移除（新装包，确实没授权，该显示） | 1 | 80 秒内 |
| GlassCard(pad6) | 音效库空态卡：10:39:45 保存第一条音效后换成列表 | 1 | 2~3 分钟 |
| DeviceRow(paired / paired,on) | 写入期间 A2DP 状态变了 6 次，行按新键重建 6 次 | 6 | 1~3 分钟 |

- 10:41:05 那次 `MEM_RETAINED` 报了 5 个（卸载 62~84 秒），10:42:05 复查全部回收：**是回收晚，不是挂住**。推测是这些实例存活过几次新生代 GC、晋升到老生代，要等下一次老生代 GC（推断，SDK 没写 `jsLeakWatcher.check()` 触发哪一种 GC）。
- 之前 `DeviceRow ×1`、`GlassCard ×2` 的报告是同一回事：只在卸载后几秒看了一次。
- 冷启动不再闪权限卡：本轮第一张 tinted 卡是隐私放行、读到真实状态（未授权）之后才出现的。

改动：`RETAINED_AFTER_MS` 60 秒 → 5 分钟；实例标签改为卸载序号 `GlassCard#u3(pad16)`（之前用 created 计数，同一批卸载标签重复，如 8 个 `GlassCard#24`）。

顺带看到（与内存无关）：DeviceRow 在一次写入里重建 6 次，是 ForEach 键里带连接状态、写入时 A2DP 来回切换造成的；只是多建几行，不改。

---

## A9. 本地模拟测试机房（debug 包）

家里复现不了的原因（7.6）：周围只有两三台设备，而且每次扫描拿到的虚拟地址相同，旧逻辑按地址去重就兜住了。
这里用**随机地址**直接喂发现回调，模拟「周围几十台设备 + 每次扫描都换虚拟地址」，在家里也能验证两道防线。地址随机生成，不对应真实设备。

入口：「我的」连点版本号 3 次 → 调试菜单。

| 菜单项 | 做什么 | 期望 |
|:--|:--|:--|
| 模拟机房①：系统页扫描推送 500 台 | 本应用不在扫描时喂 500 个随机地址（等同系统蓝牙页在扫） | `SIM_FOREIGN fed=500 ignored=500 nearby=0`，`DeviceRow live` 不变 |
| 模拟机房②：本应用扫描中涌入 500 台 | `startScan` 后喂 500 个随机地址，2 秒后停扫 | `SIM_OWN nearby=50`；`SCAN_SUMMARY found≥500 distinct≥500 kept=50`；`DeviceRow live` ≈ 已配对数 + 50 |
| 对照：旧逻辑累积 1200 行再清空 | 不分来源、不设上限，每 3 秒加 300 行，每步 GC 后采样；最后清空再采样 | 每步 heap 线性上涨；按 `(heap@1200 − heap@0) / 1200` 算每行占用，与现场约 30KB/行（370MB / 12280 行）对比；清空后 heap 回落、`MEM_AUDIT` 里 DeviceRow 被回收 |

对照组要停在设备页（行真正建出来才占内存，`DeviceRow live` 能看出建了多少）。只构造数据，不调系统蓝牙接口。

配套改动（`MemProbe`）：

- `report()` 先借 `jsLeakWatcher.check()` 触发一次 GC 再采样，前后两次 heap 才可比（之前混着待回收的垃圾）；
- `MEM_DUP` 改为 live 翻倍才再记一条（上千个 DeviceRow 同时挂载时不刷屏）；
- 高频组件的卸载不再逐条记日志（清空 1200 行会刷满 600 条上限的日志中心），回收情况看 `MEM_AUDIT`。

判读：

| 结果 | 含义 |
|:--|:--|
| ① ② 符合期望，对照组每行 20~40KB、清空后回落 | 根因机制与现场数据吻合，两道防线各自有效，可以送测 |
| 对照组每行远小于 30KB | 现场每行还有别的开销（例如图片 / 渲染节点的原生内存），需要再看 RSS 那一列 |
| 对照组清空后 heap 不回落 | 设备行被别处挂住，第 7 节的「活对象」判断要修正 |

### A9.1 结果（11-27 10:49~10:51）

**两道防线**：

| 项 | 日志 | 结论 |
|:--|:--|:--|
| ① 非本应用扫描 500 台 | `SIM_FOREIGN fed=500 ignored=500 nearby=0`；`DeviceRow live=2`（只有已配对） | 全部丢弃 ✓ |
| ② 本应用扫描中涌入 500 台 | `SIM_OWN nearby=50`；`SCAN_SUMMARY found=500 distinct=500 kept=50`；`DeviceRow live=52` | 停在上限 ✓ |

**对照（旧逻辑，每步 300 行）**，每步先 GC 再采样：

| 行数 | JS 堆 | RSS | PSS |
|--:|--:|--:|--:|
| 52（基线） | 9.6MB | 220MB | 124MB |
| 352 | 20.3MB | 347MB | 251MB |
| 652 | 31.0MB | 468MB | 372MB |
| 952 | 40.9MB | 588MB | 492MB |
| 1252 | 49.4MB | 709MB | 613MB |
| 清空 5 秒后 | 52.9MB | 284MB | 184MB |

**和现场对得上（量化证实第 7 节）**：

| | 本地模拟 | 现场（12280 行） |
|:--|--:|--:|
| 每行 JS 堆 | (49.4 − 9.6) / 1200 ≈ **33KB** | 369MB / 12280 ≈ **30KB** |
| 每行 RSS | (709 − 220) / 1200 ≈ **408KB** | 4898MB / 12280 ≈ **399KB** |

JS 堆和 RSS 两个维度、相差十倍的行数，都在 10% 以内吻合：现场的 386MB JS 堆、4.9GB RSS **基本都是这些设备行**。

**清空后**：设备行 `live` 立即回到 2；RSS 5 秒内释放 425MB（增长的 87%）——原生渲染节点随组件销毁立即释放；
JS 堆 5 秒时还没回落（52.9MB，已卸载的行全部「待定」），要等老生代 GC，和 8.4 观察到的 1~3 分钟一致。
最终回收结果这轮没等到（导出在清空后 54 秒），对照组已改为清空后在 1、3、5 分钟各采一次。

**附带发现**：每个设备行约 400KB 原生内存，偏大（一个 18vp 的 SVG 图标位图本身只有十几 KB，推测主要是渲染节点和 SVG 每实例单独解码；
未查证）。有 50 行上限后最多约 20MB，可接受，暂不优化。

**MemProbe 调整**：

- 跟踪改为每种组件最多 40 个样本，其余只计数（之前总量 300 先进先出，1250 行一卸载就把 GlassCard / LogPage 的样本挤掉了）；
- `MEM_AUDIT` 改为按种类一行汇总：`DeviceRow(nearby) 回收12/待定28/滞留0 最久13s 未跟踪1210`；`MEM_RETAINED` 最多列 10 个。

### A9.2 清空后的回收（11-27 10:56~11:02）：全部回收，结案

| 采样 | JS 堆 | RSS | PSS | DeviceRow live |
|:--|--:|--:|--:|--:|
| 起点（2 行） | 7.7MB | 177MB | 88MB | 2 |
| 1202 行 | 46.8MB | 693MB | 603MB | 1202 |
| 清空 5 秒 | **10.3MB** | 244MB | 150MB | 2 |
| +60 秒 | 10.4MB | 205MB | 110MB | 2 |
| +180 秒 | 10.4MB | 205MB | 108MB | 2 |
| +300 秒 | 10.4MB | 204MB | 108MB | 2 |

- 清空后 `MEM_AUDIT`：跟踪的 40 个设备行样本全部回收（其余 1160 个只计数），之后再没有待复查实例；没有 `MEM_RETAINED`。
- 每行占用复测：JS 堆 (46.8 − 7.7) / 1200 ≈ 33KB，RSS ≈ 430KB，与 9.1、现场一致。
- 清空后比起点多约 2.7MB JS 堆、27MB RSS，5 分钟内不再变化：属于分配器/缓存保留的水位，不随次数增长，不是泄漏。
  （起点 7.7MB 是冷启动刚 GC 后的值；之前几轮稳态都在 10~11MB。）
- 9.1 那轮清空 5 秒时 JS 堆还在 52.9MB，这轮 5 秒就回到 10.3MB：老生代 GC 什么时候发生不确定，两轮都说明「可以回收」，回收时机有快有慢。

**结论**：现场 OOM 的内存就是「附近设备」列表里还挂在页面上的设备行，删掉就能回收；不存在别的持有者。第 7 节的根因判断完整成立，第 9 节两道防线验证有效。剩下的工作是送测。

---

## A10. 设备行原生内存偏大（每行约 400KB）

9.1 / 9.2 两轮实测：每个附近设备行约 33KB JS 堆、400~430KB RSS；显存（gfx）全程 3.8MB 不变，所以不是 GPU 纹理。
有 50 行上限后最多约 20MB，不影响稳定性；这里只是弄清楚钱花在哪。

设备行的组成（`components/DeviceRow.ets`）：`Row` → 图标区（`Stack` + `Circle` + `Image(ic_tab_device.svg)` 带 `fillColor`）
→ 文字区（`Column` + `Row` + 2 个 `Text`）→ `PillButton`（`Text` + 圆角 + 描边 + `clickEffect`），外层 `DevicePage` 还有一层 `Column` 和 `Divider`。
图标 SVG 只有 345 字节（一段 path + 两个 rect）。

本地 SDK 能查到的线索都不足以下结论：`image.d.ts` 没写 SVG 是否按实例解码 / 缓存；`UIContext.setImageCacheCount`（23）说明「不设置则不缓存任何解码后的图片」，
但没说是否适用于 SVG；`autoResize` / `sourceSize` 都标注「不适用于 SVG」。现场 hilog 里 12280 行对应 12280 次 `ImageLoadSuccess ... .svg`，
说明每个实例都走了一遍加载。

### A10.1 实验

调试菜单「测量：设备行各部分内存」：依次用 5 种样子各建 500 行，GC 后读数，再清空（`DebugFlags.deviceRowVariant`，只影响新建的行）。

| 变体 | 去掉了什么 |
|:--|:--|
| full | — |
| noImage | 耳机图标（SVG），保留底下的圆 |
| noPill | 右侧按钮 |
| textOnly | 图标区整个 + 按钮，只留文字 |
| full（再跑一次） | 对照：和第一次差得多，说明前几轮清空后分配器保留的内存被复用、压低了 RSS 差值 |

每种一行 `SIM_ROWCOST`，给出每行的 heap / malloc / rss / pss / gfx（KB）。malloc（`getNativeHeapAllocatedSize`，当前在用字节）不受分配器保留页影响，两次 full 不一致时以它为准。

估算方式：图标 ≈ full − noImage，按钮 ≈ full − noPill，其余（行容器 + 文字）≈ textOnly。

`DebugFlags` 与 `DeviceRow` 里的 `showIcon / showImage / showPill` 是临时代码，结论出来后删除。

### A10.2 结果（11-27 11:12，每种 500 行）：分布平均，没有单一大头，不优化

原始数据（每行 KB）：

| # | 变体 | malloc | rss | heap |
|--:|:--|--:|--:|--:|
| 1 | full | **380** | 489 | 34 |
| 2 | noImage | **337** | 321 | −1 |
| 3 | noPill | **305** | 287 | −14 |
| 4 | textOnly | **236** | −81 | 21 |
| 5 | full | **376** | 170 | 9 |

- **以 malloc 为准**：两次 full 是 380 / 376，稳定；RSS 是 489 / 170、还有负数，被分配器保留页的复用搅乱了（10.1 预料的情况）；heap 有负数，说明 GC 时机没对齐，这一列不可用（JS 堆每行约 33KB 以 9.1、9.2 为准）。
- 显存每种都是 0：渲染不占 GPU 纹理。

按 malloc 拆分（每行约 378KB）：

| 部分 | 估算 | 每行 | 占比 |
|:--|:--|--:|--:|
| 图标 SVG | full − noImage | ≈ 41KB | 11% |
| 右侧按钮（PillButton） | full − noPill | ≈ 73KB | 19% |
| 图标底圆 + Stack | full − textOnly − 按钮 − 图标 | ≈ 28KB | 7% |
| 行容器 + 两段文字 + 外层 Column / Divider | textOnly | ≈ 236KB | 62% |

**结论**：没有单一大头。最大的一块是「一行带两段文字的普通布局」本身，这是 ArkUI 组件树的常规开销（推测主要在 Text 的排版对象，未查证）；SVG 图标只占 11%，换 SymbolGlyph 或 PNG 每行最多省约 40KB。
有 50 行上限后，附近设备列表最多约 50 × 380KB ≈ 19MB，不值得为此改界面，**不优化，结案**。

实验代码（`DebugFlags`、DeviceRow 的变体开关、`debugMeasureRowCost`、`MemProbe.figures`、调试菜单入口）已全部删除。
