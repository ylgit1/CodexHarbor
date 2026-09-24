import SwiftUI
import CodexHarborCore

struct HarborHostedKeySheet: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @State private var activationKey = ""
    @State private var apiBaseURL = HarborRemoteConfiguration.fallback.apiBaseURL.absoluteString
    @State private var revealsKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            secureKeyField

            VStack(alignment: .leading, spacing: 7) {
                Text("服务地址")
                    .font(.callout.weight(.semibold))
                TextField("留空使用默认服务地址", text: $apiBaseURL)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()

                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))

                Button {
                    Task {
                        await model.addProfile(
                            activationKey: activationKey,
                            apiBaseURL: apiBaseURL
                        )
                        if model.errorMessage == nil {
                            activationKey = ""
                            onClose()
                        }
                    }
                } label: {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("验证并添加")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                .disabled(
                    model.isBusy
                        || activationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(26)
        .frame(width: 500, height: 330)
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack {
            Text("添加托管密钥")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.045), in: Circle())
            }
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
        }
    }

    private var secureKeyField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("托管密钥")
                .font(.callout.weight(.semibold))

            HStack(spacing: 8) {
                Group {
                    if revealsKey {
                        TextField("输入托管密钥", text: $activationKey)
                    } else {
                        SecureField("输入托管密钥", text: $activationKey)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))

                Button {
                    revealsKey.toggle()
                } label: {
                    Image(systemName: revealsKey ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        }
    }
}
