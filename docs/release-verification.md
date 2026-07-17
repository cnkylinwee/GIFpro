# GIFpro 本地发布验证记录

## 2026-07-17 — 当前开发机

- 主机：MacBook Pro（Mac16,7，Apple M4 Pro，24 GB）
- 系统：macOS 27.0（26A5368g）
- 工具链：Xcode 26.6，Swift 6.3.3
- 结论范围：以下结果只证明当前开发机；不构成 macOS 14 发布门槛证据。

| 命令 | 真实结果 |
| --- | --- |
| `swift test --filter ImageIODestinationCompatibilityTests` | PASS；2 tests，0 failures |
| `swift test --parallel` | PASS；188 XCTest + 20 Swift Testing，0 failures |
| `swift test --parallel -Xswiftc -warnings-as-errors --scratch-path /tmp/GIFpro-task12-strict` | PASS；188 XCTest + 20 Swift Testing，0 failures，编译警告按错误处理 |
| `swift build -c release --arch arm64` | PASS |
| `./Scripts/build-app.sh release` | PASS；脚本内全部发布断言通过 |
| `codesign --verify --deep --strict .build/app/GIFpro.app` | PASS（无诊断输出） |
| `lipo -archs .build/app/GIFpro.app/Contents/MacOS/GIFpro` | `arm64` |
| `du -sh .build/app/GIFpro.app` | `928K` |
| 精确文件逻辑字节数 | `942153` bytes |
| `otool -L` | 所有路径均位于 `/System/Library` 或 `/usr/lib` |
| `plutil -lint`（源与应用包 Info.plist） | 均为 `OK` |
| `diff -u`（源与应用包 Info.plist） | 无差异 |

应用包使用 ad-hoc 签名，适用于本地验证；公开分发需要正式 Developer ID 签名和公证。

## 尚未满足的发布门槛

- **PENDING：**在 macOS 14 Apple Silicon 真机、VM 或自托管 CI 上运行 `swift test --filter ImageIODestinationCompatibilityTests`。
- **PENDING：**在同一 macOS 14 Apple Silicon 环境运行完整 `swift test --parallel`。
- **PENDING：**`docs/manual-test-checklist.md` 所列 GUI、多屏、播放和 90 秒压力验收。

当前环境没有 macOS 14，也不依赖或连接 GitHub，因此不能把上述项目记录为通过。在这些门槛完成前，不得声明 MVP 完成或发布就绪。
