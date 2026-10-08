import ChatGPTBridgeCore
import SwiftUI

struct HarborRenameDialog: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.045), in: Circle())
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("连接名称")
                    .font(.system(size: 11, weight: .semibold))
                TextField("输入新的连接名称", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(focused ? HarborColors.blue.opacity(0.55) : Color.primary.opacity(0.10))
                    )
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))
                Button("保存", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(HarborColors.cardBackground)
        .onAppear { focused = true }
    }
}

struct HarborToolApprovalDialog: View {
    let request: BridgeApprovalRequest
    let onDeny: () -> Void
    let onAllow: () -> Void
    let onRemember: () -> Bool
    @State private var saveFailed = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            approvalContent(now: timeline.date)
        }
    }

    private func approvalContent(now: Date) -> some View {
        let remaining = request.remainingSeconds(at: now)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HarborColors.orange)
                    .frame(width: 38, height: 38)
                    .background(HarborColors.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 5) {
                    Text("允许 ChatGPT \(actionTitle)？")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("本次操作需要你的确认")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onDeny) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: .secondary, cornerRadius: 8))
                .help("拒绝本次请求")
                .accessibilityLabel("拒绝本次请求")
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(actionDescription)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                if let target = request.target, !target.isEmpty, request.tool != "restore_path" {
                    VStack(alignment: .leading, spacing: 5) {
                        detailLabel("作用位置")
                        ScrollView(.horizontal) {
                            Text(target == "." ? "当前工作区" : target)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.vertical, 2)
                        }
                        .scrollIndicators(.automatic)
                    }
                }

            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Label(remaining > 0 ? "剩余 \(remaining) 秒，超时自动拒绝" : "请求已超时", systemImage: "clock")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(remaining <= 15 ? HarborColors.orange : Color.secondary)
                if saveFailed {
                    Text("授权未保存，请重试或选择允许本次。")
                        .font(.system(size: 11)).foregroundStyle(HarborColors.red)
                } else if let scope = request.rememberScope {
                    Text(scope.explanation)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button("拒绝", role: .cancel, action: onDeny)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))
                Spacer()
                Button("允许本次", action: onAllow)
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .disabled(remaining == 0)
                if request.rememberScope != nil {
                    Button("同类不再询问") { saveFailed = !onRemember() }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
                    .disabled(remaining == 0)
                }
            }
        }
        .padding(22)
        .frame(width: 520, height: 340, alignment: .topLeading)
        .background(HarborColors.cardBackground)
    }

    private func detailLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var actionTitle: String {
        switch request.tool {
        case "edit", "patch_file", "apply_patch": "修改文件"
        case "write": "写入文件"
        case "create_directory": "创建目录"
        case "move_path": "移动文件或目录"
        case "trash_path": "移入回收站"
        case "restore_path": "恢复文件或目录"
        case "bash", "run_command", "start_command": commandAction
        case "git_push": "推送 Git 更改"
        case "start_workflow", "run_workflow": "运行项目流程"
        case "repair_project": "修复项目"
        case "coding_task": "执行代码任务"
        default: "执行本地操作"
        }
    }

    // Match only complete, known operations. Compound or unfamiliar commands
    // retain a general description rather than being mislabeled as a test.
    private var commandAction: String {
        switch request.summary.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "swift test", "npm test", "npm run test": "运行项目测试"
        case "swift build", "npm run build": "构建项目"
        case "./Scripts/build-app.sh", "zsh ./Scripts/build-app.sh", "bash ./Scripts/build-app.sh": "打包并安装应用"
        case "git status", "git diff": "检查代码改动"
        default: "执行项目操作"
        }
    }

    private var actionDescription: String {
        switch actionTitle {
        case "修改文件": "将修改指定文件中的内容。"
        case "写入文件": "将创建文件或更新已有文件的内容。"
        case "创建目录": "将在指定位置创建目录。"
        case "移动文件或目录": "将更改文件或目录的存放位置。"
        case "移入回收站": "将把指定文件或目录移入回收站。"
        case "恢复文件或目录": "将从回收站恢复所选文件或目录。"
        case "运行项目测试": "将运行项目测试，检查现有功能是否正常。"
        case "构建项目": "将编译项目并生成构建产物。"
        case "打包并安装应用": "将构建应用并更新本机安装的版本。"
        case "检查代码改动": "将检查项目中的文件改动。"
        case "推送 Git 更改": "将把本地提交上传到远程代码仓库。"
        case "运行项目流程": "将执行项目流程，可能包括测试与构建。"
        case "修复项目", "执行代码任务": "将处理项目代码，可能修改文件并运行验证。"
        default: "将在工作区执行本地程序，可能修改项目文件。"
        }
    }
}

struct HarborDestructiveConfirmDialog: View {
    let title: String
    let message: String
    var confirmTitle: String = "删除"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HarborColors.red)
                    .frame(width: 38, height: 38)
                    .background(HarborColors.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))
                Button(confirmTitle, role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .prominent))
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(HarborColors.cardBackground)
    }
}
