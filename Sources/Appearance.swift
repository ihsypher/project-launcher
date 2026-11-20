import SwiftUI

// MARK: - Project icons and colours

enum ProjectColor: String, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .gray: return .gray
        }
    }

    static func named(_ name: String) -> Color {
        (ProjectColor(rawValue: name) ?? .blue).color
    }
}

/// Symbols to choose from for a project.
let projectIcons = [
    "doc.text", "book", "books.vertical", "graduationcap", "pencil.and.ruler", "function",
    "sum", "atom", "flask", "testtube.2", "airplane", "gearshape.2",
    "cpu", "chart.bar", "chart.line.uptrend.xyaxis", "globe.europe.africa", "briefcase", "folder",
    "tray.full", "lightbulb", "paintbrush", "music.note", "camera", "hammer",
    "wrench.and.screwdriver", "bolt", "leaf", "heart", "star", "flag",
    "target", "calendar",
]

/// A rounded, coloured tile with a white symbol, like an app icon.
struct ProjectIcon: View {
    var icon: String
    var color: String
    var size: CGFloat = 20

    var body: some View {
        let tint = ProjectColor.named(color)
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// Grid of symbols and a row of colours, shown in a popover from the project's icon.
struct IconPicker: View {
    @Binding var icon: String
    @Binding var color: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                ForEach(projectIcons, id: \.self) { name in
                    Button { icon = name } label: {
                        Image(systemName: name)
                            .font(.system(size: 14))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(name == icon ? ProjectColor.named(color).opacity(0.25) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            Divider()
            HStack(spacing: 8) {
                ForEach(ProjectColor.allCases) { c in
                    Button { color = c.rawValue } label: {
                        Circle()
                            .fill(c.color)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary.opacity(c.rawValue == color ? 0.8 : 0), lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(c.rawValue.capitalized)
                }
            }
            .padding(.leading, 3)
        }
        .padding(14)
    }
}
