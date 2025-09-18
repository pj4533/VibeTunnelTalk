import Foundation
import AVFoundation
import Combine
import OSLog

class OpenAIRealtimeManager: NSObject, ObservableObject {
    let logger = AppLogger.openAIRealtime
    var statsLogger: OpenAIStatisticsLogger

    @Published var isConnected = false
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var transcription = ""

    // Response tracking
    var activeResponseId: String? = nil
    @Published var isResponseInProgress = false
    var narrationQueue: [String] = []
    var pendingNarration: String? = nil
    var lastNarrationTime = Date(timeIntervalSince1970: 0)
    var minNarrationInterval: TimeInterval = 2.0 // Reduced back to 2 seconds for responsiveness

    var webSocketTask: URLSessionWebSocketTask?
    var apiKey: String

    // Audio engine for capturing microphone input
    let audioEngine = AVAudioEngine()
    let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000, // OpenAI Realtime API expects 24kHz
        channels: 1,
        interleaved: false
    )!

    // Audio player for TTS output
    var audioPlayer: AVAudioPlayer?
    var audioQueue = DispatchQueue(label: "audio.queue")
    var audioBufferData = Data()

    // Event subjects for external observation
    let functionCallRequested = PassthroughSubject<FunctionCall, Never>()
    let activityNarration = PassthroughSubject<String, Never>()

    override init() {
        self.apiKey = ""
        self.statsLogger = OpenAIStatisticsLogger(logger: AppLogger.openAIRealtime)
        super.init()
        setupAudioSession()
    }

    init(apiKey: String) {
        self.apiKey = apiKey
        self.statsLogger = OpenAIStatisticsLogger(logger: AppLogger.openAIRealtime)
        super.init()
        setupAudioSession()
    }

    /// Update the API key and reconnect if necessary
    func updateAPIKey(_ newKey: String) {
        // Disconnect if connected
        if isConnected {
            disconnect()
        }

        // Update the key
        apiKey = newKey
    }
}

// MARK: - Supporting Types

struct FunctionCall {
    let name: String
    let parameters: [String: Any]
}