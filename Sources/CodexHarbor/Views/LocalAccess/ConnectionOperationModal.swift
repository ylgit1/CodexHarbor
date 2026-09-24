import SwiftUI
import ChatGPTBridgeCore

enum ConnectionOperationState: Equatable {
    case idle
    case preparing
    case running
    case checking
    case success
    case failed
}

enum ConnectionOperationKind: Equatable {
    case starting
    case switching
    case reconnecting
    case stopping

    var title: String {
        switch self {
        case .starting: "正在启动服务"
        case .switching: "正在切换连接"
        case .reconnecting: "正在重新连接"
        case .stopping: "正在关闭服务"
        }
    }
}

enum ConnectionOperationStepState: Equatable {
    case waiting
    case running
    case completed
    case failed
}

struct ConnectionOperationStep: Identifiable, Equatable {
    let id: String
    let title: String
    var state: ConnectionOperationStepState
    var detail: String

    init(id: String, title: String, state: ConnectionOperationStepState = .waiting, detail: String = "等待") {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
    }
}

struct ConnectionOperationContext: Identifiable, Equatable {
    let id = UUID()
    let kind: ConnectionOperationKind
    let subtitle: String
    var state: ConnectionOperationState
    var steps: [ConnectionOperationStep]
    var footer: String
}

struct ConnectionOperationModal: View {
    let operation: ConnectionOperationContext
    let onDismissFailure: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.10))
                        .frame(width: 42, height: 42)
                    if operation.state == .success {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(HarborColors.green)
                    } else if operation.state == .failed {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(HarborColors.red)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(HarborColors.blue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(operation.kind.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(operation.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if operation.state == .failed {
                    Button(action: onDismissFailure) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(HarborInteractivePlainButtonStyle(tint: .secondary, cornerRadius: 9))
                    .help("关闭")
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(operation.steps.enumerated()), id: \.element.id) { index, step in
                    operationStep(step)
                    if index < operation.steps.count - 1 {
                        Divider()
                            .opacity(0.34)
                            .padding(.leading, 36)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: footerIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(operation.footer)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(operation.state == .failed ? HarborColors.red : .secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 20)
        }
        .padding(24)
        .frame(width: 440, height: 330, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 30, y: 14)
        .transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.975))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(operation.kind.title)，\(operation.subtitle)")
    }

    private func operationStep(_ step: ConnectionOperationStep) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(stepColor(step.state).opacity(0.11))
                    .frame(width: 24, height: 24)
                switch step.state {
                case .waiting:
                    Circle()
                        .stroke(stepColor(step.state).opacity(0.45), lineWidth: 1.3)
                        .frame(width: 7, height: 7)
                case .running:
                    ProgressView()
                        .controlSize(.mini)
                        .tint(HarborColors.blue)
                case .completed:
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(HarborColors.green)
                case .failed:
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(HarborColors.red)
                }
            }

            Text(step.title)
                .font(.system(size: 11.5, weight: .semibold))

            Spacer(minLength: 12)

            Text(step.detail)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(stepColor(step.state))
                .lineLimit(1)
                .frame(width: 88, alignment: .trailing)
        }
        .frame(height: 46)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: step.state)
    }

    private var accentColor: Color {
        switch operation.state {
        case .success: HarborColors.green
        case .failed: HarborColors.red
        default: HarborColors.blue
        }
    }

    private var footerIcon: String {
        switch operation.state {
        case .success: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private func stepColor(_ state: ConnectionOperationStepState) -> Color {
        switch state {
        case .waiting: .secondary
        case .running: HarborColors.blue
        case .completed: HarborColors.green
        case .failed: HarborColors.red
        }
    }
}

struct ConnectionTestFeedback: Equatable {
    enum State: Equatable {
        case testing
        case success
        case failed
    }

    var state: State
    var title: String
    var detail: String
}

struct ConnectionTestToast: View {
    let feedback: ConnectionTestFeedback

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.10))
                    .frame(width: 30, height: 30)
                if feedback.state == .testing {
                    ProgressView().controlSize(.mini).tint(HarborColors.blue)
                } else {
                    Image(systemName: feedback.state == .success ? "checkmark" : "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(color)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(feedback.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 270, height: 54, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.14)))
        .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch feedback.state {
        case .testing: HarborColors.blue
        case .success: HarborColors.green
        case .failed: HarborColors.red
        }
    }
}
