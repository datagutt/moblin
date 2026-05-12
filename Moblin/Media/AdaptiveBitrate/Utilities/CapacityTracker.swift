import Foundation

// Per-stream capacity estimator. Independent of buffer-threshold logic;
// tracks what the link is actually carrying so the rate logic can reason
// about "are we below capacity" instead of "is the buffer too deep".
//
// Three signals are exposed:
//   - currentGoodputBps: smoothed wire-egress minus retransmits. Drops fast
//     (asymmetric ewma) so a capacity collapse is visible within a tick or
//     two, climbs back conservatively to avoid chasing a single fast sample.
//   - recentPeakBps: high-water mark with slow decay. Represents "what the
//     link recently demonstrated it can carry". Used as the denominator
//     for pressure ratios.
//   - retransRatio: rolling fraction of egress that's retransmits. Useful
//     as a network-quality proxy for adaptive headroom.
final class CapacityTracker {
    private(set) var currentGoodputBps: Double = 0
    private(set) var recentPeakBps: Double = 0
    private(set) var retransRatio: Double = 0
    private(set) var initialized: Bool = false

    private var lastUpdate: ContinuousClock.Instant = .now
    private var prevRetransTotal: Int32 = 0
    private var hasPrevRetrans: Bool = false

    private static let payloadBytesPerPacket: Double = 1316
    private static let peakDecayPerSecond: Double = 0.985

    func update(
        mbpsSendRate: Double?,
        pktRetransTotal: Int32?,
        now: ContinuousClock.Instant = .now
    ) {
        defer {
            lastUpdate = now
            if let retrans = pktRetransTotal {
                prevRetransTotal = retrans
                hasPrevRetrans = true
            }
        }
        guard let mbpsSendRate else {
            return
        }
        let elapsedSeconds = max(0.001, durationToSeconds(lastUpdate.duration(to: now)))
        let wireBps = mbpsSendRate * 1_000_000
        var goodputSample = wireBps
        var retransSampleBps: Double = 0
        if hasPrevRetrans, let retrans = pktRetransTotal {
            let deltaPackets = Double(retrans &- prevRetransTotal)
            retransSampleBps = (deltaPackets / elapsedSeconds) * Self.payloadBytesPerPacket * 8
            goodputSample = max(0, wireBps - retransSampleBps)
        }
        if !initialized {
            currentGoodputBps = goodputSample
            recentPeakBps = goodputSample
            initialized = true
        } else {
            // Asymmetric ewma: react fast to drops, climb back slowly so
            // a noisy single high sample doesn't inflate the estimate.
            if goodputSample < currentGoodputBps {
                currentGoodputBps = currentGoodputBps * 0.7 + goodputSample * 0.3
            } else {
                currentGoodputBps = currentGoodputBps * 0.9 + goodputSample * 0.1
            }
            // Peak ratchets up immediately, decays slowly per real elapsed
            // time so the unit (seconds vs ticks) is stable across tick
            // rates.
            if goodputSample > recentPeakBps {
                recentPeakBps = goodputSample
            } else {
                let decay = pow(Self.peakDecayPerSecond, elapsedSeconds)
                recentPeakBps = max(currentGoodputBps, recentPeakBps * decay)
            }
        }
        let retransShare = wireBps > 0 ? retransSampleBps / wireBps : 0
        retransRatio = retransRatio * 0.8 + min(1, retransShare) * 0.2
    }

    // Pressure of a target rate against the link's recent demonstrated
    // capacity. Returns 0 when no capacity sample yet, so callers can
    // treat that as "unknown" rather than "infinite headroom".
    func pressureRatio(targetBps: Double) -> Double {
        guard recentPeakBps > 0 else {
            return 0
        }
        return targetBps / recentPeakBps
    }

    func reset() {
        initialized = false
        currentGoodputBps = 0
        recentPeakBps = 0
        retransRatio = 0
        hasPrevRetrans = false
    }
}

private func durationToSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
}
