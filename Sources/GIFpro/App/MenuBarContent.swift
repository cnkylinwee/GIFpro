import AppKit
import SwiftUI

struct MenuBarContent: View {
    var body: some View {
        Button("开始录制") {}
            .disabled(true)

        Divider()

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}
