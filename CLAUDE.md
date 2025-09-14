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

The application follows a modular architecture with clear separation of concerns.

### Data Flow Architecture

**Important**: For a comprehensive understanding of how data flows through the application, refer to `docs/Data_Flow_Architecture.md`. This document explains:
- How VibeTunnelTalk connects to and monitors Claude Code sessions
- The virtual terminal buffer system that mirrors Claude's terminal state
- The intelligent change detection and filtering pipeline
- The bidirectional voice communication flow
- The complete data flow from terminal output to voice narration and back

### Core Components

1. **VibeTunnelSocketManager**: Manages Unix domain socket connections to VibeTunnel sessions
   - Implements the VibeTunnel IPC protocol for message framing
   - Handles terminal input/output via socket communication
   - Located at: `VibeTunnelTalk/Managers/VibeTunnelSocketManager.swift`

2. **OpenAIRealtimeManager**: Manages WebSocket connection to OpenAI's Realtime API
   - Handles audio streaming in PCM16 format
   - Manages voice activity detection and TTS output
   - Located at: `VibeTunnelTalk/Managers/OpenAIRealtimeManager.swift`

3. **SessionActivityMonitor**: Analyzes terminal output for intelligent narration
   - Detects Claude activity states (thinking, writing, debugging, etc.)
   - Generates contextual summaries for voice narration
   - Located at: `VibeTunnelTalk/Managers/SessionActivityMonitor.swift`

4. **VoiceCommandProcessor**: Processes voice commands into terminal actions
   - Maps voice intents to terminal commands
   - Located at: `VibeTunnelTalk/Managers/VoiceCommandProcessor.swift`

### VibeTunnel Integration

**VibeTunnel Source Code Location**: `~/Developer/vibetunnel`

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

#### 2. SSE Stream (Terminal Output)
- Endpoint: `http://localhost:4020/api/sessions/{session-id}/stream`
- Protocol: Server-Sent Events (SSE)
- Receives real-time terminal output from VibeTunnel

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
   - Network client access (OpenAI API)
   - Audio input (microphone)
   - File access to `~/.vibetunnel/` directory

2. **API Key Management**: OpenAI API keys should be stored securely in macOS Keychain

3. **Audio Format**: OpenAI Realtime API expects 24kHz PCM16 mono audio

4. **Activity Detection**: The app uses pattern matching to detect Claude's activities and generate appropriate narrations

5. **Error Handling**: Implement reconnection logic for both socket and WebSocket connections

## Reference Implementation

**OpenAI WebSocket Reference**: When troubleshooting WebSocket communication with OpenAI's Realtime API, refer to the reference implementation at `~/Developer/swift-realtime-openai`. This codebase provides:
- Proper WebSocket connection handling
- Event serialization/deserialization patterns
- Error handling best practices
- Connection state management without unnecessary heartbeats