import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 调试：CLIPLINE_POLICY=regular 时按常规 App 运行，便于外部截图工具识别（正常启动是 accessory）。
if ProcessInfo.processInfo.environment["CLIPLINE_POLICY"] == "regular" {
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
} else {
    app.setActivationPolicy(.accessory)
}
// 调试：CLIPLINE_APPEARANCE=dark|light 强制外观，便于不改系统设置目测两种模式。
switch ProcessInfo.processInfo.environment["CLIPLINE_APPEARANCE"] {
case "dark": app.appearance = NSAppearance(named: .darkAqua)
case "light": app.appearance = NSAppearance(named: .aqua)
default: break
}
app.run()
