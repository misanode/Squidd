import Foundation

actor ITunesArtworkLookup {
    static let shared = ITunesArtworkLookup()

    private var cache: [String: URL?] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func url(name: String, artist: String, album: String) async throws -> URL? {
        guard !name.isEmpty else { return nil }
        let key = [artist, album, name].joined(separator: "|").lowercased()
        if let cached = cache[key] { return cached }
        let result = try await fetch(name: name, artist: artist, album: album)
        cache[key] = result
        return result
    }

    private func fetch(name: String, artist: String, album: String) async throws -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: [artist, name].filter { !$0.isEmpty }.joined(separator: " ")),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let results = try JSONDecoder().decode(SearchResponse.self, from: data).results
        let match = results.first { matches($0.collectionName, album) }
            ?? results.first { matches($0.artistName, artist) }
        guard let artwork = match?.artworkUrl100 else { return nil }
        return URL(string: artwork.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    private func matches(_ value: String?, _ expected: String) -> Bool {
        !expected.isEmpty && value?.caseInsensitiveCompare(expected) == .orderedSame
    }

    private struct SearchResponse: Decodable {
        let results: [Track]
    }
    private struct Track: Decodable {
        let artistName: String?
        let collectionName: String?
        let artworkUrl100: String?
    }
}
