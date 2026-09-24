import SwiftUI

struct HarborAccountSetupSheet: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            VStack(alignment: .leading, spacing: 0) {
                step(
                    number: 1,
                    title: "保护当前账户",
                    detail: "已创建隔离登录环境",
                    state: .complete,
                    drawsLine: true
                )
                step(
                    number: 2,
                    title: "登录新账户",
                    detail: model.isAwaitingAccountLogin ? "请在浏览器完成官方授权" : "打开 Codex 官方登录",
                    state: model.detectedAccountName != nil ? .complete : (model.isAwaitingAccountLogin ? .active : .idle),
                    drawsLine: true
                )
                step(
                    number: 3,
                    title: "识别并保存",
                    detail: model.detectedAccountName ?? "自动读取账户名称并加入列表",
                    state: model.detectedAccountName != nil ? .complete : (model.isAwaitingAccountLogin ? .active : .idle),
                    drawsLine: false
                )
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.40), in: RoundedRectangle(cornerRadius: 14))

            statusContent

            HStack {
                Label("Harbor 不会读取账号密码或验证码", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("取消") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))
                .disabled(model.isBusy)

                if !model.isAwaitingAccountLogin && model.detectedAccountName == nil {
                    Button("开始官方登录") {
                        Task { await model.beginAddingAccount() }
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                    .disabled(model.isBusy)
                } else if model.detectedAccountName != nil {
                    Button("关闭", action: onClose)
                        .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                }
            }
        }
        .padding(28)
        .frame(width: 560)
        .interactiveDismissDisabled(
            model.isBusy || (model.isAwaitingAccountLogin && model.detectedAccountName == nil)
        )
        .onAppear {
            model.resetAccountLoginFlow()
            pulse = false
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onExitCommand {
            close()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("添加 Codex 账户")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("通过 Codex 官方登录添加账户")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.045), in: Circle())
            }
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if let accountName = model.detectedAccountName {
            Label("账户已添加：\(accountName)", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        } else if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isAwaitingAccountLogin {
            HStack {
                ProgressView().controlSize(.small)
                Text("等待浏览器登录完成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("检测登录完成") {
                    Task { await model.detectNewAccountLogin() }
                }
                .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .secondary))
                .disabled(model.isBusy)
            }
        }
    }

    private func step(
        number: Int,
        title: String,
        detail: String,
        state: SheetFlowState,
        drawsLine: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    if state == .active {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.28), lineWidth: 2)
                            .frame(width: 30, height: 30)
                            .scaleEffect(pulse ? 1.24 : 0.92)
                            .opacity(pulse ? 0.15 : 0.75)
                    }

                    Circle()
                        .fill(stepColor(state))
                        .frame(width: 28, height: 28)

                    if state == .complete {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(number)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(state == .idle ? Color.secondary : Color.white)
                    }
                }

                if drawsLine {
                    Rectangle()
                        .fill(state == .complete ? Color.green.opacity(0.45) : Color.secondary.opacity(0.20))
                        .frame(width: 2, height: 42)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 3)
        }
    }

    private func stepColor(_ state: SheetFlowState) -> Color {
        switch state {
        case .idle: Color.secondary.opacity(0.14)
        case .active: Color.accentColor
        case .complete: Color.green
        }
    }

    private func close() {
        if model.isAwaitingAccountLogin && model.detectedAccountName == nil {
            Task {
                await model.cancelAddingAccount()
                if model.errorMessage == nil {
                    onClose()
                }
            }
        } else {
            onClose()
        }
    }
}

private enum SheetFlowState {
    case idle
    case active
    case complete
}
