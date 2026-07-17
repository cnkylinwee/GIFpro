# Selection and Recording Controls Visual Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace GIFpro's selection handles, record control, and recording stop control with the approved scalable border and automatically tinted attachment styles.

**Architecture:** Keep geometry and visual code inside the existing Selection module. Add one injectable template-image loader, make the selection border vector-based, and keep recording controls in narrow auxiliary panels so the full-screen overlay remains mouse-transparent. The build script imports only repository resources into the App bundle and verifies byte identity.

**Tech Stack:** Swift 6-compatible AppKit, XCTest, ImageIO-backed PNG validation, POSIX shell release packaging, native macOS template images.

---

## File map

- Create `Sources/GIFpro/Selection/TemplateControlImageLoader.swift`: exact resource names, template conversion, dynamic fallback images, and injectable directory loading.
- Modify `Sources/GIFpro/Selection/SelectionOverlayView.swift`: vector selection style constants, handle layout/hit testing, image-only record button, and removal of inline stop drawing.
- Modify `Sources/GIFpro/Selection/SelectionOverlayController.swift`: collision-free auxiliary layout, template stop button, one-shot action generation, and panel cleanup.
- Modify `Scripts/build-app.sh`: copy and compare the two repository PNG resources.
- Create `Resources/RecordButton.png` and `Resources/StopButton.png`: one-time imports from the user attachments.
- Create `docs/assets/SelectionBorderReference.png`: committed visual reference only; never copied into the App.
- Create `Tests/GIFproTests/TemplateControlImageLoaderTests.swift`: resource, template, and fallback tests.
- Modify `Tests/GIFproTests/SelectionControlPanelTests.swift`: button, accessibility, keyboard, panel layout, mouse policy, and one-shot tests.
- Create `Tests/GIFproTests/SelectionOverlayStyleTests.swift`: vector constants, eight handle frames, expanded hit targets, and redraw state tests.
- Modify `Tests/ScriptTests/BuildAppReleaseChecksTests.sh`: bundle resource and byte-identity checks.
- Modify `docs/manual-test-checklist.md` and `docs/release-verification.md`: record the new local visual/build checks without changing existing external PENDING gates.

### Task 1: Import resources and add the template-image loader

**Files:**
- Create: `Resources/RecordButton.png`
- Create: `Resources/StopButton.png`
- Create: `docs/assets/SelectionBorderReference.png`
- Create: `Sources/GIFpro/Selection/TemplateControlImageLoader.swift`
- Create: `Tests/GIFproTests/TemplateControlImageLoaderTests.swift`

- [ ] **Step 1: Import the approved attachments once**

Copy without conversion so the committed bytes match the attachments:

```bash
ditto /Users/wdychn/Downloads/录制按钮.png Resources/RecordButton.png
ditto /Users/wdychn/Downloads/停止按钮.png Resources/StopButton.png
mkdir -p docs/assets
ditto /Users/wdychn/Downloads/边框.png docs/assets/SelectionBorderReference.png
cmp /Users/wdychn/Downloads/录制按钮.png Resources/RecordButton.png
cmp /Users/wdychn/Downloads/停止按钮.png Resources/StopButton.png
```

Expected: every command exits 0. Downloads are never referenced after this step.

- [ ] **Step 2: Write failing loader tests**

Test these public-internal contracts:

```swift
func testRepositoryRecordAndStopImagesLoadAsTemplates() throws {
    let loader = TemplateControlImageLoader(resourceDirectory: repositoryResources)
    let record = try XCTUnwrap(loader.image(for: .record))
    let stop = try XCTUnwrap(loader.image(for: .stop))
    XCTAssertTrue(record.isTemplate)
    XCTAssertTrue(stop.isTemplate)
}

func testMissingResourcesReturnNamedFallbacks() {
    let loader = TemplateControlImageLoader(resourceDirectory: emptyDirectory)
    XCTAssertEqual(loader.load(.record).source, .systemSymbol("record.circle"))
    XCTAssertEqual(loader.load(.stop).source, .systemSymbol("stop.circle.fill"))
}
```

Also assert exact filenames `RecordButton.png` and `StopButton.png`; reject a corrupt non-image file; keep the returned image 24×24 point and template-enabled.

- [ ] **Step 3: Run the loader tests to verify RED**

Run:

```bash
swift test --filter TemplateControlImageLoaderTests
```

Expected: FAIL because the loader types do not exist.

- [ ] **Step 4: Implement the narrow loader**

Use one enum and one result type so production and tests share exact names:

```swift
enum TemplateControlImageAsset: CaseIterable {
    case record, stop

    var resourceName: String { self == .record ? "RecordButton" : "StopButton" }
    var fallbackSymbolName: String { self == .record ? "record.circle" : "stop.circle.fill" }
}

struct LoadedTemplateImage {
    enum Source: Equatable { case bundlePNG, systemSymbol(String), vectorFallback }
    let image: NSImage
    let source: Source
}
```

`TemplateControlImageLoader` accepts either `Bundle.main.resourceURL` or an injected directory URL. It loads by exact URL, copies the image, sets `isTemplate = true`, and sets size to 24×24. Missing/corrupt PNGs log an error, then use the named system symbol; if that also fails, draw a 24×24 vector record/stop fallback. No branch traps in Debug.

- [ ] **Step 5: Run loader and full selection tests**

Run:

```bash
swift test --filter TemplateControlImageLoaderTests
swift test --filter SelectionControlPanelTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Resources/RecordButton.png Resources/StopButton.png docs/assets/SelectionBorderReference.png Sources/GIFpro/Selection/TemplateControlImageLoader.swift Tests/GIFproTests/TemplateControlImageLoaderTests.swift
git commit -m "feat: add template recording control assets"
```

### Task 2: Recreate the selection border and handles as vectors

**Files:**
- Modify: `Sources/GIFpro/Selection/SelectionOverlayView.swift`
- Create: `Tests/GIFproTests/SelectionOverlayStyleTests.swift`
- Modify: `Tests/GIFproTests/SelectionControlPanelTests.swift`

- [ ] **Step 1: Write failing style and hit-target tests**

Introduce testable geometry without exposing mutable view state:

```swift
XCTAssertEqual(SelectionOverlayStyle.borderWidth, 2)
XCTAssertEqual(SelectionOverlayStyle.visibleHandleSize, CGSize(width: 10, height: 10))
XCTAssertEqual(SelectionOverlayStyle.handleHitSize, CGSize(width: 16, height: 16))

for handle in ResizeHandle.allCases {
    XCTAssertEqual(style.handleFrame(for: handle, in: selection).size, .init(width: 10, height: 10))
    XCTAssertEqual(style.handleHitFrame(for: handle, in: selection).size, .init(width: 16, height: 16))
}
```

Send synthetic mouse events at every handle center and just inside the expanded hit edge. Assert the existing resize result. Send an event inside the selection away from handles and assert it begins a new selection rather than moving the old selection.

- [ ] **Step 2: Run the tests to verify RED**

Run:

```bash
swift test --filter SelectionOverlayStyleTests
```

Expected: FAIL because `SelectionOverlayStyle` and testable handle geometry do not exist.

- [ ] **Step 3: Implement the vector style**

Add immutable constants and pure frame helpers. In `draw(_:)`:

- Use `NSColor.controlAccentColor` and a 2 point border while `showsHandles == true`.
- Draw each 10×10 handle as a rounded rectangle with radius 2, window-background fill, 2 point accent stroke.
- Use `NSColor.systemRed` for the recording border when handles are hidden.
- Expand only hit testing to 16×16; keep the visible shape 10×10.
- Preserve handle-first hit priority and the existing new-selection behavior elsewhere.
- Override appearance-change notification to set `needsDisplay = true`.

Remove inline stop-control hit testing and drawing from this full-screen view. The independent stop panel becomes the only stop UI.

- [ ] **Step 4: Run style, geometry, and coordinate tests**

Run:

```bash
swift test --filter SelectionOverlayStyleTests
swift test --filter CaptureRegionTests
swift test --filter DisplayCoordinateConverterTests
```

Expected: PASS with all eight directions unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/GIFpro/Selection/SelectionOverlayView.swift Tests/GIFproTests/SelectionOverlayStyleTests.swift Tests/GIFproTests/SelectionControlPanelTests.swift
git commit -m "feat: draw scalable selection handles"
```

### Task 3: Replace the record text button with the template image

**Files:**
- Modify: `Sources/GIFpro/Selection/SelectionOverlayView.swift`
- Modify: `Tests/GIFproTests/SelectionControlPanelTests.swift`

- [ ] **Step 1: Write failing record-button tests**

Inject `TemplateControlImageLoading` into `SelectionControlsView`. Locate the record button through a stable accessibility identifier, not its title. Assert:

```swift
XCTAssertEqual(button.title, "")
XCTAssertEqual(button.frame.size, CGSize(width: 44, height: 44))
XCTAssertEqual(button.image?.size, CGSize(width: 24, height: 24))
XCTAssertEqual(button.contentTintColor, .controlAccentColor)
XCTAssertEqual(button.keyEquivalent, "\r")
XCTAssertEqual(button.toolTip, "开始录制")
XCTAssertEqual(button.accessibilityLabel(), "开始录制")
```

Verify enabled/disabled tint, keyboard invocation, press action, and fallback-loader invocation.

- [ ] **Step 2: Run the control tests to verify RED**

Run:

```bash
swift test --filter SelectionControlPanelTests
```

Expected: FAIL because the current button title is `Record` and has no image contract.

- [ ] **Step 3: Implement the image-only record button**

Create a 44×44 borderless `NSButton`, assign the 24×24 template image, proportional scaling, dynamic accent tint, identifier, Tooltip, accessibility role/label, target/action, and Return key equivalent. Keep the existing `recordPressed` flow. Update tint when enabled state or effective appearance changes.

- [ ] **Step 4: Run control and coordinator tests**

Run:

```bash
swift test --filter SelectionControlPanelTests
swift test --filter RecordingCoordinatorTests
```

Expected: PASS; record activation still enters countdown.

- [ ] **Step 5: Commit**

```bash
git add Sources/GIFpro/Selection/SelectionOverlayView.swift Tests/GIFproTests/SelectionControlPanelTests.swift
git commit -m "feat: use the template record control"
```

### Task 4: Build the collision-free one-shot stop panel

**Files:**
- Modify: `Sources/GIFpro/Selection/SelectionOverlayController.swift`
- Modify: `Sources/GIFpro/Selection/SelectionOverlayView.swift`
- Modify: `Tests/GIFproTests/SelectionControlPanelTests.swift`

- [ ] **Step 1: Write failing layout boundary tests**

Parameterize selections at the center, four edges, four corners, and 64×64 minimum size. Cover visible frames exactly 152×44, 44×80, 140×60, and 40×40. Assert:

- horizontal or vertical status/stop frames never intersect;
- every displayed frame is inside `visibleFrame`;
- 140×60 uses stop-only mode with a full 44×44 stop frame;
- 40×40 reports the defensive error mode and does not create a clipped stop panel.

- [ ] **Step 2: Write failing one-shot and lifecycle tests**

Use an injectable action target or harness. Invoke mouse/action twice, accessibility press twice, and mixed mouse then accessibility activation. Assert `callbackCount == 1`. Start a replacement recording and invoke the old target; assert the new callback count stays zero. Verify the lifecycle table for selecting, countdown, recording, stopping, and dismiss.

- [ ] **Step 3: Run the panel tests to verify RED**

Run:

```bash
swift test --filter SelectionControlPanelTests
```

Expected: FAIL because the current layout uses overlapping 58×30 text controls and has no one-shot target.

- [ ] **Step 4: Implement pure layout modes**

Make `RecordingOverlayPanelLayout` expose optional status/stop frames plus a mode (`horizontal`, `vertical`, `stopOnly`, `unavailable`). Use 28 point status height, 100...220 desired width, 44×44 stop size, and 8 point gap. Apply the approved below/above/clamped priority and the two defensive modes.

- [ ] **Step 5: Implement the image-only one-shot stop control**

Load `.stop`, create a 44×44 borderless image-only button, use `systemRed`, and set Tooltip/accessibility metadata. Route every `NSButton` action—including accessibility press—through one `OneShotActionTarget`. On first activation, invalidate the target, disable the button, close and clear `stopPanel`, then call the coordinator callback. Invalidate the target on stopping, dismiss, display invalidation, and before installing a replacement.

Do not draw a stop title or button in `SelectionOverlayView`. Keep the status label in the separate mouse-transparent status panel. Keep the full-screen red border mouse-transparent.

- [ ] **Step 6: Run panel, overlay, and coordinator tests**

Run:

```bash
swift test --filter SelectionControlPanelTests
swift test --filter SelectionOverlayStyleTests
swift test --filter RecordingCoordinatorTests
```

Expected: PASS; UI callback and capture stop each occur once.

- [ ] **Step 7: Commit**

```bash
git add Sources/GIFpro/Selection/SelectionOverlayController.swift Sources/GIFpro/Selection/SelectionOverlayView.swift Tests/GIFproTests/SelectionControlPanelTests.swift
git commit -m "fix: use a one-shot template stop control"
```

### Task 5: Package resources and verify the visual release

**Files:**
- Modify: `Scripts/build-app.sh`
- Modify: `Tests/ScriptTests/BuildAppReleaseChecksTests.sh`
- Modify: `docs/manual-test-checklist.md`
- Modify: `docs/release-verification.md`

- [ ] **Step 1: Write failing packaging checks**

Extend the shell regression to assert the built files exist and match repository bytes:

```sh
cmp "$project_root/Resources/RecordButton.png" "$app_bundle/Contents/Resources/RecordButton.png"
cmp "$project_root/Resources/StopButton.png" "$app_bundle/Contents/Resources/StopButton.png"
```

Add a fixture that temporarily points the script at a missing/corrupt repository resource and assert a unique nonzero diagnostic. Restore the resource through `trap`; never mutate the user's Downloads files.

- [ ] **Step 2: Run the shell test to verify RED**

Run:

```bash
/bin/sh Tests/ScriptTests/BuildAppReleaseChecksTests.sh
```

Expected: FAIL because the App bundle has no `Contents/Resources` button images.

- [ ] **Step 3: Copy and verify repository resources in the build script**

Before signing, create `Contents/Resources`, copy the exact two PNGs from repository `Resources`, and use `cmp` to fail closed on missing or changed output. Do not read `/Users/wdychn/Downloads`. Keep all existing plist, arm64, dylib, size, and codesign checks.

- [ ] **Step 4: Run automated verification**

Run:

```bash
/bin/sh -n Scripts/build-app.sh Tests/ScriptTests/BuildAppReleaseChecksTests.sh
/bin/sh Tests/ScriptTests/BuildAppReleaseChecksTests.sh
swift test --parallel
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
./Scripts/build-app.sh release
lipo -archs .build/app/GIFpro.app/Contents/MacOS/GIFpro
du -sh .build/app/GIFpro.app
codesign --verify --deep --strict .build/app/GIFpro.app
```

Expected: all tests pass; architecture is exactly `arm64`; App remains below 10 MB; signature is valid; both PNGs match repository bytes.

- [ ] **Step 5: Run focused manual visual checks**

Open the App in light and dark appearance. Verify:

- all eight handles resize a 64×64, wide, tall, and full-screen-adjacent selection;
- record icon follows the accent color and Return starts countdown;
- the stop icon has no text overlap;
- double-clicking stop triggers one stop;
- the area outside the 44×44 stop button remains mouse-transparent while recording.

Record only checks actually performed. Keep macOS 14, mixed-display, chat playback, and 90-second stress gates PENDING unless run in the required environment.

- [ ] **Step 6: Update verification documents**

Record the exact test counts, App byte size, architecture, current OS, date, and manual results. Do not convert existing external PENDING items to PASS.

- [ ] **Step 7: Commit**

```bash
git add Scripts/build-app.sh Tests/ScriptTests/BuildAppReleaseChecksTests.sh docs/manual-test-checklist.md docs/release-verification.md
git commit -m "test: verify recording control visuals"
```

## Completion checkpoint

- [ ] `git status --short` is empty.
- [ ] Focused selection/control tests pass.
- [ ] Full parallel and strict-concurrency suites pass.
- [ ] Release contains byte-identical record/stop assets, is arm64-only, signed, system-library-only, and below 10 MB.
- [ ] Record and stop controls have no text titles and expose complete keyboard/accessibility behavior.
- [ ] Recording overlay remains mouse-transparent outside the 44×44 stop control.
- [ ] Existing macOS 14 and manual release gates retain their prior status.
