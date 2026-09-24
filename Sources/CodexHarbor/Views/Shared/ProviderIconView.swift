import CodexHarborCore
import SwiftUI

extension ProviderBrand {
    var tint: Color {
        switch self {
        case .openAI: .primary
        case .kimi: .purple
        case .qwen: .orange
        case .deepSeek: .cyan
        case .zhipu: .indigo
        case .miniMax: .orange
        case .openRouter: .purple
        case .siliconFlow: .teal
        case .custom: .blue
        }
    }
}

struct ProviderIconView: View {
    let identity: ProviderIdentity
    var size: CGFloat = 36

    var body: some View {
        Group {
            // DashScope hosts do not expose one stable favicon. Keep Qwen
            // recognizable offline instead of flashing between remote icons.
            if identity.brand == .qwen {
                fallback
            } else if let url = identity.faviconURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(size * 0.18)
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(identity.brand.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(identity.brand.tint.opacity(0.14))
        )
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Image(systemName: identity.brand.symbolName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(identity.brand.tint)
    }
}
