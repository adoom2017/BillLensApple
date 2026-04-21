import Foundation

#if os(macOS)
import IOKit

public func deviceName() -> String {
    Host.current().localizedName ?? UUID().uuidString
}

/// Returns a stable per-machine identifier using the IOPlatformUUID.
public func stableDeviceIdentifier() -> String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(service) }
    let cfUUID = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
    return (cfUUID?.takeRetainedValue() as? String) ?? UUID().uuidString
}
#else
import UIKit

@MainActor
public func deviceName() -> String {
    UIDevice.current.name
}

/// Returns a stable per-install identifier using identifierForVendor.
public func stableDeviceIdentifier() -> String {
    UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
}
#endif
