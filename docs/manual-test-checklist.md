# GIFpro 人工验收清单

此文档区分自动化验证和必须由人工观察的行为。`PENDING` 不代表失败，也不得改写为通过，除非在所列环境实际执行并记录证据。

## 执行环境

| 字段 | 当前记录 |
| --- | --- |
| 日期 | 2026-07-17 |
| 机器 | MacBook Pro（Mac16,7，Apple M4 Pro，24 GB） |
| 系统 | macOS 27.0（26A5368g） |
| Xcode / Swift | Xcode 26.6 / Swift 6.3.3 |
| macOS 14 Apple Silicon 环境 | PENDING — 当前不可用 |

## 自动化记录

| 项目 | 当前结果 | 证据 |
| --- | --- | --- |
| 合成 GIF 流水线：8/12/15 FPS、1×/2×、丢帧、循环、时长与清理 | PASS（仅当前 macOS 27） | `GIFPipelineTests` 2/2，2026-07-17 |
| 完整测试套件 | PASS（仅当前 macOS 27） | `swift test --parallel` 连续 5 轮：每轮 198 XCTest + 20 Swift Testing，0 失败，2026-07-17 |
| 严格警告检查 | PASS（仅当前 macOS 27） | `swift test --parallel -Xswiftc -warnings-as-errors --scratch-path /tmp/GIFpro-final-strict`：218 tests，0 失败，2026-07-17 |
| arm64 Release 构建和应用包检查 | PASS（仅当前 macOS 27） | arm64；970,473 bytes（`du` 956K）；系统库 only；ad-hoc 签名有效；2026-07-17 |
| 当前系统 ImageIO 兼容性测试 | PASS（不替代 macOS 14 门槛） | 2/2，0 失败，macOS 27，2026-07-17 |
| macOS 14 ImageIO 兼容性门槛 | PENDING | 必须在 macOS 14 Apple Silicon 执行 |
| macOS 14 完整测试套件 | PENDING | 必须在 macOS 14 Apple Silicon 执行 |

## 人工功能矩阵

| 类别 | 场景 | 预期 | 结果 | 执行环境 / 日期 / 备注 |
| --- | --- | --- | --- | --- |
| 权限 | 首次允许屏幕录制 | 授权后可开始框选 | PENDING | 需要 GUI 人工验收 |
| 权限 | 首次拒绝 | 不开始录制并提供设置入口 | PENDING | 需要 GUI 人工验收 |
| 权限 | 设置中重新允许 | 重新检查后可录制 | PENDING | 需要 GUI 人工验收 |
| 权限 | 运行时撤销 | 当前会话安全停止并提示 | PENDING | 需要 GUI 人工验收 |
| 显示器 | 单显示器框选 | 选区与成品内容一致 | PENDING | 需要 GUI 人工验收 |
| 显示器 | 双显示器相同缩放 | 各屏可独立框选 | PENDING | 需要多屏环境 |
| 显示器 | 双显示器不同 backing scale | 尺寸和坐标准确 | PENDING | 需要混合缩放多屏环境 |
| 显示器 | 选区跨屏 | 拒绝跨屏区域 | PENDING | 需要多屏环境 |
| 显示器 | 倒计时中目标屏变化/断开 | 取消录制 | PENDING | 需要多屏热插拔 |
| 显示器 | 录制中目标屏断开 | 安全停止 | PENDING | 需要多屏热插拔 |
| 显示器 | 录制中非目标屏变化 | 目标录制继续 | PENDING | 需要多屏热插拔 |
| 尺寸 | 300×200 pt Retina、1× | 成品 300×200 px | PENDING | 自动化已覆盖尺寸；GUI 尚待验收 |
| 尺寸 | 300×200 pt Retina、2× | 成品 600×400 px | PENDING | 自动化已覆盖尺寸；GUI 尚待验收 |
| 帧率 | 8 FPS | 可录制、时长准确 | PENDING | 需要 GUI 人工验收 |
| 帧率 | 12 FPS | 可录制、时长准确 | PENDING | 需要 GUI 人工验收 |
| 帧率 | 15 FPS | 可录制、时长准确 | PENDING | 需要 GUI 人工验收 |
| 时长 | 15 秒自动停止 | 误差 ≤0.5 秒 | PENDING | 需要计时人工验收 |
| 时长 | 30 秒自动停止 | 误差 ≤0.5 秒 | PENDING | 需要计时人工验收 |
| 时长 | 60 秒自动停止 | 误差 ≤0.5 秒 | PENDING | 需要计时人工验收 |
| 时长 | 90 秒自动停止 | 误差 ≤0.5 秒 | PENDING | 需要计时人工验收 |
| 指针 | 显示鼠标指针 | 成品包含指针 | PENDING | 需要 GUI 人工验收 |
| 指针 | 隐藏鼠标指针 | 成品不含指针 | PENDING | 需要 GUI 人工验收 |
| 操作 | `⌥⌘G` 唤起 | 打开框选 | PENDING | 需要 GUI 人工验收 |
| 操作 | 框选/倒计时按 Esc | 取消且无残留临时 GIF | PENDING | 需要 GUI 人工验收 |
| 操作 | 录制中按 Esc | 不停止录制 | PENDING | 需要 GUI 人工验收 |
| 操作 | 控制条或菜单提前停止 | 生成实际时长 GIF | PENDING | 需要 GUI 人工验收 |
| 磁盘 | 启动前空间不足 | 拒绝开始 | PENDING | 需要受控磁盘模拟 |
| 磁盘 | 录制中空间降至阈值 | 安全自动停止 | PENDING | 需要受控磁盘模拟 |
| 保存 | 另存为成功 | 临时文件安全移动并关闭内部预览 | PENDING | 需要 GUI 人工验收 |
| 保存 | 取消后再次另存为 | 保留预览并可再次保存 | PENDING | 需要 GUI 人工验收 |
| 保存 | 取消后重新录制 | 丢弃旧临时文件并框选 | PENDING | 需要 GUI 人工验收 |
| 保存 | 取消后丢弃 | 关闭预览且无临时文件 | PENDING | 需要 GUI 人工验收 |
| 保存 | 同名覆盖失败 | 原文件不损坏并提示错误 | PENDING | 需要 GUI 人工验收 |
| 保存 | 无写权限目录 | 不丢失临时预览并提示错误 | PENDING | 需要 GUI 人工验收 |
| 播放 | Finder | 无限循环正常 | PENDING | 需要人工播放验证 |
| 播放 | Quick Look | 无限循环正常 | PENDING | 需要人工播放验证 |
| 播放 | Safari | 无限循环正常 | PENDING | 需要人工播放验证 |
| 播放 | 主流聊天应用 | 上传和播放正常 | PENDING | 当前无聊天应用验收环境 |
| 隐私 | 离线录制 | 无网络连接或遥测 | PENDING | 需要网络观察工具人工复核 |

## 90 秒 M1 级压力测试

状态：**PENDING**。

在 M1 或同等级 Apple Silicon 上录制 1080p、1×、12 FPS、90 秒；每 10 秒记录一次 RSS/内存压力，保存后继续观察至少 30 秒。验收条件：内存不随帧数单调增长，保存后回落至接近空闲；GIF 时长误差 ≤0.2 秒，自动停止误差 ≤0.5 秒。记录机器、系统、开始/结束时间、每次内存样本、成品时长和文件大小。

## 发布阻塞项

- macOS 14 Apple Silicon 的 ImageIO 兼容性测试与完整测试尚未执行。
- 全部 GUI、多屏、保存失败路径、播放兼容性和 90 秒压力测试尚未人工执行。
- 在这些项目完成前，不得声明 MVP 完成或发布就绪。
