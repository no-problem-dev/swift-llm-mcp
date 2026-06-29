import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient
import LLMTool

// MARK: - ImageGenerationProvider Protocol

/// 画像生成プロバイダーのプロトコル
///
/// 異なる画像生成バックエンドを差し替え可能にするための抽象化。
public protocol ImageGenerationProvider: Sendable {
    /// 画像を生成
    ///
    /// - Parameters:
    ///   - prompt: 画像生成プロンプト
    ///   - size: 画像サイズ（square / landscape / portrait）
    ///   - quality: 画像品質（standard / hd）
    /// - Returns: 生成された画像データ
    func generateImage(prompt: String, size: ImageGenerationSize, quality: ImageGenerationQuality) async throws -> GeneratedImageData
}

// MARK: - ImageGenerationSize

/// 画像生成ツール用の簡略化サイズ
public enum ImageGenerationSize: String, Codable, Sendable {
    case square
    case landscape
    case portrait
}

// MARK: - ImageGenerationQuality

/// 画像生成ツール用の品質設定
public enum ImageGenerationQuality: String, Codable, Sendable {
    case standard
    case hd
}

// MARK: - GeneratedImageData

/// 画像生成の結果データ
public struct GeneratedImageData: Sendable {
    /// 画像バイナリデータ
    public let data: Data
    /// 画像フォーマット（MIME type: image/png, image/jpeg 等）
    public let mimeType: ImageMediaType
    /// プロバイダーが修正したプロンプト（OpenAI のみ）
    public let revisedPrompt: String?

    public init(data: Data, mimeType: ImageMediaType, revisedPrompt: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.revisedPrompt = revisedPrompt
    }
}

// MARK: - UnconfiguredImageGenerationProvider

/// APIキー未設定時のフォールバックプロバイダー
///
/// 画像生成実行時に設定方法を案内するエラーを返す。
public struct UnconfiguredImageGenerationProvider: ImageGenerationProvider {
    public init() {}

    public func generateImage(prompt: String, size: ImageGenerationSize, quality: ImageGenerationQuality) async throws -> GeneratedImageData {
        throw ImageGenerationToolError.providerNotConfigured
    }
}

// MARK: - ImageGenerationToolKit

/// 画像生成ツールを提供するToolKit
///
/// テキストプロンプトから画像を生成する。
/// OpenAI (gpt-image-1) / fal.ai (FLUX.2 Schnell) / Gemini (Imagen 4) をバックエンドとして使用する。
///
/// ## 提供されるツール
///
/// - `generate_image`: テキストプロンプトから画像を生成
public final class ImageGenerationToolKit: ToolKit, @unchecked Sendable {

    /// 生成画像をメディアストアに保存するクロージャ
    ///
    /// `(Data, ImageMediaType) -> String` — 画像データと MIME タイプを受け取り、保存後のメディア ID を返す。
    public typealias MediaSaver = @Sendable (Data, ImageMediaType) async throws -> String

    // MARK: - Properties

    public let name: String = "image_generation"

    /// 画像生成プロバイダー
    private let provider: any ImageGenerationProvider

    /// 生成画像を MediaStore に保存するクロージャ（nil の場合は保存しない）
    private let mediaSaver: MediaSaver?

    // MARK: - Initialization

    /// ImageGenerationToolKit を作成
    ///
    /// - Parameters:
    ///   - provider: 画像生成プロバイダー（`nil` の場合は `UnconfiguredImageGenerationProvider`）
    ///   - mediaSaver: 生成画像をメディアストアに保存するクロージャ（省略可）
    public init(provider: (any ImageGenerationProvider)? = nil, mediaSaver: MediaSaver? = nil) {
        self.provider = provider ?? UnconfiguredImageGenerationProvider()
        self.mediaSaver = mediaSaver
    }

    // MARK: - Factory Methods

    /// OpenAI gpt-image-1 プロバイダーで ImageGenerationToolKit を作成
    ///
    /// - Parameters:
    ///   - apiKey: OpenAI API キー
    ///   - mediaSaver: 生成画像をメディアストアに保存するクロージャ（省略可）
    public static func openai(apiKey: String, mediaSaver: MediaSaver? = nil) -> ImageGenerationToolKit {
        ImageGenerationToolKit(provider: OpenAIImageProvider(apiKey: apiKey), mediaSaver: mediaSaver)
    }

    /// fal.ai FLUX.2 Schnell プロバイダーで ImageGenerationToolKit を作成
    ///
    /// - Parameters:
    ///   - apiKey: fal.ai API キー
    ///   - mediaSaver: 生成画像をメディアストアに保存するクロージャ（省略可）
    public static func falai(apiKey: String, mediaSaver: MediaSaver? = nil) -> ImageGenerationToolKit {
        ImageGenerationToolKit(provider: FalAIImageProvider(apiKey: apiKey), mediaSaver: mediaSaver)
    }

    /// Gemini Imagen 4 プロバイダーで ImageGenerationToolKit を作成
    ///
    /// - Parameters:
    ///   - apiKey: Gemini API キー
    ///   - mediaSaver: 生成画像をメディアストアに保存するクロージャ（省略可）
    public static func gemini(apiKey: String, mediaSaver: MediaSaver? = nil) -> ImageGenerationToolKit {
        ImageGenerationToolKit(provider: GeminiImageProvider(apiKey: apiKey), mediaSaver: mediaSaver)
    }

    // MARK: - ToolKit Protocol

    public var tools: [any Tool] {
        [
            generateImageTool
        ]
    }

    // MARK: - Tool Definitions

    /// generate_image ツール
    private var generateImageTool: BuiltInTool {
        BuiltInTool(
            name: "generate_image",
            description: "Generate an image from a text prompt using an AI image generation model. Returns the generated image. Use descriptive, detailed prompts in English for best results.",
            inputSchema: .object(
                properties: [
                    "prompt": .string(description: "A detailed text description of the image to generate. Use English for best results. Be specific about style, composition, colors, and details."),
                    "size": .string(description: "Image size: 'square' (1024x1024), 'landscape' (1536x1024), or 'portrait' (1024x1536). Default: 'square'"),
                    "quality": .string(description: "Image quality: 'standard' or 'hd'. Default: 'standard'")
                ],
                required: ["prompt"]
            ),
            annotations: ToolAnnotations(
                title: "Image Generation",
                readOnlyHint: false,
                openWorldHint: true
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(ImageGenerationInput.self, from: data)

            let size = input.size.flatMap { ImageGenerationSize(rawValue: $0) } ?? .square
            let quality = input.quality.flatMap { ImageGenerationQuality(rawValue: $0) } ?? .standard

            let result = try await provider.generateImage(
                prompt: input.prompt,
                size: size,
                quality: quality
            )

            let imageContent = ImageContent.base64(result.data, mediaType: result.mimeType)

            var description = "Image generated successfully."
            if let revised = result.revisedPrompt {
                description += " Revised prompt: \(revised)"
            }

            if let mediaSaver = self.mediaSaver {
                do {
                    let mediaId = try await mediaSaver(result.data, result.mimeType)
                    description += " Media ID: \(mediaId). The image has been saved and is being displayed to the user."
                } catch {
                    description += " Warning: Failed to save to media store: \(error.localizedDescription)"
                }
            }

            return .textWithMedia(description, media: [imageContent])
        }
    }
}

// MARK: - Input / Output Types

private struct ImageGenerationInput: Codable {
    var prompt: String
    var size: String?
    var quality: String?
}

// MARK: - Errors

/// ImageGenerationToolKitのエラー
public enum ImageGenerationToolError: Error, LocalizedError {
    case providerNotConfigured
    case invalidResponse
    case httpError(statusCode: Int)
    case contentPolicyViolation
    case imageDownloadFailed

    public var errorDescription: String? {
        switch self {
        case .providerNotConfigured:
            return "No image generation provider configured. Use ImageGenerationToolKit.openai(apiKey:), .falai(apiKey:), or .gemini(apiKey:) to configure a provider."
        case .invalidResponse:
            return "Image generation API returned an invalid response. Try again or modify your prompt."
        case .httpError(let statusCode):
            switch statusCode {
            case 429:
                return "Image generation rate limited (HTTP 429). Wait before retrying."
            case 400:
                return "Invalid request (HTTP 400). Your prompt may violate content policies or contain unsupported parameters."
            default:
                return "Image generation failed with HTTP \(statusCode). Try again or modify your prompt."
            }
        case .contentPolicyViolation:
            return "Image generation was blocked due to content policy violation. Please modify your prompt."
        case .imageDownloadFailed:
            return "Failed to download the generated image. Try again."
        }
    }
}
