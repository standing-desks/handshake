import SwiftUI

/// A session's letters, so sessions stay distinguishable in the rail where their names don't fit.
struct SessionMonogram: View {
    let letters: String
    let isActive: Bool
    var size: CGFloat = SidebarLayout.monogramSize

    var body: some View {
        Text(letters)
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(isActive ? Color.white : .secondary)
            .frame(width: size, height: size)
            .background(
                isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                in: .rect(cornerRadius: size * 0.28)
            )
            .accessibilityHidden(true)
    }

    /// One letter, or two when another session's name starts with the same letter.
    static func letters(for name: String, among names: [String]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first.map({ String($0).uppercased() }) else { return "?" }
        let clashes = names.filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } == first
        }
        guard clashes.count > 1 else { return first }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        let second = words.count > 1 ? words[1].first : trimmed.dropFirst().first
        return first + (second.map { String($0).lowercased() } ?? "")
    }
}
