import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let window = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 320, height: 120),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "appfocus cold-launch acceptance"
window.makeKeyAndOrderFront(nil)
application.run()
