import Foundation
import ImageIO
import CoreGraphics

protocol ArtworkLoading: Sendable {
    func image(for artwork: ArtworkReference) async throws -> CGImage
}

/// Shared by the two panels. Network and thumbnail decoding run off MainActor.
actor ArtworkCache: ArtworkLoading {
    private var images: [String: CGImage] = [:]
    private var recency: [String] = []
    private let capacity: Int
    private let session: URLSession
    init(capacity: Int = 40, session: URLSession = .shared) {
        self.capacity = max(1, capacity)
        self.session = session
    }
    var cachedCount: Int { images.count }
    func image(for artwork: ArtworkReference) async throws -> CGImage {
        let key = artwork.key
        if let cached = images[key] { touch(key); return cached }
        let data: Data
        switch artwork {
        case .remote(let url): data = try await download(url)
        case .embedded(_, let bytes): data = bytes
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 300
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        images[key] = image; touch(key)
        while recency.count > capacity {
            images.removeValue(forKey: recency.removeFirst())
        }
        return image
    }
    private func download(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= 8 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
    private func touch(_ key: String) { recency.removeAll { $0 == key }; recency.append(key) }
}
