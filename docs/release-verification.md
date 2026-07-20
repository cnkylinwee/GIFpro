# GIFpro 本地发布验证记录

## 2026-07-17 — 当前开发机

- 主机：MacBook Pro（Mac16,7，Apple M4 Pro，24 GB）
- 系统：macOS 27.0（26A5368g）
- 工具链：Xcode 26.6，Swift 6.3.3
- 结论范围：以下结果只证明当前开发机；不构成 macOS 14 发布门槛证据。

| 命令 | 真实结果 |
| --- | --- |
| `swift test --filter ImageIODestinationCompatibilityTests` | PASS；2 tests，0 failures |
| `swift test --parallel --scratch-path /tmp/GIFpro-task5-parallel` | PASS；连续 3 轮，每轮 237 XCTest + 20 Swift Testing，0 failures |
| `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --scratch-path /tmp/GIFpro-task5-strict` | PASS；237 XCTest + 20 Swift Testing，0 failures；完整并发检查和编译警告按错误处理 |
| `swift test --filter RecordingCoordinatorTests.testRuntimeSystemCaptureFailureFinalizesWithNotice` | PASS；连续 10 轮，每轮 1 test，0 failures |
| `swift build -c release --arch arm64` | PASS |
| `./Scripts/build-app.sh release` | PASS；脚本内全部发布断言通过 |
| `Scripts/validate-control-assets.sh` | PASS；显式目录；`sips` PNG 格式检查并实际解码；有效、缺失、截断 PNG 3 个隔离 fixture 均符合预期且失败诊断唯一；截断 fixture 保留真实 PNG 前 64 bytes，`sips -g format` 仍报告 png、实际 decode gate 拒绝 |
| `Tests/ScriptTests/BuildAppReleaseChecksTests.sh` | PASS；共 7 个场景：3 个 validator fixture、注入 `stat` 失败、含空格路径的 Debug/Release 构建、带换行文件名的额外 regular file 拒绝；两个配置的资源集合均精确为两张逐字节相同的 PNG 和 `AppIcon.icns` |
| `codesign --verify --deep --strict .build/app/GIFpro.app` | PASS（无诊断输出） |
| `lipo -archs .build/app/GIFpro.app/Contents/MacOS/GIFpro` | `arm64` |
| `du -sh .build/app/GIFpro.app` | `1.2M` |
| 精确文件逻辑字节数 | `1,212,189` bytes（6 files，包含资源） |
| `cmp`（源资源与应用包资源） | PASS；`RecordButton.png`、`StopButton.png` 和 `AppIcon.icns` 均无差异 |
| `CFBundleIconFile` | `AppIcon` |
| `otool -L` | 所有路径均位于 `/System/Library` 或 `/usr/lib` |
| `plutil -lint`（源与应用包 Info.plist） | 均为 `OK` |
| `diff -u`（源与应用包 Info.plist） | 无差异 |
| `open -n` + 进程探测 + AppleScript 退出 | PASS；Release App 可启动并完成退出探测；未据此声称 GUI 视觉验收通过 |

应用包使用 ad-hoc 签名，适用于本地验证；公开分发需要正式 Developer ID 签名和公证。

完整 strict 测试期间，CoreData/AppKit 在若干图像相关测试打印了 `Failed to create NSXPCConnection` 运行时诊断；测试继续执行并以 237 XCTest + 20 Swift Testing、0 failures 结束。该诊断不被隐藏，也不作为 macOS 14 或 GUI 验收证据。

提交前的首次 parallel 验证暴露 `testRuntimeSystemCaptureFailureFinalizesWithNotice` 的确定性同步缺口：capture failure callback 绕过可注入 stop-request scheduler，且 fake capture 以 `startCount` 表示 ready 时尚未保证 failure handler 已安装。修复统一使用线程安全 scheduler seam，并以 `CheckedContinuation` 明确确认 fake handler 安装；没有增加 sleep 或 yield 次数。修复后定向 10 轮和完整 parallel 3 轮均通过。

## 尚未满足的发布门槛

- **PENDING：**在 macOS 14 Apple Silicon 真机、VM 或自托管 CI 上运行 `swift test --filter ImageIODestinationCompatibilityTests`。
- **PENDING：**在同一 macOS 14 Apple Silicon 环境运行完整 `swift test --parallel`。
- **PENDING：**`docs/manual-test-checklist.md` 所列浅色/深色、八 handles、Record tint/Return、Stop 无文字/双次激活、鼠标穿透，以及既有 GUI、多屏、播放和 90 秒压力验收。

当前环境没有 macOS 14，也不依赖或连接 GitHub，因此不能把上述项目记录为通过。在这些门槛完成前，不得声明 MVP 完成或发布就绪。
