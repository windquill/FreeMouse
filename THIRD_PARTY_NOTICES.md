# Stats SMC fan control adaptation

`Sources/FanHelper/SMC.swift` incorporates the Stats SMC implementation from
`https://github.com/exelban/stats/blob/master/SMC/smc.swift`, retrieved on
2026-10-21. It remains under the Stats MIT license included at
`ThirdParty/Stats/LICENSE` and in the application resources as `Stats-LICENSE.txt`.
OmniDesk adds checked fan-only reads/writes, zero-RPM decoding, readback validation
and automatic restoration. The on-demand helper protocol and menu interface are
OmniDesk adaptations; no Stats privileged service is installed.

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

# libarchive system integration

OmniDesk dynamically links the libarchive.2 library supplied with macOS for archive creation and extraction. Public API headers archive.h and archive_entry.h are pinned to upstream v3.7.4: https://github.com/libarchive/libarchive/tree/v3.7.4 . Copies and the upstream COPYING notice are in ThirdParty/libarchive. The upstream library implementation is not bundled or copied into OmniDesk; supported codecs depend on the macOS system build. OmniDesk supplies its own C bridge, metadata exclusion, private staging, exclusive publishing, path checks and UI integration. The system-library backend does not install external codecs. OmniDesk 1.1.33 adds the separately bundled engines described below. RAR creation is not supported; encrypted/multipart variants are limited by the bundled engine and validation coverage.

# 7-Zip bundled console engine

OmniDesk includes the unmodified official macOS 7-Zip 26.04 console engine from https://github.com/ip7z/7zip/releases/tag/26.04 . The original binary and license are under ThirdParty/7zip; PROVENANCE.json records origin and SHA256. Its corresponding source distribution 7z2604-src.tar.xz is included in the source package and app Resources/ArchiveTools. Binary copies are ad-hoc signed during packaging. 7-Zip is primarily LGPL 2.1 or later, with BSD-licensed portions and the unRAR restriction; full terms are reproduced in ThirdParty/7zip/License.txt and packaged with the engine. See https://www.7-zip.org/ for source and project information. OmniDesk invokes the separate executable under mandatory filesystem write isolation; it does not implement RAR creation.

# Zstandard and LZ4

Zstandard source is pinned to v1.5.7 from https://github.com/facebook/zstd/tree/v1.5.7 . It is used under its BSD license (ThirdParty/zstd/LICENSE); the alternate GPLv2 COPYING is retained for provenance. Build-only module map changes are described in ThirdParty/zstd/PATCHES.md. LZ4 library source is pinned to v1.10.0 from https://github.com/lz4/lz4/tree/v1.10.0 and used under the BSD 2-clause license (ThirdParty/lz4/lib/LICENSE). Only library C sources are linked, not the GPL command-line programs. All retained notices accompany source and binary distributions.
