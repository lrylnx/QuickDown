import AppKit
import SwiftUI

// MARK: - 下载完成角标弹窗
//
// 下载完成后在屏幕右下角滑入的轻量 toast：显示文件名 + 「打开文件」「打开文件夹」。
// 用非激活 NSPanel（borderless + nonactivatingPanel）实现：
// 弹出/点击都不抢当前应用焦点，几秒后自动淡出；同刻多条完成时替换内容并重新计时。

final class CompletionToast {
    static let shared = CompletionToast()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private let showDuration: TimeInterval = 5.5

    private var toastSize: CGSize { CGSize(width: 320, height: 128) }

    func show(filename: String, filePath: String?, directory: String) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        DispatchQueue.main.async { [weak self] in
            self?.present(filename: filename, filePath: filePath, directory: directory, on: screen)
        }
    }

    private func present(filename: String, filePath: String?, directory: String, on screen: NSScreen) {
        // 展示期间再次完成：直接替换内容并重置计时
        hideWorkItem?.cancel()

        let openFile = { [weak self] in
            self?.dismiss()
            if let path = filePath, FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory, isDirectory: true)])
            }
        }
        let openFolder = { [weak self] in
            self?.dismiss()
            var target = URL(fileURLWithPath: directory, isDirectory: true)
            if let path = filePath {
                let fileURL = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    target = fileURL.deletingLastPathComponent()
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    return
                }
            }
            NSWorkspace.shared.open(target)
        }

        let content = CompletionToastContent(
            filename: filename,
            onOpenFile: openFile,
            onOpenFolder: openFolder
        )

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
            panel.contentView = makeHostingView(content)
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: toastSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isMovable = false
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.ignoresMouseEvents = false
            panel.contentView = makeHostingView(content)
            self.panel = panel
        }

        // 右下角：可见区域留 16pt 边距，从屏幕右侧轻推入 + 淡入
        let vf = screen.visibleFrame
        let finalFrame = NSRect(
            x: vf.maxX - toastSize.width - 16,
            y: vf.minY + 16,
            width: toastSize.width,
            height: toastSize.height
        )
        panel.setFrame(finalFrame.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        })

        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + showDuration, execute: item)
    }

    private func makeHostingView(_ content: CompletionToastContent) -> NSHostingView<CompletionToastContent> {
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(origin: .zero, size: toastSize)
        // 让窗口圆角/阴影跟随 SwiftUI 背景形状
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        return view
    }

    private func dismiss() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

// MARK: - Toast 内容视图

private struct CompletionToastContent: View {
    let filename: String
    let onOpenFile: () -> Void
    let onOpenFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("文件下载完成")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text(filename)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("打开文件", action: onOpenFile)
                    .buttonStyle(QDPrimaryButtonStyle())
                Button("打开文件夹", action: onOpenFolder)
                    .buttonStyle(QDSecondaryButtonStyle())
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 320, height: 128, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
