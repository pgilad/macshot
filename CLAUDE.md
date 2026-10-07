# macshot

Native macOS screenshot and annotation tool. Swift + AppKit, built with SwiftPM and the Command Line Tools. This is a fork of sw33tLie/macshot that keeps the screenshot tool and removes screen recording, the video editor, uploads, OCR translation, Sparkle, rich-text clipboard pins, WebP, localization and all third-party packages.

## Project setup

- **Language:** Swift 6.2 toolchain in the Swift 6 language mode, `defaultIsolation(MainActor.self)` and the upcoming features listed in `Package.swift`.
- **UI:** AppKit. Every window is created in code. SwiftUI is used only by `BeautifyRenderer` for `MeshGradient` + `ImageRenderer`.
- **Target:** macOS 26 and later, tested on 27. Do not add `#available` checks for older releases.
- **Bundle ID:** `com.pgilad.macshot`.
- **Sandbox:** on, with no network entitlement. Entitlements are in `Resources/macshot.entitlements`: user-selected files read-write, app-scope bookmarks, and the `com.apple.axserver` mach-lookup exception for the Accessibility API. Do not add `network.client`; nothing in the app may make network requests.
- **LSUIElement:** YES (menu bar app; switches to `.regular` while editor windows are open).
- **Permissions:** Screen Recording. Accessibility only for scroll capture auto-scroll and element snapping.
- **Dependencies:** none. Apple frameworks only: AppKit, ScreenCaptureKit, Vision, CoreImage, ImageIO, Carbon (hotkeys), ServiceManagement (launch at login).

## Build, run and test

```fish
make test               # Swift Testing, one test at a time
make app                # release build, assembled and signed in build/macshot.app
make install            # make app, then replace /Applications/macshot.app and start it
make signing-identity   # once per Mac: a local certificate so permissions survive rebuilds
swift build             # debug build only
```

- `scripts/bundle.sh` builds the release binary, fills the `Resources/Info.plist` template (`__VERSION__` from `VERSION`, `__BUILD__` from the commit count, `__COMMIT__`), converts `Resources/AppIcon.iconset` with `iconutil`, copies the PNG resources and signs with the hardened runtime. Without the "macshot Local Signing" identity it signs ad-hoc, and macOS forgets the Screen Recording permission after each rebuild.
- Resources are plain files in `Resources/`, copied into the bundle by `scripts/bundle.sh`. Load them with `NSImage(named:)`. There is no asset catalog and no SwiftPM resource bundle.
- The tests import the app with `@testable import macshot`. They run headless: no Screen Recording permission and no window server dependency. `make test` passes `--no-parallel`, because the tests share `UserDefaults.standard` and the pasteboard.
- CI (`.github/workflows/ci.yaml`) runs `make test` and `make dist` on macOS 26 (Xcode 26.6) and macOS 27. Actions are pinned to commits.

## Architecture

Menu bar agent app. No main window. A global hotkey (default ⇧⌘X) or the menu bar menu triggers screen capture → full-screen overlay per display → selection → annotation → output.

### File structure

```
Sources/macshot/
├── main.swift                          # Entry point
├── AppDelegate.swift                   # Lifecycle, status item, hotkeys, capture orchestration, URL scheme
├── Capture/
│   ├── ScreenCaptureManager.swift      # ScreenCaptureKit capture: displays, windows
│   ├── ScrollCaptureController.swift   # Scroll capture session: frame grabs, Vision offsets, stitching
│   ├── ScrollFrameAnalyzer.swift       # Pure pixel comparison: frozen header + scrollbar detection
│   └── SafeNumerics.swift              # Clamped numeric conversions for persisted values
├── Model/
│   ├── Annotation.swift                # Annotation data model + drawing for all tools
│   ├── AnnotationCodable.swift         # CodableAnnotation + AnnotationSerializer
│   ├── CaptureEditState.swift          # Beautify/effects state saved with a capture
│   ├── LenientDecoding.swift           # Backward/forward-compatible Codable helpers
│   └── SavedCaptureValidation.swift    # Bounds checks for saved captures and sidecars
├── Services/                           # Encoding, saving, history, OCR, redaction, shortcuts, settings
└── UI/
    ├── Overlay/                        # OverlayView (canvas) and its OverlayView+Feature.swift extensions, OverlayWindowController, scroll capture HUD
    ├── Editor/                         # EditorView, DetachedEditorWindowController, top bar, centering clip view
    ├── Toolbar/                        # Toolbar definitions, button/strip views, tool options row
    ├── Tools/                          # AnnotationToolHandler implementations, TextEditingController
    ├── Popover/                        # PopoverHelper and pickers (color, emoji, font, gradient, effects, lists)
    └── Windows/                        # Settings, history overlay, floating thumbnail, pin, OCR result, onboarding, toasts
```

### AppDelegate

- `NSStatusItem` menu: capture commands, recent captures, settings, quit.
- Registers global hotkeys through `HotkeyManager` (Carbon `RegisterEventHotKey`). Only Capture Area has a default (⇧⌘X); the other slots are empty by default so macshot does not take common app shortcuts.
- On capture: `ScreenCaptureManager.captureAllScreensImmediately` captures the display under the pointer first, then the others, one at a time. Each display's pooled `OverlayWindowController` shows as soon as its capture lands. A display that cannot be captured gets no overlay.
- Implements `OverlayWindowControllerDelegate` (confirm, cancel, pin, OCR, scroll capture, delay).
- `handleOpenURLs` handles `macshot://` URLs only when the user turned on `urlSchemeEnabled` (default off). Actions may only start an interactive capture or open Settings. Never add an action that saves, copies, shows captures or reads a path from the URL.

### Capture

- macOS 26 rect screenshots (`SCScreenshotManager.captureScreenshot(rect:)`) first; displays it misses are captured through an `SCContentFilter` with fresh shareable content. `CGWindowListCreateImage` is unavailable at this target; do not try to reach it.
- ScreenCaptureKit takes CoreGraphics display coordinates (top-left origin of the primary display); `NSScreen` frames are AppKit coordinates (bottom-left origin). Convert explicitly.
- Window capture uses `SCContentFilter(desktopIndependentWindow:)`.
- Scroll capture grabs frames with `SCScreenshotManager.captureImage` through a filter that excludes macshot's own windows, waits for two identical frames, measures the scroll offset with `VNTranslationalImageRegistrationRequest` and stitches incrementally.

### OverlayView — the main interaction surface

The core canvas view. Handles the selection state machine, annotation rendering, input routing and toolbar positioning. Tool-specific creation/update/finish logic is delegated to `AnnotationToolHandler` implementations in `UI/Tools/`.

**Files:** `OverlayView.swift` has the stored state, setup, the subclass override points and `reset()`. Each feature is an extension file: `+Drawing`, `+Mouse`, `+Keyboard`, `+Cursor` (cursors and hit testing), `+Selection` (finish, resize and boundary snap), `+ResolutionBox` (size box, presets, locked aspect ratio), `+Toolbar` (layout, actions and the tool options API), `+Annotations` (creation, text, copy and paste, undo and redo, layer cache), `+AnnotationControls`, `+Canvas` (editor transforms, zoom, coordinate transforms, output), `+Guides` (snap guides, auto measure), `+Beautify`, `+Popovers` and `+WindowSnapping`. Stored properties stay in `OverlayView.swift`. A method that `EditorView` or a test overrides must be in the class body: Swift cannot override a method declared in an extension.

**State machine:** `idle` → `selecting` → `selected`

**Zoom:** 0.1x–8x (minimum 1.0x in the overlay), scroll/pinch to zoom, pan while zoomed.

**Toolbars:** real NSView-based strips (`ToolbarStripView` + `ToolbarButtonView`) positioned by OverlayView. Tool options are in `ToolOptionsRowView` with real NSSlider/NSSegmentedControl/NSButton controls. Popovers use `NSPopover` via `PopoverHelper`.

**Editor mode:** `EditorView` is an `OverlayView` subclass that overrides behavior through override points and lives in an NSScrollView. Use the `isEditorMode` computed property.

**CRITICAL — overlay vs editor coordinate rules:**
- **Never use `bounds` for image-to-pixel mapping.** Always use `captureDrawRect` (returns `bounds` in the overlay, `selectionRect` in the editor).
- **Never use raw view-space points for annotation positions.** Always convert via `viewToCanvas()` first.
- **Never call `viewToCanvas()` on a point that is already in canvas space.** `startAnnotation(at:)` receives canvas-space points.
- **When positioning NSViews (e.g. the text tool's NSTextView),** convert canvas coordinates back with `canvasToView()`.
- **`compositedImage()`** renders at `captureDrawRect.size`, not `bounds.size`.
- **`sourceImageBounds`** for pixelate/blur/loupe must be `captureDrawRect`, not `bounds`.
- **For Vision region crops** (OCR, barcode, auto-redact), draw the screenshot at `captureDrawRect` size.
- **Cursor management** is imperative (no cursor rects) via `updateCursorForPoint()` + `mouseMoved`. Each window sets cursors only while the mouse is over it.

### Tool handler architecture

Each annotation tool's start/update/finish logic is an `AnnotationToolHandler`. OverlayView dispatches through `toolHandlers[currentTool]`. `AnnotationCanvas` is the interface handlers use to reach OverlayView state; `TextEditingCanvas` adds coordinate transforms for `TextEditingController`. Not extracted: `select`, `colorSampler`, `crop` and text start/click detection. New tools implement `AnnotationToolHandler`; do not add switch cases to OverlayView.

### Annotation

Class (not struct) with `clone()` for safe copies. `AnnotationTool` has 18 cases with explicit `Int` raw values. The raw values are persisted (history annotations, `enabledTools`, `knownToolRawValues`, `lastUsedTool`): never change one, and never reuse 14 (the removed translate overlay). Each annotation draws itself (`draw(in:)`) and supports `hitTest`, `move`, `boundingRect` and `drawSelectionHighlight()`.

**When adding a property to Annotation, update four places:** the declaration, `clone()`, `CodableAnnotation` in `AnnotationCodable.swift` (struct field, `toCodable`, `fromCodable`, and a line in its `init(from:)`), and the census in `Tests/macshotTests/AnnotationPersistenceTests.swift`. The compiler won't catch a missing field; the census test will.

Other persisted raw values: `ToolbarCustomAction` tags 1001, 1008 and 1009 and hotkey slots 3 and 4 belonged to removed features; do not reuse them.

### Undo/redo

`UndoEntry`: `.added(Annotation)`, `.deleted(Annotation, Int)`, `.imageTransform(...)`. Stacks `undoStack` / `redoStack`. Batch undo via `groupID` (auto-redact creates several annotations with one group ID).

**CRITICAL — transient `NSTextView` undo ownership:** `UndoManager` keeps undo targets unowned. A disposable editable `NSTextView` that uses the window's undo manager can leave entries pointing at a deallocated view, and the next ⌘Z crashes in `_NSUndoStack popAndInvoke`. Every editable app-created text view with `allowsUndo = true` must use `ScopedUndoTextView` (or a subclass). Call `discardUndoHistory()` before releasing an editing session.

### Detached editor

Opens from the overlay ("Open in Editor"), the thumbnail, a pin or history. NSScrollView → CenteringClipView → EditorView. `chromeParentView` is set before `applySelection` so toolbars go in the container. A static `activeControllers` array keeps instances alive and switches the activation policy.

### Protocols

```
OverlayWindowControllerDelegate  — OverlayWindowController → AppDelegate
OverlayViewDelegate              — OverlayView → OverlayWindowController / DetachedEditorWindowController
PinWindowControllerDelegate      — PinWindowController → AppDelegate
AnnotationToolHandler            — tool creation/update/finish
AnnotationCanvas                 — OverlayView state for tool handlers
TextEditingCanvas                — coordinate transforms + annotation storage for TextEditingController
```

### Threading

- Capture: displays one at a time (on macOS 26 `replayd` serializes concurrent screenshot requests and charges more per queued request).
- Scroll capture: async frame grabs; `isCapturing` serializes capture-and-compare.
- OCR: Vision on a detached task, results to the main actor.
- Saving and history writes: background queues; completions on the main actor.
- UI: all drawing, state and input on the main thread.

## Coding conventions

- **Use proper AppKit components:** NSPopover, NSView subclasses for toolbar buttons and strips, NSSlider/NSSegmentedControl/NSButton, NSScrollView for editor zoom, NSTextView for text. Avoid reimplementing standard controls with `draw()` and manual hit testing.
- **Concurrency:** everything is on the main actor unless it says otherwise. Work that runs on another thread must be `nonisolated` and take only `Sendable` values. SwiftUI rendering stays `@MainActor`.
  - In the Swift 6 mode every main-actor closure checks at run time that it runs on the main thread, and stops the app if not. A closure that a framework can call on another thread must not be main-actor: make it `@Sendable` or `nonisolated`. NSImage drawing handlers run on the thread that draws the image, so draw such images on the main thread only.
  - `Timer` blocks and `NSAnimationContext` completion handlers are `@Sendable` but run on the main thread: enter the main actor with `MainActor.assumeIsolated`, and use the stored timer, not the block parameter, inside it.
- `[weak self]` in escaping closures. Minimal allocations during mouse tracking. Tear down overlay windows and images promptly after capture (`autoreleasepool` for overlay teardown).
- UserDefaults for all preferences.
- Extension files (`OverlayView+Feature.swift`) for self-contained features that need OverlayView state.
- **No network.** Do not add URLSession, WebKit or any other network client, and do not add the network entitlement.
- **No third-party packages.**
- **Persisted models decode leniently.** Swift's synthesized `init(from:)` requires a key for every non-optional property even when it has a default, so a new field breaks every older file. Any `Codable` type written to disk or UserDefaults needs a hand-written `init(from:)` using `decode(_:or:)` / `decodeOptional(_:)` from `Model/LenientDecoding.swift`, and arrays decode through `LenientArrayDecoder`. This applies to `CodableAnnotation`, `CaptureEditState`, `ScreenshotHistory.IndexEntry`, and anything new.
- **History cleanup is conservative.** Missing or salvaged indexes do not establish orphanhood. `HistoryFileCleanup` only reclaims old unreferenced thumbnails/previews using a captured cutoff. Index identifiers must be UUIDs, extensions recognized image types, and duplicate rows are removed before retention.
- **History writes are transactions.** `HistoryImageSnapshot` owns composited/raw pixels and serialized annotations before enqueueing. `HistoryStorage` serializes saves, deletion and retention; a new immutable revision becomes current only after atomic index publication. Quit drains pending history writes.
- **Redacted pixels never reach history.** A capture with a redaction annotation (pixelate, blur, filled rectangle) is stored flattened only, without `raw.png`, so it reopens without editable annotations.
- **Reopen editable history as a unit.** Use `loadEditableCapture`; if a sidecar or annotation cannot be restored, open the flattened capture rather than raw pixels with an omitted annotation. `SavedCaptureValidation` bounds saved settings and canvas geometry. See `docs/history-recovery.md`.
- **History queues retain a bounded amount of snapshot data** (512 MiB and 32 pending saves by default). Report saturation through the failed-save completion; never silently drop a queued capture.
- **Screenshot clipboard is image data only.** Never put a file URL on the pasteboard for a screenshot (sandbox paths break Teams, Photopea and RDP clients). PNG and TIFF are always present; the opt-in configured format is added first, never instead.
- **Clipboard pins read plain text only.** Do not parse RTF, RTFD or HTML from the pasteboard.
- **Editor saves keep their original state.** Capture the image, cloned annotations, edit state and editor revision together before showing a save panel or starting an asynchronous output.
- **Filename components are sanitized one by one** with `FilenameSanitizer`. Template expansion is one pass. A `/` in a template creates subfolders (`FilenameFormatter.formatRelativePath`); empty, `.` and `..` components are dropped, and `ImageSaveService.createSubfolders` only creates folders below an existing save folder. Slashes inside token values never create folders.
- **Report failures the user can't otherwise see.** `ImageSaveService.onFailure` is wired to `AppDelegate.showFailureToast(_:)` (an `ErrorToastController`). Never swallow a lost capture into an ignored `false`.
- **Saves outlive their windows.** Image saves run as `MediaExportCoordinator` jobs and publish through `AtomicMediaSave`. `ApplicationTerminationCoordinator` keeps the event loop running while saves and history writes drain, then retries Quit.
- **Keyboard shortcuts:** character-based commands go through `KeyboardShortcutMatcher`; do not compare raw letter key codes or read `charactersIgnoringModifiers`. Use `EditorCommandShortcutManager` for undo/redo chords and `ToolShortcutManager` for single-key tools. Raw `event.keyCode` checks are only for layout-independent keys (Escape, Return, Tab, Space, Delete, arrows, function keys). Global Carbon hotkeys stay physical key-code bindings; translate them only for display with `KeyboardShortcutMatcher.currentLayoutCharacter(for:)`.
- **Light/dark mode:** the toolbar and popovers always use a dark background. `ToolOptionsRowView` and `PopoverHelper` force `NSAppearance(named: .darkAqua)`. Do not use system-adaptive label colors in toolbar/popover contexts without checking contrast.
- **English only.** UI strings are plain string literals.
- **Focus management:** all focus return goes through `AppDelegate.returnFocusIfNeeded()`.
  - `previousApp` is captured in `startCapture()` before the overlay steals focus and cleared after one use.
  - `returnFocusIfNeeded()` checks for visible titled windows, switches to `.accessory`, and activates `previousApp` (or the frontmost non-macshot app). It does not call `NSApp.hide(nil)`, which can suspend the Carbon event loop and break global hotkeys.
  - `dismissOverlays(refocusPreviousApp: false)` only when a floating panel is created right after (pin, OCR window). Save `previousApp` first, create the panel, then activate the saved app.
  - Every window close (editor, OCR, settings) calls `returnFocusIfNeeded()`.
  - Floating panels set `hidesOnDeactivate = false`. Pin windows use `orderFrontRegardless()`.

## Tests

- `Tests/macshotTests/TestSupport.swift`: `withDefaults` (isolated UserDefaults, sync and async), `ImageProbe` (scale-independent fixture images and pixel probes — never build fixtures with `lockFocus`), `TestKeyEvent` (synthesized `NSEvent`s), `Reflect`/`FieldDescriber`, and `TestExpectation` with `fulfillment(of:timeout:)` for callback-based APIs.
- Swift Testing runs main-actor tests as main-actor jobs, so spinning the run loop does not let main-queue work run. Await instead (`fulfillment(of:)`, `Task.sleep`).
- `#require` cannot call a mutating method or contain another `#require`; take the value first.
- Logic worth testing that is buried in a permission-gated class should be extracted (see `ScrollFrameAnalyzer`).

## Releasing

Not set up. Build from source with `make install`. `make dist` produces `build/macshot-<version>-arm64.zip` with a SHA-256 file.
