#!/usr/bin/env swift
import Cocoa

let radiusRatio: CGFloat = 180.0 / 1024.0

let iconDir = CommandLine.arguments.dropFirst().first
    ?? (FileManager.default.currentDirectoryPath + "/Sources/BillLensMacApp/Assets.xcassets/AppIcon.appiconset")

let fm = FileManager.default
let pngs = (try? fm.contentsOfDirectory(atPath: iconDir))?.filter { $0.hasSuffix(".png") } ?? []

for filename in pngs {
    let path = (iconDir as NSString).appendingPathComponent(filename)
    guard let src = NSImage(contentsOfFile: path),
          let cgSrc = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { print("skip \(filename)"); continue }

    let w = cgSrc.width
    let h = cgSrc.height
    let radius = CGFloat(min(w, h)) * radiusRatio

    // 用 premultipliedLast 创建透明 context
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { print("ctx fail \(filename)"); continue }

    let rect = CGRect(x: 0, y: 0, width: w, height: h)

    // 先画原图
    ctx.draw(cgSrc, in: rect)

    // 用 clear 混合模式擦掉圆角外的区域（无暗边残留）
    ctx.setBlendMode(.clear)
    let roundedPath = CGMutablePath()
    roundedPath.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    // 偶奇规则：全图矩形 + 圆角矩形 → 圆角外的区域被清除
    let outerPath = CGMutablePath()
    outerPath.addRect(rect)
    outerPath.addPath(roundedPath)
    ctx.addPath(outerPath)
    ctx.fillPath(using: .evenOdd)

    guard let result = ctx.makeImage() else { print("img fail \(filename)"); continue }
    let rep = NSBitmapImageRep(cgImage: result)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: path))
    print("rounded: \(filename) (\(w)x\(h), r=\(Int(radius)))")
}
