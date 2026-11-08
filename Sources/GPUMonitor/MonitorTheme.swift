import SwiftUI
import AppKit

enum MonitorTheme {
    static let cyan = Color.primary
    static let mint = Color.green
    static let amber = Color.orange
    static let background = Color(nsColor: .textBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let surface = Color.primary.opacity(0.025)
    static let border = Color.primary.opacity(0.10)
}

struct MonitorBackdrop: View {
    var body: some View { MonitorTheme.background.ignoresSafeArea() }
}

struct FlatSurface: ViewModifier {
    var radius: CGFloat = 8
    func body(content: Content) -> some View {
        content.background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(MonitorTheme.border, lineWidth: 0.5))
    }
}

extension View {
    func monitorSurface(radius: CGFloat = 8) -> some View { modifier(FlatSurface(radius: radius)) }
}

struct StateBadge: View {
    var title: String
    var tint: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title).font(.system(size: 11, weight: .medium))
        }.padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.10), in: Capsule()).foregroundStyle(tint)
    }
}

struct MetricBar: View {
    var value: Double?
    var tint: Color = MonitorTheme.cyan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.opacity(0.65))
                    .frame(width: g.size.width * min(1, max(0, value ?? 0)))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: value)
            }
        }.frame(height: 4)
    }
}

extension CardState {
    var tint: Color {
        switch self { case .busy: return MonitorTheme.amber; case .occupied: return MonitorTheme.amber; case .idle: return MonitorTheme.mint; case .checking, .unknown: return .secondary }
    }
}

struct CardSelection: Identifiable {
    let serverID: UUID
    let deviceID: String
    var id: String { "\(serverID)-\(deviceID)" }
}


struct SubtleGlass: ViewModifier {
    var radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(MonitorTheme.sidebar, in: RoundedRectangle(cornerRadius: radius))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

extension View {
    func subtleGlass(radius: CGFloat = 8) -> some View { modifier(SubtleGlass(radius: radius)) }
}

struct SidebarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { }
}

extension MonitorPanel {
    var tint: Color {
        switch self {
        case .gpu: return .primary
        case .cpu: return .purple
        case .memory: return .teal
        case .network: return .blue
        case .disk: return .pink
        }
    }
}
