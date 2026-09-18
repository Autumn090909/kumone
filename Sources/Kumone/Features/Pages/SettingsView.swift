import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    #if os(macOS)
    @ObservedObject private var downloader = StemModelDownloader.shared
    #endif
    @State private var cacheSize: String = String(localized: "计算中…")
    @State private var audioCacheSize: String = String(localized: "计算中…")

    var body: some View {
        Form {
            Section("播放") {
                Picker("音质", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text("无损与 Hi-Res 需要黑胶 VIP，未开通时自动回落到可用音质")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("灰色歌曲解锁", isOn: $settings.enableUnblock)
                Text("无版权 / 下架歌曲自动从第三方音源（酷我、酷狗等）匹配播放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if os(macOS)
            // AutoMix is a group of its own because it is a group of costs:
            // the master switch buys analysis, and each sub-switch below adds
            // one specific bill (a seam, extra downloads, the GPU) on top.
            Section {
                Toggle("AutoMix", isOn: $settings.automixEnabled)
                    .onChange(of: settings.automixEnabled) { _, _ in
                        PlayerService.shared.reconcileQueueOrderAvailability()
                    }
                Text("分析已下载的歌曲，自动衔接队列里的歌。所有分析都在本机完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("自动过渡", isOn: $settings.automixTransitionsEnabled)
                    .disabled(!settings.automixEnabled)
                Text("在两首歌之间做节拍对齐的过渡。只分析本来就要播放的歌曲，不产生额外下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("智能顺序", isOn: $settings.automixOrderEnabled)
                    .disabled(!settings.automixEnabled)
                    .onChange(of: settings.automixOrderEnabled) { _, _ in
                        PlayerService.shared.reconcileQueueOrderAvailability()
                    }
                Text("按过渡效果重排队列，随机按钮会多出一个 AutoMix 状态。需要额外下载候选歌曲（标准音质）来打分。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("统一歌曲响度", isOn: $settings.loudnessCompensationEnabled)
                    .disabled(!settings.automixEnabled)
                Text("按每首歌的母带响度调整播放增益，下一首不会突然变响；需要开启 AutoMix")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Off *and* unavailable until the model is on disk: a toggle
                // that cannot do anything must not look like it can, and the
                // section below is where it becomes possible.
                Toggle("增强过渡（人声 / 鼓分离）",
                       isOn: stemsBinding)
                    .disabled(!settings.automixEnabled || !stemModelsInstalled)
                Text("用本机 GPU 分离音轨，过渡更干净。需要下载模型，播放时会占用 GPU 并增加发热和耗电。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StemModelsSettingsSection()
            } header: {
                Text("AutoMix")
            } footer: {
                Text("对古典、现场录音、有声书等内容效果不佳，遇到这类歌单可在这里暂时关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            Section("外观") {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                Picker("播放页模式", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
                Toggle("逐字歌词（卡拉OK）", isOn: $settings.verbatimLyrics)
                Picker("日文歌词读音", selection: $settings.lyricsAnnotation) {
                    ForEach(LyricsAnnotation.allCases) { annotation in
                        Text(annotation.displayName).tag(annotation)
                    }
                }
                Text("罗马音在歌词上方另起一行，汉字读音把假名标在汉字正上方；缺少官方罗马音时自动生成读音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("主界面环境色", isOn: $settings.showMainWindowAmbientBackground)
                if settings.showMainWindowAmbientBackground {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("背景色强度")
                            Spacer()
                            Text("\(Int(settings.mainWindowAmbientBackgroundIntensity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.mainWindowAmbientBackgroundIntensity,
                            in: SettingsManager.mainWindowAmbientBackgroundIntensityRange,
                            step: 0.1
                        )
                        HStack {
                            Text("50%")
                            Spacer()
                            Text("150%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                Toggle("桌面歌词", isOn: $settings.showDesktopLyrics)
                if settings.showDesktopLyrics {
                    Toggle("桌面歌词水平居中", isOn: $settings.desktopLyricsCentered)
                }
                Text("在屏幕上悬浮显示当前歌词，可拖动调整位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("存储") {
                LabeledContent("图片缓存", value: cacheSize)
                Button("清除缓存") {
                    clearCache()
                }
                LabeledContent("歌曲缓存", value: audioCacheSize)
                Picker("歌曲缓存上限", selection: $settings.audioCacheLimit) {
                    Text("512 MB").tag(Int64(512) << 20)
                    Text("2 GB").tag(Int64(2) << 30)
                    Text("8 GB").tag(Int64(8) << 30)
                    Text("不限").tag(Int64(0))
                }
                .onChange(of: settings.audioCacheLimit) { _, _ in
                    updateAudioCacheSize()
                }
                Button("清除歌曲缓存") {
                    Task {
                        await AudioCache.shared.removeAll()
                        updateAudioCacheSize()
                        ToastCenter.shared.show(String(localized: "歌曲缓存已清除"))
                    }
                }
            }

            Section("账号") {
                if let profile = account.profile {
                    LabeledContent("当前账号", value: profile.nickname)
                    Button("退出登录", role: .destructive) {
                        Task { await AccountStore.shared.logout() }
                    }
                } else {
                    Text("未登录")
                        .foregroundStyle(.secondary)
                }
            }

            Section("更新") {
                Toggle("启动时自动检查更新", isOn: $settings.autoCheckUpdates)
                Text("关闭后启动不再自动弹出更新提示，仍可手动检查更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledContent("Kumone", value: appVersion)
                #if os(iOS)
                Button {
                    IOSUpdater.shared.check(interactive: true)
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("装有 TrollStore（巨魔）可在应用内一键自动安装；否则可下载 IPA 用侧载工具重装（登录状态与设置保留）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Text("网易云音乐第三方客户端 · 数据来自网易云音乐")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 440, height: 480)
        #endif
        .task {
            updateCacheSize()
            updateAudioCacheSize()
        }
    }

    #if os(macOS)
    /// Whether the two-stem model is on disk, read from the downloader so the
    /// toggle flips the moment a download lands (the launcher wires the
    /// separator in via `onInstalled`; `StemSeparation.isAvailable` is not
    /// observable and only says what was installed at launch).
    private var stemModelsInstalled: Bool { downloader.vocalsInstalled }

    /// Reads as off whenever the models are missing, however the stored
    /// setting stands: the toggle must never claim a capability the machine
    /// does not have. The stored value is left alone so turning it on once and
    /// installing the models later still works.
    private var stemsBinding: Binding<Bool> {
        Binding(get: { settings.automixStemsEnabled && stemModelsInstalled },
                set: { settings.automixStemsEnabled = $0 })
    }
    #endif

    private func updateAudioCacheSize() {
        Task {
            let bytes = await AudioCache.shared.totalUsageBytes()
            audioCacheSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("im.missuo.Kumone/images", isDirectory: true)
    }

    private func updateCacheSize() {
        let dir = cacheDirectory
        DispatchQueue.global(qos: .utility).async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            let bytes = files.reduce(0) { sum, url in
                sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            DispatchQueue.main.async {
                cacheSize = formatted
            }
        }
    }

    private func clearCache() {
        let dir = cacheDirectory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                cacheSize = String(localized: "0 字节")
                ToastCenter.shared.show(String(localized: "缓存已清除"))
            }
        }
    }
}
