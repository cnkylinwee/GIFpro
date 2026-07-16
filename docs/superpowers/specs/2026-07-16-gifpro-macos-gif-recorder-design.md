# GIFpro macOS GIF 录制工具设计

日期：2026-07-16  
状态：已通过产品设计确认，待规格评审

## 1. 产品目标

GIFpro 是一款仅适配 Apple Silicon 的轻量级 macOS 菜单栏工具。用户按下全局快捷键后框选屏幕区域，设置分辨率、帧率、时长和鼠标指针选项，然后录制、保存并预览 GIF。

首版使用 Apple 原生框架，不嵌入 FFmpeg、gifski 或其他第三方运行库。Release 构建只包含 `arm64`，最低支持 macOS 14，签名前 `.app` 体积目标低于 10 MB。

### 1.1 成功标准

- 用户能从菜单栏或 `⌥⌘G` 完成框选、录制、保存和预览。
- App 支持 1×/2×、8/12/15 FPS、15/30/60/90 秒，以及是否显示鼠标指针。
- 单次录制最长 90 秒；长时间录制不会形成无界内存队列。
- Finder、Quick Look、Safari 和主流聊天工具能循环播放生成的 GIF。
- App 不联网、不采集遥测，也不保留用户取消的临时文件。

### 1.2 首版不做

- Intel (`x86_64`) 和 macOS 14 以下系统。
- 指定窗口、整屏和跨显示器区域录制。
- 音频、摄像头、按键显示、标注和水印。
- 裁剪、删帧、调速、压缩等录后编辑。
- 任意 FPS、任意录制时长、自定义全局快捷键。
- 第三方 GIF 编码器和云端处理。

## 2. 用户体验

### 2.1 App 形态

GIFpro 使用纯菜单栏形态，不显示 Dock 图标。菜单提供“开始录制”“停止录制”“打开屏幕录制设置”和“退出”。App 通过 Carbon `RegisterEventHotKey` 注册 `⌥⌘G`，避免申请辅助功能权限。

### 2.2 主流程

1. 用户点击“开始录制”或按 `⌥⌘G`。
2. GIFpro 检查屏幕录制权限。首次使用时请求权限；权限被拒绝时解释原因并提供“打开系统设置”。
3. App 在每块显示器上显示暗色透明遮罩。用户在一块显示器内拖出矩形区域；选区不能跨屏。按 `Esc` 退出框选。
4. App 显示可调整的红色选区边框和底部悬浮控制条。控制条包含：
   - 分辨率：1× 或 2×；默认 1×。若显示器的 backing scale 为 1，禁用 2×，避免无意义放大。
   - 帧率：8、12 或 15 FPS；默认 12 FPS。
   - 时长：15、30、60 或 90 秒；默认 30 秒。
   - 鼠标指针：默认开启，可关闭。
   - “录制”和“取消”按钮。
5. 用户点击“录制”后看到 3 秒倒计时。GIFpro 随后隐藏遮罩，保留红色边框、计时器和停止按钮；这些窗口不进入捕捉内容。
6. 用户再次按 `⌥⌘G`、点击停止按钮或从菜单选择“停止录制”，即可提前停止。最后 10 秒计时器变黄；达到所选时长后自动停止。
7. GIFpro 完成临时 GIF，并立即打开系统“另存为”面板。用户取消保存时，App 保留本次临时 GIF，并回到预览操作。
8. 保存成功后，GIFpro 删除临时副本并用 Quick Look 打开成品。

录制时按 `Esc` 不停止或删除录制，避免误操作。用户必须使用快捷键、控制条或菜单停止。

### 2.3 多显示器

框选遮罩覆盖所有显示器，但一次选区必须完全位于一块显示器内。`SelectionOverlay` 记录目标 `NSScreen`、显示器标识和屏幕坐标，并将选区转换为 ScreenCaptureKit 使用的显示器局部坐标。显示器配置变化时，App 取消尚未开始的框选；录制中显示器断开时，App 尽可能完成已有 GIF，并报告录制中断。

## 3. 技术架构

### 3.1 技术选型

| 领域 | 方案 |
| --- | --- |
| UI | SwiftUI + AppKit |
| 菜单栏 | `MenuBarExtra`，应用激活策略为 accessory |
| 悬浮框和遮罩 | 无标题透明 `NSPanel` / `NSWindow` |
| 全局快捷键 | Carbon `RegisterEventHotKey` |
| 屏幕捕捉 | ScreenCaptureKit |
| 帧处理 | Core Image + Core Graphics |
| GIF 编码 | ImageIO `CGImageDestination` |
| 预览 | Quick Look |
| 设置 | `UserDefaults` |
| 并发 | Swift Concurrency + 专用串行采集/编码队列 |

### 3.2 组件边界

`RecordingCoordinator` 是唯一状态源，并在主线程管理 UI 状态。其他组件通过窄接口协作：

- `MenuBarController`：菜单命令和全局快捷键注册。
- `PermissionService`：预检、请求屏幕录制权限，并打开隐私设置页。
- `SelectionOverlayController`：创建各显示器遮罩，管理单屏选区、调整手柄、参数控制条和坐标转换。
- `CaptureEngine`：配置 `SCContentFilter`、`SCStreamConfiguration` 和 `SCStream`，输出带时间戳的像素缓冲区。
- `FrameProcessor`：按 1×/2×目标尺寸生成 sRGB `CGImage`，并通过 autorelease pool 及时释放中间对象。
- `GIFStreamEncoder`：在单一串行执行上下文中设置 GIF 元数据、写入帧、计算帧延迟并最终关闭文件。
- `TemporaryFileStore`：创建、保留、移动和清理临时 GIF。
- `SaveAndPreviewController`：显示 `NSSavePanel`，保存成品并调用 Quick Look。
- `PreferencesStore`：保存上次使用的倍率、FPS、时长和指针设置。

`RecordingCoordinator` 使用以下状态，非法转换直接拒绝：

```text
idle → requestingPermission → selecting → countingDown → recording
recording → finalizing → awaitingSave → previewing → idle
任意可取消状态 → cancelling → idle
任意运行状态 → failed → idle 或 retry
```

## 4. 捕捉与编码数据流

### 4.1 ScreenCaptureKit 配置

`CaptureEngine` 获取目标 `SCDisplay`，并用 `SCContentFilter` 排除 GIFpro 自身应用，从而排除遮罩、边框、控制条和菜单栏窗口。`SCStreamConfiguration` 使用以下设置：

- `sourceRect`：目标显示器内的选区。
- `width` / `height`：选区逻辑尺寸乘以所选倍率；倍率不超过显示器实际 backing scale。
- `minimumFrameInterval`：分别对应 8、12 或 15 FPS。
- `pixelFormat`：`kCVPixelFormatType_32BGRA`。
- `queueDepth`：3，限制 IOSurface 积压。
- `showsCursor`：采用用户设置。
- 音频捕捉关闭。

### 4.2 实时 GIF 写入

编码开始时，`GIFStreamEncoder` 在系统临时目录创建 `CGImageDestination`。目标图像数使用“所选时长 × FPS”的理论上限；提前停止或背压跳帧时，ImageIO 以实际添加的帧完成文件。GIF 设置无限循环。

每个被接受的帧按以下顺序处理：

1. `CaptureEngine` 读取有效的视频 `CMSampleBuffer` 和 presentation timestamp。
2. 背压控制器尝试取得处理槽位。没有槽位时丢弃新帧，不等待、不扩充队列。
3. `FrameProcessor` 将像素缓冲区转换为目标尺寸的 sRGB `CGImage`。
4. 编码器保留一个待写帧。当下一个可用帧到达时，它用两帧时间戳差作为前一帧延迟，再写入前一帧。
5. 停止时，编码器用停止时间与最后一帧时间戳之差写入最后一帧，然后调用 `CGImageDestinationFinalize`。

GIF 使用百分之一秒精度。编码器同时设置 `kCGImagePropertyGIFUnclampedDelayTime` 和 `kCGImagePropertyGIFDelayTime`，并通过累计误差补偿分配四舍五入误差，使各帧延迟总和接近真实录制时长。编码跟不上时，GIF 会降低瞬时帧率，但不会加速播放。

### 4.3 内存和磁盘保护

处理管线最多保留一个待写帧和两个处理中帧。所有 ImageIO 写操作都在同一串行执行上下文中执行；任何组件都不能缓存完整录制帧序列。

录制前，`TemporaryFileStore` 要求临时卷至少有 1 GB 可用空间。录制中每秒检查一次可用空间；可用空间低于 256 MB 时，App 主动停止、完成当前 GIF，并说明原因。App 不设固定 GIF 文件大小上限。

## 5. 状态持久化与隐私

`PreferencesStore` 只保存四项录制参数：倍率、FPS、时长和指针开关。保存面板负责记忆最近目录。App 不保存选区内容、录制历史或文件列表。

临时文件名使用随机 UUID。用户保存成功、明确丢弃或退出 App 时，`TemporaryFileStore` 删除临时文件。App 启动时也删除自身临时目录中的历史残留。清理范围严格限制在 GIFpro 专属临时子目录。

GIFpro 不发起网络请求，不包含分析 SDK，不上传录制内容。

## 6. 错误处理

| 场景 | 行为 |
| --- | --- |
| 未获屏幕录制权限 | 说明权限用途，提供“打开系统设置”和“重新检测” |
| 权限在录制前被撤销 | 返回空闲状态，不创建无效临时文件 |
| 捕捉流启动失败 | 停止流、清理资源，提供重试 |
| 显示器在录制中断开 | 完成已写入帧；提示录制提前结束 |
| 编码初始化失败 | 不开始倒计时；显示错误并允许重试 |
| ImageIO 最终写入失败 | 删除无效文件；显示失败原因 |
| 临时空间低于 256 MB | 自动停止并尽可能完成当前 GIF |
| 用户取消另存为 | 保留临时 GIF，回到预览操作 |
| 目标文件移动失败 | 保留临时 GIF，允许更换位置重试 |
| App 异常退出 | 下次启动清理专属临时目录残留 |

所有错误都让状态机回到可恢复状态。组件停止和清理操作必须幂等，以便处理并发停止、权限变化或 App 退出。

## 7. 测试策略

### 7.1 单元测试

- 覆盖全部合法和非法状态转换。
- 验证 15/30/60/90 秒计时与最后 10 秒提示。
- 验证时间戳间隔、GIF 百分之一秒量化、累计误差补偿和丢帧后的总时长。
- 验证多显示器坐标、Retina 1×/2×尺寸和跨屏选区拒绝逻辑。
- 验证参数默认值、持久化和非法旧值回退。
- 验证临时目录隔离、保存、取消、启动清理和幂等清理。

### 7.2 集成测试

测试帧生成器向 `FrameProcessor` 和 `GIFStreamEncoder` 输入固定颜色与时间戳序列。测试读取生成的 GIF，验证：

- 画布尺寸和帧数。
- 8/12/15 FPS 对应的延迟。
- 提前停止和模拟丢帧后的总时长。
- 无限循环元数据。
- 1×/2×输出尺寸和 sRGB 色彩空间。

### 7.3 真机测试

- 屏幕权限首次授权、拒绝、重新授权和运行时撤销。
- 单显示器、双显示器、不同 backing scale 和显示器热插拔。
- 快捷键唤起、提前停止、菜单停止和 `Esc` 规则。
- 另存为成功、取消、同名覆盖失败和无写入权限目录。
- Finder、Quick Look、Safari 和至少一个主流聊天工具的播放兼容性。
- M1 或同等级基线机器上的 90 秒压力测试。

## 8. 验收标准

- macOS 14+ Apple Silicon 机器能完成全部主流程。
- 1080p、1×、12 FPS、90 秒录制时，内存不随帧数持续增长；录制后资源得到释放。
- 编码背压不会阻塞框选和停止操作；发生丢帧时，成品时长仍与实际录制时长一致，误差不超过 0.2 秒。
- 录制边框、控制条和 GIFpro 菜单不会出现在成品中。
- 达到所选时长后，自动停止误差不超过 0.5 秒。
- 临时文件不会在正常保存、丢弃或下次启动清理后残留。
- Release 构建只包含 `arm64`，不嵌入第三方动态库，签名前 `.app` 小于 10 MB。

## 9. 实施约束

- 工程使用 Swift 和 Apple SDK，不引入外部包管理依赖。
- UI、状态机、捕捉、处理、编码和文件管理保持独立接口。
- 捕捉回调不执行同步磁盘写入或主线程 UI 工作。
- 所有 GIF destination 调用都在编码器的串行执行上下文中完成。
- 实现计划必须先建立可测试的状态机、计时与帧延迟逻辑，再接入真实屏幕捕捉。
