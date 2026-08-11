import SwiftUI
import UIKit

struct CachedCoverImage: View {
    let urlString: String
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
                        colors: [YJColor.purple, YJColor.ink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .task(id: urlString) {
            image = nil
            guard let data = try? await CoverImageStore.shared.data(for: urlString) else { return }
            image = UIImage(data: data)
        }
    }
}
