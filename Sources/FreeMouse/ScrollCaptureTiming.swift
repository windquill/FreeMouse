import Foundation

/// One outstanding scroll at a time. Sample times and `at` use the host clock.
/// Processing an old queued image can never release a newer scroll request.
struct ScrollAutomaticPacer {
    private var postedAt: TimeInterval?
    private var confirmedAt: TimeInterval?

    func nextStep(at time: TimeInterval, viewportHeight: CGFloat, scale: CGFloat, speed: Int) -> Int32 {
        guard time.isFinite, viewportHeight.isFinite, viewportHeight > 0,
              scale.isFinite, scale > 0 else { return 0 }
        if let postedAt {
            guard let confirmedAt, time - postedAt >= 0.15,
                  time - confirmedAt >= 0.15 else { return 0 }
        }
        let fraction = [0.08, 0.14, 0.2][min(2, max(0, speed))]
        let overlap = max(20 / scale, viewportHeight / 6)
        return Int32(min(1000, floor(max(0, min(viewportHeight * fraction, viewportHeight - overlap)))))
    }

    mutating func posted(at time: TimeInterval) {
        postedAt = time
        confirmedAt = nil
    }

    mutating func matched(frameTime: TimeInterval, at time: TimeInterval, advanced: Bool) {
        guard let postedAt, frameTime.isFinite, time.isFinite,
              frameTime > postedAt, advanced else { return }
        confirmedAt = time
    }

    mutating func rejected() { confirmedAt = nil }
    mutating func reset() { postedAt = nil; confirmedAt = nil }
}

/// Wait for the tail while continuing to consume frames. An idle SCK stream
/// need not emit a second identical complete frame to prove quietness.
struct ScrollFinishSettler {
    enum Decision: Equatable { case waiting, settled, timedOut }
    private let startedAt: TimeInterval
    private var lastChange: TimeInterval

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        lastChange = startedAt
    }

    mutating func observed(at time: TimeInterval, changed: Bool) {
        if changed { lastChange = max(lastChange, time) }
    }

    func decision(at time: TimeInterval, hasPending: Bool) -> Decision {
        if time - startedAt >= 2 { return .timedOut }
        if !hasPending, time - startedAt >= 0.3, time - lastChange >= 0.25 { return .settled }
        return .waiting
    }
}
