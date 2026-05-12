import Foundation

// EWMA whose smoothing weight depends on time since the previous sample.
// Fast back-to-back samples get heavy smoothing (stable in bursts), samples
// after long gaps get light smoothing or a full reset (responsive after
// quiet periods like a closed congestion window).
final class AgeWeightedEwma {
    private(set) var value: Double = 0
    private(set) var initialized: Bool = false
    private var lastUpdate: ContinuousClock.Instant = .now

    func update(sample: Double, now: ContinuousClock.Instant = .now) {
        defer { lastUpdate = now }
        guard initialized else {
            value = sample
            initialized = true
            return
        }
        let elapsed = lastUpdate.duration(to: now)
        let oldWeight: Double
        let newWeight: Double
        if elapsed >= .seconds(2) {
            value = sample
            return
        } else if elapsed >= .seconds(1) {
            oldWeight = 1
            newWeight = 1
        } else if elapsed >= .milliseconds(500) {
            oldWeight = 3
            newWeight = 1
        } else if elapsed >= .milliseconds(250) {
            oldWeight = 5
            newWeight = 1
        } else {
            oldWeight = 15
            newWeight = 1
        }
        value = (oldWeight * value + newWeight * sample) / (oldWeight + newWeight)
    }

    func reset() {
        initialized = false
        value = 0
    }
}
