# GIFpro 选框与录制控件视觉改版

日期：2026-07-17  
状态：已获用户口头批准，规格复审修订中

## 1. 目标

本次改版只调整框选和录制控件：

1. 框选边框采用用户提供的 `边框.png` 风格，并继续支持八方向拖动缩放。
2. “开始录制”改用用户提供的 `录制按钮.png` 图形。
3. 录制中的“停止”控件改用用户提供的 `停止按钮.png` 图形，删除重叠文字。

改版保持现有录制流程、设置、快捷键、屏幕捕获、GIF 编码和保存逻辑不变。

## 2. 视觉与交互

### 2.1 自动着色

- 录制与停止 PNG 作为 `NSImage.isTemplate = true` 的模板图使用。录制按钮取动态 `NSColor.controlAccentColor`；停止按钮取动态 `NSColor.systemRed`。
- 两个按钮都使用无边框、image-only、proportional scaling 的 `NSButton`。系统高亮状态将图形降至 75% alpha；禁用状态使用 `NSColor.disabledControlTextColor`。按钮的 `effectiveAppearance` 改变时重新解析动态颜色并重绘。
- 框选边框使用 AppKit 矢量路径重绘，不直接拉伸 `边框.png`。路径颜色取动态 `NSColor.controlAccentColor`。`effectiveAppearance` 或系统强调色改变时，overlay 立即重绘。
- 录制进行中的红色边框保持现有 `systemRed` 语义。

### 2.2 框选边框

`SelectionOverlayView` 绘制 2 point 选区边线和八个控制点。控制点位于四角和四边中点，使用 10×10 point 圆角方形：填充色为窗口背景色，2 point 描边取系统强调色，圆角半径为 2 point。位置允许 0.5 point 的像素对齐误差。边线与控制点保持固定 point 尺寸，不随选区宽高拉伸。

每个控制点使用 16×16 point 透明命中区域。命中优先级为控制点、其他区域。用户可以拖动四边、四角调整选区；点击或拖动选区内部的非控制点区域沿用现有行为，开始绘制新选区。本次不增加移动整个选区或自定义缩放光标。现有 64×64 point 最小尺寸、单显示器约束和坐标转换继续生效。

框选阶段的全屏 panel 接收鼠标。倒计时和录制阶段继续穿透鼠标，避免遮挡底层应用。

### 2.3 录制按钮

设置控制条中的录制操作只显示 `录制按钮.png`，title 为空。图形按比例缩放到 24×24 point，按钮 frame 固定为 44×44 point。

按钮保留：

- 辅助功能 role `button`、标签“开始录制”和 press action。
- Tooltip“开始录制”。
- 原有启用状态和点击回调。
- Return (`\r`) key equivalent、键盘焦点和键盘激活。

### 2.4 停止按钮

录制中的独立停止 panel 只显示 `停止按钮.png`。代码不再创建“停止”标题，也不在 `SelectionOverlayView` 中重复绘制该文字或按钮。

停止图形按比例缩放到 24×24 point，按钮和 panel 固定为 44×44 point。按钮保留辅助功能 role `button`、标签“停止录制”、press action 和 Tooltip“停止录制”。只有这个窄 panel 接收鼠标；录制边框和状态 panel 继续穿透鼠标。

停止按钮使用会话代次和 one-shot gate。第一次有效 activation（鼠标或辅助功能 press action）先禁用按钮并关闭停止 panel，再调用一次 UI callback。停止 panel 保持 nonactivating，不获取键盘焦点。后续双击、迟到 action、重复辅助功能 action 或旧会话 action 都无效。`RecordingCoordinator` 继续保证底层 capture stop 只执行一次。

### 2.5 状态与 panel 生命周期

| 状态 | owner overlay | 设置 panel | 状态 panel | 停止 panel | 鼠标策略 |
| --- | --- | --- | --- | --- | --- |
| selecting | 存在 | 选区完成后存在 | 无 | 无 | overlay 和设置 panel 接收鼠标 |
| countingDown | 存在 | 无 | 存在 | 无 | overlay、状态 panel 均穿透；底层全部可操作 |
| recording | 存在 | 无 | 存在 | 存在 | overlay、状态 panel 穿透；只有停止按钮接收鼠标 |
| stopping/finalizing | 存在 | 无 | 存在 | 立即关闭 | overlay、状态 panel 穿透；底层全部可操作 |
| hidden/idle | 全部关闭 | 无 | 无 | 无 | 不保留 window、target 或 callback |

进入倒计时后关闭非 owner display 的 overlay。`dismiss`、显示器失效、取消和会话结束都关闭所有辅助 panel，并使旧代次 callback 失效。

### 2.6 状态与停止 panel 布局

状态 panel 高 28 point，期望宽度限制在 100...220 point。停止 panel 为 44×44 point，两者间距 8 point。布局器必须让两个 frame 不相交，并让两个 frame 完全位于目标屏幕 `visibleFrame` 内。

布局按以下顺序选择：

1. 如果 `visibleFrame` 可容纳横向组合，状态在左、停止在右。组合优先放在选区下方 8 point；下方不足则放在上方 8 point；上下都不足则靠近选区上边缘并夹取到 `visibleFrame`。
2. 如果横向组合无法容纳，改为纵向排列，状态在上、停止在下，间距 8 point；状态宽度最多缩至 `visibleFrame.width`。组合仍按下方、上方、夹取的顺序放置。
3. 倒计时和 stopping 没有停止 panel。状态 panel 单独居中靠近选区，并夹取到 `visibleFrame`。
4. 当 `visibleFrame` 既无法容纳横排（至少 152×44 point），也无法容纳纵排（至少 44×80 point）时，停止操作优先：隐藏状态 panel，只显示完整的 44×44 point 停止 panel，并把它夹取到 `visibleFrame`。如果 `visibleFrame` 本身小于 44×44 point，记录布局错误并让菜单栏“停止录制”作为可达回退；真实 `NSScreen.visibleFrame` 不应触发此测试专用防御路径。

布局测试使用 64×64 最小选区、四个屏幕角、贴四边和普通居中选区，并覆盖恰好 152×44、44×80、140×60 和小于 44×44 point 的 `visibleFrame`。正常与 stop-only 用例断言停止 frame 完整可点击且所有已显示 frame 位于 `visibleFrame`；小于 44×44 的防御用例断言记录错误并保留菜单停止入口。

## 3. 资源与体积

实现时执行一次性资源导入：

| 源文件 | 仓库目标 | App bundle 目标 |
| --- | --- | --- |
| `/Users/wdychn/Downloads/录制按钮.png` | `Resources/RecordButton.png` | `Contents/Resources/RecordButton.png` |
| `/Users/wdychn/Downloads/停止按钮.png` | `Resources/StopButton.png` | `Contents/Resources/StopButton.png` |
| `/Users/wdychn/Downloads/边框.png` | `docs/assets/SelectionBorderReference.png` | 不复制到 App |

`/Users/wdychn/Downloads` 只提供本次导入来源。资源提交到仓库后，所有 Debug、Release、测试和 CI 构建都只读取仓库中的 `Resources/RecordButton.png`、`Resources/StopButton.png` 和 `docs/assets/SelectionBorderReference.png`，不依赖 Downloads 或任何用户绝对路径。

生产加载器使用 `Bundle.main.url(forResource: "RecordButton", withExtension: "png")` 和对应的 `StopButton` 精确名称，不使用泛名称 `NSImage(named:)`。测试向加载器注入仓库资源目录，并复用同一组资源名常量。

构建脚本把两张按钮资源复制到 `.app`，并继续执行小于 10 MB、arm64-only、系统动态库和签名门禁。两张原始 PNG 合计约 81 KB。加载器复制 `NSImage` 后设置 `isTemplate = true`，不得修改用户的原始附件。

## 4. 组件边界

- `SelectionOverlayView`：绘制矢量框选边框、控制点和录制红框；处理八方向命中与拖动。
- `SelectionControlsView`：显示模板化录制图标，提供鼠标、键盘、Tooltip 和辅助功能语义。
- `SelectionOverlayController`：创建独立停止按钮 panel，维护布局、one-shot gate、鼠标穿透和 panel 生命周期。
- 资源加载器：按精确名称加载模板 PNG；支持注入资源目录，以便测试缺失资源。

图像资源和视觉状态不进入 `RecordingCoordinator`。领域状态只通过现有 overlay 接口驱动 UI。

## 5. 错误与回退

- Debug 和 Release 都不因资源缺失崩溃。加载器记录错误，并返回具体回退图形：录制使用 `record.circle`，停止使用 `stop.circle.fill`。如果系统 symbol 也不可用，则用矢量圆环加圆点、圆环加方块绘制 24×24 point 模板图。
- 回退图形继续使用规定的 tint、44×44 frame、Tooltip、辅助功能 role、label、action 和原有 callback。
- Release 构建验证仓库 `Resources` 与 App bundle 对应资源字节一致；缺失或复制不一致时构建失败。构建脚本不得读取 Downloads。运行时回退用于开发启动方式和受损 bundle，不放宽发布门禁。
- 边框矢量绘制不依赖外部文件，因此框选始终可用。

## 6. 测试与验收

自动化测试覆盖：

- 八个控制点的布局和拖动结果。
- 2 point 边框、10×10 圆角控制点、16×16 命中区域及控制点优先命中；选区内部非控制点开始新选区。
- 框选边框使用系统强调色，录制边框仍为红色；浅色、深色和强调色变化触发重绘。
- 录制和停止按钮 title 为空，使用精确模板资源、规定 tint、24×24 图形和 44×44 frame。
- 两个按钮具有 button role、正确 label、press action、Tooltip 和可执行 callback；录制按钮保留 Return 键盘激活与 enabled 状态。
- 缺失资源的注入测试验证具体 symbol/矢量回退，按钮仍可点击且辅助功能语义完整。
- 参数化布局测试覆盖最小选区、四角、四边和居中选区；状态与停止 panel 不相交且都在 `visibleFrame` 内。
- 状态表中的每个阶段都验证 panel 存在性、鼠标穿透、关闭和旧 callback 失效。
- 快速双击和连续两次辅助功能 press action 都满足 `callbackCount == 1` 且下游 `stopCount == 1`；鼠标后接辅助功能 action 的混合重复也无效。
- Debug 与 Release 包含两张 PNG；Release 还验证仓库资源与 bundle 字节一致，arm64、签名、动态库和 10 MB 门禁继续通过。

人工验收覆盖浅色与深色模式，并在不同大小的选区上检查边框无拉伸、控制点清晰、八方向缩放正确。录制时验证停止图形无文字重叠，除停止按钮外的区域都能操作底层应用。

## 7. 不在本次范围

- 不增加移动整个选区的功能。
- 不修改菜单栏图标。
- 不改变倒计时、录制状态文字或保存预览界面。
- 不改变录制红框颜色。
- 不增加动画、声音或悬停特效。
- 不修改附件源文件。
