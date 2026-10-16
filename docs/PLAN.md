# 自在工具箱 Implementation Plan

> Execute using Superpowers workflows. User explicitly approved the session; independent modules may run in parallel with separate file ownership and one integrated review.

**Goal:** Deliver an installable offline Chinese macOS app and DMG with capture, scrolling capture, recording and file utilities.

**Architecture:** Swift executable packaged as a native app. Separate capture, stitch, recording, editing and file modules. Root owns app integration and packaging; independent agents own capture/stitch and recording.

**Tech Stack:** Swift 5 language mode, macOS 15+, AppKit, SwiftUI, ScreenCaptureKit, Vision, AVFoundation, CryptoKit. No downloaded libraries.

**Spec:** DESIGN.md

## Global Constraints
- macOS 15 minimum; current Apple Silicon host is primary target.
- Offline, Chinese UI, no copied original resources, no credentials or network in app.
- Do not modify settings, install extensions or grant permissions automatically.
- All save operations are user-selected or use unique filenames; no silent replacement.
- All implementation files under this project; intermediate outputs under ../ work folders.

## Review Focus
- Screen coordinates across Retina and secondary displays.
- Duplicate, unrelated and low-texture scrolling frames.
- Recording start/stop failure and asynchronous finalization.
- Large images and output bounds.
- Filename collisions and denied filesystem access.

## Task 1 — capture and scrolling (agent)
- [ ] Write failing tests for overlap duplicate, known overlap, unrelated images, size mismatch and negative/retina crop coordinates.
- [ ] Implement CaptureTypes.swift, CaptureService.swift, RegionSelector.swift, ScrollStitcher.swift, ScrollCaptureController.swift.
- [ ] Interfaces: CaptureRegion(displayID: CGDirectDisplayID, rect: CGRect, scale: CGFloat); @MainActor CaptureService.fullScreenRegion() -> CaptureRegion?, chooseRegion() async -> CaptureRegion?, capture(region:) async throws -> CGImage, chooseWindow() async throws -> CGImage?; @MainActor ScrollCaptureController.start(region: CaptureRegion, onComplete: @escaping (CGImage)->Void), cancel().
- [ ] Test core algorithm through swift test; record actual red/green evidence.

## Task 2 — recording (agent)
- [ ] Implement Recorder.swift only and RecordingTests.swift using independent recording state logic tests first.
- [ ] Interfaces: @MainActor final class Recorder: NSObject, ObservableObject; @Published private(set) var isRecording: Bool; @Published private(set) var isBusy: Bool; @Published private(set) var elapsed: TimeInterval; var onFinished: ((URL)->Void)?; var onError: ((String)->Void)?; func start(region: CaptureRegion, to: URL, systemAudio: Bool, microphone: Bool, fps: Int) async throws; func stop() async.
- [ ] ScreenCaptureKit SCRecordingOutput MP4, retain all lifecycles, wait delegate completion, report audio permission failures; keep user output file non-overwrite.

## Task 3 — app, editor and utilities (root)
- [ ] Implement app delegate, menu bar, SwiftUI dashboard, permissions help, hotkeys and document opening.
- [ ] Add EditorWindow with actual annotation rasterization, OCR, clipboard, pin, unique save handling and image import/stitch.
- [ ] Add file utilities and NSServices, test unique paths, rename collision protection and actual image export.
- [ ] Integrate independent modules, run all unit tests and native build.

## Task 4 — package and review
- [ ] Fresh independent review focused on user-visible bugs; fix blockers.
- [ ] Build release .app, app icon, plist, local code signature; verify signed bundle and architecture.
- [ ] Launch and inspect real UI, record constraints on screen/mic/AX testing.
- [ ] Produce DMG, verify contents, package source zip and Chinese README. No public publishing.
