#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    public func toCGImage() -> CGImage? {
        #if os(macOS)
        guard let data = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }
}
