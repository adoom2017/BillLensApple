import Foundation

#if os(macOS)
public func deviceName() -> String {
    Host.current().localizedName ?? UUID().uuidString
}
#else
import UIKit
@MainActor
public func deviceName() -> String {
    UIDevice.current.name
}
#endif
