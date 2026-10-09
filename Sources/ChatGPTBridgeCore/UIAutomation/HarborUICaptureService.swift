import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

public struct HarborUICaptureResult: Codable, Sendable {
    public let bundleID: String
    public let windowTitle: String
    public let width: Int
    public let height: Int
    public let imageFormat: String
    public let base64: String
}

/// Single-frame, opt-in screenshot of one exact window only. No stream is
/// started; no captures happen on timers, during inspection, or in the
/// background. Permissions are independent of AX read/control grants.
@MainActor
public final class HarborUICaptureService {
    private let consent: HarborUIConsentStore
    private let paths: BridgePaths

    public init(paths: BridgePaths) {
        self.paths = paths
        consent = HarborUIConsentStore(paths: paths)
    }

    public func capture(
        bundleID: String, windowIndex: Int, windowTitle: String,
        skipAgentAXValidation: Bool = false
    ) async throws -> HarborUICaptureResult {
        guard consent.allows(bundleID: bundleID, capability: .capture) else {
            throw BridgeError.permissionDenied(
                "尚未获得 \(bundleID) 的单帧截图授权，请通过本地授权弹窗确认"
            )
        }
        // This method runs ONLY for an explicit ui_capture call with a
        // separate per-app capture grant. ScreenCaptureKit is the authoritative
        // system permission gate. The legacy CG preflight can lag an updated
        // macOS Screen & System Audio Recording grant; do not reject a valid
        // ScreenCaptureKit grant solely because that probe is stale.
        let legacyScreenPermission = CGPreflightScreenCaptureAccess()
        // Only the signed Agent may use the GUI socket path. It verifies the
        // exact AX window index/title before forwarding the request. The GUI
        // cannot rely on AX because macOS granted Accessibility to the Agent,
        // not the main application. ScreenCaptureKit still matches the exact
        // bundle ID and a unique on-screen window title.
        if !skipAgentAXValidation {
            let windows = try HarborUIAutomationService(paths: paths)
                .windows(bundleID: bundleID)
            guard windows.contains(where: {
                $0.windowIndex == windowIndex && $0.title == windowTitle
            }) else {
                throw BridgeError.permissionDenied("所选窗口已改变，不能继续捕获")
            }
        }

        // Do not call CGRequestScreenCaptureAccess() from this launchd-managed
        // headless Agent. CoreGraphics can abort the process with
        // CGS_REQUIRE_INIT because no graphics session is initialized.
        // Only the foreground application may present a system consent prompt.
        // ScreenCaptureKit remains the enforcement gate for this explicit
        // one-frame request; a denial is returned as an error, never bypassed.
        let available: SCShareableContent
        do {
            available = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            let underlying = error as NSError
            let diagnostic = "\(underlying.domain) (\(underlying.code))"
            if !legacyScreenPermission {
                throw BridgeError.permissionDenied(
                    "无法获取窗口截图：系统录屏预检未通过，ScreenCaptureKit 返回 \(diagnostic)。请检查新版 HarborChatGPTAgent 的「屏幕与系统音频录制」权限"
                )
            }
            throw BridgeError.searchFailed(
                "ScreenCaptureKit 无法列出窗口：\(diagnostic)"
            )
        }
        let candidates = available.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID &&
            $0.title == windowTitle && $0.isOnScreen
        }
        guard candidates.count == 1, let window = candidates.first else {
            throw BridgeError.permissionDenied("无法唯一识别目标窗口，已拒绝截图以防捕获其他窗口")
        }

        let config = SCStreamConfiguration()
        let size = window.frame.size
        let factor = min(1, 1280 / max(size.width, size.height, 1))
        config.width = max(1, Int(size.width * factor))
        config.height = max(1, Int(size.height * factor))
        config.showsCursor = false
        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config
        )
        guard let bytes = NSBitmapImageRep(cgImage: cgImage).representation(
            using: .jpeg, properties: [.compressionFactor: 0.58]
        ), bytes.count < 2_000_000 else {
            throw BridgeError.fileTooLarge("画面尺寸超限，未输出截图")
        }
        return HarborUICaptureResult(
            bundleID: bundleID, windowTitle: windowTitle,
            width: cgImage.width, height: cgImage.height,
            imageFormat: "image/jpeg", base64: bytes.base64EncodedString()
        )
    }
}
