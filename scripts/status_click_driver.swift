import CoreGraphics
import Foundation

// A separate process keeps mouse release independent of the application's UI.
guard CommandLine.arguments.count == 4,
      let x = Double(CommandLine.arguments[1]), let y = Double(CommandLine.arguments[2]),
      let milliseconds = Int(CommandLine.arguments[3]), x.isFinite, y.isFinite,
      (0...1000).contains(milliseconds), CGPreflightPostEventAccess() else { exit(1) }
let point = CGPoint(x: x, y: y)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.05)
for (type, delay) in [(CGEventType.leftMouseDown, Double(milliseconds) / 1000), (.leftMouseUp, 0.0)] {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventClickState, value: 1)
    event?.post(tap: .cghidEventTap)
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
}
