import SwiftUI
import UIKit

struct CachedCoverImage: View {
    let urlString: String
    var maxPixelSize = 512
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [YJColor.elevated, YJColor.paper],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .task(id: "\(urlString)|\(maxPixelSize)") {
            image = nil
            image = try? await CoverImageStore.shared.image(for: urlString, maxPixelSize: maxPixelSize)
        }
    }
}
