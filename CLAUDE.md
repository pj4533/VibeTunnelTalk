# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VibeTunnelTalk is a native macOS application built with SwiftUI that provides real-time voice narration and control for Claude Code sessions running through VibeTunnel. The app connects to VibeTunnel's IPC socket infrastructure to monitor terminal output and uses OpenAI's Realtime API for bidirectional voice interaction.

## Build and Development Commands

### Building
```bash
# Build the project
xcodebuild -project VibeTunnelTalk.xcodeproj -scheme VibeTunnelTalk -configuration Debug build

# Build for release
xcodebuild -project VibeTunnelTalk.xcodeproj -scheme VibeTunnelTalk -configuration Release build

# Clean build
xcodebuild -project VibeTunnelTalk.xcodeproj -scheme VibeTunnelTalk clean
```

### Testing
```bash
# Run unit tests
xcodebuild test -project VibeTunnelTalk.xcodeproj -scheme VibeTunnelTalk -destination 'platform=macOS'

# Run specific test class
xcodebuild test -project VibeTunnelTalk.xcodeproj -scheme VibeTunnelTalk -only-testing:VibeTunnelTalkTests/VibeTunnelSocketManagerTests
```

### Running
```bash
# Open in Xcode
open VibeTunnelTalk.xcodeproj

# Run from command line (after building)
./build/Debug/VibeTunnelTalk.app/Contents/MacOS/VibeTunnelTalk
```

## Architecture

The application uses a real-time WebSocket-based architecture that leverages VibeTunnel's server-side terminal processing capabilities.

### Data Flow Architecture

**Important**: For a comprehensive understanding of how data flows through the application, refer to `docs/Data_Flow_Architecture.md`. This document explains:
- How VibeTunnelTalk receives real-time terminal buffer updates via WebSocket
- The binary protocol with magic byte validation and efficient data transfer
- The intelligent accumulation and change detection pipeline
- The bidirectional voice communication flow
- The complete data flow from buffer streaming to voice narration and back

### Core Components

1. **VibeTunnelSocketManager**: Manages Unix domain socket connections to VibeTunnel sessions
   - Implements the VibeTunnel IPC protocol for sending commands
   - Coordinates the WebSocket client lifecycle
   - Located at: `VibeTunnelTalk/Managers/VibeTunnelSocketManager.swift`

2. **BufferWebSocketClient**: Real-time WebSocket connection for terminal buffer streaming
   - Establishes WebSocket connection to VibeTunnel's `/buffers` endpoint at `ws://localhost:4020/buffers`
   - Receives binary buffer updates in real-time with magic byte validation (0xBF for frames, 0x5654 for buffers)
   - Implements JWT authentication via both query parameter AND Authorization header (matching iOS implementation)
   - Automatic reconnection with exponential backoff
   - Session subscription management via JSON messages
   - Ping-based connection health monitoring (30-second intervals)
   - Located at: `VibeTunnelTalk/Services/WebSocket/BufferWebSocketClient.swift`

3. **SmartTerminalProcessor**: Processes buffer snapshots for intelligent narration
   - Subscribes to WebSocket buffer updates via BufferWebSocketClient
   - Uses BufferAccumulator for intelligent batching (100 char size / 2 sec time thresholds)
   - Extracts plain text from buffer cell grid
   - Manages communication with OpenAI
   - Located at: `VibeTunnelTalk/Managers/SmartTerminalProcessor.swift`

4. **OpenAIRealtimeManager**: Manages WebSocket connection to OpenAI's Realtime API
   - Handles audio streaming in PCM16 format
   - Manages voice activity detection and TTS output
   - Located at: `VibeTunnelTalk/Managers/OpenAIRealtimeManager.swift`

5. **VoiceCommandProcessor**: Processes voice commands into terminal actions
   - Maps voice intents to terminal commands
   - Located at: `VibeTunnelTalk/Managers/VoiceCommandProcessor.swift`

### VibeTunnel Integration

**IMPORTANT**: For all information about VibeTunnel architecture, authentication, and integration details, refer to `docs/vibetunnel_architecture.md`. This is where you should look for all information about VibeTunnel. Anything you can't find in this architecture document, you can find in the actual VibeTunnel code.

**VibeTunnel Source Code Locations**:
- Web/Server: `~/Developer/vibetunnel`
- iOS/Swift: `~/Developer/vibetunnel/ios` (Contains Swift implementations for terminal buffer handling, models, and rendering)

**IMPORTANT**: When troubleshooting VibeTunnel integration issues, ALWAYS check the iOS implementation at `~/Developer/vibetunnel/ios` as it provides working Swift code that maps directly to our macOS implementations. Key files to reference:
- `BufferWebSocketClient.swift` - WebSocket client implementation
- `WebSocketProtocol.swift` - WebSocket connection patterns
- Terminal buffer decoding and handling patterns

**WebSocket Implementation**: Our macOS WebSocket implementation (`BufferWebSocketClient`, `WebSocketProtocol`, etc.) is an EXACT copy of the iOS VibeTunnel implementation. We match it precisely, including:
- Using both query parameter AND Authorization header for authentication (iOS does both)
- WebSocket abstraction layer with protocols and factory pattern
- Ping-based connection verification
- Binary buffer decoding logic
Always refer to the iOS implementation as the source of truth and match it exactly.

The app communicates with VibeTunnel sessions using two mechanisms:

#### 1. IPC Socket (Control Commands)
- Socket path: `~/.vibetunnel/control/{session-id}/ipc.sock`
- Message format: 5-byte header (1 byte type + 4 bytes length) + payload
- Message types:
  - STDIN_DATA (0x01): Send keyboard input to terminal
  - CONTROL_CMD (0x02): Control commands (resize, kill, etc)
  - STATUS_UPDATE (0x03): Status updates (Claude activity, etc)
  - HEARTBEAT (0x04): Keep-alive ping/pong
  - ERROR (0x05): Error messages

#### 2. WebSocket Stream (Terminal State)
- Endpoint: `ws://localhost:4020/buffers`
- Protocol: WebSocket with binary frame streaming
- Authentication: JWT token in query parameter and Authorization header
- Subscription: JSON messages to subscribe/unsubscribe from sessions
- Response: Real-time binary buffer updates with cell-level detail
- Format: Binary protocol with magic bytes (0xBF for frames, 0x5654 for buffers)

### Key Dependencies

- SwiftUI for the native macOS interface
- Network framework for Unix domain socket connections
- AVFoundation for audio capture and playback
- URLSession for WebSocket communication with OpenAI

## Implementation Guide

A comprehensive implementation guide is available in `docs/VibeTunnelTalk_Implementation_Guide.md` which includes:
- Detailed component implementations
- IPC protocol specifications
- OpenAI Realtime API integration
- UI component examples
- Testing strategies

## Key Implementation Notes

1. **Entitlements**: The app requires specific sandbox permissions for:
   - Network client access (OpenAI API and VibeTunnel buffer API)
   - Audio input (microphone)
   - File access to `~/.vibetunnel/` directory

2. **API Key Management**: OpenAI API keys should be stored securely in macOS Keychain

3. **Audio Format**: OpenAI Realtime API expects 24kHz PCM16 mono audio

4. **Real-time Updates**: The app uses WebSocket for real-time terminal buffer updates with intelligent accumulation

5. **No ANSI Parsing**: VibeTunnel handles all terminal emulation and ANSI escape sequence parsing server-side

6. **Error Handling**: Implement reconnection logic for IPC socket and WebSocket connections (automatic exponential backoff included)

## Reference Implementation

**OpenAI WebSocket Reference**: When troubleshooting WebSocket communication with OpenAI's Realtime API, refer to the reference implementation at `~/Developer/swift-realtime-openai`. This codebase provides:
- Proper WebSocket connection handling
- Event serialization/deserialization patterns
- Error handling best practices
- Connection state management without unnecessary heartbeats