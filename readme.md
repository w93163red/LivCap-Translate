# Livcap

A lightweight live caption and translation app for macOS. 
This is my personal fork and borrow the idea from [livecaptions-translator](https://github.com/SakiRinn/LiveCaptions-Translator)


## Highlights

- **Lightweight & Fast** – Up to **1.7x faster word-level performance** and **10% lower latency** compared to macOS native Live Caption.
- **Dual Audio Sources** – Capture from microphone or system audio (macOS 14.4+), with automatic mutual exclusivity.
- **Live Translation** – LLM-powered translation supporting 17 languages via OpenAI-compatible APIs.
- **Minimalist Design** – Floating overlay with one-click on/off. Less is more.
- **Open Source** – Free and transparent.


## Features

### Real-Time Captioning
- Speech-to-text powered by Apple's native `SFSpeechRecognizer`
- Voice Activity Detection (VAD) for efficient silence skipping
- Smart audio downsampling (48kHz to 16kHz mono) optimized for speech

### Audio Sources
- **Microphone** – Direct mic input via `AVAudioEngine`
- **System Audio** – System-wide audio capture via CoreAudio Tap (macOS 14.4+), no screen recording permission needed
- Sources are mutually exclusive – only one active at a time

### Translation
- Real-time and finalized sentence translation
- 17 supported languages: Arabic, Chinese, Dutch, English, French, German, Hindi, Italian, Japanese, Korean, Polish, Portuguese, Russian, Spanish, Swedish, Turkish, Vietnamese
- Works with any OpenAI-compatible API endpoint

### Caption Display
- Floating semi-transparent overlay window
- Resizable with compact and expanded layout modes
- Window pinning (always on top)
- Full caption history with timestamps


## Performance

Livcap outperforms macOS native Live Caption:

| Metric | Improvement |
|--------|-------------|
| Word-level lead rate | **1.7x faster** |
| Average latency | **10% lower** (557ms vs 617ms) |

> Detailed benchmarks available in [`livcapComparision.md`](livcapComparision.md)

**Key optimizations:**
- **Single-pass inference** – One `SFSpeechRecognizer` call vs multiple inferences in native Live Caption
- **Smart downsampling** – 48kHz to 16kHz conversion reduces computational overhead while maintaining quality
- **VAD-based silence skipping** – Prevents unnecessary processing during silent periods


## Architecture

MVVM + Service Layer architecture with async data flow:

```
SwiftUI Views (CaptionView, MainWindowView, SettingsView)
        |
        v
ViewModels (CaptionViewModel, PermissionManager)
        |
        v
Services (AudioCoordinator, SpeechProcessor, TranslationController)
        |
        v
Foundation (VADProcessor, CoreAudioTapEngine, SFSpeechRecognizer)
```

**Data Flow:**
```
Audio Source (Mic / System Audio)
    -> VAD Analysis (RMS energy threshold)
    -> Format Conversion (16kHz mono Float32 PCM)
    -> Speech Recognition (SFSpeechRecognizer)
    -> Caption Display
    -> Translation (via LLM API)
```

### Project Structure

```
Livcap/
├── Views/                  # SwiftUI views
├── ViewModels/             # CaptionViewModel, PermissionManager
├── Service/                # Audio managers, speech processing, translation
├── Models/                 # CaptionEntry, TranslationSettings
├── CoreAudioTapEngine/     # System audio capture engine
└── LivcapApp.swift         # Entry point
```


## Requirements

- macOS 15.0+ (deployment target)
- macOS 14.4+ for system audio capture
- Xcode 16.4+, Swift 5.9+ (for development)
- Microphone permission required


## Development

```bash
# Build
xcodebuild -project Livcap.xcodeproj -scheme Livcap -configuration Release

# Run tests
xcodebuild test -scheme Livcap

# Reset permissions for testing
tccutil reset All com.xxx.xx
```

## License

[MIT](LICENSE)
