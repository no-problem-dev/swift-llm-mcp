import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient

// MARK: - GeminiImageProvider

/// Google Imagen 4 を使用した画像生成プロバイダー
///
/// Gemini API キーが必要です。
/// `POST https://generativelanguage.googleapis.com/v1beta/models/imagen-4.0-generate-001:predict` を直接呼び出します。
public final class GeminiImageProvider: ImageGenerationProvider, @unchecked Sendable {
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
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/imagen-4.0-generate-001:predict")!

        let requestBody = ImagenRequest(
            instances: [ImagenInstance(prompt: prompt)],
            parameters: ImagenParameters(
                sampleCount: 1,
                aspectRatio: imagenAspectRatio(size),
                personGeneration: "allow_all"
            )
        )

        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["x-goog-api-key": apiKey, "Content-Type": "application/json"],
            body: try JSONEncoder().encode(requestBody),
            timeout: timeout
        )

        let response = try await transport.send(request)

        guard (200...299).contains(response.status) else {
            if response.status == 400 {
                // Check for content policy violation
                if let errorBody = String(data: response.body, encoding: .utf8),
                   errorBody.contains("SAFETY") || errorBody.contains("policy") {
                    throw ImageGenerationToolError.contentPolicyViolation
                }
            }
            throw ImageGenerationToolError.httpError(statusCode: response.status)
        }

        let apiResponse = try JSONDecoder().decode(ImagenResponse.self, from: response.body)

        guard let firstPrediction = apiResponse.predictions.first else {
            throw ImageGenerationToolError.invalidResponse
        }

        guard let imageData = Data(base64Encoded: firstPrediction.bytesBase64Encoded) else {
            throw ImageGenerationToolError.invalidResponse
        }

        let mimeType = ImageMediaType(rawValue: firstPrediction.mimeType) ?? .png

        return GeneratedImageData(
            data: imageData,
            mimeType: mimeType
        )
    }

    // MARK: - Private

    private func imagenAspectRatio(_ size: ImageGenerationSize) -> String {
        switch size {
        case .square: "1:1"
        case .landscape: "16:9"
        case .portrait: "9:16"
        }
    }
}

// MARK: - API Types

private struct ImagenRequest: Encodable {
    let instances: [ImagenInstance]
    let parameters: ImagenParameters
}

private struct ImagenInstance: Encodable {
    let prompt: String
}

private struct ImagenParameters: Encodable {
    let sampleCount: Int
    let aspectRatio: String
    let personGeneration: String
}

private struct ImagenResponse: Decodable {
    let predictions: [ImagenPrediction]
}

private struct ImagenPrediction: Decodable {
    let bytesBase64Encoded: String
    let mimeType: String
}
