import AppKit

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
withExtendedLifetime(appDelegate) {
    application.run()
}
