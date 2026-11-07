import Foundation

/// Çentikteki adada nelerin görüneceği. Tek bir anahtarda JSON olarak durur; sonradan eklenen seçenekler
/// eski kayıtlarda yoksa varsayılanını alır.
nonisolated struct IslandOptions: Equatable, Sendable {
    /// Dinlenirken soldaki işaret
    enum Leading: String, CaseIterable, Identifiable, Codable, Sendable {
        case mark, sender, hidden
        var id: Self { self }
    }

    /// Dinlenirken sağdaki sayı neyi sayar
    enum Badge: String, CaseIterable, Identifiable, Codable, Sendable {
        case people, everything, hidden
        var id: Self { self }
    }

    /// Ada fareyle üzerine gelince mi, tıklayınca mı açılır
    enum Trigger: String, CaseIterable, Identifiable, Codable, Sendable {
        case hover, click
        var id: Self { self }
    }

    /// Ada açılınca ne listelenir
    enum Content: String, CaseIterable, Identifiable, Codable, Sendable {
        case people, feed, latest
        var id: Self { self }
    }

    var leading = Leading.mark
    var badge = Badge.people
    /// Okunmamış yoksa ada çentiğin içine çekilir
    var hidesWhenRead = false

    /// Yeni mail gelince ada birkaç saniyeliğine açılır
    var announces = true
    var showsSubject = true
    var peekSeconds = 6
    /// Doğrulama kodları, Akış'tan gelseler de kopyalama düğmesiyle gösterilir
    var showsCodes = true

    var trigger = Trigger.hover
    var content = Content.people
    var rows = 4
    var showsFeed = true
    var showsActions = true

    static let peekChoices = [3, 6, 10]
    static let rowChoices = [3, 4, 5, 6]

    static var current: IslandOptions {
        UserDefaults.standard.string(forKey: SettingsKey.islandOptions).flatMap(IslandOptions.init(rawValue:)) ?? IslandOptions()
    }

    /// İnsanlar ve Akış ayrımı kapalıysa Akış diye bir liste yok
    func content(splitInbox: Bool) -> Content {
        content == .feed && !splitInbox ? .people : content
    }

    /// Akış satırı yalnızca kişi listesinin altında durur
    func showsFeedLine(splitInbox: Bool) -> Bool {
        showsFeed && splitInbox && content == .people
    }
}

nonisolated extension IslandOptions: Codable {
    private enum CodingKeys: String, CodingKey {
        case leading, badge, hidesWhenRead, announces, showsSubject, peekSeconds, showsCodes, trigger, content, rows, showsFeed, showsActions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = IslandOptions()
        leading = (try? c.decodeIfPresent(Leading.self, forKey: .leading)) ?? base.leading
        badge = (try? c.decodeIfPresent(Badge.self, forKey: .badge)) ?? base.badge
        hidesWhenRead = (try? c.decodeIfPresent(Bool.self, forKey: .hidesWhenRead)) ?? base.hidesWhenRead
        announces = (try? c.decodeIfPresent(Bool.self, forKey: .announces)) ?? base.announces
        showsSubject = (try? c.decodeIfPresent(Bool.self, forKey: .showsSubject)) ?? base.showsSubject
        peekSeconds = (try? c.decodeIfPresent(Int.self, forKey: .peekSeconds)) ?? base.peekSeconds
        showsCodes = (try? c.decodeIfPresent(Bool.self, forKey: .showsCodes)) ?? base.showsCodes
        trigger = (try? c.decodeIfPresent(Trigger.self, forKey: .trigger)) ?? base.trigger
        content = (try? c.decodeIfPresent(Content.self, forKey: .content)) ?? base.content
        rows = (try? c.decodeIfPresent(Int.self, forKey: .rows)) ?? base.rows
        showsFeed = (try? c.decodeIfPresent(Bool.self, forKey: .showsFeed)) ?? base.showsFeed
        showsActions = (try? c.decodeIfPresent(Bool.self, forKey: .showsActions)) ?? base.showsActions
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(leading, forKey: .leading)
        try c.encode(badge, forKey: .badge)
        try c.encode(hidesWhenRead, forKey: .hidesWhenRead)
        try c.encode(announces, forKey: .announces)
        try c.encode(showsSubject, forKey: .showsSubject)
        try c.encode(peekSeconds, forKey: .peekSeconds)
        try c.encode(showsCodes, forKey: .showsCodes)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(content, forKey: .content)
        try c.encode(rows, forKey: .rows)
        try c.encode(showsFeed, forKey: .showsFeed)
        try c.encode(showsActions, forKey: .showsActions)
    }
}

/// `@AppStorage` ile doğrudan saklanabilsin diye
nonisolated extension IslandOptions: RawRepresentable {
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let options = try? JSONDecoder().decode(IslandOptions.self, from: data) else { return nil }
        self = options
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension IslandOptions.Leading {
    var title: String {
        switch self {
        case .mark: String(localized: "Nook mark")
        case .sender: String(localized: "Latest sender")
        case .hidden: String(localized: "Nothing")
        }
    }
}

extension IslandOptions.Badge {
    var title: String {
        switch self {
        case .people: String(localized: "People")
        case .everything: String(localized: "People and Feed")
        case .hidden: String(localized: "Nothing")
        }
    }
}

extension IslandOptions.Content {
    var title: String {
        switch self {
        case .people: String(localized: "People")
        case .feed: String(localized: "Feed")
        case .latest: String(localized: "Latest mail")
        }
    }
}

extension IslandOptions.Trigger {
    var title: String {
        switch self {
        case .hover: String(localized: "Hover")
        case .click: String(localized: "Click")
        }
    }
}
