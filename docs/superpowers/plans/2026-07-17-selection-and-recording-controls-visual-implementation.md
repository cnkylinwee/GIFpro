# Selection and Recording Controls Visual Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace GIFpro's selection handles, record control, and recording stop control with the approved scalable border and automatically tinted attachment styles.

**Architecture:** Keep geometry and presentation inside the Selection module. Add an injectable ImageIO-validating resource loader and a shared template-button subclass, draw the selection border as vectors, and make auxiliary-panel layout and lifecycle testable without real displays. The hand-built App bundle copies only committed repository assets and verifies them before signing.

**Tech Stack:** Swift/AppKit, ImageIO, XCTest, POSIX shell, native macOS template images.

---

## File map

- Create `Sources/GIFpro/Selection/TemplateControlImageLoader.swift`: asset constants, resource locators, ImageIO validation, symbol provider, and vector fallback.
- Create `Sources/GIFpro/Selection/TemplateControlButton.swift`: fixed sizing, tint states, accessibility-friendly image-only button behavior.
- Create `Sources/GIFpro/Selection/RecordingOverlayPresentation.swift`: pure layout modes, lifecycle policy/snapshot, one-shot generation target, and test seams.
- Modify `Sources/GIFpro/Selection/SelectionOverlayView.swift`: vector selection border/handles and image-only record button; remove all inline status/stop UI.
- Modify `Sources/GIFpro/Selection/SelectionOverlayController.swift`: injected loader/environment, status/stop panels, generation invalidation, and lifecycle snapshot.
- Create `Scripts/validate-control-assets.sh`: fail-closed PNG decoding checks shared by packaging tests and the build.
- Modify `Scripts/build-app.sh`: copy repository PNGs, compare bytes, then preserve all current release gates.
- Create `Resources/RecordButton.png`, `Resources/StopButton.png`, and `docs/assets/SelectionBorderReference.png` from the three approved attachments.
- Create `Tests/GIFproTests/TemplateControlImageLoaderTests.swift` and `Tests/GIFproTests/SelectionOverlayStyleTests.swift`.
- Modify `Tests/GIFproTests/SelectionControlPanelTests.swift`, `Tests/GIFproTests/RecordingCoordinatorTests.swift`, `Tests/GIFproTests/MenuBarContentTests.swift`, and `Tests/ScriptTests/BuildAppReleaseChecksTests.sh`.
- Modify `docs/manual-test-checklist.md` and `docs/release-verification.md` with only checks actually run.

### Task 1: Import and validate the approved assets

**Files:**
- Create: `Resources/RecordButton.png`
- Create: `Resources/StopButton.png`
- Create: `docs/assets/SelectionBorderReference.png`
- Create: `Sources/GIFpro/Selection/TemplateControlImageLoader.swift`
- Create: `Tests/GIFproTests/TemplateControlImageLoaderTests.swift`

- [ ] **Step 1: Import the attachments once and verify exact bytes**

```bash
ditto /Users/wdychn/Downloads/录制按钮.png Resources/RecordButton.png
ditto /Users/wdychn/Downloads/停止按钮.png Resources/StopButton.png
mkdir -p docs/assets
ditto /Users/wdychn/Downloads/边框.png docs/assets/SelectionBorderReference.png
cmp /Users/wdychn/Downloads/录制按钮.png Resources/RecordButton.png
cmp /Users/wdychn/Downloads/停止按钮.png Resources/StopButton.png
cmp /Users/wdychn/Downloads/边框.png docs/assets/SelectionBorderReference.png
```

Expected: all commands exit 0. No later build or test may read Downloads.

- [ ] **Step 2: Write failing loader tests**

Define tests around protocols before the concrete loader:

```swift
protocol TemplateControlImageLoading {
    func load(_ asset: TemplateControlImageAsset) -> LoadedTemplateImage
}

protocol TemplateControlImageResourceLocating {
    func url(for asset: TemplateControlImageAsset) -> URL?
}

protocol TemplateControlSymbolProviding {
    func image(named symbolName: String) -> NSImage?
}
```

Test exact names `RecordButton.png` and `StopButton.png`; production `BundleResourceLocator` must call `bundle.url(forResource:withExtension:)`; `DirectoryResourceLocator` must append the same constants. Test a valid repository PNG, missing file, corrupt bytes, named-symbol fallback, and a forced nil symbol provider that reaches vector fallback. Assert each result is 24×24 and `isTemplate == true`.

- [ ] **Step 3: Run tests and verify RED**

```bash
swift test --filter TemplateControlImageLoaderTests
```

Expected: FAIL because the protocols and loader do not exist.

- [ ] **Step 4: Implement exact lookup, decoding, and fallback**

Use `CGImageSourceCreateWithURL` plus `CGImageSourceCreateImageAtIndex` to reject corrupt or undecodable PNGs before creating the `NSImage`. Return a copied 24×24 template image. Missing/corrupt resources log once, then try `record.circle` or `stop.circle.fill`; a missing symbol uses a vector circle+dot or circle+square. Debug and Release both remain usable.

Production construction uses:

```swift
TemplateControlImageLoader(
    locator: BundleResourceLocator(bundle: .main),
    symbols: AppKitTemplateControlSymbolProvider()
)
```

- [ ] **Step 5: Run focused tests and commit**

```bash
swift test --filter TemplateControlImageLoaderTests
git add Resources/RecordButton.png Resources/StopButton.png docs/assets/SelectionBorderReference.png Sources/GIFpro/Selection/TemplateControlImageLoader.swift Tests/GIFproTests/TemplateControlImageLoaderTests.swift
git commit -m "feat: add validated recording control assets"
```

Expected: loader tests PASS; commit succeeds.

### Task 2: Draw the scalable selection border and remove duplicate inline UI

**Files:**
- Modify: `Sources/GIFpro/Selection/SelectionOverlayView.swift`
- Modify: `Sources/GIFpro/Selection/SelectionOverlayController.swift`
- Create: `Tests/GIFproTests/SelectionOverlayStyleTests.swift`
- Modify: `Tests/GIFproTests/SelectionControlPanelTests.swift`

- [ ] **Step 1: Write failing style, hit, and redraw tests**

Create a pure configuration that tests can inspect:

```swift
struct SelectionOverlayStyle: Equatable {
    static let borderWidth: CGFloat = 2
    static let visibleHandleSize = CGSize(width: 10, height: 10)
    static let handleHitSize = CGSize(width: 16, height: 16)
    static let handleCornerRadius: CGFloat = 2
    let borderRole: BorderRole // .selectionAccent or .recordingRed
    let handleFillRole: HandleFillRole // .windowBackground
}
```

Assert all eight visible and hit frames, corner-before-edge priority, 2 point stroke, radius 2, and window-background fill. Synthetic mouse events at every handle center and hit-edge must resize. An interior non-handle drag must start a new selection, never move it. Test `viewDidChangeEffectiveAppearance()` and `NSColor.systemColorsDidChangeNotification` through an injectable redraw observer; both set `needsDisplay`. Test selecting resolves accent role and recording resolves red role in light and dark appearances.

- [ ] **Step 2: Run and verify RED**

```bash
swift test --filter SelectionOverlayStyleTests
```

Expected: FAIL because the style and redraw observer do not exist.

- [ ] **Step 3: Implement vector drawing and color invalidation**

Use 2 point accent border plus 10×10 rounded-square handles in selecting. Use 16×16 hit frames. When handles are hidden, draw only the existing 2 point `systemRed` recording border. Override `viewDidChangeEffectiveAppearance()` and observe `NSColor.systemColorsDidChangeNotification`; remove the observer on deinit.

Delete the duplicate inline UI from `SelectionOverlayView`:

- `onStop`, `statusText`, `statusIsWarning`, `showsStopControl`;
- inline stop hit testing;
- `showCountdown`, `showRecording`, `updateRecordingStatus`, `showStopping`;
- `drawStatus`, `statusRect`, and `stopControlRect`.

Delete the corresponding controller calls. The separate status panel becomes the only countdown/recording/stopping text; the separate stop panel becomes the only stop control. Replace `testOverlayStatusMovesFromCountdownToRecordingAndStopping` with auxiliary-panel lifecycle assertions.

- [ ] **Step 4: Run focused regression tests and commit**

```bash
swift test --filter SelectionOverlayStyleTests
swift test --filter SelectionControlPanelTests
swift test --filter CaptureRegionTests
swift test --filter DisplayCoordinateConverterTests
git add Sources/GIFpro/Selection/SelectionOverlayView.swift Sources/GIFpro/Selection/SelectionOverlayController.swift Tests/GIFproTests/SelectionOverlayStyleTests.swift Tests/GIFproTests/SelectionControlPanelTests.swift
git commit -m "feat: draw scalable selection handles"
```

Expected: all focused tests PASS.

### Task 3: Add a shared template button and replace Record

**Files:**
- Create: `Sources/GIFpro/Selection/TemplateControlButton.swift`
- Modify: `Sources/GIFpro/Selection/SelectionOverlayView.swift`
- Modify: `Sources/GIFpro/Selection/SelectionOverlayController.swift`
- Modify: `Tests/GIFproTests/SelectionControlPanelTests.swift`

- [ ] **Step 1: Write failing shared-button state tests**

Test a `TemplateControlButton` with injected image and semantic tint (`.accent` or `.destructive`). It must install explicit width/height constraints of 44, use a 24×24 image, `.imageOnly`, `.scaleProportionallyDown`, empty title, and borderless style. Inspect a testable `resolvedVisualState`:

- normal: dynamic accent or red at alpha 1.0;
- highlighted: the same semantic color at alpha 0.75;
- disabled: `disabledControlTextColor`;
- light/dark `effectiveAppearance`: semantic colors resolve again and request redraw.

Do not assume a stock borderless `NSButton` supplies the 75% highlight.

- [ ] **Step 2: Run and verify RED**

```bash
swift test --filter SelectionControlPanelTests
```

Expected: FAIL because the shared button does not exist and Record still has a title.

- [ ] **Step 3: Implement `TemplateControlButton`**

Centralize sizing, image scaling, `highlight(_:)`, `isEnabled`, and `viewDidChangeEffectiveAppearance()`. Reapply `contentTintColor` from the semantic state and expose only immutable test snapshots. Keep AppKit's button role and normal target/action path.

- [ ] **Step 4: Replace Record with an injected template control**

Inject one `TemplateControlImageLoading` into `SelectionOverlayController` through every initializer, with the production loader as the default. Pass that shared loader into each `SelectionControlsView`. Create a `.record` `TemplateControlButton`, accessibility identifier `gifpro.record`, empty title, Tooltip/label “开始录制”, press action, and Return key equivalent. Keep the existing `recordPressed` callback and enabled behavior. Because the stack uses Auto Layout, rely on the button's explicit 44×44 constraints rather than setting frame only. Task 4 reuses this controller-owned loader for Stop rather than adding another default path.

- [ ] **Step 5: Run focused tests and commit**

```bash
swift test --filter SelectionControlPanelTests
swift test --filter RecordingCoordinatorTests
git add Sources/GIFpro/Selection/TemplateControlButton.swift Sources/GIFpro/Selection/SelectionOverlayView.swift Sources/GIFpro/Selection/SelectionOverlayController.swift Tests/GIFproTests/SelectionControlPanelTests.swift
git commit -m "feat: use the template record control"
```

Expected: Record has no title, all visual states pass, Return still starts countdown.

### Task 4: Build deterministic panel layout, lifecycle, and one-shot Stop

**Files:**
- Create: `Sources/GIFpro/Selection/RecordingOverlayPresentation.swift`
- Modify: `Sources/GIFpro/Selection/SelectionOverlayController.swift`
- Modify: `Tests/GIFproTests/SelectionControlPanelTests.swift`
- Modify: `Tests/GIFproTests/RecordingCoordinatorTests.swift`
- Modify: `Tests/GIFproTests/MenuBarContentTests.swift`

- [ ] **Step 1: Write failing pure layout tests**

The layout input explicitly distinguishes `.statusOnly` and `.recording`. The output contains optional frames plus one mode: `statusOnly`, `horizontal`, `vertical`, `stopOnly`, or `unavailable`.

Use exact expected frames for negative-origin visible frames, center, four edges, four corners, 64×64 selections, and the thresholds 152×44, 44×80, 140×60, and 40×40. Assert below/above/clamp order. `140×60` must be stop-only. `<44×44` must emit one injected error and return unavailable. For unavailable recording layout, assert the coordinator remains `.recording` and `recordingCommandTitle == "停止录制"`; `MenuBarContentTests` verifies the menu command uses that title. Do not move command-title ownership into `MenuBarPresentation`, which only owns failure/warning issues.

- [ ] **Step 2: Write failing lifecycle and generation tests**

Create a pure `RecordingOverlayLifecycle` with state (`hidden`, `selecting`, `countingDown`, `recording`, `stopping`) and an internal snapshot describing owner/non-owner overlays, control/status/stop panels, `ignoresMouseEvents`, and current generation. Controller methods update this model before applying window commands.

Test every transition, non-owner closure, display invalidation, dismiss/cancel, and replacement recording. `OneShotActionTarget` stores both a monotonic generation and `fired`; it verifies the controller's current generation before firing. Exercise real `NSButton.performClick(nil)`, `accessibilityPerformPress()`, repeated accessibility presses, mixed mouse/action then accessibility, and a retained stale target. Stop remains nonactivating and never becomes key.

Update the recording fake to retain `onStop`. Trigger it repeatedly and assert `FakeCapture.stopCount == 1`, proving the UI callback and coordinator stop both remain one-shot.

- [ ] **Step 3: Run and verify RED**

```bash
swift test --filter SelectionControlPanelTests
swift test --filter RecordingCoordinatorTests
swift test --filter MenuBarContentTests
```

Expected: FAIL because the pure layout/lifecycle and generated target do not exist.

- [ ] **Step 4: Add deterministic environment seams**

Define focused protocols/value types:

```swift
protocol SelectionOverlayEnvironment {
    var displays: [OverlayDisplayDescriptor] { get }
    func makeSelectionPanel(for display: OverlayDisplayDescriptor) -> SelectionOverlayPanel
    func makeAuxiliaryPanel(frame: CGRect, contentView: NSView) -> NSPanel
}
```

Production adapts `NSScreen`; tests provide display descriptors and fake panel records without querying `NSScreen.screens`. Expose an internal read-only lifecycle snapshot for tests. Inject one `TemplateControlImageLoading` instance into the controller and pass it to both Record and Stop controls.

- [ ] **Step 5: Implement layout, lifecycle, and one-shot Stop**

Implement the approved layout modes. Install a 44×44 `.stop` `TemplateControlButton` with red semantic tint, Tooltip/label “停止录制”, button role, and press action. The first valid mouse or AX activation invalidates the target, disables the button, closes/clears the stop panel, and invokes the callback. Stopping, display loss, dismiss, and replacement all advance generation and invalidate old targets. Full-screen/status panels keep `ignoresMouseEvents = true`; only the 44×44 stop panel receives mouse events.

- [ ] **Step 6: Run focused tests and commit**

```bash
swift test --filter SelectionControlPanelTests
swift test --filter RecordingCoordinatorTests
swift test --filter MenuBarContentTests
git add Sources/GIFpro/Selection/RecordingOverlayPresentation.swift Sources/GIFpro/Selection/SelectionOverlayController.swift Tests/GIFproTests/SelectionControlPanelTests.swift Tests/GIFproTests/RecordingCoordinatorTests.swift Tests/GIFproTests/MenuBarContentTests.swift
git commit -m "fix: use a one-shot template stop control"
```

Expected: all layout, lifecycle, AX, stale-generation, mouse policy, and downstream stop tests PASS.

### Task 5: Package assets fail-closed and verify the App

**Files:**
- Create: `Scripts/validate-control-assets.sh`
- Modify: `Scripts/build-app.sh`
- Modify: `Tests/ScriptTests/BuildAppReleaseChecksTests.sh`
- Modify: `docs/manual-test-checklist.md`
- Modify: `docs/release-verification.md`

- [ ] **Step 1: Write failing isolated validator tests**

The validator accepts an explicit resource directory, checks both exact names, and uses `/usr/bin/sips` to decode each file and require format `png`. Test valid, missing, and corrupt files in a temporary fixture; assert unique diagnostics. This does not rename or mutate repository resources and is safe under interruption and parallel runs.

- [ ] **Step 2: Write failing Debug and Release bundle tests**

Run `build-app.sh debug` and `build-app.sh release`. For both, assert the two bundle files exist and `cmp` equal the repository files. For Release, retain arm64, dylib, codesign, plist, and below-10-MB assertions. The shell test must also run the validator fixture; it must not depend on Downloads.

- [ ] **Step 3: Run and verify RED**

```bash
/bin/sh Tests/ScriptTests/BuildAppReleaseChecksTests.sh
```

Expected: FAIL because no bundle resources or validator exist.

- [ ] **Step 4: Implement fail-closed validation and packaging**

`build-app.sh` calls the validator on repository `Resources`, creates `Contents/Resources`, copies the exact two PNGs, and uses `cmp` before codesign. A corrupt PNG must fail before copy; changed output must fail after copy. Keep every existing release gate.

- [ ] **Step 5: Run complete automated verification**

```bash
/bin/sh -n Scripts/validate-control-assets.sh Scripts/build-app.sh Tests/ScriptTests/BuildAppReleaseChecksTests.sh
/bin/sh Tests/ScriptTests/BuildAppReleaseChecksTests.sh
swift test --parallel
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test --filter ImageIODestinationCompatibilityTests
./Scripts/build-app.sh release
lipo -archs .build/app/GIFpro.app/Contents/MacOS/GIFpro
du -sh .build/app/GIFpro.app
codesign --verify --deep --strict .build/app/GIFpro.app
cmp Resources/RecordButton.png .build/app/GIFpro.app/Contents/Resources/RecordButton.png
cmp Resources/StopButton.png .build/app/GIFpro.app/Contents/Resources/StopButton.png
git diff --check
git status --short
```

Expected: all tests pass, status is clean, App is arm64-only, signed, system-library-only, below 10 MB, and contains byte-identical assets.

- [ ] **Step 6: Run and record manual checks**

In light and dark appearance, verify eight-handle resizing at minimum/wide/tall/edge selections, accent recoloring, Return activation for Record, image-only Stop without overlap, one-shot double activation, and mouse passthrough outside Stop. Record only executed checks. Preserve macOS 14, mixed-display, chat playback, and 90-second stress PENDING gates.

- [ ] **Step 7: Commit**

```bash
git add Scripts/validate-control-assets.sh Scripts/build-app.sh Tests/ScriptTests/BuildAppReleaseChecksTests.sh docs/manual-test-checklist.md docs/release-verification.md
git commit -m "test: verify recording control visuals"
```

## Completion checkpoint

- [ ] Selection overlay contains no inline countdown/status/stop drawing.
- [ ] Record and Stop use committed template assets, exact semantic tints, 44×44 controls, 24×24 images, and complete accessibility metadata.
- [ ] Record retains Return; Stop remains nonactivating and one-shot for mouse and AX activation.
- [ ] Layout and lifecycle tests cover status-only, horizontal, vertical, stop-only, unavailable, display loss, dismiss, and stale generation.
- [ ] Debug and Release bundles contain validated, byte-identical PNGs.
- [ ] Full parallel, strict-concurrency, ImageIO, shell, release, diff, and status checks pass.
- [ ] Existing external release gates retain their prior status.
