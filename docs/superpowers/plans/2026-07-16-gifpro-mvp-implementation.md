# GIFpro MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native, arm64-only macOS 14+ menu-bar app that records a user-selected screen region to a looping GIF and saves or previews the result.

**Architecture:** A main-thread `RecordingCoordinator` owns the state machine and delegates to isolated services for selection, capture, frame processing, streaming ImageIO encoding, temporary files, and preview. ScreenCaptureKit supplies bounded BGRA frames; a serial encoder writes accepted frames with timestamp-derived delays so backpressure cannot create unbounded memory or shorten playback.

**Tech Stack:** Swift 5 language mode, SwiftPM, SwiftUI, AppKit, ScreenCaptureKit, Core Image, Core Graphics, ImageIO, Quick Look, Carbon hot keys, XCTest, shell packaging with Apple command-line tools.

---

## Working assumptions and gates

- Design spec: `docs/superpowers/specs/2026-07-16-gifpro-macos-gif-recorder-design.md`.
- The current machine runs macOS 27 with Xcode 26.6 and Swift 6.3.3. Use SwiftPM for reproducible builds and a checked-in script to assemble the `.app` bundle; keep the package in Swift 5 language mode for the macOS 14 release gate.
- Set `swift-tools-version` to 5.10 and compile in Swift 5 language mode so the macOS 14 CI runner can build the project.
- 2026-07-17 user-approved gate adjustment: the ImageIO compatibility test and full suite pass on the current macOS 27 development system, so Tasks 4–11 may continue without connecting GitHub. macOS 14 runtime compatibility is deferred to a Task 12 release gate and has not yet passed. Before release or any MVP completion claim, run both the compatibility test and the full suite on macOS 14 hardware, a VM, or CI; failure requires returning to the encoding architecture design.
- Apply TDD to pure logic and file services. Use thin adapters plus manual tests for TCC, global hot keys, `NSPanel`, ScreenCaptureKit, `NSSavePanel`, and Quick Look.
- Do not add third-party packages, analytics, networking, Intel slices, or features excluded by the spec.

## File map

```text
Package.swift                                  SwiftPM products, targets, macOS 14 floor
Resources/Info.plist                           Bundle identity, LSUIElement, minimum OS
Scripts/build-app.sh                           Build, assemble, ad-hoc sign, verify arm64
.github/workflows/macos.yml                    macOS 14 compatibility gate

Sources/GIFpro/App/GIFproApp.swift             SwiftUI entry and MenuBarExtra
Sources/GIFpro/App/AppEnvironment.swift        Dependency construction
Sources/GIFpro/App/AppLifecycleDelegate.swift  Startup cleanup and deferred termination
Sources/GIFpro/App/MenuBarContent.swift        Menu commands and visible state
Sources/GIFpro/Domain/RecordingSettings.swift  Validated FPS, scale, duration, cursor values
Sources/GIFpro/Domain/RecordingState.swift     State and legal transitions
Sources/GIFpro/Domain/RecordingCoordinator.swift Main workflow orchestration

Sources/GIFpro/Infrastructure/PermissionService.swift    Screen-capture permission adapter
Sources/GIFpro/Infrastructure/GlobalHotKeyController.swift Carbon hot-key adapter
Sources/GIFpro/Infrastructure/PreferencesStore.swift     UserDefaults adapter
Sources/GIFpro/Infrastructure/TemporaryFileStore.swift   Temp-file lifecycle and disk checks
Sources/GIFpro/Infrastructure/DisplayConfigurationMonitor.swift Screen attach/detach events

Sources/GIFpro/Selection/CaptureRegion.swift             Display-local capture model
Sources/GIFpro/Selection/DisplayCoordinateConverter.swift Screen/AppKit/SCK conversion
Sources/GIFpro/Selection/SelectionOverlayController.swift One overlay per NSScreen
Sources/GIFpro/Selection/SelectionOverlayView.swift       Handles, border, controls, countdown

Sources/GIFpro/Capture/CaptureEngine.swift                SCStream setup and lifecycle
Sources/GIFpro/Capture/CapturedFrame.swift                Pixel buffer plus timestamp
Sources/GIFpro/Capture/FrameBackpressure.swift            Bounded processing permits

Sources/GIFpro/Encoding/FrameProcessor.swift              BGRA/CI to target-size sRGB CGImage
Sources/GIFpro/Encoding/FrameTiming.swift                  GIF centisecond delay calculation
Sources/GIFpro/Encoding/GIFStreamEncoder.swift             Serial ImageIO destination owner

Sources/GIFpro/Preview/GIFPreviewView.swift                QLPreviewView SwiftUI bridge
Sources/GIFpro/Preview/SaveAndPreviewController.swift      Save, retry, discard, Quick Look

Tests/GIFproTests/...                         Unit and native integration tests by component
Tests/GIFproIntegrationTests/GIFPipelineTests.swift       End-to-end synthetic frame pipeline
```

### Task 1: Create the buildable menu-bar app skeleton

**Files:**
- Create: `Package.swift`
- Create: `Resources/Info.plist`
- Create: `Scripts/build-app.sh`
- Modify: `.gitignore`
- Create: `Sources/GIFpro/App/GIFproApp.swift`
- Create: `Sources/GIFpro/App/MenuBarContent.swift`
- Create: `Tests/GIFproTests/AppSmokeTests.swift`
- Create: `Tests/GIFproIntegrationTests/IntegrationSmokeTests.swift`

- [ ] **Step 1: Write the package smoke test**

```swift
import XCTest
@testable import GIFpro

final class AppSmokeTests: XCTestCase {
    func testApplicationIdentity() {
        XCTAssertEqual(AppIdentity.name, "GIFpro")
        XCTAssertEqual(AppIdentity.minimumSystemVersion, "14.0")
    }
}
```

- [ ] **Step 2: Run the test and verify the package is absent**

Run: `swift test --filter AppSmokeTests`

Expected: FAIL because `Package.swift` does not exist.

- [ ] **Step 3: Create the SwiftPM executable and test targets**

Use a 5.10 tools manifest, `.macOS(.v14)`, one executable target named `GIFpro`, and two test targets: `GIFproTests` and `GIFproIntegrationTests`. Set Swift language mode to version 5. Do not declare package dependencies. Add one trivial integration smoke test so SwiftPM recognizes the second test target from the first commit. Add `.build/` to `.gitignore`.

Create this initial app entry:

```swift
import SwiftUI

enum AppIdentity {
    static let name = "GIFpro"
    static let minimumSystemVersion = "14.0"
}

@main
struct GIFproApp: App {
    var body: some Scene {
        MenuBarExtra("GIFpro", systemImage: "record.circle") {
            MenuBarContent()
        }
    }
}
```

`MenuBarContent` initially exposes disabled “开始录制”, a separator, and “退出”.

- [ ] **Step 4: Add bundle metadata and deterministic packaging**

`Info.plist` must set `CFBundleIdentifier=com.gifpro.app`, `CFBundleExecutable=GIFpro`, `CFBundlePackageType=APPL`, `LSUIElement=true`, `LSMinimumSystemVersion=14.0`, and version `0.1.0`.

`Scripts/build-app.sh` must:

1. accept `debug` or `release`;
2. run `swift build -c "$configuration" --arch arm64`;
3. copy the executable and plist into `.build/app/GIFpro.app/Contents`;
4. ad-hoc sign by default with `codesign --force --sign -`;
5. assert `lipo -archs` returns only `arm64`;
6. fail if `otool -L` reports a non-system dylib.

- [ ] **Step 5: Build, test, and launch the bundle**

Run:

```bash
swift test
./Scripts/build-app.sh debug
open .build/app/GIFpro.app
```

Expected: tests PASS; the menu-bar icon appears; no Dock icon appears.

- [ ] **Step 6: Commit**

```bash
git add .gitignore Package.swift Resources Scripts Sources/GIFpro/App Tests/GIFproTests/AppSmokeTests.swift Tests/GIFproIntegrationTests/IntegrationSmokeTests.swift
git commit -m "build: scaffold native GIFpro menu bar app"
```

### Task 2: Implement validated settings and the recording state machine

**Files:**
- Create: `Sources/GIFpro/Domain/RecordingSettings.swift`
- Create: `Sources/GIFpro/Domain/RecordingState.swift`
- Create: `Tests/GIFproTests/RecordingSettingsTests.swift`
- Create: `Tests/GIFproTests/RecordingStateTests.swift`

- [ ] **Step 1: Write failing settings tests**

Cover defaults `(scale: 1, fps: 12, duration: 30, showsCursor: true)`, allowed values, and fallback from invalid persisted integers. Use enums whose raw values are exactly `1/2`, `8/12/15`, and `15/30/60/90`.

```swift
func testDefaultsMatchProductDecision() {
    XCTAssertEqual(RecordingSettings.default, .init(
        scale: .one, fps: .twelve, duration: .thirty, showsCursor: true
    ))
}
```

- [ ] **Step 2: Write failing transition tests**

Test the happy path and reject at least these illegal transitions: `idle → recording`, `recording → selecting`, and `awaitingSave → recording`. Test the cancel-save loop `awaitingSave → previewReady → awaitingSave` and “重新录制” transition `previewReady → selecting`.

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter 'Recording(Settings|State)Tests'`

Expected: FAIL because domain types are missing.

- [ ] **Step 4: Implement the minimal value types and transition validator**

Keep the state free of AppKit and ScreenCaptureKit types. Model file-bearing states with `URL` and failures with a small `RecordingFailure` enum. Implement `RecordingState.canTransition(to:)` as an exhaustive switch so a new state forces review.

- [ ] **Step 5: Run the domain tests**

Run: `swift test --filter 'Recording(Settings|State)Tests'`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/GIFpro/Domain Tests/GIFproTests/RecordingSettingsTests.swift Tests/GIFproTests/RecordingStateTests.swift
git commit -m "feat: define recording settings and state machine"
```

### Task 3: Prove the ImageIO variable-frame-count architecture

**Files:**
- Create: `Tests/GIFproIntegrationTests/ImageIODestinationCompatibilityTests.swift`
- Create: `.github/workflows/macos.yml`

- [ ] **Step 1: Write the compatibility test**

Create a destination with `count: 10`, add two 2×2 `CGImage` frames, finalize, reopen with `CGImageSource`, and assert a frame count of two. Also verify that adding exactly the declared count succeeds.

```swift
func testFinalizesWithFewerFramesThanDeclaredMaximum() throws {
    let url = temporaryURL("fewer-than-count.gif")
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
        url as CFURL, UTType.gif.identifier as CFString, 10, nil
    ))
    CGImageDestinationAddImage(destination, try solidImage(.red), nil)
    CGImageDestinationAddImage(destination, try solidImage(.blue), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetCount(source), 2)
}
```

- [ ] **Step 2: Run the gate on the current system**

Run: `swift test --filter ImageIODestinationCompatibilityTests`

Expected: PASS with both output GIFs readable.

- [ ] **Step 3: Add the macOS 14 CI gate**

Create a GitHub Actions workflow triggered by pushes and pull requests. Use `runs-on: macos-14`, run `swift test --filter ImageIODestinationCompatibilityTests`, then run the full `swift test` suite. Do not publish artifacts or require secrets.

- [ ] **Step 4: Record the approved macOS 14 gate deferral**

On 2026-07-17, the user approved continuing Tasks 4–11 after the compatibility test and full suite passed on the current macOS 27 system. A macOS 14 result is still outstanding and is required in Task 12 before release or any completion claim. If macOS 14 fails, return to design; do not implement frame padding or assume `count: 0` works.

- [ ] **Step 5: Commit the proven gate**

```bash
git add Tests/GIFproIntegrationTests/ImageIODestinationCompatibilityTests.swift .github/workflows/macos.yml
git commit -m "test: gate ImageIO streaming compatibility"
```

### Task 4: Implement timestamp timing and bounded backpressure

**Files:**
- Create: `Sources/GIFpro/Encoding/FrameTiming.swift`
- Create: `Sources/GIFpro/Capture/FrameBackpressure.swift`
- Create: `Tests/GIFproTests/FrameTimingTests.swift`
- Create: `Tests/GIFproTests/FrameBackpressureTests.swift`

- [ ] **Step 1: Write timing tests**

Cover 8, 12, and 15 FPS; an irregular gap caused by dropped frames; final-frame delay; and cumulative centisecond rounding. For a 1.00-second synthetic recording, assert the encoded delay sum stays within 0.01 second.

- [ ] **Step 2: Write permit tests**

Initialize capacity at two. Assert that two acquisitions succeed, the third fails immediately, release restores capacity, and repeated release cannot exceed capacity.

- [ ] **Step 3: Verify the tests fail**

Run: `swift test --filter 'Frame(Timing|Backpressure)Tests'`

Expected: FAIL because both types are missing.

- [ ] **Step 4: Implement pure timing and permit logic**

`FrameTiming` keeps the prior presentation timestamp and a fractional centisecond remainder. It returns the previous frame plus a delay only when the next accepted timestamp arrives. `finish(at:)` emits the pending final frame delay. Clamp each emitted GIF delay to at least 0.02 second and carry rounding error forward.

`FrameBackpressure` uses `NSLock` around an integer permit count and exposes `tryAcquire()`, `release()`, and async `waitUntilDrained()`. Draining records continuations under the same lock and resumes them when the in-use count reaches zero; it never blocks the main or capture queue.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter 'Frame(Timing|Backpressure)Tests'
git add Sources/GIFpro/Encoding/FrameTiming.swift Sources/GIFpro/Capture/FrameBackpressure.swift Tests/GIFproTests/FrameTimingTests.swift Tests/GIFproTests/FrameBackpressureTests.swift
git commit -m "feat: add bounded frame timing pipeline"
```

### Task 5: Implement preferences and temporary-file ownership

**Files:**
- Create: `Sources/GIFpro/Infrastructure/PreferencesStore.swift`
- Create: `Sources/GIFpro/Infrastructure/TemporaryFileStore.swift`
- Create: `Tests/GIFproTests/PreferencesStoreTests.swift`
- Create: `Tests/GIFproTests/TemporaryFileStoreTests.swift`

- [ ] **Step 1: Write isolated tests**

Use a unique `UserDefaults` suite and a test-only temporary root. Verify setting round trips, invalid values fall back, file URLs remain inside the GIFpro directory, save moves a file, discard is idempotent, cleanup cannot delete siblings, and available-capacity policy returns `canStart`, `mustStop`, or `continue` at the 1 GB/256 MB boundaries.

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter '(PreferencesStore|TemporaryFileStore)Tests'`

Expected: FAIL because stores are missing.

- [ ] **Step 3: Implement stores with injected dependencies**

Inject `UserDefaults`, `FileManager`, root URL, and a capacity-reading closure. Production temp root is `FileManager.default.temporaryDirectory/GIFpro/`. Generate UUID filenames ending in `.gif`. Never enumerate or delete outside that root.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter '(PreferencesStore|TemporaryFileStore)Tests'
git add Sources/GIFpro/Infrastructure/PreferencesStore.swift Sources/GIFpro/Infrastructure/TemporaryFileStore.swift Tests/GIFproTests/PreferencesStoreTests.swift Tests/GIFproTests/TemporaryFileStoreTests.swift
git commit -m "feat: persist settings and own temporary GIF files"
```

### Task 6: Add permissions and the global hot key

**Files:**
- Create: `Sources/GIFpro/Infrastructure/PermissionService.swift`
- Create: `Sources/GIFpro/Infrastructure/GlobalHotKeyController.swift`
- Create: `Tests/GIFproTests/PermissionServiceTests.swift`
- Modify: `Sources/GIFpro/App/GIFproApp.swift`
- Modify: `Sources/GIFpro/App/MenuBarContent.swift`

- [ ] **Step 1: Test permission decision logic through an adapter**

Define a `ScreenCapturePermissionChecking` protocol with `preflight()`, `request()`, and `openSettings()`. Test coordinator-facing outcomes using a fake; keep CoreGraphics global functions in the production adapter.

- [ ] **Step 2: Implement native permission behavior**

Use `CGPreflightScreenCaptureAccess()` and `CGRequestScreenCaptureAccess()`. Open `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` through `NSWorkspace` when denied. Re-check after the app becomes active.

- [ ] **Step 3: Implement `⌥⌘G` with Carbon**

Wrap `RegisterEventHotKey`, install one event handler, publish one callback, and unregister during teardown. Use key code `kVK_ANSI_G` with `optionKey | cmdKey`. Do not use `NSEvent.addGlobalMonitorForEvents`, which would add an Accessibility permission dependency.

- [ ] **Step 4: Wire all menu commands to temporary actions**

Both the recording menu command and hot key call the same closure. The menu title switches between “开始录制” and “停止录制” based on state. Add the permanent “打开屏幕录制设置” item and connect it directly to `PermissionService.openSettings()`. Keep the separator and “退出”.

- [ ] **Step 5: Build and manually verify**

Run:

```bash
swift test --filter PermissionServiceTests
./Scripts/build-app.sh debug
open .build/app/GIFpro.app
```

Expected: `⌥⌘G` triggers once without Accessibility permission; denied screen permission offers System Settings.

- [ ] **Step 6: Commit**

```bash
git add Sources/GIFpro/Infrastructure Sources/GIFpro/App Tests/GIFproTests/PermissionServiceTests.swift
git commit -m "feat: add screen permission and global shortcut"
```

### Task 7: Build the single-display selection overlay

**Files:**
- Create: `Sources/GIFpro/Selection/CaptureRegion.swift`
- Create: `Sources/GIFpro/Selection/DisplayCoordinateConverter.swift`
- Create: `Sources/GIFpro/Selection/SelectionOverlayController.swift`
- Create: `Sources/GIFpro/Selection/SelectionOverlayView.swift`
- Create: `Sources/GIFpro/Infrastructure/DisplayConfigurationMonitor.swift`
- Create: `Tests/GIFproTests/DisplayCoordinateConverterTests.swift`
- Create: `Tests/GIFproTests/CaptureRegionTests.swift`
- Create: `Tests/GIFproTests/DisplayConfigurationMonitorTests.swift`

- [ ] **Step 1: Write coordinate and validation tests**

Cover a primary display, a display left of the origin, a display above the primary display, Retina 1×/2× output, a 1× external display that rejects 2×, minimum 64×64 pt selection, each resize handle, resize clamping at display edges, and a rectangle crossing display bounds.

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter '(DisplayCoordinateConverter|CaptureRegion)Tests'`

Expected: FAIL because selection models are missing.

- [ ] **Step 3: Implement model and conversion logic**

`CaptureRegion` stores the stable display ID, global AppKit rect, display-local source rect, logical pixel size, output pixel size, and backing scale. Put all origin flipping and scaling in `DisplayCoordinateConverter`; UI code must not duplicate coordinate math.

- [ ] **Step 4: Implement overlays and controls**

Create one borderless transparent `NSPanel` per `NSScreen`, at `.screenSaver` level, without activating the Dock. During drag, accept one panel as owner and ignore other screens. After selection, keep a red border panel with eight resize handles and attach a bottom control panel with:

- 1×/2× picker;
- 8/12/15 FPS picker;
- 15/30/60/90 second picker;
- cursor toggle;
- record and cancel buttons.

Expose callbacks `onSettingsChanged(RecordingSettings)`, `onRecord(CaptureRegion, RecordingSettings)`, and `onCancel()`. The controller owns no recording state.

Make the active overlay panel accept key status while selecting. Override `cancelOperation(_:)` or handle `keyDown` for key code 53 so `Esc` calls `onCancel()` only during selection/countdown. Remove the handler before recording starts; `Esc` must never stop an active recording.

- [ ] **Step 5: Implement and test display-configuration monitoring**

`DisplayConfigurationMonitor` observes `NSApplication.didChangeScreenParametersNotification`, compares the previous and current `CGDirectDisplayID` sets, and reports added/removed IDs. Inject a notification center and screen-ID provider for tests. `SelectionOverlayController` cancels an active selection when any screen change invalidates its panels. Expose removed display IDs to the coordinator so an active recording on that display stops with `.displayDisconnected` and finalizes frames already written.

- [ ] **Step 6: Run tests and manual multi-display check**

Run: `swift test --filter '(DisplayCoordinateConverter|CaptureRegion|DisplayConfigurationMonitor)Tests'`

Expected: PASS. Manually confirm resize handles stay within one display, cross-screen drags are rejected, `Esc` cancels selection but not recording, and control panels stay outside the captured rectangle.

- [ ] **Step 7: Commit**

```bash
git add Sources/GIFpro/Selection Sources/GIFpro/Infrastructure/DisplayConfigurationMonitor.swift Tests/GIFproTests/DisplayCoordinateConverterTests.swift Tests/GIFproTests/CaptureRegionTests.swift Tests/GIFproTests/DisplayConfigurationMonitorTests.swift
git commit -m "feat: add region selection overlay"
```

### Task 8: Implement the ScreenCaptureKit engine

**Files:**
- Create: `Sources/GIFpro/Capture/CapturedFrame.swift`
- Create: `Sources/GIFpro/Capture/CaptureEngine.swift`
- Create: `Tests/GIFproTests/CaptureConfigurationTests.swift`

- [ ] **Step 1: Extract and test configuration mapping**

Given a `CaptureRegion` and settings, verify source rect, output width/height, minimum frame interval, BGRA pixel format, queue depth 3, cursor flag, and audio disabled. Keep this mapping in a pure helper testable without starting `SCStream`.

- [ ] **Step 2: Implement shareable-content lookup and self-exclusion**

Resolve the selected `CGDirectDisplayID` to `SCDisplay`. Find GIFpro's `SCRunningApplication` by process ID and create a content filter that excludes the entire app. Treat a missing display or app entry as a typed error.

- [ ] **Step 3: Implement stream lifecycle**

`CaptureEngine.start(region:settings:onFrame:) async throws` creates the stream, adds a `.screen` output on a dedicated serial queue, then starts capture. The output adapter accepts only complete screen frames and emits `CapturedFrame(pixelBuffer:presentationTime:)`. Forward `SCStreamDelegate` stop/error callbacks as typed capture failures, including display removal. `stop() async` must be safe when called twice.

- [ ] **Step 4: Apply backpressure at the callback boundary**

Acquire a permit before handing a frame to the processing-and-encoding pipeline. If no permit is available, return from the delegate immediately. The pipeline holds the permit across pixel conversion and the awaited `GIFStreamEncoder.append` call, and releases it only after the encoder's serial context has accepted/written the frame or returned an error. Never release immediately after conversion: that would allow unbounded `CGImage` submissions to queue behind a slow encoder.

- [ ] **Step 5: Run tests and a capture smoke test**

Run: `swift test --filter CaptureConfigurationTests`

Expected: PASS. With permission granted, log timestamps for a five-second selected-region capture and confirm GIFpro's red border is excluded.

- [ ] **Step 6: Commit**

```bash
git add Sources/GIFpro/Capture Tests/GIFproTests/CaptureConfigurationTests.swift
git commit -m "feat: capture bounded region frames with ScreenCaptureKit"
```

### Task 9: Implement frame processing and streaming GIF encoding

**Files:**
- Create: `Sources/GIFpro/Encoding/FrameProcessor.swift`
- Create: `Sources/GIFpro/Encoding/GIFStreamEncoder.swift`
- Create: `Tests/GIFproTests/FrameProcessorTests.swift`
- Create: `Tests/GIFproIntegrationTests/GIFStreamEncoderTests.swift`

- [ ] **Step 1: Write processor tests**

Create a small BGRA `CVPixelBuffer`, process it at 1× and 2×, and assert dimensions and sRGB color space. Keep permit ownership outside `FrameProcessor`; the pipeline coordinator owns release on every success and failure path.

- [ ] **Step 2: Write encoder tests**

Encode three solid frames with timestamps `0.00`, `0.10`, and `0.30`, stop at `0.50`, and verify frame count, infinite loop metadata, per-frame delays near `0.10/0.20/0.20`, and total duration near 0.50 second. Add finalize-failure and double-stop tests. Add a deliberately suspended/slow encoder test: submit more frames than the two-permit capacity and assert that at most two `CGImage` values exist in the processing/encoder path while later capture frames are dropped immediately.

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter '(FrameProcessor|GIFStreamEncoder)Tests'`

Expected: FAIL because both implementations are missing.

- [ ] **Step 4: Implement processing**

Use one reusable `CIContext`. Create a `CIImage` from the pixel buffer, transform only when output size differs, then call `createCGImage` with an sRGB destination color space inside `autoreleasepool`. Return errors; never retain `CVPixelBuffer` after completion.

- [ ] **Step 5: Implement the serial encoder**

The encoder owns the destination, temporary URL, maximum frame count, `FrameTiming`, and one pending `CGImage`. Every public operation hops to one serial execution context. Make `append` async and return only after that serial context has accepted and, when applicable, written the frame; callers keep their processing permit until this return. Set GIF loop count to zero and set both delay keys on each frame. Refuse frames after stop, finalize once, and return the valid temporary URL only when `CGImageDestinationFinalize` succeeds.

- [ ] **Step 6: Run tests and inspect generated GIF metadata**

Run: `swift test --filter '(FrameProcessor|GIFStreamEncoder)Tests'`

Expected: PASS; test cleanup leaves no temporary GIFs.

- [ ] **Step 7: Commit**

```bash
git add Sources/GIFpro/Encoding Tests/GIFproTests/FrameProcessorTests.swift Tests/GIFproIntegrationTests/GIFStreamEncoderTests.swift
git commit -m "feat: stream timestamped frames into GIF"
```

### Task 10: Orchestrate countdown, capture, stopping, and disk protection

**Files:**
- Create: `Sources/GIFpro/Domain/RecordingCoordinator.swift`
- Create: `Sources/GIFpro/App/AppEnvironment.swift`
- Create: `Sources/GIFpro/App/AppLifecycleDelegate.swift`
- Create: `Tests/GIFproTests/RecordingCoordinatorTests.swift`
- Modify: `Sources/GIFpro/App/GIFproApp.swift`
- Modify: `Sources/GIFpro/App/MenuBarContent.swift`
- Modify: `Sources/GIFpro/Selection/SelectionOverlayController.swift`

- [ ] **Step 1: Write coordinator tests with fake services and clock**

Cover permission granted/denied, selection cancellation by button and `Esc`, persisted settings loaded into the overlay, changed settings saved, encoder-initialization failure before countdown with no invalid temp file, 3-2-1 countdown, manual stop, each duration preset, last-ten-second warning, automatic stop within 0.5 second, concurrent stop idempotence, deliberately slow encoding with no more than two in-flight frames, capture failure, display-disconnect finalization, the 1 GB preflight rejection, the 256 MB disk-low stop, startup/termination temp cleanup, and state recovery after failure.

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter RecordingCoordinatorTests`

Expected: FAIL because the coordinator is missing.

- [ ] **Step 3: Implement dependency protocols and coordinator**

Make the coordinator `@MainActor` and observable. Inject clock/sleeper, permissions, selection, capture, processor, encoder factory, temp store, preferences store, display monitor, and preview controller protocols. Load preferences before presenting the overlay. Save validated settings whenever the user changes a control, so the next recording starts with the last-used values. Each recording gets a UUID session token; asynchronous callbacks must match the active token before changing state.

- [ ] **Step 4: Implement timer and shutdown order**

Before countdown, query `TemporaryFileStore` and reject recording unless at least 1 GB is available. Next create the temporary URL and initialize `GIFStreamEncoder`/`CGImageDestination`; only after initialization succeeds may the 3-second countdown begin. Initialization failure deletes any partial file, reports `.encoderInitializationFailed`, and returns to a retryable state without starting `SCStream`. On stop: mark the session stopping, stop `SCStream`, wait for acquired processing permits to drain, finalize at the monotonic stop timestamp, cancel disk/timer tasks, then move to `previewReady`. The first stop reason wins. A disk check runs once per second and triggers `.lowDiskSpace` below 256 MB. A removed target display triggers the same orderly stop, then reports that recording ended early after the valid GIF reaches preview.

- [ ] **Step 5: Wire the real environment and UI**

`AppEnvironment` constructs one instance of each production service. At launch it calls `TemporaryFileStore.cleanupStaleFiles()` before accepting commands. `AppLifecycleDelegate.applicationShouldTerminate(_:)` returns `.terminateLater` when work or unsaved preview data exists, asks the coordinator to stop and discard, then calls `NSApplication.reply(toApplicationShouldTerminate:)`; this guarantees cleanup before normal exit instead of starting asynchronous work from `willTerminate`. Wire the delegate through `@NSApplicationDelegateAdaptor`. The menu, hot key, selection controls, and timer all call coordinator methods. Render countdown and recording elapsed/remaining time in the border/control UI.

- [ ] **Step 6: Run tests and manually verify 15-second recording**

Run:

```bash
swift test --filter RecordingCoordinatorTests
./Scripts/build-app.sh debug
open .build/app/GIFpro.app
```

Expected: stale temp files disappear at launch; last-used settings populate the controls; a simulated sub-1 GB capacity blocks countdown; select, count down, record, stop via `⌥⌘G`, and produce a valid temporary GIF without memory growth.

- [ ] **Step 7: Commit**

```bash
git add Sources/GIFpro/App Sources/GIFpro/Domain Sources/GIFpro/Selection/SelectionOverlayController.swift Tests/GIFproTests/RecordingCoordinatorTests.swift
git commit -m "feat: orchestrate the recording lifecycle"
```

### Task 11: Implement preview, save retry, re-record, and discard

**Files:**
- Create: `Sources/GIFpro/Preview/GIFPreviewView.swift`
- Create: `Sources/GIFpro/Preview/SaveAndPreviewController.swift`
- Create: `Tests/GIFproTests/SaveAndPreviewControllerTests.swift`
- Modify: `Sources/GIFpro/Domain/RecordingCoordinator.swift`

- [ ] **Step 1: Write controller tests using save-panel and Quick Look adapters**

Cover immediate save presentation, successful move, cancel returning to `previewReady`, retry after move failure, re-record deleting temp then selecting, discard deleting temp then idle, and saved-file Quick Look invocation.

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter SaveAndPreviewControllerTests`

Expected: FAIL because preview types are missing.

- [ ] **Step 3: Implement preview UI**

Wrap `QLPreviewView` in `NSViewRepresentable`. Show animated GIF, pixel dimensions, duration, and file size. Buttons are exactly “另存为”“重新录制”“丢弃”. Keep the preview panel alive when `NSSavePanel` returns cancel.

- [ ] **Step 4: Implement save and system Quick Look**

Configure `NSSavePanel` for GIF only with a timestamped default name. Move through `TemporaryFileStore`; never copy then silently retain the temp file. After success, close the internal panel and present the saved URL through `QLPreviewPanel` or the system Quick Look service.

- [ ] **Step 5: Run tests and manual cancellation matrix**

Run: `swift test --filter SaveAndPreviewControllerTests`

Expected: PASS. Manually test save, cancel-save-save, cancel-re-record, and cancel-discard.

- [ ] **Step 6: Commit**

```bash
git add Sources/GIFpro/Preview Sources/GIFpro/Domain/RecordingCoordinator.swift Tests/GIFproTests/SaveAndPreviewControllerTests.swift
git commit -m "feat: preview and save recorded GIFs"
```

### Task 12: Complete end-to-end verification and release checks

**Files:**
- Create: `Tests/GIFproIntegrationTests/GIFPipelineTests.swift`
- Create: `docs/manual-test-checklist.md`
- Modify: `Scripts/build-app.sh`
- Modify: `.github/workflows/macos.yml`
- Create: `README.md`

- [ ] **Step 1: Satisfy the macOS 14 release gate**

On macOS 14 hardware, a VM, or CI, run:

```bash
swift test --filter ImageIODestinationCompatibilityTests
swift test
```

Expected: both commands PASS. This result is mandatory before release or any MVP completion claim. The current macOS 27 system has already passed both commands, but that does not count as a macOS 14 result. If either macOS 14 command fails, stop release work and return to the encoding architecture design.

- [ ] **Step 2: Add the synthetic end-to-end test**

Feed generated pixel buffers through processor, timing, and encoder for regular and dropped-frame sequences. Assert output dimensions for a 300×200 pt Retina selection at 1× and 2×, frame count, infinite loop, total duration error ≤0.2 second, and cleanup.

- [ ] **Step 3: Run all automated tests**

Run:

```bash
swift test --parallel
swift build -c release --arch arm64
```

Expected: all tests PASS; release build succeeds.

- [ ] **Step 4: Strengthen release verification**

Make `Scripts/build-app.sh release` fail unless:

- the executable architecture is exactly `arm64`;
- every linked dylib is under `/System/Library` or `/usr/lib`;
- the uncompressed `.app` is below 10 MB;
- `codesign --verify --deep --strict` succeeds;
- `plutil -lint Resources/Info.plist` succeeds.

- [ ] **Step 5: Run the manual acceptance matrix**

Document results for permission grant/deny/recheck, single and mixed-scale displays, cross-screen rejection, 1×/2×, every FPS and duration, cursor on/off, early stop, automatic stop, disk-low simulation, save cancellation paths, display disconnect, and playback in Finder, Quick Look, Safari, and one chat app.

- [ ] **Step 6: Run the 90-second M1-class stress test**

Record 1080p, 1×, 12 FPS for 90 seconds. Use Activity Monitor or `memory_pressure`/`ps` samples to show memory has no monotonic frame-count growth and returns near idle after save. Confirm duration error ≤0.2 second and auto-stop error ≤0.5 second.

- [ ] **Step 7: Build the final local artifact and inspect it**

Run:

```bash
./Scripts/build-app.sh release
codesign --verify --deep --strict .build/app/GIFpro.app
lipo -archs .build/app/GIFpro.app/Contents/MacOS/GIFpro
du -sh .build/app/GIFpro.app
```

Expected: valid signature; `arm64`; size below 10 MB.

- [ ] **Step 8: Update user documentation**

README must state macOS 14+, Apple Silicon only, screen-recording permission steps, `⌥⌘G`, supported settings, build commands, test commands, and the absence of network/telemetry.

- [ ] **Step 9: Commit**

```bash
git add Tests/GIFproIntegrationTests/GIFPipelineTests.swift docs/manual-test-checklist.md Scripts/build-app.sh .github/workflows/macos.yml README.md
git commit -m "test: verify GIFpro MVP release"
```

## Completion checkpoint

Before declaring the MVP complete:

1. `git status --short` is empty.
2. The full test suite passes locally and on macOS 14 hardware, a VM, or CI.
3. The ImageIO compatibility gate passes on macOS 14 hardware, a VM, or CI, in addition to the recorded macOS 27 pass.
4. The manual acceptance checklist contains results, machine model, OS version, and date.
5. The release `.app` is arm64-only, signed, below 10 MB, and contains no third-party dylibs.
6. The implementation matches the approved design spec; deferred features remain absent.
