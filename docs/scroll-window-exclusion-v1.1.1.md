# Scroll capture overlay exclusion diagnosis

## Evidence

The user's 1955 × 6980 screenshot contains the blue selection border and repeated FreeMouse control-panel title. Those overlays must not enter any accepted capture frame. Current code excludes applications only by the current PID. The controller creates and orders border, preview, and control panels before starting the native stream, so a later-created panel is not the cause in this path.

The local macOS SDK `SCStream.h` explicitly documents:

- `SCContentFilter(display:excludingApplications:exceptingWindows:)` captures applications outside the excluded set; windows in `exceptingWindows` that belong to an excluded application are *included again*.
- `SCContentFilter(display:excludingWindows:)` excludes those exact window objects from the display.

Therefore the original `exceptingWindows: []` was semantically correct. Filling it with current-app windows would introduce a new bug. The screenshot alone cannot establish why the original system application filter failed. Missing application metadata, ownerless panels, or a second copy of the bundle are defensible cases to handle without guessing the OS implementation.

Primary sources:

- https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingapplications:exceptingwindows:)
- https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingwindows:)
- `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ScreenCaptureKit.framework/Headers/SCStream.h`
- `SCShareableContent.h`: `SCWindow.owningApplication` is nullable; `windowID` is its `CGWindowID`; `onScreenWindowsOnly` controls visible-only filtering.

## Implementation

`ScrollFrameSource.swift` now requests the complete shareable-window inventory and explicitly excludes windows matching any of:

1. The current PID.
2. The same nonempty bundle ID, covering another running copy.
3. A known `NSApp.windows.windowNumber`, even without owning-application metadata.

No other app titles, paths, window identities, or contents are logged. One setup log records only the current-app entry count, own-window-ID count, and excluded-window count. Panels are stable throughout capture, so an immutable explicit window filter matches their current lifecycle. Future code that creates additional overlays during active capture must update the content filter.

## Verification

`ScrollWindowExclusionTests` first used the old PID-only strategy. Compilation succeeded and two behavioral assertions failed: missing owner metadata for a known panel, and a second bundle instance. Red log: `work/scroll-window-exclusion-red.log`.

After the implementation, all 3 exclusion tests plus all 3 existing latest-frame-buffer tests passed, with exit code 0. Green log: `work/scroll-window-exclusion-green.log`.

Native screen capture was not exercised by these tests. They prove the selection policy and existing buffer lifetimes, not that a particular macOS release renders every excluded panel correctly. The root task owns live capture verification and final delivery.
