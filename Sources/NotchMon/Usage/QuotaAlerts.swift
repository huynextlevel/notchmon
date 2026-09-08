import Foundation

/// A window that has just crossed the line the user asked to be told about.
struct QuotaWarning: Equatable {
    let provider: String
    let label: String
    let spentPercent: Int
}

/// Decides when to say something, and — the harder half — when to stay quiet.
///
/// Quotas are polled every few minutes, so a window sitting at 80% against a
/// 75% threshold is *over the line* on every single poll. Warning on the
/// condition would mean warning forever; the thing worth reporting is the
/// **crossing**, once, and then not again until the window resets.
///
/// So each crossing is recorded against the window it belongs to, and a window
/// is identified by when it resets. A new window has a new reset instant, has
/// therefore never been warned about, and re-arms on its own without anything
/// having to notice that a reset happened.
struct AlertLedger {
    private(set) var warned: Set<String>

    init(warned: Set<String> = []) { self.warned = warned }

    /// The threshold is part of the key on purpose: lowering it is a request to
    /// be told about windows that were already past the new line, and a ledger
    /// keyed only by the window would swallow exactly those.
    static func key(provider: String, label: String, reset: Date, threshold: Int) -> String {
        "\(provider)|\(label)|\(Int(reset.timeIntervalSince1970 / 60))|\(threshold)"
    }

    /// Everything that crossed since the last call, recorded as it is returned.
    ///
    /// A metric with no reset instant is skipped rather than warned about. Not
    /// an oversight: without one there is no way to tell this window from the
    /// next, so "once per window" degrades to "once ever", and a quota you were
    /// told about in March would stay silent in December.
    mutating func crossings(
        in providers: [ProviderSnapshot],
        threshold: Int
    ) -> [QuotaWarning] {
        guard (1...100).contains(threshold) else { return [] }
        let line = Double(threshold) / 100
        var found: [QuotaWarning] = []

        for snapshot in providers {
            for metric in snapshot.meteredMetrics {
                guard metric.fraction >= line, let reset = metric.resetDate else { continue }
                let key = Self.key(provider: snapshot.provider, label: metric.label,
                                   reset: reset, threshold: threshold)
                guard !warned.contains(key) else { continue }
                warned.insert(key)
                found.append(QuotaWarning(
                    provider: snapshot.provider,
                    label: metric.label,
                    spentPercent: Int((metric.fraction * 100).rounded())))
            }
        }
        return found
    }

    /// Forgets windows that have already reset, so the ledger does not grow for
    /// the life of the install.
    mutating func prune(now: Date = Date()) {
        let cutoff = Int(now.timeIntervalSince1970 / 60)
        warned = warned.filter { key in
            let parts = key.split(separator: "|")
            guard parts.count == 4, let minute = Int(parts[2]) else { return false }
            return minute >= cutoff
        }
    }
}
