import SwiftUI

/// Çentikteki adanın ayarları. Üstte canlı bir önizleme var; bir seçenek değişince önizleme o seçeneğin
/// etkilediği duruma geçer.
struct NotchSettings: View {
    @Environment(MailStore.self) private var store
    @AppStorage(SettingsKey.showsIsland) private var showsIsland = true
    @AppStorage(SettingsKey.islandOptions) private var options = IslandOptions()
    @State private var preview = IslandPreview.Stage.rest

    var body: some View {
        VStack(spacing: 0) {
            IslandPreview(options: options, stage: $preview)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 4)
                .opacity(showsIsland ? 1 : 0.4)

            Form {
                Section {
                    SettingRow("Show in the notch", detail: "Nook lives in your notch, even when its window is closed.") {
                        Toggle("Show in the notch", isOn: $showsIsland)
                    }
                    .onChange(of: showsIsland) { MailIsland.shared.update() }
                }

                Group {
                    Section("At rest") {
                        SettingRow("Left side") {
                            Picker("Left side", selection: $options.leading) {
                                ForEach(IslandOptions.Leading.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        SettingRow("Count", detail: "Unread conversations, on the right.") {
                            Picker("Count", selection: $options.badge) {
                                ForEach(IslandOptions.Badge.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        SettingRow("Hide when everything is read", detail: "The island folds back into the notch until new mail arrives.") {
                            Toggle("Hide when everything is read", isOn: $options.hidesWhenRead)
                        }
                    }

                    Section("New mail") {
                        SettingRow("Announce new mail", detail: "When someone writes, the island opens for a moment. Mail in the Feed never does this.") {
                            Toggle("Announce new mail", isOn: $options.announces)
                        }
                        SettingRow("Show the subject", detail: "Turn off to show only who it's from, for example while sharing your screen.") {
                            Toggle("Show the subject", isOn: $options.showsSubject)
                        }
                        .disabled(!options.announces)
                        SettingRow("Stay open for") {
                            Picker("Stay open for", selection: $options.peekSeconds) {
                                ForEach(IslandOptions.peekChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                            }
                        }
                        .disabled(!options.announces)
                        SettingRow("Verification codes", detail: "Sign-in codes appear in the notch with a Copy button, even when they come from the Feed.") {
                            Toggle("Verification codes", isOn: $options.showsCodes)
                        }
                    }

                    Section("Opening") {
                        SettingRow("Open with") {
                            Picker("Open with", selection: $options.trigger) {
                                ForEach(IslandOptions.Trigger.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        SettingRow("Conversations") {
                            Picker("Conversations", selection: $options.rows) {
                                ForEach(IslandOptions.rowChoices, id: \.self) { Text($0, format: .number).tag($0) }
                            }
                        }
                        SettingRow("Show the Feed", detail: "A single line with what's new in the Feed.") {
                            Toggle("Show the Feed", isOn: $options.showsFeed)
                        }
                        .disabled(!store.splitInbox)
                        SettingRow("Show buttons", detail: "New message and Open Nook.") {
                            Toggle("Show buttons", isOn: $options.showsActions)
                        }
                    }

                    Section {
                        HStack {
                            Spacer()
                            Button("Restore defaults") { options = IslandOptions() }
                                .disabled(options == IslandOptions())
                                .handCursor()
                        }
                    }
                }
                .disabled(!showsIsland)
            }
            .formStyle(.grouped)
        }
        // Değişen seçeneğin görüldüğü duruma geç
        .onChange(of: [options.leading.rawValue, options.badge.rawValue, "\(options.hidesWhenRead)"]) { show(.rest) }
        .onChange(of: [options.announces, options.showsSubject]) { show(.peek) }
        .onChange(of: options.peekSeconds) { show(.peek) }
        .onChange(of: options.showsCodes) { _, shows in show(shows ? .code : .rest) }
        .onChange(of: [options.trigger.rawValue, "\(options.rows)", "\(options.showsFeed)", "\(options.showsActions)"]) { show(.open) }
    }

    private func show(_ stage: IslandPreview.Stage) {
        withAnimation(MailIsland.spring) { preview = stage }
    }
}

/// Masaüstünün üst kenarından bir kesit ve ortasında ada. Gerçek verilerle çizilir; açık hali sığsın diye küçültülür.
struct IslandPreview: View {
    enum Stage: String, CaseIterable, Identifiable {
        case rest, peek, code, open
        var id: Self { self }

        var title: String {
            switch self {
            case .rest: String(localized: "At rest")
            case .peek: String(localized: "New mail")
            case .code: String(localized: "island.stage.code", defaultValue: "Code", comment: "Önizlemede doğrulama kodu hali")
            case .open: String(localized: "island.stage.open", defaultValue: "Open", comment: "Önizlemede adanın açık hali")
            }
        }
    }

    @Environment(MailStore.self) private var store
    let options: IslandOptions
    @Binding var stage: Stage

    private let notch = CGSize(width: 180, height: 32)
    private let height: CGFloat = 190

    var body: some View {
        let summary = store.widgetSnapshot(accent: nil)
        let mode = mode(summary: summary)
        let compact = IslandSurface.isCompact(summary: summary, options: options)
        let size = MailIsland.size(for: mode, notch: notch, options: options, compact: compact, feed: options.showsFeed && store.splitInbox)
        let scale = min(1, (height - 14) / size.height)

        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                // Masaüstü ve menü çubuğu
                LinearGradient(colors: [Color.primary.opacity(0.07), Color.primary.opacity(0.03)], startPoint: .top, endPoint: .bottom)
                Rectangle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: notch.height * scale)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5) }
                HStack {
                    Image(systemName: "apple.logo")
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                }
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.3))
                .padding(.horizontal, 16)
                .frame(height: notch.height * scale)

                IslandSurface(
                    mode: mode,
                    size: size,
                    notch: notch.height,
                    summary: summary,
                    options: options,
                    open: { _ in },
                    tap: { withAnimation(MailIsland.spring) { stage = .open } }
                )
                // Açık hali sığsın diye küçültülür; yerleşimde de küçük boyutu kaplasın ki üstü kırpılmasın
                .scaleEffect(scale, anchor: .top)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .top)
                .allowsHitTesting(stage == .rest)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

            Picker("Preview", selection: $stage.animation(MailIsland.spring)) {
                ForEach(Stage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .handCursor()
        }
    }

    private func mode(summary: WidgetSnapshot) -> MailIsland.Mode {
        switch stage {
        case .rest: return .rest
        case .open: return .open
        case .code:
            return .code(MailIsland.Code(threadID: UUID(), sender: "Cloudly", code: "482913"))
        case .peek:
            // Son yazan kişi; henüz mail yoksa bir örnek
            let latest = summary.people.max { ($0.isUnread ? 1 : 0, $0.date) < ($1.isUnread ? 1 : 0, $1.date) }
            return .peek(MailIsland.Peek(
                threadID: latest?.id ?? UUID(),
                sender: latest?.sender ?? "Maya Chen",
                subject: latest?.subject ?? String(localized: "Dinner on Saturday?"),
                others: 0
            ))
        }
    }
}
