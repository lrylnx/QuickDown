import SwiftUI
import QuickDownCore

// MARK: - 主题
//
// 统一品牌色与材质：跟随系统强调色，深浅色模式自动适配。

enum QDTheme {
    /// 品牌主色（速下绿，与 App 图标 / 扩展 / 菜单栏图标同色系）
    static let accent = Color(red: 0.16, green: 0.65, blue: 0.36)

    /// 品牌渐变（亮翠绿 → 品牌绿，与图标同款对角渐变）
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.31, green: 0.78, blue: 0.47),
                 Color(red: 0.11, green: 0.55, blue: 0.31)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    /// 图标底色的柔和渐变
    static func softGradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.22), color.opacity(0.06)],
                       startPoint: .top,
                       endPoint: .bottom)
    }
}

// MARK: - 分割线
//
// 系统 Divider 在深色模式下过淡（几乎不可见），统一用自定义分割线：
// 主线条 + 极淡高光，深浅色都清晰但不抢眼。

struct QDDivider: View {
    /// true = 垂直分割线（如侧栏与内容区之间）
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

// MARK: - 分类配色

extension DownloadCategory {
    var color: Color {
        switch self {
        case .video:      return Color(red: 0.95, green: 0.36, blue: 0.36)  // 红
        case .music:      return Color(red: 0.70, green: 0.43, blue: 0.90)  // 紫
        case .archive:    return Color(red: 0.96, green: 0.61, blue: 0.23)  // 橙
        case .image:      return Color(red: 0.33, green: 0.58, blue: 0.97)  // 蓝
        case .application:return Color(red: 0.30, green: 0.72, blue: 0.47)  // 绿
        case .document:   return Color(red: 0.25, green: 0.68, blue: 0.65)  // 青
        case .code:       return Color(red: 0.48, green: 0.46, blue: 0.92)  // 靛
        case .other:      return .gray
        }
    }
}

// MARK: - 状态配色

extension DownloadStatus {
    var color: Color {
        switch self {
        case .queued:      return .secondary
        case .connecting:  return .teal
        case .downloading: return QDTheme.accent
        case .paused:      return .orange
        case .completed:   return .green
        case .error:       return .red
        case .cancelled:   return .gray
        }
    }
}

// MARK: - 分类图标容器（圆角渐变底 + 图标）

struct QDCategoryIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 36

    private var corner: CGFloat { size * 0.27 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(QDTheme.softGradient(color))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(color.opacity(0.24), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 状态圆点

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7
    /// true = 呼吸闪烁（用于「下载中」等活跃状态，让界面有生命感）
    var pulsing = false
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.4 : 1)
            .onAppear { restartPulse() }
            .onChange(of: pulsing) { _ in restartPulse() }
    }

    private func restartPulse() {
        dimmed = false
        guard pulsing else { return }
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}

// MARK: - 自定义进度条（胶囊形 + 渐变填充）

struct QDProgressBar: View {
    var value: Double
    var height: CGFloat = 6
    var gradient: LinearGradient = QDTheme.accentGradient

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(gradient)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: value)
    }
}

// MARK: - 卡片容器

struct QDCard: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 5, y: 2)
    }
}

extension View {
    func qdCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(QDCard(cornerRadius: cornerRadius))
    }
}

// MARK: - 主操作按钮（胶囊 + 品牌渐变）
//
// 悬停：白色提亮 + 品牌色光晕扩大 + 轻微上浮；按下：回缩。
// 悬停态做在 makeBody 返回的内层视图里（@State 挂在那里才能驱动动画）。

struct QDPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration)
    }

    private struct PrimaryBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var active: Bool { isEnabled && !configuration.isPressed }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(QDTheme.accentGradient)
                        .opacity(isEnabled ? 1 : 0.4)
                        .overlay(Capsule().fill(Color.white.opacity(active && hovering ? 0.14 : 0)))
                )
                .shadow(color: QDTheme.accent.opacity(isEnabled ? (hovering ? 0.42 : 0.30) : 0),
                        radius: active && hovering ? 10 : 6, y: 2)
                .scaleEffect(configuration.isPressed ? 0.97 : (active && hovering ? 1.03 : 1))
                .opacity(configuration.isPressed ? 0.92 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { hover in
                    hovering = hover
                    if hover { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .onDisappear {
                    if hovering { NSCursor.arrow.set(); hovering = false }
                }
        }
    }
}

// MARK: - 次级按钮（取消 / 打开文件夹 等）
//
// 系统 .bordered 在深色模式下是一块几乎与背景融为一体的暗灰矩形，
// 与品牌胶囊主按钮并列时风格割裂。统一为同高度胶囊：柔和底色 + 描边 + 悬停反馈。

struct QDSecondaryButtonStyle: ButtonStyle {
    /// 危险操作（如删除）传入红色，普通为 nil
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, tint: tint)
    }

    private struct SecondaryBody: View {
        let configuration: Configuration
        var tint: Color?
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var base: Color { tint ?? Color.primary }
        private var active: Bool { isEnabled && !configuration.isPressed }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(base.opacity(isEnabled ? 0.85 : 0.35))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(base.opacity(
                        configuration.isPressed ? 0.15 : (active && hovering ? 0.12 : 0.07)))
                )
                .overlay(
                    Capsule().strokeBorder(base.opacity(active && hovering ? 0.30 : 0.16), lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.92 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { hover in
                    hovering = hover
                    if hover { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .onDisappear {
                    if hovering { NSCursor.arrow.set(); hovering = false }
                }
        }
    }
}
