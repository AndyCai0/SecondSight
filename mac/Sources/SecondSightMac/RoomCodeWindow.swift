import AppKit
import SwiftUI

struct RoomCodeView: View {
    let code: String
    let onExit: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(role: .destructive, action: onExit) {
                Label("结束求助", systemImage: "xmark.circle.fill")
                    .font(.system(size: 26, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .accessibilityHint("停止分享画面并结束本次求助")
        }
        .padding(64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class RoomCodeWindowController {
    private var window: NSWindow?

    func show(code: String, onExit: @escaping () -> Void) {
        close()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "分享求助号码"
        window.minSize = NSSize(width: 700, height: 520)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RoomCodeView(code: code) { [weak self] in
            self?.close()
            onExit()
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}
