#!/usr/bin/env swift
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("用法: create-dmg-background.swift <output.png>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 660, height: 420)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("无法创建 DMG 背景画布\n", stderr)
    exit(3)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let bounds = NSRect(origin: .zero, size: size)

// 三段斜向弧形色带(51 版式):左上薄荷绿 → 灰绿过渡带 → 右下青灰。
// 每条边界是过三点的大圆弧;左侧圆内为浅色带。
let mint = NSColor(calibratedRed: 0.878, green: 0.965, blue: 0.925, alpha: 1)
let sage = NSColor(calibratedRed: 0.784, green: 0.863, blue: 0.824, alpha: 1)
let teal = NSColor(calibratedRed: 0.333, green: 0.518, blue: 0.565, alpha: 1)

/// 过三点的圆(外接圆);色带边界用它来画大弧。
func circle(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> (center: NSPoint, radius: CGFloat) {
    let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
    let ux = ((a.x * a.x + a.y * a.y) * (b.y - c.y)
        + (b.x * b.x + b.y * b.y) * (c.y - a.y)
        + (c.x * c.x + c.y * c.y) * (a.y - b.y)) / d
    let uy = ((a.x * a.x + a.y * a.y) * (c.x - b.x)
        + (b.x * b.x + b.y * b.y) * (a.x - c.x)
        + (c.x * c.x + c.y * c.y) * (b.x - a.x)) / d
    let center = NSPoint(x: ux, y: uy)
    return (center, hypot(a.x - center.x, a.y - center.y))
}

func fillDisc(_ boundary: (center: NSPoint, radius: CGFloat), with color: NSColor) {
    let rect = NSRect(x: boundary.center.x - boundary.radius,
                      y: boundary.center.y - boundary.radius,
                      width: boundary.radius * 2,
                      height: boundary.radius * 2)
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
}

teal.setFill()
bounds.fill()
// 边界取(顶边交点, 图标行高度处交点, 底边交点),弧向右下方微凸。
fillDisc(circle(NSPoint(x: 515, y: 420), NSPoint(x: 430, y: 230), NSPoint(x: 260, y: 0)),
         with: sage)
fillDisc(circle(NSPoint(x: 396, y: 420), NSPoint(x: 310, y: 230), NSPoint(x: 132, y: 0)),
         with: mint)

// 手绘风打圈箭头:左下起笔 → 上挑打一个小圈 → 向右缓 S → 右端箭头。
let ink = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.09, alpha: 1)
let squiggle = NSBezierPath()
squiggle.move(to: NSPoint(x: 256, y: 206))
squiggle.curve(to: NSPoint(x: 330, y: 262),
               controlPoint1: NSPoint(x: 290, y: 212),
               controlPoint2: NSPoint(x: 314, y: 234))
squiggle.curve(to: NSPoint(x: 318, y: 284),
               controlPoint1: NSPoint(x: 340, y: 282),
               controlPoint2: NSPoint(x: 331, y: 290))
squiggle.curve(to: NSPoint(x: 323, y: 258),
               controlPoint1: NSPoint(x: 303, y: 277),
               controlPoint2: NSPoint(x: 308, y: 262))
squiggle.curve(to: NSPoint(x: 418, y: 250),
               controlPoint1: NSPoint(x: 352, y: 251),
               controlPoint2: NSPoint(x: 390, y: 261))
squiggle.lineWidth = 2.4
squiggle.lineCapStyle = .round
squiggle.lineJoinStyle = .round
ink.setStroke()
squiggle.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 409, y: 259))
head.line(to: NSPoint(x: 420, y: 249))
head.line(to: NSPoint(x: 411, y: 238))
head.lineWidth = 2.4
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// 左上角署名:Google Sans Flex,轴参数按 51 设计稿
// (Slant 0 / Width 100 / Weight 400 / Grad 0 / Rond 0)。
func signatureFont(size: CGFloat) -> NSFont {
    let axes: [NSNumber: NSNumber] = [
        0x7767_6874: 400, // wght
        0x7764_7468: 100, // wdth
        0x736C_6E74: 0,   // slnt
        0x4752_4144: 0,   // GRAD
        0x524F_4E44: 0,   // ROND
    ]
    let descriptor = NSFontDescriptor(fontAttributes: [
        .name: "GoogleSansFlex-Regular",
        NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): axes,
    ])
    return NSFont(descriptor: descriptor, size: size)
        ?? NSFont(name: "Futura-Medium", size: size)
        ?? NSFont.systemFont(ofSize: size, weight: .medium)
}
NSAttributedString(string: "Made by 51", attributes: [
    .font: signatureFont(size: 19),
    .foregroundColor: ink,
    .kern: 0.8,
]).draw(at: NSPoint(x: 26, y: size.height - 48))

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("无法生成 DMG 背景 PNG\n", stderr)
    exit(3)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
