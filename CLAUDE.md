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

The application follows a modular architecture with clear separation of concerns:

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

### VibeTunnel IPC Protocol

The app communicates with VibeTunnel sessions using a binary protocol:
- Socket path: `~/.vibetunnel/control/{session-id}/ipc.sock`
- Message format: 8-byte header + payload
- Message types: input (0x01), data (0x02), resize (0x03), etc.

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