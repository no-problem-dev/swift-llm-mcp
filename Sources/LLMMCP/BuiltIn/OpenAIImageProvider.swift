import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient

// MARK: - OpenAIImageProvider

/// Generates images with OpenAI's gpt-image-1.
///
/// The only provider that reports how it rewrote the prompt, and the only one that
/// distinguishes a content-policy rejection from a generic bad request. Calls
/// `POST https://api.openai.com/v1/images/generations` directly rather than through an SDK.
public final class OpenAIImageProvider: ImageGenerationProvider, @unchecked Sendable {
    // MARK: - Properties

    private let apiKey: String
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    // MARK: - Initialization

    /// Creates a provider, building a `URLSession`-backed transport unless one is supplied.
    ///
    /// - Parameters:
    ///   - apiKey: OpenAI API key, sent as a bearer token.
    ///   - timeout: Per-request timeout in seconds. Generation routinely takes tens of
    ///     seconds, which is why this defaults far higher than the search providers.
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

    /// Generates one PNG.
    ///
    /// `hd` maps to OpenAI's `high` quality and `standard` to `auto`, letting the model
    /// choose. Only the first image is used, and the response is base64 in the body, so
    /// nothing is downloaded afterwards.
    ///
    /// - Parameters:
    ///   - prompt: Description of the image. OpenAI may rewrite it; the rewrite comes back
    ///     in ``GeneratedImageData/revisedPrompt``.
    ///   - size: 1024x1024, 1536x1024 or 1024x1536.
    ///   - quality: `hd` costs more and takes longer.
    /// - Throws: ``ImageGenerationToolError/contentPolicyViolation`` when a 400 identifies
    ///   itself as one, ``ImageGenerationToolError/httpError(statusCode:)`` otherwise, and
    ///   ``ImageGenerationToolError/invalidResponse`` for an empty or undecodable payload.
    /// - Throws: ``ImageGenerationToolError``
    public func generateImage(prompt: String, size: ImageGenerationSize, quality: ImageGenerationQuality) async throws -> GeneratedImageData {
        let url = URL(string: "https://api.openai.com/v1/images/generations")!

        let requestBody = OpenAIImageRequest(
            model: "gpt-image-1",
            prompt: prompt,
            n: 1,
            size: openAISize(size),
            quality: quality == .hd ? "high" : "auto",
            outputFormat: "png"
        )

        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"],
            body: try JSONEncoder().encode(requestBody),
            timeout: timeout
        )

        let response = try await transport.send(request)

        guard (200...299).contains(response.status) else {
            if response.status == 400 {
                // Check if it's a content policy violation
                if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: response.body),
                   errorResponse.error.code == "content_policy_violation" {
                    throw ImageGenerationToolError.contentPolicyViolation
                }
            }
            throw ImageGenerationToolError.httpError(statusCode: response.status)
        }

        let apiResponse = try JSONDecoder().decode(OpenAIImageResponse.self, from: response.body)

        guard let firstImage = apiResponse.data.first else {
            throw ImageGenerationToolError.invalidResponse
        }

        guard let imageData = Data(base64Encoded: firstImage.b64Json) else {
            throw ImageGenerationToolError.invalidResponse
        }

        return GeneratedImageData(
            data: imageData,
            mimeType: .png,
            revisedPrompt: firstImage.revisedPrompt
        )
    }

    // MARK: - Private

    private func openAISize(_ size: ImageGenerationSize) -> String {
        switch size {
        case .square: "1024x1024"
        case .landscape: "1536x1024"
        case .portrait: "1024x1536"
        }
    }
}

// MARK: - API Types

private struct OpenAIImageRequest: Encodable {
    let model: String
    let prompt: String
    let n: Int
    let size: String
    let quality: String
    let outputFormat: String

    enum CodingKeys: String, CodingKey {
        case model, prompt, n, size, quality
        case outputFormat = "output_format"
    }
}

private struct OpenAIImageResponse: Decodable {
    let data: [OpenAIImageData]
}

private struct OpenAIImageData: Decodable {
    let b64Json: String
    let revisedPrompt: String?

    enum CodingKeys: String, CodingKey {
        case b64Json = "b64_json"
        case revisedPrompt = "revised_prompt"
    }
}

private struct OpenAIErrorResponse: Decodable {
    let error: OpenAIErrorDetail
}

private struct OpenAIErrorDetail: Decodable {
    let message: String
    let code: String?
}
