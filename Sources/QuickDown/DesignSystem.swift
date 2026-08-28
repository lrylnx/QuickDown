import SwiftUI
import QuickDownCore

// MARK: - 主题
//
// 统一品牌色与材质：跟随系统强调色，深浅色模式自动适配。

enum QDTheme {
    /// 品牌主色（跟随系统强调色，保持原生观感）
    static let accent = Color.accentColor

    /// 品牌渐变（强调色 → 靛紫）
    static let accentGradient = LinearGradient(
        colors: [accent,
                 Color(red: 0.45, green: 0.42, blue: 0.96)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    /// 图标底色的柔和渐变
    static func softGradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.22), color.opacity(0.06)],
                       startPoint: .top,
                       endPoint: .bottom)
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
        case .connecting:  return .blue
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

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
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
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    func qdCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(QDCard(cornerRadius: cornerRadius))
    }
}

// MARK: - 主操作按钮（胶囊 + 品牌渐变）

struct QDPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(QDTheme.accentGradient)
                    .opacity(isEnabled ? 1 : 0.4)
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
