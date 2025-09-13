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

    // Response tracking
    private var activeResponseId: String? = nil
    private var isResponseInProgress = false
    private var narrationQueue: [String] = []
    private var pendingNarration: String? = nil
    private var lastNarrationTime = Date(timeIntervalSince1970: 0)
    private var minNarrationInterval: TimeInterval = 2.0 // Reduced back to 2 seconds for responsiveness

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
            self.isResponseInProgress = false
            self.activeResponseId = nil
            self.narrationQueue.removeAll()
        }
    }
    
    /// Send text context about terminal activity
    func sendTerminalContext(_ context: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        // Queue the narration request
        narrationQueue.append(context)
        logger.info("[OPENAI @ \(timestamp)] 📥 Queued narration request (queue size: \(self.narrationQueue.count), isResponseInProgress: \(self.isResponseInProgress), activeResponseId: \(self.activeResponseId ?? "none"))")

        // Process queue if not currently processing a response
        processNarrationQueue()
    }

    /// Process the narration queue
    private func processNarrationQueue() {
        // Create timestamp for logging
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        // Check if WebSocket is connected
        guard isConnected else {
            logger.debug("[OPENAI @ \(timestamp)] 🔌 Not connected, clearing narration queue")
            narrationQueue.removeAll()
            return
        }

        // Check if we can send a narration
        guard !isResponseInProgress else {
            logger.info("[OPENAI @ \(timestamp)] ⏸️ Response in progress (ID: \(self.activeResponseId ?? "none")), will retry when complete")
            // Don't schedule retry here - response.done will trigger processNarrationQueue
            return
        }

        guard !narrationQueue.isEmpty else {
            return
        }

        // Check if enough time has passed since last narration
        let timeSinceLastNarration = Date().timeIntervalSince(lastNarrationTime)

        // For the very first narration (when lastNarrationTime is ancient), don't wait
        let isFirstNarration = timeSinceLastNarration > 3600 // More than an hour means it's the first

        if !isFirstNarration && timeSinceLastNarration < minNarrationInterval {
            let waitTime = minNarrationInterval - timeSinceLastNarration
            logger.info("[OPENAI @ \(timestamp)] ⏱️ Waiting \(String(format: "%.1f", waitTime))s before next narration")
            // Schedule retry
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) { [weak self] in
                self?.processNarrationQueue()
            }
            return
        }

        // Combine all queued narrations into one comprehensive update
        let combinedContext = narrationQueue.joined(separator: "\n\n")
        narrationQueue.removeAll()

        // Mark as processing
        isResponseInProgress = true
        lastNarrationTime = Date()

        logger.info("[OPENAI @ \(timestamp)] 📤 Sending combined narration request (\(combinedContext.count) chars)")

        // Send the chunk with analysis request
        let event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [
                    [
                        "type": "input_text",
                        "text": combinedContext
                    ]
                ]
            ]
        ]

        sendEvent(event)

        // Request both text and audio response with narration
        let responseEvent: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": ["text", "audio"],
                "instructions": """
                    Analyze the terminal output and provide a natural, conversational narration.
                    Keep it brief (1-2 sentences) and informative.
                    Focus on what Claude is actually doing, not just listing commands.
                    Speak naturally as if you're explaining to someone what's happening on screen.
                    """
            ]
        ]
        logger.info("[OPENAI @ \(timestamp)] 🎤 Requesting narration response")
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        logger.info("[OPENAI @ \(timestamp)] 🔧 Sending session configuration")

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
        guard let webSocketTask = webSocketTask else {
            logger.error("[OPENAI-TX] ❌ No WebSocket task available")
            return
        }

        // Create timestamp for logging
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        do {
            let data = try JSONSerialization.data(withJSONObject: event)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                logger.error("[OPENAI-TX @ \(timestamp)] ❌ Failed to convert data to string")
                return
            }
            let message = URLSessionWebSocketTask.Message.string(jsonString)

            // Log event type
            if let eventType = event["type"] as? String {
                logger.debug("[OPENAI-TX @ \(timestamp)] 📨 Sending event: \(eventType)")
            }

            webSocketTask.send(message) { [weak self] error in
                if let error = error {
                    self?.logger.error("[OPENAI-TX @ \(timestamp)] ❌ Failed to send event: \(error.localizedDescription)")

                    // If send fails, we might be disconnected
                    self?.handleDisconnection()
                }
            }
        } catch {
            logger.error("[OPENAI-TX @ \(timestamp)] ❌ Failed to serialize event: \(error.localizedDescription)")
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage() // Continue receiving

            case .failure(let error):
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timestamp = formatter.string(from: Date())
                self?.logger.error("[OPENAI-RX @ \(timestamp)] ❌ WebSocket receive error: \(error.localizedDescription)")
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
            case "response.created":
                // Track the response ID
                if let response = json["response"] as? [String: Any],
                   let responseId = response["id"] as? String {
                    activeResponseId = responseId
                    isResponseInProgress = true
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss.SSS"
                    let timestamp = formatter.string(from: Date())
                    logger.info("[OPENAI @ \(timestamp)] 🆔 Response started: \(responseId)")
                } else {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss.SSS"
                    let timestamp = formatter.string(from: Date())
                    logger.warning("[OPENAI @ \(timestamp)] ⚠️ Response created without ID")
                }

            case "response.done":
                // Response completed
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timestamp = formatter.string(from: Date())

                if let response = json["response"] as? [String: Any],
                   let responseId = response["id"] as? String {
                    logger.info("[OPENAI @ \(timestamp)] ✅ Response completed: \(responseId)")
                    if responseId == activeResponseId {
                        activeResponseId = nil
                        isResponseInProgress = false

                        // Process any queued narrations immediately
                        DispatchQueue.main.async { [weak self] in
                            self?.processNarrationQueue()
                        }
                    } else {
                        logger.warning("[OPENAI @ \(timestamp)] ⚠️ Response done for unknown ID: \(responseId), active: \(self.activeResponseId ?? "none")")
                    }
                } else {
                    // Response done without ID - still clear the flag
                    logger.warning("[OPENAI @ \(timestamp)] ⚠️ Response done without ID, clearing flag")
                    activeResponseId = nil
                    isResponseInProgress = false

                    // Process any queued narrations
                    DispatchQueue.main.async { [weak self] in
                        self?.processNarrationQueue()
                    }
                }

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

            case "session.created":
                // Session created successfully
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timestamp = formatter.string(from: Date())
                logger.info("[OPENAI @ \(timestamp)] 🎯 Session created successfully")

                // Send initial greeting after session is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.sendTerminalContext("VibeTunnelTalk connected to Claude Code session. Ready to narrate terminal activity.")
                }
                break

            case "session.updated":
                // Session updated successfully
                let formatter2 = DateFormatter()
                formatter2.dateFormat = "HH:mm:ss.SSS"
                let timestamp2 = formatter2.string(from: Date())
                logger.info("[OPENAI @ \(timestamp2)] 🎯 Session updated successfully")
                break
                
            case "error":
                // Handle error
                if let error = json["error"] as? [String: Any] {
                    logger.error("[OPENAI] 🚨 Error from OpenAI: \(error)")

                    // Check error type and handle appropriately
                    if let code = error["code"] as? String {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "HH:mm:ss.SSS"
                        let timestamp = formatter.string(from: Date())

                        switch code {
                        case "conversation_already_has_active_response":
                            logger.info("[OPENAI @ \(timestamp)] ⚠️ Active response conflict - waiting for current response to complete")
                            // Don't clear the active response state, just wait longer
                            // The response.done event will clear it properly

                        case "rate_limit_exceeded":
                            logger.error("[OPENAI @ \(timestamp)] 🚫 Rate limit exceeded - backing off")
                            // Clear state and wait longer before retrying
                            activeResponseId = nil
                            isResponseInProgress = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                                self?.processNarrationQueue()
                            }

                        default:
                            logger.error("[OPENAI @ \(timestamp)] 🚨 Unhandled error code: \(code)")
                            // For unknown errors, reset state and retry
                            activeResponseId = nil
                            isResponseInProgress = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                                self?.processNarrationQueue()
                            }
                        }
                    }
                }
                
            case "rate_limits.updated":
                // Handle rate limits update - only log if there's an issue
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timestamp = formatter.string(from: Date())

                // Parse the rate limit details and only warn if needed
                if let rateLimits = json["rate_limits"] as? [[String: Any]] {
                    for rateLimit in rateLimits {
                        if let name = rateLimit["name"] as? String,
                           let limit = rateLimit["limit"] as? Int,
                           let remaining = rateLimit["remaining"] as? Int,
                           let resetSeconds = rateLimit["reset_seconds"] as? Double {

                            let percentUsed = Double(limit - remaining) / Double(limit) * 100

                            if remaining == 0 {
                                // Log full details when exhausted
                                logger.error("[OPENAI @ \(timestamp)] 🚫 RATE LIMIT EXHAUSTED: \(name) - 0/\(limit) remaining, resets in \(resetSeconds)s")
                                logger.error("[OPENAI @ \(timestamp)] Response state - isResponseInProgress: \(self.isResponseInProgress), activeResponseId: \(self.activeResponseId ?? "none")")
                            } else if percentUsed > 90 {
                                // Only warn when usage is very high (>90%)
                                logger.warning("[OPENAI @ \(timestamp)] ⚠️ Rate limit high usage: \(name) - \(remaining)/\(limit) remaining (\(String(format: "%.1f", percentUsed))% used), resets in \(resetSeconds)s")
                            }
                            // Don't log anything for normal usage
                        }
                    }
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
            self.isResponseInProgress = false
            self.activeResponseId = nil
            self.narrationQueue.removeAll()
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        logger.error("[OPENAI @ \(timestamp)] 🔴 WebSocket disconnected - connection lost")
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OpenAIRealtimeManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        logger.info("[OPENAI-WS @ \(timestamp)] ✅ WebSocket opened with protocol: \(`protocol` ?? "none")")

        // Mark as connected and send configuration once WebSocket is open
        DispatchQueue.main.async {
            self.isConnected = true
            self.logger.info("[OPENAI-WS @ \(timestamp)] 🔄 Connection state updated to: connected")
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
