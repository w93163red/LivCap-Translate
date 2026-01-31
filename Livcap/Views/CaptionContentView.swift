//
//  CaptionContentView.swift
//  Livcap
//
//  Paragraph-style caption display (mac-transcriber style)
//  Shows recent 4 sentences merged into one paragraph
//

import SwiftUI

struct CaptionContentView<ViewModel: CaptionViewModelProtocol>: View {
    @ObservedObject var captionViewModel: ViewModel
    @ObservedObject private var settings = TranslationSettings.shared
    @Binding var hasShownFirstContentAnimation: Bool
    @Binding var firstContentAnimationOffset: CGFloat
    @Binding var firstContentAnimationOpacity: Double

    // Computed: recent sentences (last N from settings)
    private var recentHistory: [CaptionEntry] {
        let history = captionViewModel.captionHistory
        let maxVisible = settings.maxVisibleSentences
        if history.count > maxVisible {
            return Array(history.suffix(maxVisible))
        }
        return history
    }

    // Computed: combined original text paragraph
    private var originalParagraph: String {
        var texts = recentHistory.map { $0.text }
        if !captionViewModel.currentTranscription.isEmpty {
            texts.append(captionViewModel.currentTranscription + "...")
        }
        return texts.joined(separator: " ")
    }

    // Computed: combined translation paragraph
    private var translationParagraph: String {
        var translations = recentHistory.compactMap { $0.translation }.filter { !$0.isEmpty }
        if !captionViewModel.currentTranslation.isEmpty {
            translations.append(captionViewModel.currentTranslation)
        }
        return translations.joined(separator: " ")
    }

    private var hasContent: Bool {
        !originalParagraph.isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if hasContent {
                        // Original text paragraph
                        Text(originalParagraph)
                            .font(.system(size: CGFloat(settings.overlayOriginalFontSize), weight: .medium, design: .rounded))
                            .foregroundColor(.primary)
                            .lineSpacing(8)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Translation paragraph (if available)
                        if !translationParagraph.isEmpty {
                            Text(translationParagraph)
                                .font(.system(size: CGFloat(settings.overlayTranslationFontSize), weight: .regular, design: .rounded))
                                .foregroundColor(.secondary)
                                .lineSpacing(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Anchor for auto-scroll
                        Color.clear
                            .frame(height: 1)
                            .id("caption-bottom")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: originalParagraph) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("caption-bottom", anchor: .bottom)
                }
            }
            .onChange(of: translationParagraph) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("caption-bottom", anchor: .bottom)
                }
            }
        }
        .offset(y: !hasShownFirstContentAnimation && hasContent ? firstContentAnimationOffset : 0)
        .opacity(!hasShownFirstContentAnimation && hasContent ? firstContentAnimationOpacity : 1.0)
        .onChange(of: hasContent) {
            if hasContent && !hasShownFirstContentAnimation {
                triggerFirstContentAnimation()
            }
        }
    }

    private func triggerFirstContentAnimation() {
        guard !hasShownFirstContentAnimation else { return }

        withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.1)) {
            firstContentAnimationOffset = 0
            firstContentAnimationOpacity = 1.0
        }

        hasShownFirstContentAnimation = true
    }
}

// MARK: - Preview Support

class MockCaptionViewModel: ObservableObject, CaptionViewModelProtocol {
    @Published var captionHistory: [CaptionEntry] = [
        CaptionEntry(text: "Welcome to Livcap, the real-time live captioning application for macOS.", confidence: 0.95, translation: "欢迎使用 Livcap，macOS 上的实时字幕应用程序。"),
        CaptionEntry(text: "This app captures audio from your microphone and system audio sources.", confidence: 0.92, translation: "此应用程序从您的麦克风和系统音频源捕获音频。"),
        CaptionEntry(text: "Speech recognition is powered by Apple's advanced Speech framework.", confidence: 0.88, translation: "语音识别由 Apple 先进的语音框架提供支持。"),
        CaptionEntry(text: "Translation is done using AI models with context awareness.", confidence: 0.90, translation: "翻译使用具有上下文感知能力的 AI 模型完成。")
    ]

    @Published var currentTranscription: String = "This is a sample of real-time transcription"
    @Published var currentTranslation: String = "这是实时转录的示例"
}


#Preview("Light Mode") {
    CaptionContentView(
        captionViewModel: MockCaptionViewModel(),
        hasShownFirstContentAnimation: .constant(true),
        firstContentAnimationOffset: .constant(0),
        firstContentAnimationOpacity: .constant(1.0)
    )
    .frame(width: 600, height: 300)
    .background(Color.gray.opacity(0.1))
    .preferredColorScheme(.light)
}

#Preview("Dark Mode") {
    CaptionContentView(
        captionViewModel: MockCaptionViewModel(),
        hasShownFirstContentAnimation: .constant(true),
        firstContentAnimationOffset: .constant(0),
        firstContentAnimationOpacity: .constant(1.0)
    )
    .frame(width: 600, height: 300)
    .background(Color.gray.opacity(0.1))
    .preferredColorScheme(.dark)
}
