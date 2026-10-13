import Foundation
import IOKit.ps

/// Internal battery state from IOPowerSources (btop `Cpu::get_battery`, src/osx).
final class BatteryCollector {
    func collect() -> BatterySample? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  (description[kIOPSIsPresentKey] as? Bool) ?? true else { continue }

            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charged = (description[kIOPSIsChargedKey] as? Bool) ?? false

            let minutesKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (description[minutesKey] as? NSNumber)?.intValue

            return BatterySample(
                percent: maximum > 0 ? min(100, current * 100 / maximum) : current,
                isCharging: charging,
                isOnAC: onAC,
                isCharged: charged || (onAC && !charging && current >= maximum),
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil
            )
        }
        return nil
    }
}
