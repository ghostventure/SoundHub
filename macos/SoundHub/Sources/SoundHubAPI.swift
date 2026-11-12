import Foundation

/// Read-only DTO for the legacy Express song-node response.
struct SoundHubSong: Decodable, Identifiable, Hashable {
    let uuid: String
    let title: String
    let genre: String?
    let author: Int?
    let authorName: String?
    let authorPic: String?
    let description: String?
    let url: String?
    let like: Int
    let forks: Int
    let rootId: String
    let parentId: String?

    var id: String { uuid }

    private enum CodingKeys: String, CodingKey {
        case uuid, title, genre, author, authorName, authorPic, description, url
        case like, forks, rootId, parentId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try values.decode(String.self, forKey: .uuid)
        title = try values.decode(String.self, forKey: .title)
        genre = try values.decodeIfPresent(String.self, forKey: .genre)
        author = try values.decodeIfPresent(Int.self, forKey: .author)
        authorName = try values.decodeIfPresent(String.self, forKey: .authorName)
        authorPic = try values.decodeIfPresent(String.self, forKey: .authorPic)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        like = try values.decodeIfPresent(Int.self, forKey: .like) ?? 0
        forks = try values.decodeIfPresent(Int.self, forKey: .forks) ?? 0
        rootId = try values.decode(String.self, forKey: .rootId)
        parentId = try values.decodeIfPresent(String.self, forKey: .parentId)
    }
}

enum SoundHubAPIError: Error, LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int)
    case encoding(String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The SoundHub API base URL must use HTTP or HTTPS and include a host."
        case .invalidResponse:
            return "The SoundHub API returned an invalid HTTP response."
        case let .httpStatus(status):
            return "The SoundHub API returned HTTP status \(status)."
        case let .encoding(message):
            return "The SoundHub API request could not be encoded: \(message)"
        case let .decoding(message):
            return "The SoundHub API response could not be decoded: \(message)"
        case let .transport(message):
            return "The SoundHub API request failed: \(message)"
        }
    }
}

/// State suitable for a view model that loads data from SoundHubAPI.
enum SoundHubLoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(SoundHubAPIError)
}

/// Client for the existing read-only Express catalog and tree routes.
/// It intentionally has no login, voting, favorite, upload, or write methods.
struct SoundHubAPI {
    static let defaultBaseURL = URL(string: "http://localhost:3000")!

    let baseURL: URL
    private let session: URLSession
    private let timeoutInterval: TimeInterval

    init(
        baseURL: URL = SoundHubAPI.defaultBaseURL,
        session: URLSession? = nil,
        timeoutInterval: TimeInterval = 20
    ) {
        self.baseURL = baseURL
        self.timeoutInterval = timeoutInterval

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeoutInterval
            configuration.timeoutIntervalForResource = timeoutInterval + 10
            self.session = URLSession(configuration: configuration)
        }
    }

    /// GET /allSongs returns a flat array of song nodes.
    func allSongs() async throws -> [SoundHubSong] {
        try await send(path: "allSongs", method: "GET")
    }

    /// POST /tree with {"rootId": ...} returns that tree as a flat node array.
    func tree(rootID: String) async throws -> [SoundHubSong] {
        let body: Data
        do {
            body = try JSONEncoder().encode(TreeRequest(rootId: rootID))
        } catch {
            throw SoundHubAPIError.encoding(error.localizedDescription)
        }
        return try await send(path: "tree", method: "POST", body: body)
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> Response {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil else {
            throw SoundHubAPIError.invalidBaseURL
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SoundHubAPIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SoundHubAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SoundHubAPIError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SoundHubAPIError.decoding(error.localizedDescription)
        }
    }
}

private struct TreeRequest: Encodable {
    let rootId: String
}
