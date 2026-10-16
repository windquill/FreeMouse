import AppKit
import Foundation
let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let rect = NSRect(x: 60, y: 60, width: 904, height: 904)
let path = NSBezierPath(roundedRect: rect, xRadius: 204, yRadius: 204)
NSGradient(starting: NSColor(calibratedRed: 0.28, green: 0.35, blue: 0.93, alpha: 1), ending: NSColor(calibratedRed: 0.44, green: 0.25, blue: 0.70, alpha: 1))!.draw(in: path, angle: -55)
NSColor.white.withAlphaComponent(0.9).setStroke()
let frame = NSBezierPath(); frame.lineWidth = 24; frame.lineCapStyle = .round
for (x,y,sx,sy) in [(270.0,280.0,1.0,1.0),(754.0,280.0,-1.0,1.0),(270.0,744.0,1.0,-1.0),(754.0,744.0,-1.0,-1.0)] {
    frame.move(to: NSPoint(x:x,y:y+sy*108)); frame.line(to:NSPoint(x:x,y:y)); frame.line(to:NSPoint(x:x+sx*108,y:y))
}
frame.stroke()
let cursor = NSBezierPath()
cursor.move(to:NSPoint(x:414,y:672)); cursor.line(to:NSPoint(x:414,y:363)); cursor.line(to:NSPoint(x:498,y:437)); cursor.line(to:NSPoint(x:565,y:303)); cursor.line(to:NSPoint(x:622,y:333)); cursor.line(to:NSPoint(x:555,y:467)); cursor.line(to:NSPoint(x:670,y:475)); cursor.close()
NSColor.white.setFill(); cursor.fill()
image.unlockFocus()
let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:destination))
