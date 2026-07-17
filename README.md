# GIFpro

GIFpro 是一款轻量级 macOS 菜单栏 GIF 录制工具。它只使用 Apple 原生框架，面向 Apple Silicon，并且不包含网络请求、账号系统或遥测。

## 系统要求

- Apple Silicon（M 系列芯片），仅构建 `arm64`
- macOS 14 Sonoma 或更高版本
- Xcode 及其 Command Line Tools

首次录制时，macOS 会请求“屏幕与系统音频录制”权限。也可以前往“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”允许 GIFpro；修改权限后按系统提示重新打开应用。

## 使用

GIFpro 以菜单栏应用运行，不显示 Dock 图标。点击菜单栏图标，或按 `⌥⌘G`，拖动选择同一显示器内的矩形区域，然后等待 3 秒倒计时开始录制。

设置支持：

- 输出比例：1×、2×
- 帧率：8、12、15 FPS
- 录制时长：15、30、60、90 秒（默认 30 秒）
- 鼠标指针：显示或隐藏（默认显示）

可以提前停止；达到所选时长或磁盘空间过低时会自动停止。录制完成后可预览、另存为、重新录制或丢弃。

## 构建与测试

```sh
swift test --parallel
swift build -c release --arch arm64
./Scripts/build-app.sh release
open .build/app/GIFpro.app
```

发布脚本会验证 Info.plist、arm64-only 架构、系统动态库依赖、10 MB 未压缩体积上限和代码签名。生成的本地应用使用 ad-hoc 签名；公开分发仍需开发者签名和公证。

macOS 14 是发布硬门槛：发布前必须在 macOS 14 Apple Silicon 真机、虚拟机或自托管 CI 上运行 `swift test --filter ImageIODestinationCompatibilityTests` 和完整 `swift test`。仓库不需要连接 GitHub 即可在本机构建或测试。

## 隐私

GIFpro 不访问网络，不上传录屏，不收集使用数据，也不包含任何第三方分析或遥测 SDK。GIF 数据只写入本机临时目录和用户选择的保存位置。
