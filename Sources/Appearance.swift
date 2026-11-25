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

/// Symbols to choose from for a project, by topic.
let projectIconGroups: [(name: String, icons: [String])] = [
    ("Study", [
        "doc.text", "doc.richtext", "doc.on.doc", "book", "book.closed", "books.vertical", "text.book.closed",
        "graduationcap", "pencil", "pencil.and.ruler", "highlighter", "paperclip", "bookmark", "newspaper",
        "note.text", "list.bullet.rectangle", "checklist", "character.book.closed", "signature", "studentdesk",
    ]),
    ("Science & Maths", [
        "function", "sum", "x.squareroot", "percent", "plusminus", "divide", "number",
        "atom", "flask", "testtube.2", "microbe", "pills", "cross.case", "brain.head.profile",
        "waveform.path.ecg", "thermometer.medium", "scope", "scalemass", "ruler", "triangle",
    ]),
    ("Engineering", [
        "airplane", "airplane.departure", "car", "bus", "tram", "ferry", "bicycle",
        "fuelpump", "gearshape", "gearshape.2", "wrench.and.screwdriver", "hammer", "screwdriver", "cpu",
        "memorychip", "antenna.radiowaves.left.and.right", "bolt", "bolt.car", "powerplug", "battery.100",
    ]),
    ("Space & Nature", [
        "globe.europe.africa", "globe.americas", "moon.stars", "sun.max", "sparkles", "cloud.sun", "snowflake",
        "wind", "drop", "flame", "leaf", "tree", "mountain.2", "water.waves",
        "tortoise", "hare", "pawprint", "ladybug", "fish", "bird",
    ]),
    ("Data & Code", [
        "chart.bar", "chart.pie", "chart.line.uptrend.xyaxis", "chart.xyaxis.line", "tablecells", "square.grid.3x3", "cube",
        "cube.transparent", "shippingbox", "server.rack", "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "externaldrive",
        "network", "link", "lock", "key", "qrcode", "barcode",
    ]),
    ("Work", [
        "briefcase", "folder", "tray.full", "archivebox", "doc.text.magnifyingglass", "envelope", "paperplane",
        "phone", "bubble.left.and.bubble.right", "person", "person.2", "person.3", "building.2", "building.columns",
        "banknote", "creditcard", "cart", "bag", "signpost.right", "calendar",
    ]),
    ("Creative", [
        "lightbulb", "paintbrush", "paintpalette", "pencil.tip", "scissors", "camera", "photo",
        "film", "video", "music.note", "music.mic", "headphones", "guitars", "pianokeys",
        "theatermasks", "gamecontroller", "puzzlepiece", "dice", "wand.and.stars", "eyedropper",
    ]),
    ("Everyday", [
        "house", "heart", "star", "flag", "target", "bell", "clock",
        "timer", "hourglass", "alarm", "cup.and.saucer", "fork.knife", "dumbbell", "figure.run",
        "sportscourt", "soccerball", "tennisball", "gift", "map", "location",
    ]),
]

/// Every symbol to choose from, in order.
let projectIcons = projectIconGroups.flatMap(\.icons)

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

/// Symbols by topic (searchable) and a row of colours, shown in a popover from the project's icon.
struct IconPicker: View {
    @Binding var icon: String
    @Binding var color: String
    @State private var search = ""

    private var groups: [(name: String, icons: [String])] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return projectIconGroups }
        return projectIconGroups.compactMap { g in
            let topic = g.name.lowercased()
            let icons = g.icons.filter { name in
                words.allSatisfy { name.replacingOccurrences(of: ".", with: " ").contains($0) || topic.contains($0) }
            }
            return icons.isEmpty ? nil : (g.name, icons)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search icons", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.name) { group in
                        Text(group.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                            ForEach(group.icons, id: \.self) { name in
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
                    }
                    if groups.isEmpty {
                        Text("No icons match.").foregroundStyle(.secondary).font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 282, height: 300)
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
