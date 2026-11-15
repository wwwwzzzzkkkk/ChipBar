#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Procedural, resolution-independent ChipBar icon: a restrained dark
/// graphite-blue rounded surface with the same cyan signal waveform seen in
/// the approved dashboard concept. Generated at build time, no third-party
/// asset or raster scaling artifacts.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift draw_icon.swift output.png\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let width = 1024
let height = 1024
let rgb = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: width, height: height,
                          bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot allocate icon canvas")
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: rgb, components: [r, g, b, a])!
}

let area = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
let rounded = CGPath(roundedRect: area.insetBy(dx: 18, dy: 18),
                     cornerWidth: 226, cornerHeight: 226, transform: nil)
ctx.addPath(rounded)
ctx.clip()

// The dark glass icon stays legible in Light and Dark appearance.
let ground = CGGradient(colorsSpace: rgb,
                        colors: [color(0.16, 0.26, 0.41), color(0.075, 0.12, 0.22),
                                 color(0.035, 0.060, 0.11)] as CFArray,
                        locations: [0, 0.56, 1])!
ctx.drawLinearGradient(ground, start: CGPoint(x: 180, y: 1010),
                       end: CGPoint(x: 880, y: -40), options: [])
ctx.addPath(rounded)
ctx.setStrokeColor(color(0.70, 0.82, 0.97, 0.23))
ctx.setLineWidth(14)
ctx.strokePath()

let disc = CGRect(x: 132, y: 132, width: 760, height: 760)
let center = CGPoint(x: disc.midX, y: disc.midY)
let halo = CGGradient(colorsSpace: rgb,
                      colors: [color(0.19, 0.36, 0.54, 0.92),
                               color(0.09, 0.19, 0.32, 0.96),
                               color(0.045, 0.095, 0.18, 0.96)] as CFArray,
                      locations: [0, 0.54, 1])!
ctx.saveGState()
ctx.addEllipse(in: disc)
ctx.clip()
ctx.drawRadialGradient(halo, startCenter: CGPoint(x: 448, y: 650),
                       startRadius: 20, endCenter: center, endRadius: 490,
                       options: [.drawsAfterEndLocation])
ctx.restoreGState()
ctx.setStrokeColor(color(0.48, 0.70, 0.91, 0.22))
ctx.setLineWidth(10)
ctx.strokeEllipse(in: disc.insetBy(dx: 5, dy: 5))

let signal = CGMutablePath()
signal.move(to: CGPoint(x: 224, y: 494))
signal.addLine(to: CGPoint(x: 352, y: 494))
signal.addLine(to: CGPoint(x: 419, y: 574))
signal.addLine(to: CGPoint(x: 485, y: 344))
signal.addLine(to: CGPoint(x: 557, y: 654))
signal.addLine(to: CGPoint(x: 624, y: 483))
signal.addLine(to: CGPoint(x: 690, y: 494))
signal.addLine(to: CGPoint(x: 800, y: 494))

ctx.addPath(signal)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(31)
ctx.setStrokeColor(color(0.15, 0.81, 0.99, 0.85))
ctx.setShadow(offset: .zero, blur: 44, color: color(0.07, 0.75, 1.0, 0.65))
ctx.strokePath()
ctx.setShadow(offset: .zero, blur: 0)
ctx.addPath(signal)
ctx.setLineWidth(25)
ctx.setStrokeColor(color(0.25, 0.89, 1.0))
ctx.strokePath()

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL,
                UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot create icon image")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Cannot write icon image")
}
