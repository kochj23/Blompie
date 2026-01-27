import SwiftUI

//
//  ImageGenerationView.swift
//  Blompie
//
//  AI image generation for characters, scenes, and items
//  Author: Jordan Koch
//  Date: 2026-01-21
//

struct ImageGenerationView: View {
    @StateObject private var imageService = ImageGenerationService()
    @Binding var currentScene: String
    @Binding var isPresented: Bool

    @State private var generationType: GenerationType = .scene
    @State private var customPrompt = ""
    @State private var selectedStyle: ImageStyle = .fantasy
    @State private var generatedImage: NSImage?

    enum GenerationType: String, CaseIterable {
        case scene = "Scene Illustration"
        case character = "Character Portrait"
        case item = "Item/Object"
        case custom = "Custom Prompt"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 24))
                    .foregroundColor(.purple)

                Text("Generate Adventure Art")
                    .font(.title2)
                    .bold()

                Spacer()

                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Generation Type
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What to Generate:")
                            .font(.headline)

                        Picker("Type", selection: $generationType) {
                            ForEach(GenerationType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Style Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Art Style:")
                            .font(.headline)

                        Picker("Style", selection: $selectedStyle) {
                            ForEach(ImageStyle.allCases, id: \.self) { style in
                                Text(style.rawValue).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Custom Prompt (for custom type)
                    if generationType == .custom {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Custom Prompt:")
                                .font(.headline)

                            TextEditor(text: $customPrompt)
                                .frame(height: 80)
                                .border(Color.gray.opacity(0.3))
                        }
                    } else {
                        // Auto-generated prompt preview
                        VStack(alignment: .leading, spacing: 8) {
                            Text("AI Will Generate:")
                                .font(.headline)

                            Text(buildPrompt())
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.gray.opacity(0.1))
                                )
                        }
                    }

                    // Generate Button
                    Button {
                        Task {
                            await generateImage()
                        }
                    } label: {
                        HStack {
                            if imageService.isGenerating {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Generating...")
                            } else {
                                Image(systemName: "sparkles")
                                Text("Generate Image")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(imageService.isGenerating || !hasAvailableBackend)

                    // Progress bar
                    if imageService.isGenerating {
                        ProgressView(value: imageService.progress)
                            .progressViewStyle(.linear)
                    }

                    // Error message
                    if let error = imageService.lastError {
                        Text("⚠️ \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding()
                    }

                    // Generated Image Display
                    if let image = generatedImage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Generated Image:")
                                .font(.headline)

                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 400)
                                .border(Color.gray.opacity(0.3), width: 1)

                            HStack {
                                Button {
                                    saveImageToDesktop(image)
                                } label: {
                                    HStack {
                                        Image(systemName: "square.and.arrow.down")
                                        Text("Save to Desktop")
                                    }
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    copyImageToClipboard(image)
                                } label: {
                                    HStack {
                                        Image(systemName: "doc.on.doc")
                                        Text("Copy to Clipboard")
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    // Backend Status
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Available Backends:")
                            .font(.headline)

                        HStack(spacing: 12) {
                            BackendStatusBadge(name: "SwarmUI", isAvailable: AIBackendManager.shared.isSwarmUIAvailable)
                            BackendStatusBadge(name: "ComfyUI", isAvailable: AIBackendManager.shared.isComfyUIAvailable)
                            BackendStatusBadge(name: "Automatic1111", isAvailable: AIBackendManager.shared.isAutomatic1111Available)
                        }

                        if !hasAvailableBackend {
                            Text("⚠️ No image generation backend available. Please start SwarmUI, ComfyUI, or Automatic1111.")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.orange.opacity(0.1))
                                )
                        }
                    }

                    // Image Gallery (Recent generations)
                    if !imageService.generatedImages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recently Generated:")
                                .font(.headline)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(imageService.generatedImages.prefix(5)) { generated in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Image(nsImage: generated.image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 120, height: 120)
                                                .clipped()
                                                .cornerRadius(8)
                                                .onTapGesture {
                                                    generatedImage = generated.image
                                                }

                                            Text(generated.style.rawValue)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 600, height: 800)
    }

    // MARK: - Methods

    private func buildPrompt() -> String {
        let sceneContext = extractSceneContext(from: currentScene)

        switch generationType {
        case .scene:
            return "Illustrate this fantasy scene: \(sceneContext). Show the environment and atmosphere."
        case .character:
            return "Create a character portrait from this description: \(sceneContext). Fantasy RPG style."
        case .item:
            return "Draw this fantasy item or object: \(sceneContext). Item illustration style."
        case .custom:
            return customPrompt
        }
    }

    private func extractSceneContext(from text: String) -> String {
        // Extract last 200 characters as context
        let context = String(text.suffix(200))
        return context.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateImage() async {
        let prompt = buildPrompt()

        do {
            let image = try await imageService.generateImage(
                prompt: prompt,
                style: selectedStyle,
                size: .square1024
            )

            await MainActor.run {
                generatedImage = image
            }
        } catch {
            await MainActor.run {
                imageService.lastError = error.localizedDescription
            }
        }
    }

    private func saveImageToDesktop(_ image: NSImage) {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let filename = "Blompie_\(Date().timeIntervalSince1970).png"
        let fileURL = desktop.appendingPathComponent(filename)

        if let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL)
        }
    }

    private func copyImageToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private var hasAvailableBackend: Bool {
        AIBackendManager.shared.isSwarmUIAvailable || AIBackendManager.shared.isComfyUIAvailable || AIBackendManager.shared.isAutomatic1111Available
    }
}

// MARK: - Backend Status Badge

struct BackendStatusBadge: View {
    let name: String
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isAvailable ? Color.green : Color.gray)
                .frame(width: 6, height: 6)

            Text(name)
                .font(.caption)
                .foregroundColor(isAvailable ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isAvailable ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
        )
    }
}

// MARK: - Preview

#Preview {
    ImageGenerationView(
        currentScene: .constant("You stand in a mystical forest clearing..."),
        isPresented: .constant(true)
    )
}
