# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VibeTunnelTalk is a native macOS application built with SwiftUI that provides real-time voice narration for Claude Code sessions running through VibeTunnel. The app reads terminal output from asciinema files created by VibeTunnel and uses OpenAI's Realtime API for voice narration (no command execution).

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

The application uses a file-based architecture that reads complete terminal output from asciinema files, ensuring 100% data capture without any loss from debouncing.

### Data Flow Architecture

**Important**: For a comprehensive understanding of how data flows through the application, refer to `docs/Data_Flow_Architecture.md`. This document explains:
- How VibeTunnelTalk reads terminal output from asciinema files
- The asciinema v2 format (JSONL) parsing
- The intelligent accumulation pipeline with StreamingAccumulator
- The voice narration flow through OpenAI
- Why file-based is superior to WebSocket streaming

### Core Components

1. **VibeTunnelSocketManager**: Manages Unix domain socket connections to VibeTunnel sessions
   - Implements the VibeTunnel IPC protocol for sending commands
   - Coordinates the asciinema file reader lifecycle
   - Located at: `VibeTunnelTalk/Managers/VibeTunnelSocketManager.swift`

2. **AsciinemaFileReader**: Reads terminal output from asciinema files
   - Monitors asciinema files at `~/.vibetunnel/control/{sessionId}/stdout`
   - Parses asciinema v2 format (JSONL)
   - Provides 100% complete terminal output capture
   - No data loss from debouncing or network issues
   - Located at: `VibeTunnelTalk/Services/AsciinemaFileReader.swift`

3. **SmartTerminalProcessor**: Processes terminal output for intelligent narration
   - Reads terminal output from AsciinemaFileReader
   - Uses StreamingAccumulator for batching (100 char size / 1 sec time thresholds)
   - Simpler than WebSocket approach - no change detection needed
   - Manages communication with OpenAI
   - Located at: `VibeTunnelTalk/Managers/SmartTerminalProcessor.swift`

4. **OpenAIRealtimeManager**: Manages WebSocket connection to OpenAI's Realtime API
   - Handles audio streaming in PCM16 format
   - Manages voice activity detection and TTS output
   - Implements drop-and-replace audio queueing:
     - Only one audio response plays at a time
     - New responses replace queued ones while audio is playing
     - Latest update plays immediately after current audio finishes
     - Prevents overlapping speech and ensures current information
   - Uses AVAudioPlayerDelegate for playback completion tracking
   - Located at: `VibeTunnelTalk/Managers/OpenAIRealtimeManager.swift`

### VibeTunnel Integration

**IMPORTANT**: For all information about VibeTunnel architecture, authentication, and integration details, refer to `docs/vibetunnel_architecture.md`. This is where you should look for all information about VibeTunnel. Anything you can't find in this architecture document, you can find in the actual VibeTunnel code.

**VibeTunnel Source Code Locations**:
- Web/Server: `~/Developer/vibetunnel`
- iOS/Swift: `~/Developer/vibetunnel/ios` (Contains Swift implementations for terminal buffer handling, models, and rendering)

**IMPORTANT**: When troubleshooting VibeTunnel integration issues, ALWAYS check the iOS implementation at `~/Developer/vibetunnel/ios` as it provides working Swift code that maps directly to our macOS implementations.

**File-Based Architecture**: VibeTunnelTalk uses asciinema files for terminal data:
- Asciinema files provide 100% complete terminal output
- No data loss from 50ms debouncing that would occur with WebSocket updates
- Simpler implementation without binary protocol decoding
- More reliable than network-based streaming
- No WebSocket connections needed at all

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

#### 2. Asciinema Files (Terminal State)
- Location: `~/.vibetunnel/control/{sessionId}/stdout`
- Format: Asciinema v2 (JSONL - JSON Lines)
- Content: Complete terminal output without debouncing
- Updates: File monitoring detects new content in real-time
- Reliability: 100% data capture from local filesystem

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

4. **Real-time Updates**: The app uses file monitoring for real-time terminal updates with intelligent accumulation

5. **No WebSocket Buffers**: Terminal data comes from asciinema files, not WebSocket streaming

6. **Error Handling**: IPC socket reconnection with automatic retry

7. **Audio Playback Management**: The system uses a drop-and-replace strategy for audio responses:
   - Prevents audio overlap by playing only one response at a time
   - Drops intermediate responses in favor of the latest update
   - Ensures users always hear the most current terminal state
   - **Future Improvements**: Plan to implement intelligent queue management with response summarization, priority-based playback, and user-configurable behavior

## Reference Implementation

**OpenAI WebSocket Reference**: When troubleshooting WebSocket communication with OpenAI's Realtime API, refer to the reference implementation at `~/Developer/swift-realtime-openai`. This codebase provides:
- Proper WebSocket connection handling
- Event serialization/deserialization patterns
- Error handling best practices
- Connection state management without unnecessary heartbeats