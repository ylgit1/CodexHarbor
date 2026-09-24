import SwiftUI
import CodexHarborCore

struct HarborCustomAPISheet: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @State private var name = ""
    @State private var apiKey = ""
    @State private var provider: CustomAPIProvider = .openAI
    @State private var apiBaseURL = CustomAPIProvider.openAI.defaultBaseURL
    @State private var modelName = ""
    @State private var revealsKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 8) {
                Text("常用模板")
                    .font(.callout.weight(.semibold))

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(HarborAPIPreset.common) { preset in
                        presetButton(preset)
                    }
                }

                Text("连接提供商")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("连接提供商", selection: $provider) {
                    ForEach(CustomAPIProvider.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }

            field("连接名称") {
                formTextField("例如 Kimi、公司网关", text: $name)
            }

            field("API Key") {
                HStack(spacing: 8) {
                    Group {
                        if revealsKey {
                            TextField("输入 API Key", text: $apiKey)
                        } else {
                            SecureField("输入 API Key", text: $apiKey)
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

            field("API 地址") {
                formTextField("https://api.example.com/v1", text: $apiBaseURL, monospaced: true)
            }

            if let identity = previewIdentity {
                HStack(spacing: 10) {
                    ProviderIconView(identity: identity, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.brand.title)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(identity.host)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Label("已识别", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(HarborColors.green)
                }
                .padding(10)
                .background(identity.brand.tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }

            field("模型") {
                formTextField("可留空，将自动选择", text: $modelName, monospaced: true)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))

                Button {
                    Task {
                        await model.addCustomProfile(
                            name: name,
                            apiKey: apiKey,
                            apiBaseURL: apiBaseURL,
                            model: modelName,
                            provider: provider
                        )

                        if model.errorMessage == nil {
                            apiKey = ""
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
                .disabled(!canSubmit)
            }
        }
        .padding(26)
        .frame(width: 600)
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack {
            Text("添加自定义 API")
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

    private func presetButton(_ preset: HarborAPIPreset) -> some View {
        let selected = apiBaseURL == preset.baseURL

        return Button {
            name = name.isEmpty ? preset.name : name
            apiBaseURL = preset.baseURL
            if let matchedProvider = CustomAPIProvider.allCases.first(where: { item in
                preset.baseURL.contains(item.defaultBaseURL.replacingOccurrences(of: "https://", with: ""))
            }) {
                provider = matchedProvider
            }
        } label: {
            HStack(spacing: 7) {
                if let url = URL(string: preset.baseURL) {
                    ProviderIconView(identity: ProviderCatalog.identity(for: url), size: 26)
                }

                Text(preset.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(HarborColors.blue)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(
                selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.50) : Color.primary.opacity(0.10), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.callout.weight(.semibold))
            content()
        }
    }

    private func formTextField(
        _ placeholder: String,
        text: Binding<String>,
        monospaced: Bool = false
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }

    private var previewIdentity: ProviderIdentity? {
        guard let url = URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ProviderCatalog.identity(for: url)
    }

    private var canSubmit: Bool {
        !model.isBusy
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct HarborAPIPreset: Identifiable {
    let id: String
    let name: String
    let baseURL: String

    static let common: [HarborAPIPreset] = [
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1"),
        .init(id: "kimi", name: "Kimi", baseURL: "https://api.moonshot.cn/v1"),
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1"),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"),
        .init(id: "siliconflow", name: "SiliconFlow", baseURL: "https://api.siliconflow.cn/v1")
    ]
}
