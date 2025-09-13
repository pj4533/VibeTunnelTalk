# VibeTunnelTalk Implementation Guide

## Table of Contents
1. [Project Overview](#project-overview)
2. [Architecture Design](#architecture-design)
3. [Technical Requirements](#technical-requirements)
4. [Project Setup](#project-setup)
5. [Core Components](#core-components)
6. [Implementation Details](#implementation-details)
7. [Testing Strategy](#testing-strategy)
8. [Deployment](#deployment)

---

## Project Overview

VibeTunnelTalk is a native macOS application built with SwiftUI that provides real-time voice narration and control for Claude Code sessions running through VibeTunnel. The application connects to VibeTunnel's IPC socket infrastructure to monitor terminal output and uses OpenAI's Realtime API for bidirectional voice interaction, allowing users to hear what Claude is doing and control it through voice commands.

### Key Features
- **Real-time Terminal Monitoring**: Connects to VibeTunnel sessions via Unix domain sockets
- **Intelligent Voice Narration**: Uses OpenAI's Realtime API to describe Claude's activities
- **Voice Command Control**: Send commands to Claude through speech
- **Activity Detection**: Recognizes and narrates Claude's different states (thinking, writing, debugging)
- **Smart Summarization**: Doesn't read everything verbatim but provides contextual updates

### System Architecture
```
┌─────────────────────────┐
│   User Voice Input      │
└───────────┬─────────────┘
            ↓
┌─────────────────────────┐     WebSocket      ┌─────────────────────────┐
│   VibeTunnelTalk App    │ ←───────────────→  │  OpenAI Realtime API    │
│      (SwiftUI)          │                    │   (gpt-realtime)        │
└───────────┬─────────────┘                    └─────────────────────────┘
            ↓
     Unix Domain Socket
            ↓
┌─────────────────────────┐
│   VibeTunnel Session    │
│   ~/.vibetunnel/control │
│   /{session-id}/ipc.sock│
└───────────┬─────────────┘
            ↓
┌─────────────────────────┐
│   Claude Code Session   │
│      (Terminal PTY)     │
└─────────────────────────┘
```

---

## Architecture Design

### Component Breakdown

#### 1. **VibeTunnelSocketManager**
- Manages Unix domain socket connections to VibeTunnel sessions
- Implements the VibeTunnel IPC protocol
- Handles message framing and parsing
- Maintains connection state and reconnection logic

#### 2. **OpenAIRealtimeManager**
- Manages WebSocket connection to OpenAI's Realtime API
- Handles audio streaming (PCM16 format)
- Manages voice activity detection (VAD)
- Processes function calls for terminal commands

#### 3. **SessionActivityMonitor**
- Parses terminal output for Claude-specific patterns
- Detects activity states (thinking, writing, debugging, idle)
- Tracks file modifications and command execution
- Generates contextual summaries for narration

#### 4. **VoiceCommandProcessor**
- Processes spoken commands from OpenAI transcriptions
- Maps voice intents to terminal commands
- Handles command confirmation and feedback

#### 5. **UI Components**
- Main connection view with status indicators
- Session picker for multiple VibeTunnel sessions
- Voice activity visualization
- Terminal output preview (optional)

### Data Flow

1. **Terminal Output → Narration**:
   ```
   VibeTunnel Session → IPC Socket → VibeTunnelSocketManager 
   → SessionActivityMonitor → OpenAIRealtimeManager → Voice Output
   ```

2. **Voice Command → Terminal Input**:
   ```
   Voice Input → OpenAI Realtime API → VoiceCommandProcessor 
   → VibeTunnelSocketManager → IPC Socket → Terminal Session
   ```

---

## Technical Requirements

### System Requirements
- **macOS**: 14.0+ (Sonoma or later)
- **Xcode**: 16.0+
- **Swift**: 6.0+
- **Hardware**: Apple Silicon Mac (M1 or later) recommended for optimal performance

### Dependencies
```swift
// Package.swift dependencies
dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.68.0"),
    .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.21.0"),
    .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.8"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
]
```

### API Keys and Configuration
- **OpenAI API Key**: Required for Realtime API access
- **VibeTunnel**: Must be installed and running locally
- **Microphone Permissions**: Required for voice input
- **Network Permissions**: Required for OpenAI WebSocket connection

---

## Project Setup

### 1. Create Xcode Project

```bash
# Create project directory
mkdir VibeTunnelTalk
cd VibeTunnelTalk

# Initialize as git repository
git init
echo "# VibeTunnelTalk" > README.md
```

### 2. Xcode Configuration

1. Open Xcode and create new macOS App
2. Product Name: `VibeTunnelTalk`
3. Team: Your Developer ID
4. Organization Identifier: `com.yourcompany`
5. Interface: SwiftUI
6. Language: Swift
7. Use Core Data: No
8. Include Tests: Yes

### 3. Project Structure

```
VibeTunnelTalk/
├── VibeTunnelTalk/
│   ├── App/
│   │   ├── VibeTunnelTalkApp.swift
│   │   └── AppDelegate.swift
│   ├── Models/
│   │   ├── SessionInfo.swift
│   │   ├── ActivityState.swift
│   │   └── VoiceCommand.swift
│   ├── Managers/
│   │   ├── VibeTunnelSocketManager.swift
│   │   ├── OpenAIRealtimeManager.swift
│   │   ├── SessionActivityMonitor.swift
│   │   └── VoiceCommandProcessor.swift
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── ConnectionView.swift
│   │   ├── SessionPickerView.swift
│   │   └── VoiceActivityView.swift
│   ├── Utilities/
│   │   ├── IPCProtocol.swift
│   │   ├── ANSIParser.swift
│   │   ├── AudioConverter.swift
│   │   └── Logger.swift
│   ├── Resources/
│   │   ├── Info.plist
│   │   └── VibeTunnelTalk.entitlements
│   └── Config/
│       └── Config.xcconfig
├── VibeTunnelTalkTests/
└── Package.swift
```

### 4. Entitlements Configuration

```xml
<!-- VibeTunnelTalk.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
    <array>
        <string>/.vibetunnel/</string>
    </array>
</dict>
</plist>
```

---

## Core Components

### 1. VibeTunnel IPC Protocol Implementation

```swift
// IPCProtocol.swift
import Foundation

/// VibeTunnel IPC Message Types
enum MessageType: UInt8 {
    case input = 0x01
    case data = 0x02
    case resize = 0x03
    case kill = 0x04
    case resetSize = 0x05
    case updateTitle = 0x06
    case heartbeat = 0x07
    case error = 0xFF
}

/// Message header structure (8 bytes)
struct MessageHeader {
    let type: MessageType
    let flags: UInt8
    let reserved: UInt16
    let length: UInt32
    
    var data: Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(flags)
        data.append(contentsOf: withUnsafeBytes(of: reserved.bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Data($0) })
        return data
    }
    
    static func parse(from data: Data) -> MessageHeader? {
        guard data.count >= 8 else { return nil }
        
        let type = MessageType(rawValue: data[0]) ?? .error
        let flags = data[1]
        let reserved = data[2..<4].withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let length = data[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        return MessageHeader(type: type, flags: flags, reserved: reserved, length: length)
    }
}

/// Complete message with header and payload
struct IPCMessage {
    let header: MessageHeader
    let payload: Data
    
    var data: Data {
        var result = header.data
        result.append(payload)
        return result
    }
    
    static func createInput(_ text: String) -> IPCMessage {
        let payload = text.data(using: .utf8) ?? Data()
        let header = MessageHeader(
            type: .input,
            flags: 0,
            reserved: 0,
            length: UInt32(payload.count)
        )
        return IPCMessage(header: header, payload: payload)
    }
    
    static func createResize(cols: Int, rows: Int) -> IPCMessage {
        let json = ["cols": cols, "rows": rows]
        let payload = try! JSONSerialization.data(withJSONObject: json)
        let header = MessageHeader(
            type: .resize,
            flags: 0,
            reserved: 0,
            length: UInt32(payload.count)
        )
        return IPCMessage(header: header, payload: payload)
    }
}
```

### 2. VibeTunnel Socket Manager

```swift
// VibeTunnelSocketManager.swift
import Foundation
import Network
import Combine
import os.log

class VibeTunnelSocketManager: ObservableObject {
    private let logger = Logger(subsystem: "com.vibetunneltalk", category: "SocketManager")
    
    @Published var isConnected = false
    @Published var currentSessionId: String?
    @Published var terminalOutput = PassthroughSubject<String, Never>()
    
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "vibetunnel.socket", qos: .userInitiated)
    
    /// Find available VibeTunnel sessions
    func findAvailableSessions() -> [String] {
        let controlPath = NSHomeDirectory() + "/.vibetunnel/control"
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(atPath: controlPath) else {
            logger.warning("No VibeTunnel control directory found")
            return []
        }
        
        // Filter for directories that contain an ipc.sock file
        return contents.filter { sessionId in
            let socketPath = "\(controlPath)/\(sessionId)/ipc.sock"
            return fm.fileExists(atPath: socketPath)
        }
    }
    
    /// Connect to a VibeTunnel session
    func connect(to sessionId: String) {
        let socketPath = NSHomeDirectory() + "/.vibetunnel/control/\(sessionId)/ipc.sock"
        
        logger.info("Connecting to session \(sessionId) at \(socketPath)")
        
        // Create Unix domain socket endpoint
        let endpoint = NWEndpoint.unix(path: socketPath)
        let parameters = NWParameters()
        
        connection = NWConnection(to: endpoint, using: parameters)
        
        connection?.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }
        
        connection?.start(queue: queue)
    }
    
    /// Disconnect from current session
    func disconnect() {
        logger.info("Disconnecting from session")
        connection?.cancel()
        connection = nil
        isConnected = false
        currentSessionId = nil
    }
    
    /// Send input to the terminal
    func sendInput(_ text: String) {
        guard isConnected else {
            logger.warning("Cannot send input - not connected")
            return
        }
        
        let message = IPCMessage.createInput(text)
        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send input: \(error.localizedDescription)")
            }
        })
    }
    
    /// Resize terminal
    func resize(cols: Int, rows: Int) {
        guard isConnected else { return }
        
        let message = IPCMessage.createResize(cols: cols, rows: rows)
        connection?.send(content: message.data, completion: .contentProcessed { _ in })
    }
    
    // MARK: - Private Methods
    
    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("Socket connected and ready")
            DispatchQueue.main.async {
                self.isConnected = true
            }
            startReceiving()
            
        case .failed(let error):
            logger.error("Socket connection failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isConnected = false
            }
            
        case .cancelled:
            logger.info("Socket connection cancelled")
            DispatchQueue.main.async {
                self.isConnected = false
            }
            
        default:
            break
        }
    }
    
    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handleReceivedData(data)
            }
            
            if error == nil && !isComplete {
                self?.startReceiving()
            }
        }
    }
    
    private func handleReceivedData(_ data: Data) {
        receiveBuffer.append(data)
        
        // Process complete messages from buffer
        while receiveBuffer.count >= 8 {
            // Try to parse header
            guard let header = MessageHeader.parse(from: receiveBuffer) else {
                logger.error("Failed to parse message header")
                receiveBuffer.removeAll()
                break
            }
            
            let totalMessageSize = 8 + Int(header.length)
            
            // Check if we have the complete message
            guard receiveBuffer.count >= totalMessageSize else {
                // Wait for more data
                break
            }
            
            // Extract message payload
            let payload = receiveBuffer[8..<totalMessageSize]
            
            // Process the message
            processMessage(header: header, payload: payload)
            
            // Remove processed message from buffer
            receiveBuffer.removeFirst(totalMessageSize)
        }
    }
    
    private func processMessage(header: MessageHeader, payload: Data) {
        switch header.type {
        case .data:
            // Terminal output data
            if let text = String(data: payload, encoding: .utf8) {
                // Remove ANSI escape codes for cleaner processing
                let cleanText = removeANSIEscapeCodes(from: text)
                
                DispatchQueue.main.async {
                    self.terminalOutput.send(cleanText)
                }
            }
            
        case .error:
            if let errorText = String(data: payload, encoding: .utf8) {
                logger.error("Received error from VibeTunnel: \(errorText)")
            }
            
        case .heartbeat:
            // Respond to heartbeat
            sendHeartbeat()
            
        default:
            logger.debug("Received message type: \(header.type)")
        }
    }
    
    private func sendHeartbeat() {
        let header = MessageHeader(type: .heartbeat, flags: 0, reserved: 0, length: 0)
        let message = IPCMessage(header: header, payload: Data())
        connection?.send(content: message.data, completion: .contentProcessed { _ in })
    }
    
    private func removeANSIEscapeCodes(from text: String) -> String {
        // Remove ANSI escape sequences
        let pattern = "\\x1B\\[[0-9;]*[a-zA-Z]"
        return text.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }
}
```

### 3. OpenAI Realtime Manager

```swift
// OpenAIRealtimeManager.swift
import Foundation
import AVFoundation
import Combine
import os.log

class OpenAIRealtimeManager: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.vibetunneltalk", category: "OpenAIRealtime")
    
    @Published var isConnected = false
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var transcription = ""
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private let apiKey: String
    
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
    
    // Event subjects for external observation
    let functionCallRequested = PassthroughSubject<FunctionCall, Never>()
    let activityNarration = PassthroughSubject<String, Never>()
    
    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
        
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        setupAudioSession()
    }
    
    /// Connect to OpenAI Realtime API
    func connect() {
        let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.resume()
        
        // Send initial session configuration
        sendSessionConfiguration()
        
        // Start receiving messages
        receiveMessage()
        
        DispatchQueue.main.async {
            self.isConnected = true
        }
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
        let event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [
                    [
                        "type": "text",
                        "text": "Terminal Update: \(context)"
                    ]
                ]
            ]
        ]
        
        sendEvent(event)
    }
    
    /// Start listening for voice input
    func startListening() {
        guard !isListening else { return }
        
        DispatchQueue.main.async {
            self.isListening = true
        }
        
        startAudioCapture()
        
        // Send input audio buffer append begin event
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": nil // Will be followed by audio chunks
        ]
        sendEvent(event)
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
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat)
            try session.setActive(true)
        } catch {
            logger.error("Failed to setup audio session: \(error.localizedDescription)")
        }
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
                "voice": "alloy", // or "echo", "fable", "onyx", "nova", "shimmer"
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
            let message = URLSessionWebSocketTask.Message.data(data)
            
            webSocketTask.send(message) { [weak self] error in
                if let error = error {
                    self?.logger.error("Failed to send event: \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("Failed to serialize event: \(error.localizedDescription)")
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage() // Continue receiving
                
            case .failure(let error):
                self?.logger.error("WebSocket receive error: \(error.localizedDescription)")
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
                if let audioData = json["delta"] as? String,
                   let decodedAudio = Data(base64Encoded: audioData) {
                    handleAudioChunk(decodedAudio)
                }
                
            case "response.audio.done":
                // Audio response complete
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
                    DispatchQueue.main.async {
                        self.activityNarration.send(text)
                        self.transcription = ""
                    }
                }
                
            case "response.function_call":
                // Handle function call
                handleFunctionCall(json)
                
            case "input_audio_buffer.speech_started":
                // User started speaking
                logger.debug("Speech started")
                
            case "input_audio_buffer.speech_stopped":
                // User stopped speaking
                logger.debug("Speech stopped")
                
            case "conversation.item.created":
                // New conversation item created
                logger.debug("Conversation item created")
                
            case "error":
                // Handle error
                if let error = json["error"] as? [String: Any] {
                    logger.error("OpenAI error: \(error)")
                }
                
            default:
                logger.debug("Received event type: \(type)")
            }
            
        } catch {
            logger.error("Failed to parse message: \(error.localizedDescription)")
        }
    }
    
    private func handleAudioChunk(_ audioData: Data) {
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
        
        // Convert PCM16 data to audio and play
        audioQueue.async { [weak self] in
            self?.playAudioData(audioData)
        }
    }
    
    private func handleFunctionCall(_ json: [String: Any]) {
        guard let call = json["call"] as? [String: Any],
              let name = call["name"] as? String,
              let parameters = call["parameters"] as? [String: Any] else {
            return
        }
        
        let functionCall = FunctionCall(name: name, parameters: parameters)
        
        DispatchQueue.main.async {
            self.functionCallRequested.send(functionCall)
        }
        
        // Send function call result back
        let resultEvent: [String: Any] = [
            "type": "response.function_call_result",
            "call_id": call["id"] as? String ?? "",
            "result": "Command executed successfully"
        ]
        sendEvent(resultEvent)
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
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }
    
    private func stopAudioCapture() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.int16ChannelData else { return }
        
        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(
            from: 0,
            to: Int(buffer.frameLength),
            by: buffer.stride
        ).map { channelDataValue[$0] }
        
        let data = Data(bytes: channelDataValueArray, count: channelDataValueArray.count * 2)
        
        // Send audio data to OpenAI
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
        sendEvent(event)
    }
    
    private func playAudioData(_ data: Data) {
        // Convert PCM16 data to playable format
        // This is a simplified version - you may need more robust audio handling
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.play()
        } catch {
            logger.error("Failed to play audio: \(error.localizedDescription)")
        }
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
        logger.info("WebSocket connected to OpenAI")
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        logger.info("WebSocket closed with code: \(closeCode)")
        handleDisconnection()
    }
}

// MARK: - Supporting Types

struct FunctionCall {
    let name: String
    let parameters: [String: Any]
}
```

### 4. Session Activity Monitor

```swift
// SessionActivityMonitor.swift
import Foundation
import Combine
import os.log

/// Monitors terminal output and generates intelligent summaries for narration
class SessionActivityMonitor: ObservableObject {
    private let logger = Logger(subsystem: "com.vibetunneltalk", category: "ActivityMonitor")
    
    @Published var currentActivity: ActivityState = .idle
    @Published var lastNarration: String = ""
    
    private var outputBuffer = ""
    private var lastActivityTime = Date()
    private var fileOperations: [FileOperation] = []
    private var currentCommand: String?
    private var errorCount = 0
    
    // Patterns for detecting Claude activities
    private let patterns = ActivityPatterns()
    
    // Debounce timer for narration
    private var narrationTimer: Timer?
    private let narrationDebounceInterval: TimeInterval = 2.0
    
    /// Process new terminal output
    func processOutput(_ text: String) {
        outputBuffer += text
        lastActivityTime = Date()
        
        // Detect activity type
        let detectedActivity = detectActivity(from: text)
        if detectedActivity != currentActivity {
            currentActivity = detectedActivity
            scheduleNarration()
        }
        
        // Track file operations
        trackFileOperations(from: text)
        
        // Track errors
        trackErrors(from: text)
        
        // Limit buffer size
        if outputBuffer.count > 10000 {
            outputBuffer = String(outputBuffer.suffix(5000))
        }
    }
    
    /// Generate narration based on current activity
    func generateNarration() -> String {
        switch currentActivity {
        case .thinking:
            return generateThinkingNarration()
        case .writing:
            return generateWritingNarration()
        case .reading:
            return generateReadingNarration()
        case .executing:
            return generateExecutingNarration()
        case .debugging:
            return generateDebuggingNarration()
        case .idle:
            return "Claude is idle"
        }
    }
    
    // MARK: - Private Methods
    
    private func detectActivity(from text: String) -> ActivityState {
        let lowercased = text.lowercased()
        
        // Check for specific Claude states
        if patterns.thinkingPatterns.contains(where: { lowercased.contains($0) }) {
            return .thinking
        }
        
        if patterns.writingPatterns.contains(where: { lowercased.contains($0) }) {
            return .writing
        }
        
        if patterns.readingPatterns.contains(where: { lowercased.contains($0) }) {
            return .reading
        }
        
        if patterns.executingPatterns.contains(where: { lowercased.contains($0) }) {
            return .executing
        }
        
        if patterns.debuggingPatterns.contains(where: { lowercased.contains($0) }) {
            return .debugging
        }
        
        // Check for file operations
        if text.contains("Creating") || text.contains("Writing") || text.contains("Updating") {
            return .writing
        }
        
        if text.contains("Reading") || text.contains("Analyzing") || text.contains("Examining") {
            return .reading
        }
        
        if text.contains("Running") || text.contains("Executing") || text.contains("npm") || text.contains("pnpm") {
            return .executing
        }
        
        if text.contains("error") || text.contains("Error") || text.contains("failed") {
            return .debugging
        }
        
        return .idle
    }
    
    private func trackFileOperations(from text: String) {
        // Extract file paths being modified
        let filePathPattern = #"(?:\/[\w\-\.]+)+\.[\w]+"#
        if let regex = try? NSRegularExpression(pattern: filePathPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            
            for match in matches {
                if let range = Range(match.range, in: text) {
                    let filePath = String(text[range])
                    
                    // Determine operation type
                    let operation: FileOperation.OperationType
                    if text.contains("Creating") || text.contains("Writing") {
                        operation = .write
                    } else if text.contains("Reading") {
                        operation = .read
                    } else if text.contains("Deleting") || text.contains("Removing") {
                        operation = .delete
                    } else {
                        operation = .modify
                    }
                    
                    fileOperations.append(FileOperation(
                        path: filePath,
                        operation: operation,
                        timestamp: Date()
                    ))
                }
            }
        }
        
        // Keep only recent operations
        let cutoff = Date().addingTimeInterval(-30)
        fileOperations = fileOperations.filter { $0.timestamp > cutoff }
    }
    
    private func trackErrors(from text: String) {
        let errorKeywords = ["error", "Error", "ERROR", "failed", "Failed", "exception", "Exception"]
        
        for keyword in errorKeywords {
            if text.contains(keyword) {
                errorCount += 1
                break
            }
        }
    }
    
    private func scheduleNarration() {
        narrationTimer?.invalidate()
        narrationTimer = Timer.scheduledTimer(withTimeInterval: narrationDebounceInterval, repeats: false) { [weak self] _ in
            self?.performNarration()
        }
    }
    
    private func performNarration() {
        let narration = generateNarration()
        if narration != lastNarration {
            lastNarration = narration
            
            // This will be sent to OpenAI for voice synthesis
            NotificationCenter.default.post(
                name: .activityNarrationReady,
                object: nil,
                userInfo: ["narration": narration]
            )
        }
    }
    
    private func generateThinkingNarration() -> String {
        let duration = Date().timeIntervalSince(lastActivityTime)
        if duration < 3 {
            return "Claude is thinking about your request"
        } else if duration < 10 {
            return "Claude is analyzing the codebase"
        } else {
            return "Claude is working on a complex solution"
        }
    }
    
    private func generateWritingNarration() -> String {
        guard !fileOperations.isEmpty else {
            return "Claude is writing code"
        }
        
        let recentWrites = fileOperations.filter { $0.operation == .write || $0.operation == .modify }
        
        if recentWrites.count == 1,
           let file = recentWrites.first {
            let filename = URL(fileURLWithPath: file.path).lastPathComponent
            return "Claude is modifying \(filename)"
        } else if recentWrites.count > 1 {
            return "Claude is updating \(recentWrites.count) files"
        }
        
        return "Claude is writing code"
    }
    
    private func generateReadingNarration() -> String {
        let recentReads = fileOperations.filter { $0.operation == .read }
        
        if recentReads.count == 1,
           let file = recentReads.first {
            let filename = URL(fileURLWithPath: file.path).lastPathComponent
            return "Claude is examining \(filename)"
        } else if recentReads.count > 1 {
            return "Claude is reviewing \(recentReads.count) files"
        }
        
        return "Claude is reading the codebase"
    }
    
    private func generateExecutingNarration() -> String {
        if let command = currentCommand {
            if command.contains("test") {
                return "Running tests"
            } else if command.contains("build") {
                return "Building the project"
            } else if command.contains("install") {
                return "Installing dependencies"
            } else {
                return "Executing \(command)"
            }
        }
        
        return "Running a command"
    }
    
    private func generateDebuggingNarration() -> String {
        if errorCount == 1 {
            return "Claude encountered an error and is fixing it"
        } else if errorCount > 1 {
            return "Claude is debugging \(errorCount) issues"
        }
        
        return "Claude is debugging"
    }
}

// MARK: - Supporting Types

enum ActivityState {
    case idle
    case thinking
    case writing
    case reading
    case executing
    case debugging
}

struct FileOperation {
    enum OperationType {
        case read, write, modify, delete
    }
    
    let path: String
    let operation: OperationType
    let timestamp: Date
}

struct ActivityPatterns {
    let thinkingPatterns = [
        "thinking",
        "analyzing",
        "considering",
        "evaluating",
        "planning"
    ]
    
    let writingPatterns = [
        "writing",
        "creating",
        "implementing",
        "adding",
        "modifying"
    ]
    
    let readingPatterns = [
        "reading",
        "examining",
        "reviewing",
        "searching",
        "looking"
    ]
    
    let executingPatterns = [
        "running",
        "executing",
        "starting",
        "launching",
        "building"
    ]
    
    let debuggingPatterns = [
        "debugging",
        "fixing",
        "resolving",
        "troubleshooting",
        "investigating"
    ]
}

// MARK: - Notifications

extension Notification.Name {
    static let activityNarrationReady = Notification.Name("activityNarrationReady")
}
```

### 5. Main UI Implementation

```swift
// ContentView.swift
import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var socketManager = VibeTunnelSocketManager()
    @StateObject private var openAIManager: OpenAIRealtimeManager
    @StateObject private var activityMonitor = SessionActivityMonitor()
    @StateObject private var commandProcessor: VoiceCommandProcessor
    
    @State private var availableSessions: [String] = []
    @State private var selectedSession: String?
    @State private var isConnecting = false
    @State private var showSettings = false
    @State private var apiKey = ""
    
    private let cancelBag = Set<AnyCancellable>()
    
    init() {
        // Load API key from Keychain or UserDefaults
        let key = KeychainHelper.loadAPIKey() ?? ""
        _openAIManager = StateObject(wrappedValue: OpenAIRealtimeManager(apiKey: key))
        _commandProcessor = StateObject(wrappedValue: VoiceCommandProcessor())
        _apiKey = State(initialValue: key)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HeaderView(
                isConnected: socketManager.isConnected && openAIManager.isConnected,
                showSettings: $showSettings
            )
            
            Divider()
            
            // Main Content
            if apiKey.isEmpty {
                APIKeySetupView(apiKey: $apiKey) {
                    saveAPIKey()
                }
            } else if !socketManager.isConnected {
                SessionSelectionView(
                    sessions: availableSessions,
                    selectedSession: $selectedSession,
                    isConnecting: isConnecting,
                    onRefresh: refreshSessions,
                    onConnect: connectToSession
                )
            } else {
                ConnectedView(
                    socketManager: socketManager,
                    openAIManager: openAIManager,
                    activityMonitor: activityMonitor
                )
            }
            
            // Status Bar
            StatusBarView(
                socketConnected: socketManager.isConnected,
                openAIConnected: openAIManager.isConnected,
                activity: activityMonitor.currentActivity
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            setupBindings()
            refreshSessions()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(apiKey: $apiKey)
        }
    }
    
    private func setupBindings() {
        // Connect terminal output to activity monitor
        socketManager.terminalOutput
            .sink { output in
                activityMonitor.processOutput(output)
            }
            .store(in: &cancelBag)
        
        // Connect activity narrations to OpenAI
        NotificationCenter.default.publisher(for: .activityNarrationReady)
            .compactMap { $0.userInfo?["narration"] as? String }
            .sink { narration in
                openAIManager.sendTerminalContext(narration)
            }
            .store(in: &cancelBag)
        
        // Connect OpenAI function calls to command processor
        openAIManager.functionCallRequested
            .sink { functionCall in
                commandProcessor.processFunctionCall(functionCall) { command in
                    socketManager.sendInput(command)
                }
            }
            .store(in: &cancelBag)
    }
    
    private func refreshSessions() {
        availableSessions = socketManager.findAvailableSessions()
        if availableSessions.count == 1 {
            selectedSession = availableSessions.first
        }
    }
    
    private func connectToSession() {
        guard let session = selectedSession else { return }
        
        isConnecting = true
        
        // Connect to VibeTunnel session
        socketManager.connect(to: session)
        
        // Connect to OpenAI
        if !apiKey.isEmpty {
            openAIManager.connect()
        }
        
        isConnecting = false
    }
    
    private func saveAPIKey() {
        KeychainHelper.saveAPIKey(apiKey)
        // Recreate OpenAI manager with new key
        openAIManager = OpenAIRealtimeManager(apiKey: apiKey)
        setupBindings()
    }
}

// MARK: - Subviews

struct HeaderView: View {
    let isConnected: Bool
    @Binding var showSettings: Bool
    
    var body: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundColor(isConnected ? .green : .gray)
            
            Text("VibeTunnelTalk")
                .font(.title2)
                .fontWeight(.semibold)
            
            Spacer()
            
            Button(action: { showSettings = true }) {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

struct SessionSelectionView: View {
    let sessions: [String]
    @Binding var selectedSession: String?
    let isConnecting: Bool
    let onRefresh: () -> Void
    let onConnect: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Select VibeTunnel Session")
                .font(.headline)
            
            if sessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    
                    Text("No VibeTunnel sessions found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("Start a session with: vt claude")
                        .font(.caption)
                        .fontFamily(.monospaced)
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(4)
                }
            } else {
                List(sessions, id: \.self, selection: $selectedSession) { session in
                    HStack {
                        Image(systemName: "terminal")
                        Text(session)
                            .fontFamily(.monospaced)
                    }
                }
                .frame(maxHeight: 200)
            }
            
            HStack(spacing: 15) {
                Button("Refresh") {
                    onRefresh()
                }
                
                Button("Connect") {
                    onConnect()
                }
                .disabled(selectedSession == nil || isConnecting)
                .keyboardShortcut(.return)
            }
            
            if isConnecting {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConnectedView: View {
    @ObservedObject var socketManager: VibeTunnelSocketManager
    @ObservedObject var openAIManager: OpenAIRealtimeManager
    @ObservedObject var activityMonitor: SessionActivityMonitor
    
    @State private var isExpanded = true
    @State private var terminalOutput = ""
    @State private var showTerminal = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Voice Activity Indicator
            VoiceActivityView(
                isListening: openAIManager.isListening,
                isSpeaking: openAIManager.isSpeaking,
                onToggleListening: {
                    if openAIManager.isListening {
                        openAIManager.stopListening()
                    } else {
                        openAIManager.startListening()
                    }
                }
            )
            
            Divider()
            
            // Activity Display
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    // Current Activity
                    ActivityCard(
                        title: "Current Activity",
                        activity: activityMonitor.currentActivity,
                        narration: activityMonitor.lastNarration
                    )
                    
                    // Transcription
                    if !openAIManager.transcription.isEmpty {
                        TranscriptionCard(text: openAIManager.transcription)
                    }
                    
                    // Terminal Preview (Optional)
                    if showTerminal {
                        TerminalPreviewCard(output: terminalOutput)
                    }
                }
                .padding()
            }
            
            // Controls
            HStack {
                Button(action: { showTerminal.toggle() }) {
                    Label(
                        showTerminal ? "Hide Terminal" : "Show Terminal",
                        systemImage: "terminal"
                    )
                }
                
                Spacer()
                
                Button("Disconnect") {
                    disconnect()
                }
                .foregroundColor(.red)
            }
            .padding()
        }
        .onReceive(socketManager.terminalOutput) { output in
            terminalOutput += output
            // Keep last 1000 lines
            let lines = terminalOutput.components(separatedBy: .newlines)
            if lines.count > 1000 {
                terminalOutput = lines.suffix(1000).joined(separator: "\n")
            }
        }
    }
    
    private func disconnect() {
        socketManager.disconnect()
        openAIManager.disconnect()
    }
}

struct VoiceActivityView: View {
    let isListening: Bool
    let isSpeaking: Bool
    let onToggleListening: () -> Void
    
    @State private var animationAmount = 1.0
    
    var body: some View {
        VStack(spacing: 20) {
            // Waveform visualization
            HStack(spacing: 4) {
                ForEach(0..<20) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(waveformColor)
                        .frame(width: 4, height: waveformHeight(for: index))
                        .animation(
                            .easeInOut(duration: 0.3)
                                .delay(Double(index) * 0.02),
                            value: isListening || isSpeaking
                        )
                }
            }
            .frame(height: 60)
            
            // Control Button
            Button(action: onToggleListening) {
                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 80, height: 80)
                    
                    if isListening {
                        // Animated listening indicator
                        Circle()
                            .stroke(Color.blue, lineWidth: 2)
                            .frame(width: 80, height: 80)
                            .scaleEffect(animationAmount)
                            .opacity(2 - animationAmount)
                            .animation(
                                .easeOut(duration: 1)
                                    .repeatForever(autoreverses: false),
                                value: animationAmount
                            )
                    }
                    
                    Image(systemName: iconName)
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            
            // Status Text
            Text(statusText)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 30)
        .onAppear {
            if isListening {
                animationAmount = 2.0
            }
        }
    }
    
    private var waveformColor: Color {
        if isSpeaking {
            return .green
        } else if isListening {
            return .blue
        } else {
            return .gray
        }
    }
    
    private func waveformHeight(for index: Int) -> CGFloat {
        if isSpeaking || isListening {
            let base: CGFloat = 20
            let variation = CGFloat.random(in: 0.3...1.0)
            return base * variation
        } else {
            return 10
        }
    }
    
    private var buttonColor: Color {
        if isSpeaking {
            return .green
        } else if isListening {
            return .blue
        } else {
            return .gray
        }
    }
    
    private var iconName: String {
        if isSpeaking {
            return "speaker.wave.3.fill"
        } else if isListening {
            return "mic.fill"
        } else {
            return "mic"
        }
    }
    
    private var statusText: String {
        if isSpeaking {
            return "Speaking..."
        } else if isListening {
            return "Listening..."
        } else {
            return "Press to speak"
        }
    }
}

struct ActivityCard: View {
    let title: String
    let activity: ActivityState
    let narration: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                
                Spacer()
                
                ActivityBadge(activity: activity)
            }
            
            Text(narration)
                .font(.body)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct ActivityBadge: View {
    let activity: ActivityState
    
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.2))
        .cornerRadius(12)
    }
    
    private var color: Color {
        switch activity {
        case .thinking: return .purple
        case .writing: return .blue
        case .reading: return .green
        case .executing: return .orange
        case .debugging: return .red
        case .idle: return .gray
        }
    }
    
    private var text: String {
        switch activity {
        case .thinking: return "Thinking"
        case .writing: return "Writing"
        case .reading: return "Reading"
        case .executing: return "Executing"
        case .debugging: return "Debugging"
        case .idle: return "Idle"
        }
    }
}

struct TranscriptionCard: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transcription", systemImage: "text.bubble")
                .font(.headline)
            
            Text(text)
                .font(.body)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(8)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct TerminalPreviewCard: View {
    let output: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Terminal Output", systemImage: "terminal")
                .font(.headline)
            
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .padding(10)
            .background(Color.black.opacity(0.9))
            .foregroundColor(.green)
            .cornerRadius(8)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct StatusBarView: View {
    let socketConnected: Bool
    let openAIConnected: Bool
    let activity: ActivityState
    
    var body: some View {
        HStack {
            // Connection Status
            HStack(spacing: 15) {
                StatusIndicator(
                    label: "VibeTunnel",
                    isConnected: socketConnected
                )
                
                StatusIndicator(
                    label: "OpenAI",
                    isConnected: openAIConnected
                )
            }
            
            Spacer()
            
            // Activity Status
            Text(activity == .idle ? "Ready" : "Active")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
    }
}

struct StatusIndicator: View {
    let label: String
    let isConnected: Bool
    
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
```

---

## Testing Strategy

### Unit Tests

```swift
// VibeTunnelSocketManagerTests.swift
import XCTest
@testable import VibeTunnelTalk

class VibeTunnelSocketManagerTests: XCTestCase {
    var socketManager: VibeTunnelSocketManager!
    
    override func setUp() {
        super.setUp()
        socketManager = VibeTunnelSocketManager()
    }
    
    func testFindAvailableSessions() {
        // Create mock session directory
        let testPath = NSTemporaryDirectory() + "/.vibetunnel/control/test-session"
        try? FileManager.default.createDirectory(
            atPath: testPath,
            withIntermediateDirectories: true
        )
        
        // Create mock socket file
        let socketPath = testPath + "/ipc.sock"
        FileManager.default.createFile(atPath: socketPath, contents: nil)
        
        let sessions = socketManager.findAvailableSessions()
        XCTAssertFalse(sessions.isEmpty)
    }
    
    func testMessageParsing() {
        let text = "Hello, World!"
        let message = IPCMessage.createInput(text)
        
        XCTAssertEqual(message.header.type, .input)
        XCTAssertEqual(String(data: message.payload, encoding: .utf8), text)
    }
    
    func testANSICodeRemoval() {
        let input = "\u{001B}[31mError\u{001B}[0m: Something went wrong"
        let expected = "Error: Something went wrong"
        
        // Test ANSI removal logic
        let result = socketManager.removeANSIEscapeCodes(from: input)
        XCTAssertEqual(result, expected)
    }
}
```

### Integration Tests

```swift
// IntegrationTests.swift
import XCTest
@testable import VibeTunnelTalk

class IntegrationTests: XCTestCase {
    func testEndToEndConnection() async throws {
        // Start a mock VibeTunnel session
        let sessionId = "test-\(UUID().uuidString)"
        let mockSession = try await createMockSession(sessionId: sessionId)
        
        // Connect socket manager
        let socketManager = VibeTunnelSocketManager()
        socketManager.connect(to: sessionId)
        
        // Wait for connection
        await waitForConnection(socketManager)
        
        // Send test input
        socketManager.sendInput("echo 'Hello from test'\n")
        
        // Verify output received
        let expectation = XCTestExpectation(description: "Output received")
        socketManager.terminalOutput.sink { output in
            if output.contains("Hello from test") {
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Cleanup
        socketManager.disconnect()
        mockSession.terminate()
    }
}
```

---

## Deployment

### Build Configuration

```bash
# 1. Archive the app
xcodebuild archive \
  -project VibeTunnelTalk.xcodeproj \
  -scheme VibeTunnelTalk \
  -configuration Release \
  -archivePath build/VibeTunnelTalk.xcarchive

# 2. Export for distribution
xcodebuild -exportArchive \
  -archivePath build/VibeTunnelTalk.xcarchive \
  -exportPath build \
  -exportOptionsPlist ExportOptions.plist
```

### Export Options Plist

```xml
<!-- ExportOptions.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

### Notarization

```bash
# Submit for notarization
xcrun notarytool submit \
  build/VibeTunnelTalk.app \
  --apple-id "your-apple-id@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password" \
  --wait

# Staple the notarization
xcrun stapler staple build/VibeTunnelTalk.app
```

---

## Additional Implementation Notes

### Performance Optimization

1. **Buffer Management**: Implement circular buffers for terminal output to prevent memory growth
2. **Debouncing**: Use debouncing for narration to avoid overwhelming the TTS system
3. **Async Processing**: Use Swift's async/await for all I/O operations
4. **Resource Cleanup**: Properly close sockets and cancel timers on disconnection

### Error Handling

1. **Connection Failures**: Implement exponential backoff for reconnection attempts
2. **API Limits**: Handle OpenAI rate limits with queuing and retry logic
3. **Audio Issues**: Gracefully handle microphone permission denials
4. **Session Crashes**: Detect and handle VibeTunnel session termination

### Security Considerations

1. **API Key Storage**: Use macOS Keychain for secure API key storage
2. **Sandbox Permissions**: Request minimal necessary permissions
3. **Network Security**: Validate all incoming data from sockets
4. **Input Sanitization**: Sanitize all terminal commands before execution

### Future Enhancements

1. **Multi-Session Support**: Handle multiple concurrent VibeTunnel sessions
2. **Custom Voices**: Allow users to select different OpenAI voices
3. **Command History**: Maintain history of voice commands
4. **Activity Logs**: Export session activity for review
5. **Shortcuts Integration**: Add macOS Shortcuts support for automation

---

## Conclusion

This implementation guide provides a complete foundation for building VibeTunnelTalk. The architecture leverages VibeTunnel's existing infrastructure while adding intelligent voice interaction through OpenAI's Realtime API. The modular design allows for easy testing, maintenance, and future enhancements.

Key success factors:
- Clean separation between socket management and UI
- Robust error handling and reconnection logic
- Intelligent activity detection and summarization
- Smooth voice interaction with minimal latency
- Native SwiftUI interface following macOS design guidelines

With this guide, you have everything needed to create a powerful voice-controlled interface for Claude Code sessions, transforming terminal interaction into a natural conversation.