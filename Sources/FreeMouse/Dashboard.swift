import SwiftUI
import AppKit

struct Dashboard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: Recorder
    @AppStorage(NetworkSpeedMenuPreferences.spacingKey) private var networkIconSpacing = NetworkSpeedMenuPreferences.defaultSpacing
    @AppStorage(NetworkSpeedMenuPreferences.trailingSpacingKey) private var networkTrailingSpacing = NetworkSpeedMenuPreferences.defaultTrailingSpacing
    private let accent = Color.accentColor
    private var actionsUnavailable: Bool { model.busy || recorder.isBusy || recorder.isRecording || model.scrolling }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.33" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                if model.tab == 4 {
                    menuPage
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if model.tab == 0 { capturePage }
                            else if model.tab == 1 { recordingPage }
                            else if model.tab == 2 { filesPage }
                            else { settingsPage }
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                statusBar
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 880, minHeight: 620)
            .onAppear { model.refreshPermissions() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.rays").font(.system(size: 25, weight: .medium)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OmniDesk").font(.system(size: 15, weight: .semibold))
                    Text("Menu Bar Toolkit").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 9).padding(.top, 16).padding(.bottom, 25)
            Text("工具").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 12).padding(.bottom, 5)
            navigation("截图与长图", icon: "viewfinder", index: 0)
            navigation("录屏", icon: "record.circle", index: 1)
            navigation("文件工具", icon: "folder", index: 2)
            Divider().padding(.vertical, 12).padding(.horizontal, 9)
            Text("设置").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 12).padding(.bottom, 5)
            navigation("右键菜单", icon: "cursorarrow.click.2", index: 4)
            navigation("通用设置", icon: "gearshape", index: 3)
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text("版本 \(version)").font(.system(size: 11))
                Text("macOS 15 及以上").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
        }.padding(.horizontal, 12).padding(.vertical, 12).frame(width: 188).frame(maxHeight: .infinity).background(.regularMaterial)
    }
    private func navigation(_ title: String, icon: String, index: Int) -> some View {
        Button { model.tab = index } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: model.tab == index ? .semibold : .regular))
                Spacer(minLength: 0)
            }.padding(.horizontal, 11).padding(.vertical, 10)
                .background(model.tab == index ? accent.opacity(0.13) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(model.tab == index ? accent : Color.primary).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(model.tab == index ? .isSelected : [])
    }
    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(recorder.isRecording ? Color.red : accent).frame(width: 5, height: 5)
                Text(model.status).font(.system(size: 11)).lineLimit(2)
                Spacer(minLength: 8)
                if model.busy || recorder.isBusy { ProgressView().controlSize(.small) }
            }.foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 11)
        }
    }
    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 2)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0, content: content).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
        }
    }
    private func actionRow(_ title: String, detail: String, icon: String, shortcut: String? = nil, button: String = "打开", action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let shortcut { Text(shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary) }
            Button(button, action: action).controlSize(.small).frame(minWidth: 54)
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }
    private var capturePage: some View {
        Group {
            heading("截图与长图", "选择截图方式，完成后可标注、识别文字、复制或保存。")
            if !model.screenAllowed { permissionBanner }
            section("截图") {
                actionRow("区域截图", detail: "拖动选择屏幕区域，Esc 取消", icon: "viewfinder", shortcut: model.shortcuts.bindings[.region]?.display, button: "截图") { model.capture("region") }
                Divider().padding(.leading, 50)
                actionRow("窗口截图", detail: "选择一个应用窗口", icon: "macwindow", shortcut: model.shortcuts.bindings[.window]?.display, button: "截图") { model.capture("window") }
                Divider().padding(.leading, 50)
                actionRow("全屏截图", detail: "截取当前鼠标所在的屏幕", icon: "display", shortcut: model.shortcuts.bindings[.full]?.display, button: "截图") { model.capture("full") }
            }.disabled(actionsUnavailable)
            section("长图") {
                actionRow("滚动长截图", detail: "选取滚动内容区，边滚动边拼接", icon: "rectangle.expand.vertical", shortcut: model.shortcuts.bindings[.scroll]?.display, button: "开始") { model.capture("scroll") }
            }.disabled(actionsUnavailable)
            Text("长截图框选后自动采集；拖动边角调整区域，点击结束截图后编辑或保存。").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, -12)
            section("图片处理") {
                actionRow("截图识字（OCR）", detail: "框选屏幕区域，自动识别中英文，可选择或复制文字", icon: "text.viewfinder", shortcut: model.shortcuts.bindings[.ocr]?.display, button: "识字") { model.capture("ocr") }
                Divider().padding(.leading, 50)
                actionRow("图片编辑", detail: "箭头、方框、文字、遮挡与 OCR", icon: "pencil.and.outline") { model.openImages() }
                Divider().padding(.leading, 50)
                actionRow("多图拼接", detail: "选择多张图片，按顺序纵向合并", icon: "rectangle.stack") { model.openImages(stitch: true) }
            }.disabled(actionsUnavailable)
            recentSection
        }
    }
    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.badge.checkmark").foregroundStyle(.orange)
            Text("截图和录屏需要「屏幕与系统音频录制」权限。").font(.system(size: 11))
            Spacer(minLength: 4)
            Button("去授权") { model.requestScreen() }.controlSize(.small)
        }.padding(12).background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 7))
    }
    private var recordingPage: some View {
        Group {
            heading("录屏", "录制全屏或指定区域，保存为 MP4 视频。")
            if recorder.isRecording {
                section("正在录制") {
                    HStack(spacing: 15) {
                        Image(systemName: "record.circle.fill").font(.system(size: 30)).foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "%02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60)).font(.system(size: 28, weight: .medium, design: .monospaced))
                            Text(model.shortcuts.bindings[.record].map { "也可从菜单栏停止 · " + $0.display } ?? "也可从菜单栏停止").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("停止并保存") { model.stopRecording() }.buttonStyle(.borderedProminent).tint(.red)
                    }.padding(18)
                }
            } else {
                if !model.screenAllowed { permissionBanner }
                section("录制选项") {
                    preferenceRow("系统声音", detail: "同时录制应用播放的声音") { Toggle("系统声音", isOn: $model.systemAudio).labelsHidden() }
                    Divider().padding(.leading, 14)
                    preferenceRow("麦克风", detail: "首次开启时需要麦克风权限") { Toggle("麦克风", isOn: $model.microphone).labelsHidden() }
                    Divider()
                    preferenceRow("摄像头小窗", detail: "小方框可在录制区域内拖动，画面一起保存到视频") { Toggle("摄像头小窗", isOn: $model.cameraEnabled).labelsHidden() }
                    Divider().padding(.leading, 14)
                    preferenceRow("帧率", detail: "较高帧率适合动态画面") {
                        Picker("帧率", selection: $model.fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }.labelsHidden().frame(width: 115)
                    }
                    Divider().padding(.leading, 14)
                    preferenceRow("开始前倒计时", detail: "留出切换应用和准备的时间") {
                        Picker("倒计时", selection: $model.countdown) { Text("无").tag(0); Text("3 秒").tag(3); Text("5 秒").tag(5) }.labelsHidden().frame(width: 115)
                    }
                }.disabled(model.busy || recorder.isBusy || model.scrolling)
                HStack(spacing: 10) {
                    Button { model.startRecording(fullScreen: false) } label: { Label("录制选定区域…", systemImage: "viewfinder") }.buttonStyle(.borderedProminent)
                    Button { model.startRecording(fullScreen: true) } label: { Label("录制全屏…", systemImage: "display") }
                }.disabled(model.busy || recorder.isBusy || model.scrolling)
                Text("选择保存位置后开始倒计时。录屏时将隐藏本应用的控制窗口，仅摄像头小窗会录入视频；按住小窗拖动即可调整位置。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            recentSection
        }
    }
    private func preferenceRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            control().controlSize(.small)
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }
    private var filesPage: some View {
        Group {
            heading("文件工具", "选择文件或文件夹，再使用下方工具。更多操作可从工具菜单打开。")
            section("当前选择") {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.selectedFiles.isEmpty ? "尚未选择文件" : "已选择 \(model.selectedFiles.count) 项").font(.system(size: 13, weight: .medium))
                        Text(model.selectedFiles.isEmpty ? "支持同时选择多个项目" : model.selectedFiles.prefix(3).map(\.lastPathComponent).joined(separator: "、") + (model.selectedFiles.count > 3 ? " 等" : "")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button("选择项目…") { model.chooseFiles() }.controlSize(.small)
                }.padding(14)
            }
            section("文件操作") {
                actionRow("复制路径", detail: "将完整路径复制到剪贴板", icon: "doc.on.clipboard", button: "复制") { model.copyPaths() }
                Divider().padding(.leading, 50)
                actionRow("复制名称", detail: "批量复制所选文件的名称", icon: "textformat", button: "复制") { model.copyPaths(namesOnly: true) }
                Divider().padding(.leading, 50)
                actionRow("批量重命名", detail: "预览后添加文件名前缀", icon: "character.cursor.ibeam") { model.renameFiles() }
                Divider().padding(.leading, 50)
                actionRow("SHA-256", detail: "计算并复制文件校验值", icon: "number", button: "计算") { model.hashFiles() }
                Divider().padding(.leading, 50)
                actionRow("打开终端", detail: "进入所选文件或文件夹所在目录", icon: "terminal") { model.openTerminal() }
            }.disabled(actionsUnavailable)
            section("新建") {
                actionRow("新建文件夹", detail: "同名时自动编号", icon: "folder.badge.plus", button: "新建") { model.createFile(folder: true) }
                Divider().padding(.leading, 50)
                actionRow("新建文本", detail: "创建空白 TXT 文稿", icon: "doc.badge.plus", button: "新建") { model.createFile() }
                Divider().padding(.leading, 50)
                actionRow("新建 Markdown", detail: "创建带标题的 Markdown 文稿", icon: "text.alignleft", button: "新建") { model.createFile(markdown: true) }
            }.disabled(actionsUnavailable)
            section("图片转换") {
                actionRow("转为 PNG", detail: "生成新图片，保留原图", icon: "photo", button: "转换") { model.convertImages(jpeg: false) }
                Divider().padding(.leading, 50)
                actionRow("转为 JPEG", detail: "生成高质量压缩图片", icon: "photo.on.rectangle", button: "转换") { model.convertImages(jpeg: true) }
            }.disabled(actionsUnavailable)
            HStack(spacing: 10) {
                Button("打开全部工具…") { model.contextTools.showMenu() }.buttonStyle(.borderedProminent).disabled(actionsUnavailable)
                Button("常用目录…") { model.favoriteDirectories() }
                Spacer()
                Button("配置右键菜单") { model.contextTools.settings() }
            }
        }
    }
    private var menuPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("右键菜单", "勾选要显示的工具，选中一行后调整顺序。修改会自动保存。")
            MenuConfigurationPane(owner: model.contextTools, scopeSelection: $model.menuSettingsScope).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(24)
    }
    private var settingsPage: some View {
        Group {
            heading("通用设置", "调整工具行为，并查看各项功能需要的系统权限。")
            section("菜单栏") {
                preferenceRow("图标与网速间距", detail: "0–20 点，修改即时生效并自动保存。") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { NetworkSpeedMenuPreferences.spacing(from: NSNumber(value: networkIconSpacing)) },
                            set: { networkIconSpacing = $0 }
                        ), in: 0...20, step: 1).frame(width: 130)
                        Text("\(Int(NetworkSpeedMenuPreferences.spacing(from: NSNumber(value: networkIconSpacing)))) 点")
                            .monospacedDigit().frame(width: 38)
                        Button("恢复默认") { networkIconSpacing = NetworkSpeedMenuPreferences.defaultSpacing }
                    }
                }
                Divider().padding(.leading, 14)
                preferenceRow("网速右侧留白", detail: "0–12 点，控制本图标与右侧图标之间的额外留白。") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { NetworkSpeedMenuPreferences.trailingSpacing(from: NSNumber(value: networkTrailingSpacing)) },
                            set: { networkTrailingSpacing = $0 }
                        ), in: 0...12, step: 1).frame(width: 130)
                        Text("\(Int(NetworkSpeedMenuPreferences.trailingSpacing(from: NSNumber(value: networkTrailingSpacing)))) 点")
                            .monospacedDigit().frame(width: 38)
                        Button("恢复默认") { networkTrailingSpacing = NetworkSpeedMenuPreferences.defaultTrailingSpacing }
                    }
                }
            }.onChange(of: networkIconSpacing) { _, _ in model.onMenuBarAppearanceChange?() }
                .onChange(of: networkTrailingSpacing) { _, _ in model.onMenuBarAppearanceChange?() }
            section("工具行为") { GeneralPreferencesPane(owner: model.contextTools).frame(height: 269) }
            section("快捷键") { ShortcutSettingsPane(settings: model.shortcuts) }
            section("系统权限") {
                permissionRow("屏幕与系统音频录制", detail: "截图、长截图和录屏需要", granted: model.screenAllowed) { model.requestScreen() }
                Divider().padding(.leading, 14)
                permissionRow("辅助功能", detail: "独立鼠标菜单需要", granted: model.accessibilityAllowed) { model.requestAccessibility() }
                Divider().padding(.leading, 14)
                preferenceRow("麦克风", detail: "在录屏中开启麦克风时按需申请") { Button("系统设置") { model.openSettings("Privacy_Microphone") } }
                Divider()
                preferenceRow("摄像头", detail: "在录屏中开启摄像头小窗时按需申请") { Button("系统设置") { model.openSettings("Privacy_Camera") } }
            }
            HStack {
                Button("刷新权限状态") { model.refreshPermissions() }
                Spacer()
                Button("配置右键菜单") { model.contextTools.settings() }
            }
            section("使用提示") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("首次授权后若仍无法采集屏幕，请退出并重新打开应用。")
                    Text("关闭控制窗口后，工具仍驻留菜单栏。⌘Q 退出应用。")
                    Text("OCR 在本机识别中英文。截图可添加箭头、方框、文字和遮挡。")
                    Text("独立开发的免费工具，不包含原软件的代码或素材。当前构建未签名和公证。")
                }.font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
    }
    private func permissionRow(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        preferenceRow(title, detail: detail) {
            if granted { Label("已允许", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green) }
            else { Button("去授权", action: action) }
        }
    }
    private var recentSection: some View {
        section("本次会话的文件") {
            if model.recent.isEmpty {
                HStack {
                    Image(systemName: "clock").foregroundStyle(.tertiary)
                    Text("保存后的截图和录屏会显示在这里。").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }.padding(14)
            }
            ForEach(model.recent.prefix(4), id: \.self) { url in
                HStack(spacing: 10) {
                    Image(systemName: url.pathExtension == "mp4" ? "film" : "photo").foregroundStyle(accent).frame(width: 20)
                    Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }
}
