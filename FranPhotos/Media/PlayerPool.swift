import AVFoundation
import Foundation

/// Keeps a small pool of live AVPlayers (at most `capacity`), evicting the
/// least-recently-used. Hover-preloading adjacent items would otherwise create
/// unbounded decoder instances.
@MainActor
final class PlayerPool {
    static let shared = PlayerPool()

    var capacity = 3

    private var players: [URL: AVPlayer] = [:]
    private var usageOrder: [URL] = []  // most-recently-used last

    func player(for url: URL) -> AVPlayer {
        if let existing = players[url] {
            touch(url)
            return existing
        }
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        players[url] = player
        touch(url)
        evictIfNeeded()
        return player
    }

    func release(_ url: URL) {
        players[url]?.pause()
        players.removeValue(forKey: url)
        usageOrder.removeAll { $0 == url }
    }

    func releaseAll() {
        for (_, player) in players { player.pause() }
        players.removeAll()
        usageOrder.removeAll()
    }

    private func touch(_ url: URL) {
        usageOrder.removeAll { $0 == url }
        usageOrder.append(url)
    }

    private func evictIfNeeded() {
        while players.count > capacity, let oldest = usageOrder.first {
            release(oldest)
        }
    }
}
