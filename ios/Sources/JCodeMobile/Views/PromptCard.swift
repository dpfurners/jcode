import JCodeKit
import SwiftUI

/// Inline card for a pending `stdin_request`: the tool's prompt text, a
/// field (secure when the tool asked for a password) and Send.
struct PromptCard: View {
    let prompt: PendingPrompt
    let onSend: (String) -> Void
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: prompt.isPassword ? "lock.fill" : "questionmark.bubble.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text("Needs your input")
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer(minLength: 0)
            }
            Text(prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(Theme.mono(13))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Group {
                    if prompt.isPassword {
                        SecureField("Password", text: $input)
                    } else {
                        TextField("Answer", text: $input)
                    }
                }
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.mint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .stroke(focused ? Theme.mint.opacity(0.45) : Theme.border, lineWidth: 1))
                .accessibilityLabel(prompt.isPassword ? "Password" : "Answer")
                Button(action: send) {
                    Text("Send")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.mintGradient))
                        .frame(minHeight: 44)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Send answer")
                .accessibilityHint("Replies to the waiting tool")
            }
        }
        .padding(14)
        .background(Theme.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .stroke(Theme.warning.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prompt: \(prompt.prompt)")
    }

    /// An empty answer is legitimate (Enter to accept a default), so only
    /// the request id gates sending.
    private func send() {
        onSend(input)
        input = ""
    }
}
