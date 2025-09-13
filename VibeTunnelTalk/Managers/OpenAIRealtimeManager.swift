import Foundation
import AVFoundation
import Combine
import OSLog

class OpenAIRealtimeManager: NSObject, ObservableObject {
    private let logger = AppLogger.openAIRealtime
    
    @Published var isConnected = false
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var transcription = ""
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var apiKey: String
    
    // Audio engine for capturing microphone input
    private let audioEngine = AVAudioEngine()
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000, // OpenAI Realtime API expects 24kHz
        channels: 1,
        interleaved: false
    )!
    
    // Audio player for TTS output
    private var audioPlayer: AVAudioPlayer?
    private var audioQueue = DispatchQueue(label: "audio.queue")
    private var audioBufferData = Data()
    
    // Event subjects for external observation
    let functionCallRequested = PassthroughSubject<FunctionCall, Never>()
    let activityNarration = PassthroughSubject<String, Never>()
    
    override init() {
        self.apiKey = ""
        super.init()
        setupAudioSession()
    }
    
    init(apiKey: String) {
        self.apiKey = apiKey
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
    
    /// Connect to OpenAI Realtime API
    func connect() {
        // Don't connect without an API key
        guard !apiKey.isEmpty else { 
            logger.error("[OPENAI] ❌ Cannot connect without API key")
            return 
        }
        
        logger.info("[OPENAI] 🔌 Connecting to OpenAI Realtime API...")
        
        // Create URLRequest exactly like swift-realtime-openai
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime")!.appending(queryItems: [
            URLQueryItem(name: "model", value: "gpt-4o-realtime-preview-2024-12-17")
        ]))
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        logger.info("[OPENAI] 📋 Request URL: \(request.url?.absoluteString ?? "nil")")
        
        // Use URLSession.shared instead of custom session - this is how swift-realtime-openai does it
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.delegate = self
        webSocketTask?.resume()
        
        // Start receiving messages immediately
        receiveMessage()
    }
    
    /// Disconnect from OpenAI
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        stopAudioCapture()
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.isListening = false
            self.isSpeaking = false
        }
    }
    
    /// Send text context about terminal activity
    func sendTerminalContext(_ context: String) {
        logger.info("[OPENAI] 📤 Sending to OpenAI for TTS: \(context)")

        let event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [
                    [
                        "type": "input_text",
                        "text": "Terminal Update: \(context)"
                    ]
                ]
            ]
        ]

        sendEvent(event)

        // After sending the context, request a response with both text and audio
        let responseEvent: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": ["text", "audio"],  // Request both text and audio response
                "instructions": "Speak this update naturally and concisely."
            ]
        ]
        logger.info("[OPENAI] 🎤 Requesting audio response")
        sendEvent(responseEvent)
    }
    
    /// Start listening for voice input
    func startListening() {
        guard !isListening else { return }
        
        DispatchQueue.main.async {
            self.isListening = true
        }
        
        startAudioCapture()
    }
    
    /// Stop listening for voice input
    func stopListening() {
        guard isListening else { return }
        
        stopAudioCapture()
        
        // Send input audio buffer commit event
        let event: [String: Any] = [
            "type": "input_audio_buffer.commit"
        ]
        sendEvent(event)
        
        // Request response
        let responseEvent: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": ["text", "audio"]
            ]
        ]
        sendEvent(responseEvent)
        
        DispatchQueue.main.async {
            self.isListening = false
        }
    }
    
    // MARK: - Private Methods
    
    private func setupAudioSession() {
        // AVAudioSession is not available on macOS
        // Audio permissions are handled at the system level
    }
    
    private func sendSessionConfiguration() {
        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": """
                You are VibeTunnelTalk, an intelligent assistant that monitors and narrates Claude Code sessions.
                Your role is to:
                1. Provide concise, informative narration of what Claude is doing
                2. Summarize file changes and code modifications
                3. Alert the user to errors or important events
                4. Respond to voice commands and execute them in the terminal
                5. Keep narration brief and contextual - don't read everything verbatim
                
                When you detect terminal activity, describe it in a natural, conversational way.
                For example: "Claude is modifying the authentication module" or "Running tests... 15 passed, 2 failed"
                
                When the user gives a voice command, translate it to the appropriate terminal command.
                """,
                "voice": "alloy",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ],
                "tools": [
                    [
                        "type": "function",
                        "name": "execute_terminal_command",
                        "description": "Execute a command in the terminal",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "command": [
                                    "type": "string",
                                    "description": "The terminal command to execute"
                                ]
                            ],
                            "required": ["command"]
                        ]
                    ],
                    [
                        "type": "function",
                        "name": "control_session",
                        "description": "Control the Claude session",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "action": [
                                    "type": "string",
                                    "enum": ["pause", "resume", "stop", "restart"],
                                    "description": "The control action to perform"
                                ]
                            ],
                            "required": ["action"]
                        ]
                    ]
                ]
            ]
        ]
        
        sendEvent(config)
    }
    
    private func sendEvent(_ event: [String: Any]) {
        guard let webSocketTask = webSocketTask else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: event)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                logger.error("[OPENAI-TX] ❌ Failed to convert data to string")
                return
            }
            let message = URLSessionWebSocketTask.Message.string(jsonString)

            webSocketTask.send(message) { [weak self] error in
                if let error = error {
                    self?.logger.error("[OPENAI-TX] ❌ Failed to send event: \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("[OPENAI-TX] ❌ Failed to serialize event: \(error.localizedDescription)")
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage() // Continue receiving
                
            case .failure(let error):
                self?.logger.error("[OPENAI-RX] ❌ WebSocket receive error: \(error.localizedDescription)")
                self?.handleDisconnection()
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            handleDataMessage(data)
            
        case .string(let text):
            if let data = text.data(using: .utf8) {
                handleDataMessage(data)
            }
            
        @unknown default:
            break
        }
    }
    
    private func handleDataMessage(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }
            
            switch type {
            case "response.audio.delta":
                // Handle audio chunk
                if let delta = json["delta"] as? String,
                   let decodedAudio = Data(base64Encoded: delta) {
                    logger.debug("[OPENAI] 🎵 Received audio chunk: \(decodedAudio.count) bytes")
                    handleAudioChunk(decodedAudio)
                }
                
            case "response.audio.done":
                // Audio response complete
                logger.info("[OPENAI] 🎶 Audio response complete, playing buffered audio")
                playBufferedAudio()
                DispatchQueue.main.async {
                    self.isSpeaking = false
                }
                
            case "response.text.delta":
                // Handle text response chunk
                if let delta = json["delta"] as? String {
                    DispatchQueue.main.async {
                        self.transcription += delta
                    }
                }
                
            case "response.text.done":
                // Text response complete
                if let text = json["text"] as? String {
                    logger.info("[OPENAI] 📝 Text response: \(text)")
                    DispatchQueue.main.async {
                        self.activityNarration.send(text)
                        self.transcription = ""
                    }
                }
                
            case "response.function_call_arguments.delta":
                // Handle function call arguments
                break
                
            case "response.function_call_arguments.done":
                // Function call complete
                if let name = json["name"] as? String,
                   let argumentsString = json["arguments"] as? String,
                   let argumentsData = argumentsString.data(using: .utf8),
                   let parameters = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] {
                    
                    let functionCall = FunctionCall(name: name, parameters: parameters)
                    DispatchQueue.main.async {
                        self.functionCallRequested.send(functionCall)
                    }
                }
                
            case "input_audio_buffer.speech_started":
                // User started speaking
                break
                
            case "input_audio_buffer.speech_stopped":
                // User stopped speaking
                break
                
            case "conversation.item.created":
                // New conversation item created
                break
                
            case "error":
                // Handle error
                if let error = json["error"] as? [String: Any] {
                    logger.error("[OPENAI] 🚨 Error from OpenAI: \(error)")
                }
                
            default:
                // Log other message types for debugging
                logger.debug("[OPENAI] 📩 Received message type: \(type)")
            }
            
        } catch {
            logger.error("[OPENAI-RX] ❌ Failed to parse message: \(error.localizedDescription)")
        }
    }
    
    private func handleAudioChunk(_ audioData: Data) {
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
        
        // Buffer audio data
        audioQueue.async { [weak self] in
            self?.audioBufferData.append(audioData)
        }
    }
    
    private func playBufferedAudio() {
        audioQueue.async { [weak self] in
            guard let self = self, !self.audioBufferData.isEmpty else { return }
            
            // Create WAV header for PCM16 data
            let wavData = self.createWAVData(from: self.audioBufferData)
            
            do {
                self.audioPlayer = try AVAudioPlayer(data: wavData)
                self.audioPlayer?.play()
            } catch {
                self.logger.error("[OPENAI-AUDIO] ❌ Failed to play audio: \(error.localizedDescription)")
            }
            
            // Clear buffer
            self.audioBufferData = Data()
        }
    }
    
    private func createWAVData(from pcmData: Data) -> Data {
        var wavData = Data()
        
        // WAV header
        let sampleRate: UInt32 = 24000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(pcmData.count)
        
        // RIFF chunk
        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Data($0) })
        wavData.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        wavData.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt32(sampleRate * UInt32(channels) * UInt32(bitsPerSample/8)).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt16(channels * bitsPerSample/8).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        
        // data chunk
        wavData.append("data".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wavData.append(pcmData)
        
        return wavData
    }
    
    private func startAudioCapture() {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        
        do {
            try audioEngine.start()
        } catch {
            logger.error("[OPENAI-AUDIO] ❌ Failed to start audio engine: \(error.localizedDescription)")
        }
    }
    
    private func stopAudioCapture() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let channelDataValue = channelData.pointee
        let frameLength = Int(buffer.frameLength)
        
        // Convert Float32 samples to Int16
        var int16Data = [Int16]()
        for i in 0..<frameLength {
            let sample = channelDataValue[i]
            let int16Sample = Int16(max(-32768, min(32767, sample * 32767)))
            int16Data.append(int16Sample)
        }
        
        let data = int16Data.withUnsafeBytes { Data($0) }
        
        // Send audio data to OpenAI
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
        sendEvent(event)
    }
    
    private func handleDisconnection() {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isListening = false
            self.isSpeaking = false
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OpenAIRealtimeManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        logger.info("[OPENAI-WS] ✅ WebSocket opened with protocol: \(`protocol` ?? "none")")
        
        // Mark as connected and send configuration once WebSocket is open
        DispatchQueue.main.async {
            self.isConnected = true
        }
        self.sendSessionConfiguration()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        logger.error("[OPENAI-WS] ❌ WebSocket closed with code: \(closeCode.rawValue), reason: \(reasonString)")
        handleDisconnection()
    }
}

// MARK: - Supporting Types

struct FunctionCall {
    let name: String
    let parameters: [String: Any]
}
