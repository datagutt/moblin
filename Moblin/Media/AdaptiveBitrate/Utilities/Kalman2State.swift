import Foundation

// 2-state Kalman filter tracking [value, velocity per second].
// Velocity term surfaces a trend before EWMA-only smoothing can react,
// useful for predictive holds when RTT or PIF starts climbing.
//
// Tuning: higher processNoiseValue means faster reactivity, higher
// measurementNoise means more smoothing. processNoiseVelocity controls
// how fast the velocity estimate follows the actual trend.
final class Kalman2State {
    private var x0: Double = 0
    private var x1: Double = 0
    private var p00: Double = 1
    private var p01: Double = 0
    private var p10: Double = 0
    private var p11: Double = 1
    private var lastUpdate: ContinuousClock.Instant = .now
    private(set) var initialized: Bool = false

    private let processNoiseValue: Double
    private let processNoiseVelocity: Double
    private let measurementNoise: Double

    var value: Double {
        x0
    }

    var velocity: Double {
        x1
    }

    init(processNoiseValue: Double, processNoiseVelocity: Double, measurementNoise: Double) {
        self.processNoiseValue = processNoiseValue
        self.processNoiseVelocity = processNoiseVelocity
        self.measurementNoise = measurementNoise
    }

    func update(measurement: Double, now: ContinuousClock.Instant = .now) {
        defer { lastUpdate = now }
        guard initialized else {
            x0 = measurement
            x1 = 0
            initialized = true
            return
        }
        let dt = max(0.001, durationToSeconds(lastUpdate.duration(to: now)))
        // Predict: x = F x, F = [[1, dt],[0, 1]]
        let predX0 = x0 + x1 * dt
        let predX1 = x1
        // P = F P F^T + Q
        let pp00 = p00 + dt * (p10 + p01) + dt * dt * p11 + processNoiseValue
        let pp01 = p01 + dt * p11
        let pp10 = p10 + dt * p11
        let pp11 = p11 + processNoiseVelocity
        // Innovation y = z - H x, H = [1, 0]
        let y = measurement - predX0
        let s = pp00 + measurementNoise
        // Kalman gain K = P H^T S^-1
        let k0 = pp00 / s
        let k1 = pp10 / s
        // Update
        x0 = predX0 + k0 * y
        x1 = predX1 + k1 * y
        p00 = (1 - k0) * pp00
        p01 = (1 - k0) * pp01
        p10 = pp10 - k1 * pp00
        p11 = pp11 - k1 * pp01
    }

    func reset() {
        initialized = false
        x0 = 0
        x1 = 0
        p00 = 1
        p01 = 0
        p10 = 0
        p11 = 1
    }
}

private func durationToSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
}
