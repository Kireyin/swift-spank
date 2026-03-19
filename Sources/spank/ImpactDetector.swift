import Foundation

// MARK: - Impact Detector (High-Pass Filter + Multi-Timescale STA/LTA)
// Matches the Go detector: high-pass filter (α=0.95) removes gravity,
// then 3 STA/LTA timescales detect impacts at different durations.

class ImpactDetector {
    let fs: Double = 100.0   // effective sample rate after decimation

    // High-pass filter state (1st order, α=0.95 to remove gravity DC component)
    private let hpAlpha: Double = 0.95
    private var hpPrevX: Double = 0
    private var hpPrevY: Double = 0
    private var hpPrevZ: Double = 0
    private var hpOutX: Double = 0
    private var hpOutY: Double = 0
    private var hpOutZ: Double = 0
    private var hpInitialized = false

    // STA/LTA timescales (from Go detector)
    // Timescale 1: fast (3/100, threshold 3.0)
    // Timescale 2: medium (15/500, threshold 2.5)
    // Timescale 3: slow (50/2000, threshold 2.0)
    private struct STALTAState {
        var sta: Double = 0
        var lta: Double = 0
        let staN: Int
        let ltaN: Int
        let thresholdOn: Double
        let thresholdOff: Double
        var triggered: Bool = false
    }
    private var tiers: [STALTAState] = [
        STALTAState(staN: 3, ltaN: 100, thresholdOn: 3.0, thresholdOff: 1.5),
        STALTAState(staN: 15, ltaN: 500, thresholdOn: 2.5, thresholdOff: 1.3),
        STALTAState(staN: 50, ltaN: 2000, thresholdOn: 2.0, thresholdOff: 1.2),
    ]

    private var sampleCount: Int = 0
    private var decimCounter: Int = 0

    // Refractory period: ignore triggers for N samples after an event
    private let refractorySamples: Int = 30  // ~300ms at 100Hz
    private var refractoryCountdown: Int = 0

    // Track recent filtered magnitudes for amplitude estimation
    private var recentFilteredMag: [Double] = []
    private let windowSize = 50

    var events: [ImpactEvent] = []

    func process(x: Double, y: Double, z: Double, timestamp: TimeInterval) {
        decimCounter += 1
        guard decimCounter >= kIMUDecimation else { return }
        decimCounter = 0

        // High-pass filter to remove gravity (DC component)
        // y[n] = α * (y[n-1] + x[n] - x[n-1])
        if !hpInitialized {
            hpPrevX = x; hpPrevY = y; hpPrevZ = z
            hpOutX = 0; hpOutY = 0; hpOutZ = 0
            hpInitialized = true
            sampleCount += 1
            return
        }

        hpOutX = hpAlpha * (hpOutX + x - hpPrevX)
        hpOutY = hpAlpha * (hpOutY + y - hpPrevY)
        hpOutZ = hpAlpha * (hpOutZ + z - hpPrevZ)
        hpPrevX = x; hpPrevY = y; hpPrevZ = z

        // Dynamic acceleration magnitude (gravity removed)
        let dynMag = sqrt(hpOutX * hpOutX + hpOutY * hpOutY + hpOutZ * hpOutZ)
        let energy = dynMag * dynMag

        sampleCount += 1

        // Update all STA/LTA tiers
        var anyTriggered = false
        var triggerCount = 0
        for i in 0..<tiers.count {
            let staAlpha = 1.0 / Double(min(sampleCount, tiers[i].staN))
            let ltaAlpha = 1.0 / Double(min(sampleCount, tiers[i].ltaN))
            tiers[i].sta += (energy - tiers[i].sta) * staAlpha
            tiers[i].lta += (energy - tiers[i].lta) * ltaAlpha

            guard sampleCount > tiers[i].ltaN else { continue }

            let ratio = tiers[i].sta / (tiers[i].lta + 1e-30)
            if !tiers[i].triggered && ratio > tiers[i].thresholdOn {
                tiers[i].triggered = true
                anyTriggered = true
                triggerCount += 1
            } else if tiers[i].triggered && ratio < tiers[i].thresholdOff {
                tiers[i].triggered = false
            }
        }

        // Track filtered magnitudes for amplitude
        recentFilteredMag.append(dynMag)
        if recentFilteredMag.count > windowSize {
            recentFilteredMag.removeFirst()
        }

        // Refractory period countdown
        if refractoryCountdown > 0 {
            refractoryCountdown -= 1
            // Reset any triggers during refractory period
            for i in 0..<tiers.count { tiers[i].triggered = false }
            return
        }

        if anyTriggered {
            let amplitude = recentFilteredMag.max() ?? dynMag

            let severity: String
            switch amplitude {
            case ..<0.02: severity = "light"
            case ..<0.1: severity = "medium"
            default: severity = "heavy"
            }

            let event = ImpactEvent(time: Date(), amplitude: amplitude, severity: severity)
            events.append(event)
            // Keep only latest event to avoid unbounded growth
            if events.count > 10 { events.removeFirst(events.count - 10) }

            debugLog("[detector] impact! amp=\(String(format:"%.5f",amplitude)) severity=\(severity) tiers=\(triggerCount)")

            // Enter refractory period and reset STA
            refractoryCountdown = refractorySamples
            for i in 0..<tiers.count {
                tiers[i].sta = tiers[i].lta
                tiers[i].triggered = false
            }
        }
    }
}
