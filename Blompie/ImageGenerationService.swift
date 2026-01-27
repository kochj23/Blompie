import Foundation
import AppKit

//
//  ImageGenerationService.swift
//  Shared Image Generation Service
//
//  Uses ComfyUI, SwarmUI, or Automatic1111 for AI image generation
//  Author: Jordan Koch
//  Date: 2026-01-21
//

/// Shared image generation service for AI-enabled projects
/// Supports: ComfyUI, SwarmUI, Automatic1111, OpenAI DALL-E
class ImageGenerationService: ObservableObject {

    // MARK: - Published Properties

    @Published var isGenerating = false
    @Published var progress: Double = 0
    @Published var lastError: String?
    @Published var generatedImages: [ServiceGeneratedImage] = []

    // MARK: - Properties

    private let aiBackend = AIBackendManager.shared

    // MARK: - Image Generation

    /// Generate image from text prompt
    func generateImage(
        prompt: String,
        style: ServiceImageStyle = .realistic,
        size: ServiceImageSize = .square1024
    ) async throws -> NSImage {

        await MainActor.run {
            isGenerating = true
            progress = 0
            lastError = nil
        }

        defer {
            Task { @MainActor in
                isGenerating = false
                progress = 0
            }
        }

        // Determine which backend to use
        if aiBackend.isSwarmUIAvailable {
            return try await generateWithSwarmUI(prompt: prompt, style: style, size: size)
        } else if aiBackend.isComfyUIAvailable {
            return try await generateWithComfyUI(prompt: prompt, style: style, size: size)
        } else if aiBackend.isAutomatic1111Available {
            return try await generateWithAutomatic1111(prompt: prompt, style: style, size: size)
        } else {
            throw ServiceImageGenerationError.noBackendAvailable
        }
    }

    // MARK: - SwarmUI Implementation

    private func generateWithSwarmUI(
        prompt: String,
        style: ServiceImageStyle,
        size: ServiceImageSize
    ) async throws -> NSImage {

        await updateProgress(0.1)

        let enhancedPrompt = enhancePrompt(prompt, style: style)

        guard let url = URL(string: "\(aiBackend.swarmUIServerURL)/API/GenerateText2Image") else {
            throw ServiceImageGenerationError.invalidURL
        }

        let requestBody: [String: Any] = [
            "prompt": enhancedPrompt,
            "model": "Flux/flux1-schnell-fp8",
            "width": size.width,
            "height": size.height,
            "cfgscale": 1.0,
            "steps": 6,
            "seed": -1
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 120.0

        await updateProgress(0.3)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceImageGenerationError.invalidResponse
        }

        await updateProgress(0.7)

        guard httpResponse.statusCode == 200 else {
            throw ServiceImageGenerationError.httpError(httpResponse.statusCode)
        }

        struct SwarmUIResponse: Codable {
            let images: [String] // Base64 encoded images
        }

        let swarmResponse = try JSONDecoder().decode(SwarmUIResponse.self, from: data)

        guard let imageBase64 = swarmResponse.images.first,
              let imageData = Data(base64Encoded: imageBase64),
              let image = NSImage(data: imageData) else {
            throw ServiceImageGenerationError.noImageGenerated
        }

        await updateProgress(1.0)

        // Save to generated images
        let generated = ServiceGeneratedImage(image: image, prompt: prompt, style: style, backend: "SwarmUI")
        await MainActor.run {
            generatedImages.insert(generated, at: 0)
        }

        return image
    }

    // MARK: - ComfyUI Implementation

    private func generateWithComfyUI(
        prompt: String,
        style: ServiceImageStyle,
        size: ServiceImageSize
    ) async throws -> NSImage {

        await updateProgress(0.1)

        // ComfyUI workflow would be more complex
        // For now, return placeholder
        throw ServiceImageGenerationError.notImplemented("ComfyUI integration coming soon")
    }

    // MARK: - Automatic1111 Implementation

    private func generateWithAutomatic1111(
        prompt: String,
        style: ServiceImageStyle,
        size: ServiceImageSize
    ) async throws -> NSImage {

        await updateProgress(0.1)

        let enhancedPrompt = enhancePrompt(prompt, style: style)

        guard let url = URL(string: "\(aiBackend.automatic1111ServerURL)/sdapi/v1/txt2img") else {
            throw ServiceImageGenerationError.invalidURL
        }

        let requestBody: [String: Any] = [
            "prompt": enhancedPrompt,
            "negative_prompt": "blurry, low quality, distorted, ugly",
            "steps": 20,
            "cfg_scale": 7.0,
            "width": size.width,
            "height": size.height,
            "seed": -1,
            "sampler_name": "Euler a"
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 120.0

        await updateProgress(0.3)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceImageGenerationError.invalidResponse
        }

        await updateProgress(0.7)

        guard httpResponse.statusCode == 200 else {
            throw ServiceImageGenerationError.httpError(httpResponse.statusCode)
        }

        struct A1111Response: Codable {
            let images: [String] // Base64 encoded
        }

        let a1111Response = try JSONDecoder().decode(A1111Response.self, from: data)

        guard let imageBase64 = a1111Response.images.first,
              let imageData = Data(base64Encoded: imageBase64),
              let image = NSImage(data: imageData) else {
            throw ServiceImageGenerationError.noImageGenerated
        }

        await updateProgress(1.0)

        let generated = ServiceGeneratedImage(image: image, prompt: prompt, style: style, backend: "Automatic1111")
        await MainActor.run {
            generatedImages.insert(generated, at: 0)
        }

        return image
    }

    // MARK: - Prompt Enhancement

    private func enhancePrompt(_ prompt: String, style: ServiceImageStyle) -> String {
        var enhanced = prompt

        // Add style-specific keywords
        switch style {
        case .realistic:
            enhanced += ", photorealistic, high detail, professional photography"
        case .artistic:
            enhanced += ", digital art, artistic, painterly style"
        case .fantasy:
            enhanced += ", fantasy art, magical atmosphere, epic"
        case .pixelArt:
            enhanced += ", pixel art style, retro gaming aesthetic, 16-bit"
        case .cartoon:
            enhanced += ", cartoon style, vibrant colors, illustrated"
        case .anime:
            enhanced += ", anime art style, manga aesthetic"
        }

        // Add quality keywords
        enhanced += ", 4K, high quality, detailed"

        return enhanced
    }

    // MARK: - Helper

    private func updateProgress(_ value: Double) async {
        await MainActor.run {
            progress = value
        }
    }
}

// MARK: - Models

struct ServiceGeneratedImage: Identifiable {
    let id = UUID()
    let image: NSImage
    let prompt: String
    let style: ServiceImageStyle
    let backend: String
    let timestamp = Date()
}

enum ServiceImageStyle: String, CaseIterable {
    case realistic = "Realistic"
    case artistic = "Artistic"
    case fantasy = "Fantasy"
    case pixelArt = "Pixel Art"
    case cartoon = "Cartoon"
    case anime = "Anime"
}

enum ServiceImageSize {
    case square512
    case square1024
    case portrait
    case landscape

    var width: Int {
        switch self {
        case .square512: return 512
        case .square1024: return 1024
        case .portrait: return 768
        case .landscape: return 1024
        }
    }

    var height: Int {
        switch self {
        case .square512: return 512
        case .square1024: return 1024
        case .portrait: return 1024
        case .landscape: return 768
        }
    }
}

enum ServiceImageGenerationError: LocalizedError {
    case noBackendAvailable
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noImageGenerated
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable:
            return "No image generation backend available. Please start ComfyUI, SwarmUI, or Automatic1111."
        case .invalidURL:
            return "Invalid backend URL configuration"
        case .invalidResponse:
            return "Received invalid response from image backend"
        case .httpError(let code):
            return "HTTP error \(code) from image backend"
        case .noImageGenerated:
            return "No image was generated"
        case .notImplemented(let message):
            return message
        }
    }
}
