# Capso scrolling capture

Copyright (c) 2026 lzhgus. Source: https://github.com/lzhgus/Capso

The files in Sources/FreeMouse/CapsoScrolling and CapsoUpstream tests derive from Capso, pinned in ThirdParty/Capso/REVISION. They are licensed under Business Source License 1.1, including its Additional Use Grant, not the FreeMouse MIT license. Full terms: ThirdParty/Capso/LICENSE. Original source is preserved in ThirdParty/Capso/upstream.

Local adaptations: namespace and same-module imports; synchronized cancellation; exact display selection; own-process window exclusion; Chinese labels; panel forwarding; safe window-ID conversion; disabled global Return interception; final screenshot on Done; capture/alignment issue reporting and incomplete-tail confirmation; strict pixel agreement for stationary viewports; deferred sticky-region learning until scrolling. FreeMouse supplies the session lifecycle adapter and editor integration. Vision alignment, fixed-region detection and image stitching retain the upstream implementation.

The Additional Use Grant restricts commercial Screen Capture Services; personal/internal use and non-commercial distribution are permitted under the specified terms. Change Date: 2029-04-08, Change License: Apache License 2.0. See the complete license for authoritative terms.
