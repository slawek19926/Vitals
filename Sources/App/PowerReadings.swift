import Foundation
import HelperKit
import SysCore

/// Cache acquisition times, never the time at which the UI last displayed a value.
struct PowerReadings {
    private var local: (power: SCPower, acquired: Date)?
    private var helper: (power: HelperPower, acquired: Date)?
    static let maxAge: TimeInterval = 6

    mutating func acceptLocal(_ power: SCPower, at time: Date) { local = (power, time) }
    mutating func acceptHelper(_ power: HelperPower?, receivedAt time: Date) {
        guard var power else { return } // brief gaps may use the previous sample until its original expiry
        if power.gpuFreqMHz > 0, power.gpuFreqMHz < 1 { power.gpuFreqMHz *= 1e6 }
        helper = (power, power.sampledAt.map(Date.init(timeIntervalSince1970:)) ?? time)
    }
    func snapshot(at now: Date, helperEnabled: Bool) -> (power: SCPower, frequency: HelperPower?, stale: Bool, source: String) {
        func fresh(_ time: Date) -> Bool {
            let age = now.timeIntervalSince(time)
            return age >= -1 && age < Self.maxAge
        }
        var result = SCPower()
        if let local, fresh(local.acquired) { result = local.power }
        if helperEnabled, let helper, fresh(helper.acquired), helper.power.available {
            let p = helper.power
            result.cpuWatts = p.cpuWatts; result.gpuWatts = p.gpuWatts
            result.aneWatts = p.aneWatts; result.dramWatts = p.dramWatts; result.available = true
            return (result, p, false, p.source.isEmpty ? "IOReport" : p.source)
        }
        let stale = (helperEnabled && helper.map { !fresh($0.acquired) } == true) || local.map { !fresh($0.acquired) } == true
        return (result, nil, !result.available && stale, result.available ? "IOReport" : "")
    }
}
