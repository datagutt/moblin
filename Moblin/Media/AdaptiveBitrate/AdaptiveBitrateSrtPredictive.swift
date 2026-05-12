import Collections
import Foundation

// Predictive adaptive bitrate algorithm.
//
// Decisions are driven by the link's demonstrated capacity, not by
// derived buffer thresholds. The phase machine has explicit climb /
// cruise / probe / decrease / drain states, modeled after BBR-style
// congestion control: we estimate a bottleneck bandwidth (BtlBw) and
// a minimum RTT (RTprop), and converge encoder bitrate toward a
// fraction of BtlBw.
//
// Three signals feed the decisions:
//   - capacity.recentPeakBps           the BtlBw estimate
//   - rtPropMs                          minimum-RTT estimate, refreshed by probeRtt
//   - capacity.retransRatio             loss feedback
// Plus three backstops layered after the phase output:
//   - pktSndDrop goodput shortfall      backstop for silent drops
//   - latency-fraction panic            backstop for catastrophic rtt
//   - thermal-state ceiling             backstop for hot device

private let bitrateIncrMin: Int64 = 100_000
private let bitrateIncrInterval: ContinuousClock.Duration = .milliseconds(400)
private let bitrateIncrScale: Int64 = 30
private let bitrateDecrMin: Int64 = 100_000
private let bitrateDecrInterval: ContinuousClock.Duration = .milliseconds(200)
private let bitrateDecrFastInterval: ContinuousClock.Duration = .milliseconds(250)
private let bitrateDecrScale: Int64 = 10

// Retransmit ratios that trigger cuts.
private let retransFastDecreaseThreshold: Double = 0.05
private let retransSlowDecreaseThreshold: Double = 0.015

// rtt / rtPropMs ratios that trigger cuts.
private let rttFastDecreaseRatio: Double = 2.5
private let rttSlowDecreaseRatio: Double = 1.6

// Panic if rtt eats this fraction of the SRT latency budget.
private let panicLatencyFraction: Double = 0.4

// Hard PIF panic backstop (kalman value).
private let pifHardPanicThreshold: Double = 500

// Refractory after any decrease so SRT's nak/rto cycle gets to respond.
private let lossHoldDuration: ContinuousClock.Duration = .milliseconds(1000)

// Phase transitions: cruise targets capacity * headroomDivisor, where
// headroomDivisor shrinks under loss. Headroom logic lives below.

let adaptiveBitratePredictiveSettings = AdaptiveBitrateSettings(
    packetsInFlight: 200,
    rttDiffHighFactor: 0.9,
    rttDiffHighAllowedSpike: 50,
    rttDiffHighMinDecrease: 250_000,
    pifDiffIncreaseFactor: 100_000,
    minimumBitrate: 250_000
)

private enum RatePhase: String {
    case startup        // initial multiplicative climb until throughput plateaus
    case cruise         // steady-state convergence toward BtlBw * headroom
    case probeBw        // brief stretch above BtlBw to test for hidden headroom
    case probeRtt       // brief dip to drain the queue and remeasure rtPropMs
    case hold           // kalman trend says wait
    case lossHold       // refractory after a cut
    case decreaseSlow
    case decreaseFast
    case panic
}

class AdaptiveBitrateSrtPredictive: AdaptiveBitrate {
    private var targetBitrate: Int64
    private var settings = adaptiveBitratePredictiveSettings
    private var currentBitrate: Int64 = 0
    private var phase: RatePhase = .startup
    private var phaseEnteredAt: ContinuousClock.Instant = .now
    private var bitrateBeforeLastDecrease: Int64 = 0
    private var nextBitrateIncrTime: ContinuousClock.Instant = .now
    private var nextBitrateDecrTime: ContinuousClock.Instant = .now

    // Minimum-RTT estimate. Slow drift up so an early low sample doesn't
    // anchor us forever; refreshed by occasional probeRtt phases.
    private var rtPropMs: Double = 200
    private static let rtPropDriftPerTick: Double = 1.0005
    private static let rtPropFloor: Double = 5

    // Startup stall detection. When two consecutive multiplicative climbs
    // don't actually move the bitrate (because the link's already at
    // capacity), exit startup into cruise.
    private var bitrateAtStartupRoundStart: Int64 = 0
    private var startupStallRounds: Int = 0
    private static let startupGrowthFactor: Double = 1.5
    private static let startupStallFactor: Double = 1.05
    private static let startupMaxStallRounds: Int = 2

    // Drop tracking (goodput shortfall backstop).
    private var prevPktSndDropTotal: Int32 = 0
    private var hasPrevDropTotal: Bool = false
    private var consecutiveDropTicks: Int = 0
    private var nextGoodputCutTime: ContinuousClock.Instant = .now
    private static let goodputDropBurstThreshold: Int32 = 3

    // Kalman trends.
    private let rttKalman = Kalman2State(
        processNoiseValue: 25,
        processNoiseVelocity: 1,
        measurementNoise: 100
    )
    private let pifKalman = Kalman2State(
        processNoiseValue: 4,
        processNoiseVelocity: 0.25,
        measurementNoise: 16
    )

    // Capacity tracker provides BtlBw (recentPeakBps), goodput, and
    // retrans ratio.
    private let capacity = CapacityTracker()
    private var lastLoggedPressureBand: Int = -1

    // Active BtlBw probing: stretch bitrate above the demonstrated peak
    // briefly and watch for response.
    private var nextProbeBwTime: ContinuousClock.Instant = .now.advanced(by: .seconds(15))
    private var probeStartRtt: Double = 0
    private var probeStartRetransRatio: Double = 0
    private var probeRollbackBitrate: Int64 = 0
    private static let probeBwDuration: ContinuousClock.Duration = .milliseconds(500)
    private static let probeBwIntervalNominal: ContinuousClock.Duration = .seconds(10)
    private static let probeBwIntervalBackoff: ContinuousClock.Duration = .seconds(25)
    private static let probeBwStretchFactor: Double = 1.18
    private static let probeBwRttResponseMs: Double = 12
    private static let probeBwRetransResponse: Double = 0.012

    // Active rtPropMs refresh: periodically drop bitrate to drain the
    // queue so rttMin observation has a chance to see the true minimum.
    private var nextProbeRttTime: ContinuousClock.Instant = .now.advanced(by: .seconds(30))
    private var probeRttUntil: ContinuousClock.Instant = .now
    private static let probeRttDuration: ContinuousClock.Duration = .milliseconds(600)
    private static let probeRttIntervalNominal: ContinuousClock.Duration = .seconds(20)
    private static let probeRttFactor: Double = 0.5

    // Thermal.
    private var lastThermalState: ProcessInfo.ThermalState = .nominal

    init(targetBitrate: UInt32, delegate: AdaptiveBitrateDelegate) {
        self.targetBitrate = Int64(targetBitrate)
        currentBitrate = Int64(adaptiveBitrateStart)
        super.init(delegate: delegate)
    }

    override func setTargetBitrate(bitrate: UInt32) {
        targetBitrate = Int64(bitrate)
    }

    override func setSettings(settings: AdaptiveBitrateSettings) {
        logger.info("adaptive-bitrate: Using settings \(settings)")
        self.settings = settings
    }

    override func getCurrentBitrate() -> UInt32 {
        UInt32(currentBitrate)
    }

    override func getCurrentMaximumBitrateInKbps() -> Int64 {
        Int64(currentBitrate) / 1000
    }

    override func update(stats: StreamStats) {
        updateBitrate(stats: stats)
        super.update(stats: stats)
    }

    private struct RateContext {
        let rtt: Double
        let pif: Double
        let srtLatency: Double
        let currentTime: ContinuousClock.Instant
        let retransRatio: Double
        let rttRatio: Double // rtt / rtPropMs
    }

    private func updateBitrate(stats: StreamStats) {
        guard stats.rttMs > 0 else {
            return
        }
        let rtt = stats.rttMs
        let pif = stats.packetsInFlight
        let currentTime = ContinuousClock.now
        updateMinRtt(sample: rtt)
        rttKalman.update(measurement: rtt, now: currentTime)
        pifKalman.update(measurement: pif, now: currentTime)
        capacity.update(
            mbpsSendRate: stats.mbpsSendRate,
            pktRetransTotal: stats.pktRetransTotal,
            now: currentTime
        )
        logPressureBandIfChanged()
        let context = RateContext(
            rtt: rtt,
            pif: pif,
            srtLatency: Double(stats.latency ?? defaultSrtLatency),
            currentTime: currentTime,
            retransRatio: capacity.retransRatio,
            rttRatio: rtt / max(Self.rtPropFloor, rtPropMs)
        )
        let nextPhase = selectPhase(context: context)
        if nextPhase != phase {
            logPhaseTransition(from: phase, to: nextPhase)
            phase = nextPhase
            phaseEnteredAt = currentTime
            onPhaseEntered(phase, context: context)
        }
        var bitrate = applyPhase(phase, context: context)
        // Goodput shortfall is a backstop for silent drops while phase
        // logic looks fine. When the phase is already cutting, halving
        // on top stacks and overshoots; only run on climb/hold phases.
        switch phase {
        case .startup, .cruise, .hold, .probeBw, .probeRtt:
            bitrate = applyGoodputShortfall(bitrate: bitrate, stats: stats, currentTime: currentTime)
        default:
            updateGoodputBookkeeping(stats: stats)
        }
        bitrate = stats.limitByTransportBitrate(bitrate: bitrate)
        bitrate = applyThermalCeiling(bitrate: bitrate)
        bitrate = max(min(bitrate, targetBitrate), settings.minimumBitrate)
        if bitrate != currentBitrate {
            currentBitrate = bitrate
            delegate?.adaptiveBitrateSetVideoStreamBitrate(bitrate: UInt32(bitrate))
        }
    }

    // MARK: - rtPropMs (minimum-RTT)

    private func updateMinRtt(sample: Double) {
        // Slow drift up so the floor follows real network changes when
        // probeRtt isn't running, but the real minimum still wins when
        // observed.
        rtPropMs *= Self.rtPropDriftPerTick
        if sample > Self.rtPropFloor, sample < rtPropMs {
            rtPropMs = sample
        }
    }

    // MARK: - Phase selection

    private func selectPhase(context: RateContext) -> RatePhase {
        // Panic pre-empts everything. Critical rtt eats the latency
        // budget; hard pif backstop catches a runaway queue regardless
        // of other signals.
        if currentBitrate > settings.minimumBitrate {
            if context.rtt >= context.srtLatency * panicLatencyFraction {
                return .panic
            }
            if pifKalman.initialized, pifKalman.value > pifHardPanicThreshold {
                return .panic
            }
        }
        // Stay in any active probe phase until its window closes (or it
        // aborts early on a clear response).
        if phase == .probeBw {
            if probeBwShouldAbort(context: context) {
                return finishProbeBw(context: context, abortedEarly: true)
            }
            if phaseEnteredAt.duration(to: context.currentTime) < Self.probeBwDuration {
                return .probeBw
            }
            return finishProbeBw(context: context, abortedEarly: false)
        }
        if phase == .probeRtt {
            if context.currentTime < probeRttUntil {
                return .probeRtt
            }
            nextProbeRttTime = context.currentTime.advanced(by: Self.probeRttIntervalNominal)
            return .cruise
        }
        // Refractory before non-panic decreases so a sustained-bad
        // condition can't chain cuts every 250ms.
        if isInLossHoldRefractory(context: context) {
            return .lossHold
        }
        // Loss/rtt-driven cuts.
        if currentBitrate > settings.minimumBitrate, context.currentTime > nextBitrateDecrTime {
            let heavyRetrans = context.retransRatio > retransFastDecreaseThreshold
            let heavyRtt = context.rttRatio > rttFastDecreaseRatio
            if heavyRetrans || heavyRtt {
                return .decreaseFast
            }
            let mildRetrans = context.retransRatio > retransSlowDecreaseThreshold
            let mildRtt = context.rttRatio > rttSlowDecreaseRatio
            if mildRetrans || mildRtt {
                // Pressure veto: if we're well below recentPeakBps,
                // the link clearly has room and a cut here would lock
                // us low.
                let pressure = currentPressure()
                let pressureSaysFine = capacity.initialized && pressure > 0 && pressure < 0.8
                if !pressureSaysFine {
                    return .decreaseSlow
                }
            }
        }
        // Kalman trend hold: things look fine right now but the slope
        // is rising; sit still until it clears.
        if isTrendingUp() {
            return .hold
        }
        // Startup: aggressive climb until throughput plateaus or we
        // see real congestion.
        if phase == .startup, !isStartupComplete(context: context) {
            return .startup
        }
        // probeRtt is more important than probeBw: a stale rtPropMs
        // breaks the rttRatio cut conditions, and probeBw decisions
        // depend on rtt being a clean baseline.
        if shouldEnterProbeRtt(context: context) {
            return .probeRtt
        }
        if shouldEnterProbeBw(context: context) {
            return .probeBw
        }
        return .cruise
    }

    private func onPhaseEntered(_ phase: RatePhase, context: RateContext) {
        switch phase {
        case .probeBw:
            probeRollbackBitrate = currentBitrate
            probeStartRtt = context.rtt
            probeStartRetransRatio = capacity.retransRatio
        case .probeRtt:
            probeRttUntil = context.currentTime.advanced(by: Self.probeRttDuration)
        case .startup:
            bitrateAtStartupRoundStart = currentBitrate
            startupStallRounds = 0
        default:
            break
        }
    }

    // MARK: - Phase apply

    private func applyPhase(_ phase: RatePhase, context: RateContext) -> Int64 {
        var bitrate = currentBitrate
        switch phase {
        case .hold:
            return bitrate
        case .lossHold:
            // If we entered lossHold as the rollback target from a
            // failed probeBw, snap back to the pre-probe bitrate.
            if probeRollbackBitrate > 0, bitrate > probeRollbackBitrate {
                bitrate = probeRollbackBitrate
                probeRollbackBitrate = 0
            }
            return bitrate
        case .panic:
            recordHighWaterMark(bitrate: bitrate)
            bitrate = settings.minimumBitrate
            nextBitrateDecrTime = context.currentTime.advanced(by: bitrateDecrInterval)
            logAdaptiveAcion(
                actionTaken: "Panic: rtt \(Int(context.rtt))ms of latency \(Int(context.srtLatency))ms"
            )
        case .decreaseFast:
            recordHighWaterMark(bitrate: bitrate)
            let step = bitrateDecrMin + bitrate / bitrateDecrScale
            bitrate -= step
            nextBitrateDecrTime = context.currentTime.advanced(by: bitrateDecrFastInterval)
            logAdaptiveAcion(
                actionTaken: """
                Fast decr: -\(step / 1000)k, retrans \(formatPercent(context.retransRatio)), \
                rttRatio \(formatTwoDecimals(context.rttRatio))
                """
            )
        case .decreaseSlow:
            recordHighWaterMark(bitrate: bitrate)
            bitrate -= bitrateDecrMin
            nextBitrateDecrTime = context.currentTime.advanced(by: bitrateDecrInterval)
            logAdaptiveAcion(
                actionTaken: """
                Decr: -\(bitrateDecrMin / 1000)k, retrans \(formatPercent(context.retransRatio)), \
                rttRatio \(formatTwoDecimals(context.rttRatio))
                """
            )
        case .startup:
            guard context.currentTime > nextBitrateIncrTime else {
                return bitrate
            }
            let next = Int64(Double(bitrate) * Self.startupGrowthFactor)
            bitrate = next
            nextBitrateIncrTime = context.currentTime.advanced(by: bitrateIncrInterval)
            registerStartupRoundResult(newBitrate: bitrate)
        case .cruise:
            guard context.currentTime > nextBitrateIncrTime else {
                return bitrate
            }
            bitrate = stepTowardCruiseTarget(bitrate: bitrate)
            nextBitrateIncrTime = context.currentTime.advanced(by: bitrateIncrInterval)
        case .probeBw:
            // On the first tick in probeBw, jump to the stretch target so
            // the link has time inside the probe window to actually
            // respond. Use the demonstrated peak as the floor so we
            // always test above what's been proven.
            let stretchFromCurrent = Double(bitrate) * Self.probeBwStretchFactor
            let stretchFromPeak = capacity.recentPeakBps * Self.probeBwStretchFactor
            let stretchTarget = Int64(max(stretchFromCurrent, stretchFromPeak))
            if bitrate < stretchTarget {
                bitrate = stretchTarget
            }
        case .probeRtt:
            // Drop briefly so the queue can drain and we can see the
            // true minimum rtt. Floor at the minimum bitrate.
            let target = Int64(Double(bitrate) * Self.probeRttFactor)
            bitrate = max(settings.minimumBitrate, target)
        }
        return bitrate
    }

    // MARK: - Cruise target

    // Converge toward the demonstrated BtlBw with an adaptive headroom
    // margin. Climb is rate-limited by the same growth step we used to
    // use for the old growth/recovery modes, so the algorithm never
    // jumps by huge amounts in one tick. Descent (when we're above
    // target) is a gentler half-step, because the loss/rtt decreases
    // handle real overruns; cruise descent is just trim.
    private func stepTowardCruiseTarget(bitrate: Int64) -> Int64 {
        guard capacity.initialized, capacity.recentPeakBps > 0 else {
            return bitrate + (bitrateIncrMin + bitrate / bitrateIncrScale)
        }
        let target = Int64(capacity.recentPeakBps * headroomDivisor())
        let gap = target - bitrate
        let nominalStep = bitrateIncrMin + bitrate / bitrateIncrScale
        if abs(gap) < nominalStep / 4 {
            return bitrate
        }
        if gap > 0 {
            return bitrate + min(Int64(gap), nominalStep)
        }
        return bitrate + max(Int64(gap), -(bitrateDecrMin / 2))
    }

    // MARK: - Startup completion

    private func isStartupComplete(context: RateContext) -> Bool {
        if startupStallRounds >= Self.startupMaxStallRounds {
            return true
        }
        // Don't keep climbing through clear congestion.
        if context.rttRatio > rttSlowDecreaseRatio {
            return true
        }
        if context.retransRatio > retransSlowDecreaseThreshold {
            return true
        }
        return false
    }

    private func registerStartupRoundResult(newBitrate: Int64) {
        if newBitrate < Int64(Double(bitrateAtStartupRoundStart) * Self.startupStallFactor) {
            startupStallRounds += 1
        } else {
            startupStallRounds = 0
        }
        bitrateAtStartupRoundStart = newBitrate
    }

    // MARK: - probeBw

    private func shouldEnterProbeBw(context: RateContext) -> Bool {
        guard capacity.initialized,
              capacity.recentPeakBps > 0,
              currentBitrate > settings.minimumBitrate,
              currentBitrate < targetBitrate,
              context.currentTime > nextProbeBwTime,
              !isTrendingUp(),
              context.rttRatio < rttSlowDecreaseRatio
        else {
            return false
        }
        // Don't probe right after a decrease; link is still settling.
        if [.panic, .decreaseFast, .decreaseSlow, .lossHold].contains(phase),
           phaseEnteredAt.duration(to: context.currentTime) < .seconds(2)
        {
            return false
        }
        let pressure = currentPressure()
        return pressure > 0 && pressure < 0.95
    }

    private func probeBwShouldAbort(context: RateContext) -> Bool {
        if context.rtt >= context.srtLatency * panicLatencyFraction {
            return true
        }
        let rttJump = context.rtt - probeStartRtt
        let retransJump = capacity.retransRatio - probeStartRetransRatio
        return rttJump > Self.probeBwRttResponseMs || retransJump > Self.probeBwRetransResponse
    }

    private func finishProbeBw(context: RateContext, abortedEarly: Bool) -> RatePhase {
        let responded = abortedEarly ||
            (context.rtt - probeStartRtt) > Self.probeBwRttResponseMs ||
            (capacity.retransRatio - probeStartRetransRatio) > Self.probeBwRetransResponse
        if responded {
            nextProbeBwTime = context.currentTime.advanced(by: Self.probeBwIntervalBackoff)
            logAdaptiveAcion(
                actionTaken: "ProbeBw: response (rtt \(Int(probeStartRtt))->\(Int(context.rtt))), back off"
            )
            return .lossHold
        }
        nextProbeBwTime = context.currentTime.advanced(by: Self.probeBwIntervalNominal)
        logAdaptiveAcion(actionTaken: "ProbeBw: clean, ceiling extended")
        return .cruise
    }

    // MARK: - probeRtt

    private func shouldEnterProbeRtt(context: RateContext) -> Bool {
        guard context.currentTime > nextProbeRttTime,
              currentBitrate > settings.minimumBitrate * 2,
              context.rttRatio < 2.0,
              capacity.initialized
        else {
            return false
        }
        return true
    }

    // MARK: - Refractory

    private func isInLossHoldRefractory(context: RateContext) -> Bool {
        switch phase {
        case .panic, .decreaseFast, .decreaseSlow, .lossHold:
            phaseEnteredAt.duration(to: context.currentTime) < lossHoldDuration
        default:
            false
        }
    }

    private func recordHighWaterMark(bitrate: Int64) {
        if bitrate > bitrateBeforeLastDecrease {
            bitrateBeforeLastDecrease = bitrate
        }
    }

    // MARK: - Kalman trend gate

    private func isTrendingUp() -> Bool {
        guard rttKalman.initialized, pifKalman.initialized else {
            return false
        }
        let rttRising = rttKalman.velocity > 25
        let pifRising = pifKalman.velocity > 20
        return rttRising || pifRising
    }

    // MARK: - Pressure (BtlBw vs currentBitrate, with adaptive headroom)

    private func currentPressure() -> Double {
        let raw = capacity.pressureRatio(targetBps: Double(currentBitrate))
        guard raw > 0 else {
            return 0
        }
        return raw / headroomDivisor()
    }

    // Maps retrans ratio to a divisor on raw pressure. retransRatio 0%
    // gives 1.0 (no adjustment); 10%+ gives 0.7 (treat as a 30% safety
    // margin). The same divisor multiplies recentPeakBps when picking
    // the cruise target.
    private func headroomDivisor() -> Double {
        let r = max(0, min(1, capacity.retransRatio))
        if r < 0.005 {
            return 1.0
        }
        if r > 0.1 {
            return 0.7
        }
        return 1.0 - (r - 0.005) * (0.3 / 0.095)
    }

    // MARK: - Logging

    private func logPhaseTransition(from: RatePhase, to: RatePhase) {
        guard from != to else { return }
        switch to {
        case .panic, .decreaseFast, .decreaseSlow, .probeBw, .probeRtt, .startup, .cruise:
            logAdaptiveAcion(actionTaken: "Phase: \(from.rawValue) -> \(to.rawValue)")
        default:
            break
        }
    }

    private func logPressureBandIfChanged() {
        guard capacity.initialized else { return }
        let pressure = currentPressure()
        let band: Int
        if pressure <= 0 {
            band = 0
        } else if pressure < 0.7 {
            band = 1
        } else if pressure < 0.9 {
            band = 2
        } else if pressure < 1.05 {
            band = 3
        } else {
            band = 4
        }
        if band != lastLoggedPressureBand {
            lastLoggedPressureBand = band
            logAdaptiveAcion(
                actionTaken: """
                Pressure: \(bandName(band)) (\(formatTwoDecimals(pressure)), \
                peak \(Int(capacity.recentPeakBps) / 1000)k, rtprop \(Int(rtPropMs))ms)
                """
            )
        }
    }

    private func bandName(_ band: Int) -> String {
        switch band {
        case 0: return "unknown"
        case 1: return "headroom"
        case 2: return "comfortable"
        case 3: return "at-capacity"
        case 4: return "over-capacity"
        default: return "?"
        }
    }

    private func formatPercent(_ value: Double) -> String {
        return String(format: "%.1f%%", max(0, min(100, value * 100)))
    }

    // MARK: - Goodput shortfall (backstop)

    private func applyGoodputShortfall(
        bitrate: Int64,
        stats: StreamStats,
        currentTime: ContinuousClock.Instant
    ) -> Int64 {
        guard let drops = stats.pktSndDropTotal else {
            return bitrate
        }
        defer {
            prevPktSndDropTotal = drops
            hasPrevDropTotal = true
        }
        guard hasPrevDropTotal else {
            return bitrate
        }
        let delta = drops &- prevPktSndDropTotal
        if delta >= Self.goodputDropBurstThreshold {
            consecutiveDropTicks += 1
        } else {
            consecutiveDropTicks = 0
        }
        guard consecutiveDropTicks >= 2,
              currentTime > nextGoodputCutTime,
              bitrate > settings.minimumBitrate
        else {
            return bitrate
        }
        let target = max(settings.minimumBitrate, bitrate / 2)
        nextGoodputCutTime = currentTime.advanced(by: .seconds(2))
        consecutiveDropTicks = 0
        logAdaptiveAcion(
            actionTaken: "Goodput: drops +\(delta), halving to \(target / 1000)k"
        )
        return target
    }

    private func updateGoodputBookkeeping(stats: StreamStats) {
        guard let drops = stats.pktSndDropTotal else {
            return
        }
        prevPktSndDropTotal = drops
        hasPrevDropTotal = true
        consecutiveDropTicks = 0
    }

    // MARK: - Thermal ceiling (backstop)

    private func applyThermalCeiling(bitrate: Int64) -> Int64 {
        let state = ProcessInfo.processInfo.thermalState
        let ceiling: Int64 = switch state {
        case .nominal, .fair:
            bitrate
        case .serious:
            Int64(Double(bitrate) * 0.7)
        case .critical:
            Int64(Double(bitrate) * 0.4)
        @unknown default:
            bitrate
        }
        if state != lastThermalState {
            lastThermalState = state
            if state == .serious || state == .critical {
                logAdaptiveAcion(
                    actionTaken: "Thermal: \(thermalStateName(state)), ceiling \(ceiling / 1000)k"
                )
            }
        }
        return min(bitrate, ceiling)
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
