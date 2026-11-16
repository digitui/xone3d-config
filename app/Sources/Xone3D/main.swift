import AppKit

// Programmatic AppKit bootstrap (no storyboard / NIB needed).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
