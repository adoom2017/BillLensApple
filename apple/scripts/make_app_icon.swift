#!/usr/bin/env swift
// 生成 BillLens 应用图标。用法：cd apple && swift scripts/make_app_icon.swift
// macOS：按 Apple 图标模板，1024 画布内居中 824 连续圆角方块 + 投影，四周透明。
// iOS：满铺不透明方块，圆角由系统裁切。
import AppKit

let appleDir = FileManager.default.currentDirectoryPath
let macIconSet = "\(appleDir)/Sources/BillLensMacApp/Assets.xcassets/AppIcon.appiconset"
let iosIconSet = "\(appleDir)/Sources/BillLensIOSApp/Assets.xcassets/AppIcon.appiconset"
let macIcns = "\(appleDir)/Sources/BillLensMacApp/AppIcon.icns"

precondition(FileManager.default.fileExists(atPath: macIconSet), "请在 apple/ 目录下运行：\(macIconSet) 不存在")
precondition(FileManager.default.fileExists(atPath: iosIconSet), "请在 apple/ 目录下运行：\(iosIconSet) 不存在")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// 在 rect 内绘制图标主体（背景 + 小票）。坐标系原点在左下。
func drawArtwork(in ctx: CGContext, rect: CGRect) {
    let s = rect.width / 1024

    // 背景：系统蓝竖向渐变
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [rgb(0x4DA3FF), rgb(0x0A64E0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        background,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )

    // 小票轮廓：上方圆角，底部锯齿
    let width = 520 * s
    let height = 640 * s
    let left = rect.midX - width / 2
    let right = left + width
    let top = rect.midY + height / 2 + 10 * s
    let bottom = top - height
    let corner = 56 * s
    let teeth = 6
    let toothDepth = 34 * s

    let receipt = CGMutablePath()
    receipt.move(to: CGPoint(x: left, y: bottom))
    receipt.addLine(to: CGPoint(x: left, y: top - corner))
    receipt.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + corner, y: top), radius: corner)
    receipt.addLine(to: CGPoint(x: right - corner, y: top))
    receipt.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top - corner), radius: corner)
    receipt.addLine(to: CGPoint(x: right, y: bottom))
    let toothWidth = width / CGFloat(teeth)
    for index in 0..<teeth {
        let x = right - CGFloat(index) * toothWidth
        receipt.addLine(to: CGPoint(x: x - toothWidth / 2, y: bottom - toothDepth))
        receipt.addLine(to: CGPoint(x: x - toothWidth, y: bottom))
    }
    receipt.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 40 * s, color: rgb(0x002A70, 0.35))
    ctx.addPath(receipt)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // ¥ 符号：SF Rounded Bold
    let baseFont = NSFont.systemFont(ofSize: 300 * s, weight: .bold)
    let font = baseFont.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 300 * s) } ?? baseFont
    let symbol = NSAttributedString(string: "¥", attributes: [
        .font: font,
        .foregroundColor: NSColor(cgColor: rgb(0x0A64E0))!,
    ])
    let symbolSize = symbol.size()
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    symbol.draw(at: CGPoint(x: rect.midX - symbolSize.width / 2, y: top - 70 * s - symbolSize.height))
    NSGraphicsContext.restoreGraphicsState()

    // 两条明细线
    ctx.setFillColor(rgb(0xC7D3E3))
    let lineHeight = 30 * s
    for (offset, lineWidth) in [(CGFloat(430), CGFloat(300)), (CGFloat(500), CGFloat(210))] {
        let line = CGRect(x: rect.midX - lineWidth * s / 2, y: top - offset * s - lineHeight, width: lineWidth * s, height: lineHeight)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
        ctx.fillPath()
    }
}

func makeContext(size: Int, opaque: Bool) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        preconditionFailure("无法创建 \(size)px 绘图上下文")
    }
    ctx.interpolationQuality = .high
    return ctx
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        preconditionFailure("PNG 编码失败：\(path)")
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

func renderMacMaster() -> CGImage {
    let ctx = makeContext(size: 1024, opaque: false)
    // Apple macOS 图标网格：824×824，圆角约 185.4，居中；投影向下。
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: rgb(0x000000, 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x0A64E0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    drawArtwork(in: ctx, rect: tile)
    ctx.restoreGState()
    return ctx.makeImage()!
}

func renderIOSMaster() -> CGImage {
    let ctx = makeContext(size: 1024, opaque: true)
    drawArtwork(in: ctx, rect: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    return ctx.makeImage()!
}

func resized(_ image: CGImage, to size: Int, opaque: Bool) -> CGImage {
    let ctx = makeContext(size: size, opaque: opaque)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func pixelSize(of filename: String) -> Int {
    guard let digits = filename.split(separator: "-").last?.split(separator: ".").first, let size = Int(digits) else {
        preconditionFailure("无法从文件名解析尺寸：\(filename)")
    }
    return size
}

func renderIconSet(_ dir: String, master: CGImage, opaque: Bool) {
    let files = try! FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") }.sorted()
    precondition(!files.isEmpty, "\(dir) 中没有 PNG")
    for file in files {
        let size = pixelSize(of: file)
        writePNG(size == 1024 ? master : resized(master, to: size, opaque: opaque), to: "\(dir)/\(file)")
        print("wrote \(file) (\(size)px)")
    }
}

let macMaster = renderMacMaster()
renderIconSet(macIconSet, master: macMaster, opaque: false)
renderIconSet(iosIconSet, master: renderIOSMaster(), opaque: true)

// SwiftPM 组装的 .app 与 Dock 图标使用 AppIcon.icns
let iconset = NSTemporaryDirectory() + "BillLens.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(resized(macMaster, to: base, opaque: false), to: "\(iconset)/icon_\(base)x\(base).png")
    writePNG(resized(macMaster, to: base * 2, opaque: false), to: "\(iconset)/icon_\(base)x\(base)@2x.png")
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", macIcns]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil 失败：\(iconutil.terminationStatus)")
print("wrote \(macIcns)")
