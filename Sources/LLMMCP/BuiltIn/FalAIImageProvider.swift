import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient

// MARK: - FalAIImageProvider

/// Generates images with fal.ai's FLUX.2 Schnell.
///
/// The fastest of the three providers, and the only one that costs two round trips: fal.ai
/// replies with a URL, which this then downloads. Calls
/// `POST https://fal.run/fal-ai/flux/schnell` directly rather than through an SDK.
public final class FalAIImageProvider: ImageGenerationProvider, @unchecked Sendable {
    // MARK: - Properties

    private let apiKey: String
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    // MARK: - Initialization

    /// Creates a provider, building a `URLSession`-backed transport unless one is supplied.
    ///
    /// - Parameters:
    ///   - apiKey: fal.ai API key, sent as `Authorization: Key ...`.
    ///   - timeout: Per-request timeout in seconds. It applies to the generation request and
    ///     to the image download separately, so a slow call can take twice this.
    ///   - transport: Substitute one in tests to avoid real network calls.
    public init(apiKey: String, timeout: TimeInterval = 60, transport: (any HTTPTransport)? = nil) {
        self.apiKey = apiKey
        self.timeout = timeout
        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 2
            self.transport = URLSessionTransport(session: URLSession(configuration: config), defaultTimeout: timeout)
        }
    }

    // MARK: - ImageGenerationProvider

    /// Generates one image and downloads it.
    ///
    /// Two requests: generation, then a GET of the URL fal.ai returns. That download URL is
    /// not restricted to any host, and the whole image is held in memory with no size cap.
    ///
    /// - Parameters:
    ///   - prompt: Description of the image. FLUX does not report prompt rewrites, so
    ///     ``GeneratedImageData/revisedPrompt`` is always `nil` here.
    ///   - size: 1024x1024, 1536x1024 or 1024x1536.
    ///   - quality: Ignored. Schnell has a single quality tier.
    /// - Throws: ``ImageGenerationToolError/httpError(statusCode:)`` for a failed generation,
    ///   ``ImageGenerationToolError/imageDownloadFailed`` for a failed download, and
    ///   ``ImageGenerationToolError/invalidResponse`` for an empty or malformed reply.
    ///   Content-policy rejections are not distinguished from other 4xx failures.
    /// - Throws: ``ImageGenerationToolError``
    public func generateImage(prompt: String, size: ImageGenerationSize, quality: ImageGenerationQuality) async throws -> GeneratedImageData {
        let url = URL(string: "https://fal.run/fal-ai/flux/schnell")!

        let (width, height) = falSize(size)
        let requestBody = FalImageRequest(
            prompt: prompt,
            imageSize: FalImageSize(width: width, height: height),
            numImages: 1
        )

        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Authorization": "Key \(apiKey)", "Content-Type": "application/json"],
            body: try JSONEncoder().encode(requestBody),
            timeout: timeout
        )

        let response = try await transport.send(request)

        guard (200...299).contains(response.status) else {
            throw ImageGenerationToolError.httpError(statusCode: response.status)
        }

        let apiResponse = try JSONDecoder().decode(FalImageResponse.self, from: response.body)

        guard let firstImage = apiResponse.images.first else {
            throw ImageGenerationToolError.invalidResponse
        }

        // fal.ai returns a URL; download the image
        guard let imageURL = URL(string: firstImage.url) else {
            throw ImageGenerationToolError.invalidResponse
        }

        let imageResponse = try await transport.send(HTTPRequest(method: "GET", url: imageURL, timeout: timeout))

        guard (200...299).contains(imageResponse.status) else {
            throw ImageGenerationToolError.imageDownloadFailed
        }

        // Determine format from content type or default to jpeg
        let mimeType: ImageMediaType
        if let contentType = imageResponse.headers["Content-Type"] {
            mimeType = ImageMediaType(rawValue: contentType) ?? .jpeg
        } else {
            mimeType = .jpeg
        }

        return GeneratedImageData(
            data: imageResponse.body,
            mimeType: mimeType
        )
    }

    // MARK: - Private

    private func falSize(_ size: ImageGenerationSize) -> (width: Int, height: Int) {
        switch size {
        case .square: (1024, 1024)
        case .landscape: (1536, 1024)
        case .portrait: (1024, 1536)
        }
    }
}

// MARK: - API Types

private struct FalImageRequest: Encodable {
    let prompt: String
    let imageSize: FalImageSize
    let numImages: Int

    enum CodingKeys: String, CodingKey {
        case prompt
        case imageSize = "image_size"
        case numImages = "num_images"
    }
}

private struct FalImageSize: Encodable {
    let width: Int
    let height: Int
}

private struct FalImageResponse: Decodable {
    let images: [FalImage]
}

private struct FalImage: Decodable {
    let url: String
    let contentType: String?

    enum CodingKeys: String, CodingKey {
        case url
        case contentType = "content_type"
    }
}
