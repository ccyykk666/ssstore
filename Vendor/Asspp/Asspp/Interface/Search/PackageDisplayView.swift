import ApplePackage
import Kingfisher
import SwiftUI

struct PackageDisplayView: View {
    let archive: AppStore.AppPackage
    var trailingText: String? = nil
    @State var style: DisplayStyle = .compact

    enum DisplayStyle {
        case compact
        case detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArchivePreviewView(archive: archive, preferredIconSize: 70, lineLimit: nil, trailingText: trailingText)
            if !archive.software.description.isEmpty {
                Text(archive.software.description)
                    .lineLimit(style == .compact ? 3 : nil)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            style = style == .compact ? .detail : .compact
                        }
                    } label: {
                        Text(style == .compact ? String(localized: "More") : "收起")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(style == .compact ? "展开应用介绍" : "收起应用介绍")
                }
            }
        }
        .padding(.vertical, 4)
    }
}


