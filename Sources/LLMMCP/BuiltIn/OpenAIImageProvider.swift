import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient

// MARK: - OpenAIImageProvider

/// OpenAI gpt-image-1 を使用した画像生成プロバイダー
///
/// OpenAI API キーが必要。
/// `POST https://api.openai.com/v1/images/generations` を直接呼び出す。
public final class OpenAIImageProvider: ImageGenerationProvider, @unchecked Sendable {
    // MARK: - Properties

    private let apiKey: String
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    // MARK: - Initialization

    /// OpenAIImageProvider を作成
    ///
    /// - Parameters:
    ///   - apiKey: OpenAI API キー
    ///   - timeout: リクエストのタイムアウト秒数（デフォルト: 60）
    ///   - transport: HTTP トランスポート（テスト時に差し替え可能）
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

    /// 画像を生成
    ///
    /// - Parameters:
    ///   - prompt: 画像生成プロンプト
    ///   - size: 画像サイズ（square / landscape / portrait）
    ///   - quality: 画像品質（standard / hd）
    /// - Returns: 生成された画像データ
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
