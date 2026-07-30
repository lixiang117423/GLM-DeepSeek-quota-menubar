import AppKit

/// macOS menu bar app entry point.
/// Hides the dock icon (accessory mode) and runs the app.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
