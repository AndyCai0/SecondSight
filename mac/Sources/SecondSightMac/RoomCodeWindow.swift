import AppKit
import SwiftUI

struct RoomCodeView: View {
    let code: String

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 76))
                .foregroundStyle(.blue)
            Text("请把这个号码告诉帮助您的人")
                .font(.system(size: 34, weight: .bold))
            Text(code)
                .font(.system(size: 104, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .tracking(14)
                .foregroundStyle(.blue)
            Text("对方加入后，这个画面会自动收起")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
        }
        .padding(64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class RoomCodeWindowController {
    private var window: NSWindow?

    func show(code: String) {
        close()
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: RoomCodeView(code: code))
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}
