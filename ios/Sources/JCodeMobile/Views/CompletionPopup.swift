import SwiftUI

/// Plain SwiftUI popup docked above the composer (so it stays above the
/// keyboard): `/` lists skills + builtins, `@` lists server file matches.
struct CompletionPopup: View {
    let state: CompletionState
    let onAccept: (String) -> Void

    private static let maxVisible = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: state.kind == .slash ? "command" : "doc.text.magnifyingglass")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text(state.kind == .slash ? "Skills and commands" : "Files")
                    .font(Theme.mono(10.5, weight: .medium))
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Text("\(state.rows.count)")
                    .font(Theme.mono(10.5))
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.rows, id: \.self) { row in
                        Button {
                            onAccept(row)
                        } label: {
                            HStack(spacing: 8) {
                                Text(state.kind == .slash ? "/" : "@")
                                    .font(Theme.mono(13))
                                    .foregroundStyle(Theme.mint)
                                    .accessibilityHidden(true)
                                Text(row)
                                    .font(Theme.mono(13))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(state.kind == .slash ? "Slash \(row)" : "File \(row)")
                        .accessibilityHint("Inserts into the message")
                        Hairline().padding(.leading, 14)
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(state.rows.count, Self.maxVisible)) * 45)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .stroke(Theme.borderStrong, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completion")
    }
}
