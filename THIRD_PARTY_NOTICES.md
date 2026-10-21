# Stats network speed

Copyright (c) 2019 Serhiy Mytrovtsiy. Source: https://github.com/exelban/stats

Network interface selection, 64-bit NET_RT_IFLIST2 counter reading, counter delta handling, and the two-row menu-bar display in Sources/FreeMouse/NetworkSpeed.swift derive from Stats (MIT). The pinned revision is in ThirdParty/Stats/REVISION. Full license and original readers/display sources are preserved in ThirdParty/Stats. The license is also included in the application bundle and DMG.

Local adaptations: standalone FreeMouse types; actual elapsed-time normalization; zero baseline for the first sample and interface changes; rebaseline after sleep or disconnect; bounded route-message parsing; fixed-width monochrome upload/download arrows with configurable spacing; existing toolbox menu, OCR, and recording indicator integration.

The network popup layout and chart scaling/path/gradient/grid code in NetworkPanel.swift and StatsNetworkCharts.swift adapt Stats Modules/Net/popup.swift and Kit/plugins/Charts.swift. NetworkMonitor.swift and NetworkDetailsReader.swift adapt its process CSV parsing, interface information and public-IP handling. Related original popup/main/Kit files are preserved under ThirdParty/Stats/upstream. FreeMouse provides SwiftUI/AppKit bridging, translated labels, popover lifecycle, bounded process execution, PID delta calculation, persistent totals, permission handling and cancellation. Chart configuration, hover tooltips, animations, unrelated system modules and Stats account/telemetry features are omitted. Network details query public IP and HTTPS connectivity only while the popup is open.

# Capso scrolling capture

Copyright (c) 2026 lzhgus. Source: https://github.com/lzhgus/Capso

The files in Sources/FreeMouse/CapsoScrolling and CapsoUpstream tests derive from Capso, pinned in ThirdParty/Capso/REVISION. They are licensed under Business Source License 1.1, including its Additional Use Grant, not the FreeMouse MIT license. Full terms: ThirdParty/Capso/LICENSE. Original source is preserved in ThirdParty/Capso/upstream.

Local adaptations: namespace and same-module imports; synchronized cancellation; exact display selection; own-process window exclusion; Chinese labels; panel forwarding; safe window-ID conversion; disabled global Return interception; final screenshot on Done; non-modal capture/alignment issue reporting; strict pixel agreement for stationary viewports; deferred sticky-region learning until scrolling; automatic capture and live resize handles with capture restart. FreeMouse supplies the session lifecycle adapter and editor integration. Vision alignment, fixed-region detection and image stitching retain the upstream implementation.

The Additional Use Grant restricts commercial Screen Capture Services; personal/internal use and non-commercial distribution are permitted under the specified terms. Change Date: 2029-04-08, Change License: Apache License 2.0. See the complete license for authoritative terms.
