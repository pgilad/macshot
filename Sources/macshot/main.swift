import Cocoa

// Disable "AutomaticAppKit" layer content format introduced in Big Sur.
// With automatic format, the window server's compositor applies ordered
// dithering to draw()-based layer content during compositing, which alters
// pixel values in solid-color areas. Setting this to false forces RGBA8
// format, giving pixel-perfect color reproduction — critical for a
// screenshot tool where captured colors must be exact.
UserDefaults.standard.set(false, forKey: "NSViewUsesAutomaticLayerBackingStores")

// main.swift always runs on the main thread. app.run() does not return,
// so the delegate stays alive for the life of the app.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
