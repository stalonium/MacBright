import Foundation
import IOKit

/// Reads the built-in ambient light sensor.
///
/// On Apple Silicon MacBooks the sensor is an SPU HID device (Apple vendor
/// usage page 0xFF00, usage 4) that publishes its reading as the `CurrentLux`
/// registry property — the same value CoreBrightness uses for auto-brightness.
final class AmbientLightSensor {
    private let service: io_service_t

    init?() {
        let matching = IOServiceMatching("IOService") as NSMutableDictionary
        matching[kIOPropertyMatchKey] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 4]

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var found: io_service_t = IO_OBJECT_NULL
        while case let candidate = IOIteratorNext(iterator), candidate != IO_OBJECT_NULL {
            if found == IO_OBJECT_NULL, Self.lux(of: candidate) != nil {
                found = candidate
            } else {
                IOObjectRelease(candidate)
            }
        }
        guard found != IO_OBJECT_NULL else { return nil }
        service = found
    }

    deinit {
        IOObjectRelease(service)
    }

    var lux: Double? {
        Self.lux(of: service)
    }

    private static func lux(of service: io_service_t) -> Double? {
        let value = IORegistryEntryCreateCFProperty(service, "CurrentLux" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? NSNumber)?.doubleValue
    }
}
