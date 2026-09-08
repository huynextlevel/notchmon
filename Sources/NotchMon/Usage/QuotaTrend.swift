import Foundation

/// Which way one quota window is moving, and where the recent rate lands it by
/// reset.
///
/// Ported from TokenBar's `QuotaTrend` / `QuotaTrendFold` (MIT — see
/// THIRD_PARTY.md), including its three measured constants. The reasoning is
/// reproduced rather than summarised because the constants are empirical: they
/// were chosen against recorded curves, and anyone tempted to "tidy" them needs
/// to see what they were tidying away.
///
/// **Deliberately not a cross-window ranking.** A 5-hour window and a 7-day
/// window have no shared *rate* scale, and every normalisation that would put
/// them on one needs a parameter chosen by taste. A per-window indicator needs
/// no such comparison, so none of those parameters exist here.
struct QuotaTrend: Hashable {
    enum Direction: Hashable {
        case rising, falling, flat
    }

    let direction: Direction

    /// What share of the allowance this window will have spent at reset if the
    /// recent rate continues, on the same 0…100(+) scale the window already
    /// prints.
    ///
    /// **Not** a percent-per-hour rate. That was the obvious choice and it is
    /// wrong: it is biased by window length, because a 5-hour window has to
    /// burn ~20%/h to use its allowance while a 7-day window needs only
    /// ~0.6%/h. A rate in %/h therefore names the shortest window as "burning
    /// fastest" no matter how anything is actually being used.
    ///
    /// May exceed 100. That is the one actionable state here.
    let projectedUsedPercent: Double

    /// Percentage points the recent rate will spend between now and reset.
    /// Recomputed from the clamped projection rather than kept raw, so a reader
    /// adding it to the current reading lands exactly on the projection printed
    /// beside it.
    let projectedDeltaPercent: Double

    /// How long the window has left, from the reading this was projected from.
    let timeToReset: TimeInterval

    /// Whether the recent rate spends the whole allowance before reset.
    var runsOutEarly: Bool { projectedUsedPercent > 100 }

    /// Wall-clock seconds until the allowance is gone, at the recent rate.
    ///
    /// The one quantity here that *is* comparable between windows: seconds are
    /// seconds whatever the window's length. It is what ranking across an
    /// agent's windows is allowed to use, and nothing else is.
    ///
    /// Nil unless the window actually runs out before it resets — a window that
    /// survives to reset has no exhaustion time, and treating "never" as a very
    /// large number would let it be ordered against ones that do.
    var timeToExhaustion: TimeInterval? {
        guard runsOutEarly, projectedDeltaPercent > 0 else { return nil }
        // Linear in the projection's own terms: the delta is spread evenly over
        // the time left, so the moment the level crosses 100 is that fraction
        // of the way through.
        let headroom = max(0, 100 - (projectedUsedPercent - projectedDeltaPercent))
        return timeToReset * (headroom / projectedDeltaPercent)
    }
}

enum QuotaTrendFold {
    /// Trailing fraction of the window's own duration used to measure the recent
    /// slope, back from the newest sample.
    ///
    /// TokenBar measured this on live data and settled on 25%: it produced a
    /// usable slope for every window that had a curve at all, including one
    /// whose entire recorded history was four samples. A shorter lookback was
    /// tried and rejected — at 10% a weekly window's answer flipped relative to
    /// a session window purely because of sampling density, since the session is
    /// polled far more often and a narrow slice still holds enough of its
    /// points while the weekly's does not.
    static let lookbackFraction = 0.25

    /// Below this many samples inside the lookback span, a slope would be
    /// invented from a single point. No indicator — which is not the same as a
    /// zero, and must not be drawn as one.
    static let minimumSamples = 2

    /// Slope magnitude at or under this reads as "not moving recently" rather
    /// than a direction. It sits an order of magnitude below the smallest
    /// genuine slope TokenBar measured (0.45) so a real burn is never muted, and
    /// comfortably above float noise between two adjacent readings.
    ///
    /// The case it exists for: a window sitting at 63% spent that has not been
    /// touched in days. Its lifetime average says "busy"; its recent slope is
    /// zero. Any implementation that reads that row as burning is wrong.
    static let flatThreshold = 0.05

    /// Samples, window bounds and `now` in — direction and projection out, or
    /// nil when there is not enough recent data to say anything.
    ///
    /// `usedPercent` is the window's *current* reading rather than the newest
    /// sample: the two can lag each other by a poll, and the projection has to
    /// be defined relative to the number the rest of the row already shows.
    static func trend(
        usedPercent: Double,
        windowStart: Date,
        windowEnd: Date,
        now: Date = Date(),
        samples: [QuotaSample]
    ) -> QuotaTrend? {
        let duration = windowEnd.timeIntervalSince(windowStart)
        guard duration > 0, now > windowStart else { return nil }

        let inside = samples
            .filter { $0.at >= windowStart && $0.at <= now }
            .sorted { $0.at < $1.at }
        guard let newest = inside.last else { return nil }

        let spanStart = newest.at.addingTimeInterval(-duration * lookbackFraction)
        let span = inside.filter { $0.at >= spanStart }
        guard span.count >= minimumSamples,
              let first = span.first, let last = span.last,
              last.at > first.at
        else { return nil }

        // Normalised: percentage points moved per 100 points of the WINDOW
        // elapsed, not per unit of wall time. This is what lets a 5-hour and a
        // 7-day window be measured by one rule — and the value never leaves
        // this function, precisely because it is not comparable between them.
        let elapsedFraction = last.at.timeIntervalSince(first.at) / duration
        let recentSlope = (last.usedPercent - first.usedPercent) / (elapsedFraction * 100)

        let windowElapsed = min(1, max(0, now.timeIntervalSince(windowStart) / duration))
        let rawDelta = recentSlope * (1 - windowElapsed) * 100

        // Floor only, and deliberately no ceiling.
        //
        // A provider correcting itself downward can make the recent samples
        // fall steeply enough to project a window to "-190% used", which is a
        // drop larger than the amount that exists. The ceiling is left off
        // because `runsOutEarly` IS `projectedUsedPercent > 100`: capping there
        // would delete the one signal this whole fold exists to produce. The
        // asymmetry is the point — one saturation has a name, the other does
        // not.
        let projected = max(0, usedPercent + rawDelta)
        let delta = projected - usedPercent

        let direction: QuotaTrend.Direction = abs(recentSlope) <= flatThreshold
            ? .flat
            : (recentSlope > 0 ? .rising : .falling)

        return QuotaTrend(
            direction: direction,
            projectedUsedPercent: projected,
            projectedDeltaPercent: delta,
            timeToReset: max(0, windowEnd.timeIntervalSince(now))
        )
    }
}
