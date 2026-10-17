import Foundation

/// Full-text + structured search over the library. FTS5 covers
/// title/caption/keywords/filename; scopes add structured filters.
@MainActor
@Observable
final class SearchStore {
    enum Scope: String, CaseIterable, Sendable {
        case all, photos, videos, favorites

        var localizedName: String {
            switch self {
            case .all: String(localized: "All")
            case .photos: String(localized: "Photos")
            case .videos: String(localized: "Videos")
            case .favorites: String(localized: "Favorites")
            }
        }

        var sqlFragment: String {
            switch self {
            case .all: "1=1"
            case .photos: "a.media_type = 'photo'"
            case .videos: "a.media_type = 'video'"
            case .favorites: "a.is_favorite = 1"
            }
        }
    }

    var query: String = "" {
        didSet { scheduleSearch() }
    }
    var scope: Scope = .all {
        didSet { scheduleSearch() }
    }

    private(set) var results: [Asset] = []
    private(set) var isSearching = false

    private let db: DatabaseActor
    private var searchTask: Task<Void, Never>?

    init(db: DatabaseActor) {
        self.db = db
    }

    var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)  // debounce
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    func run() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        guard let match = Self.ftsQuery(from: text) else {
            results = []
            return
        }
        let sql = """
            SELECT a.* FROM asset_fts
            JOIN assets a ON a.rowid = asset_fts.rowid
            WHERE asset_fts MATCH ?
              AND a.is_deleted = 0 AND a.is_hidden = 0
              AND \(scope.sqlFragment)
            ORDER BY a.captured_at DESC
            LIMIT 500
            """
        results = ((try? await db.query(sql, [.text(match)])) ?? []).map(Asset.init)
    }

    /// Sanitizes free text into an FTS5 query: each token becomes a prefix term.
    /// Returns nil when nothing searchable remains.
    static func ftsQuery(from text: String) -> String? {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "\"", with: "") }
        guard !tokens.isEmpty else { return nil }
        // CJK scripts have no word boundaries — FTS5's unicode61 tokenizer indexes
        // them per-run; prefix matching still finds them.
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
