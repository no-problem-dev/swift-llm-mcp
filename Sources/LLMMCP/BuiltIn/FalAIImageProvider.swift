import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient

// MARK: - FalAIImageProvider

/// fal.ai FLUX.2 Schnell を使用した画像生成プロバイダー
///
/// fal.ai API キーが必要です。
/// `POST https://fal.run/fal-ai/flux/schnell` を直接呼び出します。
public final class FalAIImageProvider: ImageGenerationProvider, @unchecked Sendable {
    // MARK: - Properties

    private let apiKey: String
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    // MARK: - Initialization

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
