import AppKit
import QuickLook
@preconcurrency import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct GIFPreviewView: View {
    static let saveButtonTitle = "另存为"
    static let rerecordButtonTitle = "重新录制"
    static let discardButtonTitle = "丢弃"

    let url: URL
    let metadata: GIFPreviewMetadata
    let notice: RecordingCompletionNotice?
    let actions: GIFPreviewViewActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuickLookGIFView(url: url)
                .frame(minWidth: 480, minHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 16) {
                Label(metadata.dimensionsText, systemImage: "rectangle")
                Label(metadata.durationText, systemImage: "clock")
                Label(metadata.fileSizeText, systemImage: "internaldrive")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let noticeText {
                Label(noticeText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            HStack {
                Button(Self.saveButtonTitle, action: actions.saveAgain)
                    .keyboardShortcut("s", modifiers: .command)
                Spacer()
                Button(Self.rerecordButtonTitle, action: actions.rerecord)
                Button(Self.discardButtonTitle, role: .destructive, action: actions.discard)
            }
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 430)
    }

    private var noticeText: String? {
        switch notice {
        case .displayRemoved: return "目标显示器已断开，录制已提前结束。"
        case .captureStopped: return "屏幕捕捉已由系统停止。"
        case nil: return nil
        }
    }
}

private struct QuickLookGIFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)
        view?.autostarts = true
        view?.shouldCloseWithWindow = false
        view?.previewItem = url as QLPreviewItem
        return view ?? QLPreviewView(frame: .zero, style: .normal)!
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as QLPreviewItem
    }
}

@MainActor
final class GIFPreviewWindowController: GIFPreviewWindowPresenting {
    private(set) var window: NSPanel?

    func present(
        url: URL,
        metadata: GIFPreviewMetadata,
        notice: RecordingCompletionNotice?,
        actions: GIFPreviewViewActions
    ) {
        let panel = window ?? makePanel()
        panel.contentViewController = NSHostingController(
            rootView: GIFPreviewView(url: url, metadata: metadata, notice: notice, actions: actions)
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "GIF 预览"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window = panel
        return panel
    }
}

@MainActor
final class AppKitGIFSavePanelPresenter: GIFSavePanelPresenting {
    private weak var previewWindow: GIFPreviewWindowController?
    private let panelFactory: () -> NSSavePanel
    private let beginPanel: (NSSavePanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private let cancelPanel: (NSSavePanel) -> Void
    private var activePanel: NSSavePanel?

    init(previewWindow: GIFPreviewWindowController) {
        self.previewWindow = previewWindow
        panelFactory = NSSavePanel.init
        beginPanel = { panel, parent, completion in
            if let parent {
                panel.beginSheetModal(for: parent, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
        cancelPanel = { $0.cancelOperation(nil) }
    }

    init(
        previewWindow: GIFPreviewWindowController,
        panelFactory: @escaping () -> NSSavePanel,
        beginPanel: @escaping (NSSavePanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void,
        cancelPanel: @escaping (NSSavePanel) -> Void
    ) {
        self.previewWindow = previewWindow
        self.panelFactory = panelFactory
        self.beginPanel = beginPanel
        self.cancelPanel = cancelPanel
    }

    func present(
        configuration: GIFSavePanelConfiguration,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        guard activePanel == nil else { return }
        let panel = panelFactory()
        activePanel = panel
        panel.allowedContentTypes = [.gif]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = configuration.suggestedFilename
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self,
                  let panel,
                  self.activePanel === panel else { return }
            let result = response == .OK ? panel.url : nil
            self.activePanel = nil
            completion(result)
        }
        beginPanel(panel, previewWindow?.window, completed)
    }

    func cancel() {
        guard let panel = activePanel else { return }
        activePanel = nil
        cancelPanel(panel)
    }
}

@MainActor
final class SystemQuickLookController: NSObject, SystemQuickLookPresenting {
    private var url: URL?

    func present(url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

}

extension SystemQuickLookController: @MainActor QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        precondition(index == 0)
        return url! as NSURL
    }
}
