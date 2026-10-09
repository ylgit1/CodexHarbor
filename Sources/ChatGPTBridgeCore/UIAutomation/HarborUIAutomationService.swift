import AppKit
import ApplicationServices
import Foundation

public struct HarborUIApp: Codable, Sendable {
    public let bundleID: String
    public let name: String
    public let running: Bool

    public init(bundleID: String, name: String, running: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.running = running
    }
}

public struct HarborUIWindow: Codable, Sendable {
    public let bundleID: String
    public let pid: Int32
    public let windowIndex: Int
    public let title: String
}

public struct HarborUIElement: Codable, Sendable {
    public let id: String
    public let role: String
    public let label: String
    public let value: String?
    public let enabled: Bool
    public let selected: Bool?
    public let actions: [String]
}

public struct HarborUITree: Codable, Sendable {
    public let bundleID: String
    public let windowTitle: String
    public let windowIndex: Int
    public let elements: [HarborUIElement]
    public let truncated: Bool
}

public struct HarborUITestStep: Codable, Sendable {
    public let elementID: String
    public let expectedLabel: String
    public let operation: String
    public let text: String?
    public let expectContains: String?
    public let expectWindowGone: Bool

    public init(
        elementID: String, expectedLabel: String, operation: String,
        text: String? = nil, expectContains: String? = nil,
        expectWindowGone: Bool = false
    ) {
        self.elementID = elementID
        self.expectedLabel = expectedLabel
        self.operation = operation
        self.text = text
        self.expectContains = expectContains
        self.expectWindowGone = expectWindowGone
    }
}

public struct HarborUITestStepResult: Codable, Sendable {
    public let index: Int
    public let operation: String
    public let passed: Bool
    public let message: String
}

public struct HarborUITestReport: Codable, Sendable {
    public let bundleID: String
    public let windowTitle: String
    public let passed: Bool
    public let steps: [HarborUITestStepResult]
    public let durationMilliseconds: Int
}

public struct HarborUIActionResult: Codable, Sendable {
    public let operation: String
    public let target: String
    public let succeeded: Bool
    public let before: HarborUITree
    public let after: HarborUITree
    public let explanation: String
}

/// UI automation runs only after the user has allowed that specific app in
/// Harbor's on-demand panel AND macOS has authorized the Agent's AX API.
/// It does not use screen capture, OCR, shell scripts or simulated trust.
@MainActor
public final class HarborUIAutomationService {
    private let consent: HarborUIConsentStore
    private let maxNodes = 160
    private let maxDepth = 6
    private let forbiddenWindowWords = [
        "authorization", "permissions", "security & privacy", "keychain",
        "password", "authentication", "privacy", "授权", "权限", "系统安全",
        "密码", "密钥", "付款", "支付"
    ]

    public init(paths: BridgePaths) {
        consent = HarborUIConsentStore(paths: paths)
    }

    public func runningApps() -> [HarborUIApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, !HarborUIConsentStore.isProtected(id),
                  app.activationPolicy == .regular else { return nil }
            return HarborUIApp(bundleID: id, name: app.localizedName ?? id, running: true)
        }.sorted { $0.name < $1.name }
    }

    public func open(bundleID: String) async throws -> HarborUIApp {
        guard consent.allows(bundleID: bundleID, capability: .read),
              !HarborUIConsentStore.isProtected(bundleID) else {
            throw BridgeError.permissionDenied("未在本机授权启动目标应用：\(bundleID)")
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw BridgeError.invalidPath("无法定位已安装的应用：\(bundleID)")
        }
        let app = try await NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration()
        )
        guard app.bundleIdentifier == bundleID else {
            throw BridgeError.permissionDenied("实际打开的应用与授权 Bundle ID 不符")
        }
        return HarborUIApp(bundleID: bundleID, name: app.localizedName ?? bundleID, running: true)
    }

    public func windows(bundleID: String) throws -> [HarborUIWindow] {
        let (app, _) = try access(bundleID: bundleID, operation: .read)
        let ui = AXUIElementCreateApplication(app.processIdentifier)
        return axChildren(ui, attribute: kAXWindowsAttribute).enumerated().compactMap { index, window in
            let title = axString(window, kAXTitleAttribute)
            guard !title.isEmpty, !isRestrictedWindow(title, bundleID: bundleID, operation: .read) else { return nil }
            return HarborUIWindow(bundleID: bundleID, pid: app.processIdentifier,
                                  windowIndex: index, title: title)
        }
    }

    public func inspect(bundleID: String, windowIndex: Int, windowTitle: String) throws -> HarborUITree {
        let (_, window) = try resolveWindow(
            bundleID: bundleID, windowIndex: windowIndex,
            windowTitle: windowTitle, operation: .read
        )
        var elements: [HarborUIElement] = []
        var truncated = false
        collect(window, path: "0", depth: 0, elements: &elements, truncated: &truncated)
        return HarborUITree(bundleID: bundleID, windowTitle: windowTitle,
                            windowIndex: windowIndex, elements: elements,
                            truncated: truncated)
    }

    public func perform(
        bundleID: String, windowIndex: Int, windowTitle: String,
        elementID: String, expectedLabel: String, operation: String,
        text: String? = nil
    ) throws -> HarborUIActionResult {
        let (_, window) = try resolveWindow(
            bundleID: bundleID, windowIndex: windowIndex,
            windowTitle: windowTitle, operation: .control
        )
        let before = try inspect(bundleID: bundleID, windowIndex: windowIndex,
                                 windowTitle: windowTitle)
        guard let info = before.elements.first(where: { $0.id == elementID }),
              info.label == expectedLabel, !expectedLabel.isEmpty,
              info.enabled, !HarborUISafety.isRestrictedAction(role: info.role, label: info.label)
        else { throw BridgeError.permissionDenied("控件已变化、不可用或属于敏感操作；请重新读取界面") }
        let element = try resolveElement(window, path: elementID)
        // Recheck the live element; never operate on an element that was
        // replaced since the immediately preceding UI tree read.
        guard axString(element, kAXRoleAttribute) == info.role,
              axLabel(element) == expectedLabel,
              axEnabled(element)
        else { throw BridgeError.permissionDenied("控件状态已变化，拒绝盲点") }

        let outcome: AXError
        switch operation {
        case "click":
            guard ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                   "AXMenuItem", "AXTab", "AXLink"].contains(info.role) else {
                throw BridgeError.permissionDenied("此控件不支持安全点击")
            }
            outcome = AXUIElementPerformAction(element, kAXPressAction as CFString)
        case "type":
            guard ["AXTextField", "AXTextArea"].contains(info.role),
                  let text, text.count <= 4_096,
                  !HarborUISafety.isSensitive(role: info.role, label: info.label)
            else { throw BridgeError.permissionDenied("禁止向密码、安全输入框或未知控件输入") }
            outcome = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString,
                                                  text as CFTypeRef)
        case "scroll_down", "scroll_up":
            guard info.role == "AXScrollArea" else {
                throw BridgeError.permissionDenied("只能滚动明确选中的滚动区域")
            }
            outcome = AXUIElementPerformAction(
                element, (operation == "scroll_down"
                    ? "AXScrollDown" : "AXScrollUp") as CFString
            )
        default:
            throw ToolRouterError.invalidArguments("仅支持 click/type/scroll_up/scroll_down；快捷键及拖动需单独安全验证")
        }
        guard outcome == .success else {
            throw BridgeError.writeFailed("macOS 辅助功能操作失败：AXError \(outcome.rawValue)")
        }
        // An action may close its window. That is a valid state transition,
        // not an AX failure; the caller can wait for the next window title.
        let after = (try? inspect(bundleID: bundleID, windowIndex: windowIndex,
                                  windowTitle: windowTitle)) ??
            HarborUITree(bundleID: bundleID, windowTitle: windowTitle,
                         windowIndex: windowIndex, elements: [], truncated: false)
        return HarborUIActionResult(
            operation: operation, target: "\(bundleID)/\(windowTitle)/\(elementID)",
            succeeded: true, before: before, after: after,
            explanation: after.elements.isEmpty
                ? "辅助功能操作成功；原窗口已关闭或无法再读取，请检查新窗口及业务结果"
                : "辅助功能操作成功；请根据前后控件状态验证业务结果"
        )
    }

    /// Run a bounded UI test, recording each operation and concrete
    /// postcondition. Stops on the first failure; never replays a failed click.
    public func runTest(
        bundleID: String, windowIndex: Int, windowTitle: String,
        steps: [HarborUITestStep]
    ) async -> HarborUITestReport {
        let started = Date()
        var results: [HarborUITestStepResult] = []
        guard !steps.isEmpty && steps.count <= 8 else {
            return HarborUITestReport(bundleID: bundleID, windowTitle: windowTitle,
                passed: false, steps: [HarborUITestStepResult(
                    index: 0, operation: "validate", passed: false,
                    message: "每次测试仅允许 1–8 个明确操作步骤"
                )], durationMilliseconds: 0)
        }
        // Never execute a test that could report "passed" without checking
        // an observable postcondition. Reject invalid test plans up front.
        for (index, step) in steps.enumerated() {
            if (step.expectContains?.isEmpty != false) && !step.expectWindowGone {
                return HarborUITestReport(
                    bundleID: bundleID, windowTitle: windowTitle, passed: false,
                    steps: [HarborUITestStepResult(
                        index: index, operation: step.operation, passed: false,
                        message: "测试步骤必须设置 expectContains 或 expectWindowGone，且不会执行未验证的操作"
                    )], durationMilliseconds: 0
                )
            }
        }
        for (index, step) in steps.enumerated() {
            do {
                _ = try perform(
                    bundleID: bundleID, windowIndex: windowIndex,
                    windowTitle: windowTitle, elementID: step.elementID,
                    expectedLabel: step.expectedLabel,
                    operation: step.operation, text: step.text
                )
                if step.expectWindowGone {
                    try await waitForWindowGone(
                        bundleID: bundleID, windowIndex: windowIndex,
                        windowTitle: windowTitle, timeoutSeconds: 8
                    )
                } else if let expected = step.expectContains {
                    _ = try await waitFor(
                        bundleID: bundleID, windowIndex: windowIndex,
                        windowTitle: windowTitle, containsText: expected,
                        timeoutSeconds: 8
                    )
                }
                results.append(HarborUITestStepResult(
                    index: index, operation: step.operation, passed: true,
                    message: step.expectWindowGone
                        ? "目标窗口已消失"
                        : "预期界面状态已出现"
                ))
            } catch {
                results.append(HarborUITestStepResult(
                    index: index, operation: step.operation, passed: false,
                    message: error.localizedDescription
                ))
                break
            }
        }
        return HarborUITestReport(
            bundleID: bundleID, windowTitle: windowTitle,
            passed: results.count == steps.count && results.allSatisfy(\.passed),
            steps: results,
            durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    public func waitForWindowGone(
        bundleID: String, windowIndex: Int, windowTitle: String,
        timeoutSeconds: Int
    ) async throws {
        guard (1...20).contains(timeoutSeconds) else {
            throw ToolRouterError.invalidArguments("窗口关闭等待时间最多 20 秒")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        repeat {
            try Task.checkCancellation()
            let list = try windows(bundleID: bundleID)
            if !list.contains(where: { $0.windowIndex == windowIndex && $0.title == windowTitle }) {
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        } while Date() < deadline
        throw BridgeError.commandTimedOut(timeoutSeconds)
    }

    public func waitForWindow(
        bundleID: String, titleContains: String, timeoutSeconds: Int
    ) async throws -> HarborUIWindow {
        guard (1...20).contains(timeoutSeconds), !titleContains.isEmpty,
              titleContains.count <= 180 else {
            throw ToolRouterError.invalidArguments("窗口等待条件不能为空，且最长 180 字、20 秒")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        repeat {
            try Task.checkCancellation()
            if let result = try windows(bundleID: bundleID).first(where: {
                $0.title.localizedCaseInsensitiveContains(titleContains)
            }) { return result }
            try await Task.sleep(for: .milliseconds(300))
        } while Date() < deadline
        throw BridgeError.commandTimedOut(timeoutSeconds)
    }

    public func waitFor(
        bundleID: String, windowIndex: Int, windowTitle: String,
        containsText: String, timeoutSeconds: Int
    ) async throws -> HarborUITree {
        guard (1...20).contains(timeoutSeconds), !containsText.isEmpty,
              containsText.count <= 180 else {
            throw ToolRouterError.invalidArguments("等待条件必须是 1–180 字，超时范围 1–20 秒")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        repeat {
            try Task.checkCancellation()
            let tree = try inspect(bundleID: bundleID, windowIndex: windowIndex,
                                   windowTitle: windowTitle)
            if tree.elements.contains(where: {
                $0.label.localizedCaseInsensitiveContains(containsText) ||
                    ($0.value?.localizedCaseInsensitiveContains(containsText) ?? false)
            }) { return tree }
            try await Task.sleep(for: .milliseconds(300))
        } while Date() < deadline
        throw BridgeError.commandTimedOut(timeoutSeconds)
    }

    private func access(bundleID: String, operation: HarborUIConsentStore.Capability) throws
        -> (NSRunningApplication, AXUIElement) {
        guard consent.allows(bundleID: bundleID, capability: operation) else {
            throw BridgeError.permissionDenied(
                "请先在 Codex Harbor → 设置 → 界面自动化中单独授权 \(bundleID) 的 \(operation.rawValue) 权限"
            )
        }
        guard AXIsProcessTrusted() else {
            throw BridgeError.permissionDenied(
                "macOS 尚未允许 HarborChatGPTAgent 使用辅助功能；请在系统设置 → 隐私与安全性 → 辅助功能中手动开启"
            )
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) else {
            throw BridgeError.permissionDenied("目标应用未运行")
        }
        return (app, AXUIElementCreateApplication(app.processIdentifier))
    }

    private func resolveWindow(
        bundleID: String, windowIndex: Int, windowTitle: String,
        operation: HarborUIConsentStore.Capability
    ) throws -> (NSRunningApplication, AXUIElement) {
        let (app, root) = try access(bundleID: bundleID, operation: operation)
        let windows = axChildren(root, attribute: kAXWindowsAttribute)
        guard !windowTitle.isEmpty,
              !isRestrictedWindow(windowTitle, bundleID: bundleID, operation: operation),
              windowIndex >= 0, windowIndex < windows.count,
              axString(windows[windowIndex], kAXTitleAttribute) == windowTitle
        else { throw BridgeError.permissionDenied("窗口已变化或属于受保护的系统/授权窗口；请重新选择") }
        return (app, windows[windowIndex])
    }

    private func resolveElement(_ root: AXUIElement, path: String) throws -> AXUIElement {
        let indices = path.split(separator: "/").compactMap { Int($0) }
        guard indices.count > 0, indices.count <= maxDepth + 1,
              indices.first == 0, indices.count == path.split(separator: "/").count else {
            throw ToolRouterError.invalidArguments("控件 ID 无效")
        }
        var element = root
        for index in indices.dropFirst() {
            let children = axChildren(element, attribute: kAXChildrenAttribute)
            guard index >= 0 && index < children.count else {
                throw BridgeError.permissionDenied("控件树已变化，请重新读取")
            }
            element = children[index]
        }
        return element
    }

    private func collect(
        _ element: AXUIElement, path: String, depth: Int,
        elements: inout [HarborUIElement], truncated: inout Bool
    ) {
        guard elements.count < maxNodes else { truncated = true; return }
        let role = axString(element, kAXRoleAttribute)
        let label = axLabel(element)
        let isSensitive = HarborUISafety.isSensitive(role: role, label: label)
        let value = isSensitive || ["AXTextField", "AXTextArea"].contains(role)
            ? nil : SecretRedactor().redact(
                axString(element, kAXValueAttribute, limit: 240)
            ).nilIfEmpty
        var selected: Bool?
        if let raw = axAttribute(element, kAXSelectedAttribute) as? NSNumber {
            selected = raw.boolValue
        }
        var cfNames: CFArray?
        let actions = AXUIElementCopyActionNames(element, &cfNames) == .success
            ? ((cfNames as? [String]) ?? []).filter {
                $0 == (kAXPressAction as String) ||
                $0 == "AXScrollUp" ||
                $0 == "AXScrollDown"
            } : []
        elements.append(HarborUIElement(
            id: path, role: role,
            label: isSensitive ? "（敏感控件）"
                : SecretRedactor().redact(String(label.prefix(240))),
            value: value, enabled: axEnabled(element), selected: selected, actions: actions
        ))
        guard depth < maxDepth else { return }
        for (index, child) in axChildren(element, attribute: kAXChildrenAttribute).enumerated() {
            if elements.count >= maxNodes { truncated = true; break }
            collect(child, path: path + "/\(index)", depth: depth + 1,
                    elements: &elements, truncated: &truncated)
        }
    }

    private func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func axString(_ element: AXUIElement, _ name: String, limit: Int = 240) -> String {
        guard let value = axAttribute(element, name) else { return "" }
        if let text = value as? String { return String(text.prefix(limit)) }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private func axLabel(_ element: AXUIElement) -> String {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
            let string = axString(element, attribute)
            if !string.isEmpty { return string }
        }
        return ""
    }

    private func axEnabled(_ element: AXUIElement) -> Bool {
        (axAttribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? false
    }

    private func axChildren(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        (axAttribute(element, attribute) as? [AXUIElement]) ?? []
    }

    private func isRestrictedWindow(
        _ title: String, bundleID: String,
        operation: HarborUIConsentStore.Capability
    ) -> Bool {
        let t = title.lowercased()
        guard forbiddenWindowWords.contains(where: t.contains) else { return false }
        // Test Harbor's own approval panel using AX *read only*. Even an
        // explicitly granted control scope cannot approve this panel.
        return !(operation == .read && bundleID == "com.codexharbor.app")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
