import CryptoKit
import Foundation
import ImageIO
import UIKit

actor CoverImageStore {
    static let shared = CoverImageStore()

    private let directory: URL
    private var downloads: [String: Task<Data, Error>] = [:]
    private let decodedImages = NSCache<NSString, UIImage>()

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        directory = applicationSupport
            .appending(path: "YouJi", directoryHint: .isDirectory)
            .appending(path: "Covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(values)
        decodedImages.countLimit = 120
        decodedImages.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(for urlString: String) async throws -> UIImage {
        let key = cacheKey(for: urlString)
        if let image = decodedImages.object(forKey: key as NSString) {
            return image
        }

        let data = try await data(for: urlString)
        if let image = decodedImages.object(forKey: key as NSString) {
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512
                ] as CFDictionary
              ) else {
            throw CoverImageError.decodeFailed
        }

        let image = UIImage(cgImage: cgImage)
        decodedImages.setObject(
            image,
            forKey: key as NSString,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return image
    }

    func data(for urlString: String) async throws -> Data {
        guard let remoteURL = URL(string: urlString), !urlString.isEmpty else {
            throw CoverImageError.invalidURL
        }
        let key = cacheKey(for: urlString)
        let localURL = directory.appending(path: key)

        if let data = try? Data(contentsOf: localURL, options: .mappedIfSafe), !data.isEmpty {
            return data
        }
        if let download = downloads[key] {
            return try await download.value
        }

        let download = Task<Data, Error> {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode,
                  !data.isEmpty else {
                throw CoverImageError.downloadFailed
            }
            try data.write(to: localURL, options: .atomic)
            return data
        }
        downloads[key] = download
        defer { downloads[key] = nil }
        return try await download.value
    }

    func removeAllCachedImages() throws {
        for download in downloads.values { download.cancel() }
        downloads.removeAll()
        decodedImages.removeAllObjects()

        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for item in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.removeItem(at: item)
        }
    }

    private func cacheKey(for urlString: String) -> String {
        SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private enum CoverImageError: Error {
    case invalidURL
    case downloadFailed
    case decodeFailed
}
