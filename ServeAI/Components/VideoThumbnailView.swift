import SwiftUI
import UIKit

struct VideoThumbnailView: View {
    let data: Data?
    let score: Int?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        ServeAITheme.deepSurface
                        Image(systemName: "figure.tennis")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(ServeAITheme.brand.opacity(0.72))
                    }
                }
            }
            .frame(width: 86, height: 64)
            .clipped()

            Text(score.map(String.init) ?? "DATA")
                .font(ServeAITheme.mono(.caption, size: 11, bold: true))
                .foregroundStyle(ServeAITheme.brand)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(ServeAITheme.background.opacity(0.94), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ServeAITheme.separator) }
        .accessibilityHidden(true)
    }
}
