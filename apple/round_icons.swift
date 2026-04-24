#!/usr/bin/env swift
import Cocoa

// macOS Big Sur 圆角半径 ≈ 17.57% (180/1024)
let radiusRatio: CGFloat = 180.0 / 1024.0

let iconDir = CommandLine.arguments.dropFirst().first
    ?? (FileManager.default.currentDirectoryPath + "/Sources/BillLensMacApp/Assets.xcassets/AppIcon.appiconset")

let fm = FileManager.default
let pngs = (try? fm.contentsOfDirectory(atPath: iconDir))?.filter { $0.hasSuffix(".png") } ?? []

for filename in pngs {
    let path = (iconDir as NSString).appendingPathComponent(filename)
    guard let src = NSImage(contentsOfFile: path) else { print("skip \(filename)"); continue }

    let size = src.size
    let radius = min(size.width, size.height) * radiusRatio

    let result = NSImage(size: size, flipped: false) { rect in
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.addClip()
        src.draw(in: rect)
        return true
    }

    guard let tiff = result.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("failed \(filename)"); continue
    }
    try! png.write(to: URL(fileURLWithPath: path))
    print("rounded: \(filename) (\(Int(size.width))x\(Int(size.height)), r=\(Int(radius)))")
}
