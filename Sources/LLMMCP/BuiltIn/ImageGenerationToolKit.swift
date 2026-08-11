import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient
import LLMTool

// MARK: - ImageGenerationProvider Protocol

/// An image generation backend, so the model can be swapped without touching the tool.
public protocol ImageGenerationProvider: Sendable {
    /// Generates one image and returns its bytes.
    ///
    /// Expected to be slow — tens of seconds is normal — and to return the image data
    /// itself rather than a URL, so the caller need not fetch anything.
    ///
    /// - Parameters:
    ///   - prompt: Description of the image. Passed through unchanged; a provider may
    ///     rewrite it and report the rewrite in ``GeneratedImageData/revisedPrompt``.
    ///   - size: Aspect ratio. Providers map these to their own supported dimensions.
    ///   - quality: Whether to spend extra time and money on fidelity. Providers that offer
    ///     only one quality ignore it.
    func generateImage(prompt: String, size: ImageGenerationSize, quality: ImageGenerationQuality) async throws -> GeneratedImageData
}

// MARK: - ImageGenerationSize

/// Aspect ratio, named rather than given in pixels so one vocabulary covers every provider.
public enum ImageGenerationSize: String, Codable, Sendable {
    /// 1024x1024 where the provider supports it.
    case square
    /// Wider than tall, typically 1536x1024.
    case landscape
    /// Taller than wide, typically 1024x1536.
    case portrait
}

// MARK: - ImageGenerationQuality

/// How much time and money to spend on one image. Providers with a single tier ignore it.
public enum ImageGenerationQuality: String, Codable, Sendable {
    case standard
    case hd
}

// MARK: - GeneratedImageData

/// A generated image, held entirely in memory.
public struct GeneratedImageData: Sendable {
    /// The decoded image bytes, not a URL — nothing further needs fetching.
    public let data: Data
    /// The image's media type, which decides how the bytes should be interpreted.
    public let mimeType: ImageMediaType
    /// The prompt the provider actually used, when it rewrote the one it was given.
    ///
    /// Only OpenAI reports this. `nil` means the prompt was used as written, or that the
    /// provider does not disclose rewrites.
    public let revisedPrompt: String?

    public init(data: Data, mimeType: ImageMediaType, revisedPrompt: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.revisedPrompt = revisedPrompt
    }
}

// MARK: - UnconfiguredImageGenerationProvider

/// The provider used when no API key was supplied. Every call throws.
public struct UnconfiguredImageGenerationProvider: ImageGenerationProvider {
    public init() {}

    /// Always throws ``ImageGenerationToolError/providerNotConfigured``, whose message names
    /// the factory methods that configure a real backend.
    public func generateImage(prompt: String, size: ImageGenerationSize, quality: ImageGenerationQuality) async throws -> GeneratedImageData {
        throw ImageGenerationToolError.providerNotConfigured
    }
}

// MARK: - ImageGenerationToolKit

/// Gives the model one tool, `generate_image`, backed by OpenAI, fal.ai or Gemini.
///
/// The image comes back inside the tool result, so it reaches the model directly. Supply a
/// ``MediaSaver`` as well if the image should also be persisted and shown to the user;
/// without one the bytes live only in the conversation.
///
/// Unlike ``WebSearchToolKit`` there is no resilience wrapper: no cache, no rate limit, no
/// retry. Image generation is slow and billed per call, so each request goes straight through.
public final class ImageGenerationToolKit: ToolKit, @unchecked Sendable {

    /// Persists a generated image and returns the id it was stored under.
    ///
    /// The id is written into the tool result, which is how the model can refer to the
    /// image later. A throw from here does not fail the tool — see the `generate_image` tool.
    public typealias MediaSaver = @Sendable (Data, ImageMediaType) async throws -> String

    // MARK: - Properties

    public let name: String = "image_generation"

    private let provider: any ImageGenerationProvider

    private let mediaSaver: MediaSaver?

    // MARK: - Initialization

    /// Creates the kit around a provider you built yourself.
    ///
    /// - Parameters:
    ///   - provider: The backend. Passing `nil` installs
    ///     ``UnconfiguredImageGenerationProvider``, so the tool exists but every call fails
    ///     with configuration instructions.
    ///   - mediaSaver: Persists each generated image. Omit it to keep images in the
    ///     conversation only.
    public init(provider: (any ImageGenerationProvider)? = nil, mediaSaver: MediaSaver? = nil) {
        self.provider = provider ?? UnconfiguredImageGenerationProvider()
        self.mediaSaver = mediaSaver
    }

    // MARK: - Factory Methods

    /// A kit backed by OpenAI's gpt-image-1, the only provider that reports prompt rewrites.
    ///
    /// - Parameters:
    ///   - apiKey: OpenAI API key.
    ///   - mediaSaver: Persists each generated image.
    public static func openai(apiKey: String, mediaSaver: MediaSaver? = nil) -> ImageGenerationToolKit {
        ImageGenerationToolKit(provider: OpenAIImageProvider(apiKey: apiKey), mediaSaver: mediaSaver)
    }

    /// A kit backed by fal.ai's FLUX.2 Schnell, the fastest of the three. It has one
    /// quality tier, so `quality` has no effect.
    ///
    /// - Parameters:
    ///   - apiKey: fal.ai API key.
    ///   - mediaSaver: Persists each generated image.
    public static func falai(apiKey: String, mediaSaver: MediaSaver? = nil) -> ImageGenerationToolKit {
        ImageGenerationToolKit(provider: FalAIImageProvider(apiKey: apiKey), mediaSaver: mediaSaver)
    }

    /// A kit backed by Google's Imagen 4.
    ///
    /// - Parameters:
    ///   - apiKey: Gemini API key. It must be an API key, which starts with `AIza`; an
    ///     OAuth token is rejected by the endpoint.
    ///   - mediaSaver: Persists each generated image.
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

    /// The `generate_image` tool: turn a prompt into an image attached to the tool result.
    ///
    /// Unrecognised `size` and `quality` values fall back to `square` and `standard` rather
    /// than failing. A failure to persist the image is reported as a warning inside the
    /// successful result, so the model still receives the image and learns that saving failed.
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

/// Failures from ``ImageGenerationToolKit`` and its providers.
///
/// Each `errorDescription` names the next step, because a model reads it to decide whether
/// to rewrite the prompt, wait, or give up.
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
