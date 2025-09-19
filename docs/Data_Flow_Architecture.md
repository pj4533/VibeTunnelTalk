# VibeTunnelTalk Data Flow Architecture

## Overview

VibeTunnelTalk creates a voice interface for Claude Code sessions by monitoring terminal output and enabling voice narration. The application uses a file-based architecture that reads complete terminal output from asciinema files created by VibeTunnel, providing 100% reliable data capture without any loss from debouncing or network issues.

## Architecture Components

### 1. Terminal Data Sources

VibeTunnelTalk uses two primary data sources:

#### Asciinema Files (Primary Data Source)
- **Path**: `~/.vibetunnel/control/{session-id}/stdout`
- **Format**: Asciinema v2 (JSONL - JSON Lines)
- **Purpose**: Complete terminal output capture
- **Benefits**: 100% data capture, no debouncing losses
- **Direction**: VibeTunnel → File → VibeTunnelTalk

#### IPC Socket (Control Channel)
- **Path**: `~/.vibetunnel/control/{session-id}/ipc.sock`
- **Purpose**: Sends keyboard input and control commands to the terminal
- **Protocol**: Binary message format with 5-byte header
- **Direction**: VibeTunnelTalk → VibeTunnel

### 2. Asciinema File Format

The asciinema v2 format provides complete terminal capture:

```json
// Line 1: Header
{"version": 2, "width": 80, "height": 24, "timestamp": 1234567890}

// Lines 2+: Events (as arrays)
[0.123, "o", "Hello World\n"]      // Output event
[0.456, "o", "$ ls -la\n"]         // More output
[1.234, "r", "80x40"]              // Resize event
```

Event types:
- `"o"`: Terminal output
- `"i"`: User input
- `"r"`: Terminal resize
- `"m"`: Marker/annotation

## Data Flow Sequence

### 1. Session Connection
1. User selects a VibeTunnel session
2. `VibeTunnelSocketManager` connects to IPC socket
3. `AsciinemaFileReader` starts monitoring the stdout file
4. `SmartTerminalProcessor` initializes with `StreamingAccumulator`

### 2. Terminal Output Processing

```
VibeTunnel Terminal → Asciinema File → AsciinemaFileReader
                                           ↓
                                   StreamingAccumulator
                                           ↓
                                   SmartTerminalProcessor
                                           ↓
                                    OpenAIRealtimeManager
```

#### AsciinemaFileReader
- Monitors file for new content
- Parses JSONL events
- Extracts terminal output
- Sends to accumulator

#### StreamingAccumulator
- Batches output intelligently
- Size threshold: 100 characters
- Time threshold: 1 second
- Simpler than WebSocket accumulator (no change detection needed)

#### SmartTerminalProcessor
- Cleans terminal output
- Formats for OpenAI
- Manages debug logging
- Tracks statistics

### 3. Voice Narration

The `OpenAIRealtimeManager` receives processed terminal content and:
1. Converts text to contextual narration
2. Streams audio responses
3. Implements drop-and-replace audio queueing
4. Manages voice activity detection

### 4. User Input

Voice commands are disabled - VibeTunnelTalk is purely a narrator:
- No function calling capabilities
- No command execution
- Only provides voice narration of terminal activity

## Key Components

### AsciinemaFileReader (`Services/AsciinemaFileReader.swift`)
- Monitors asciinema files for new content
- Parses v2 format (JSONL)
- Extracts terminal output events
- Provides real-time updates

### StreamingAccumulator (`Managers/StreamingAccumulator.swift`)
- Simpler than BufferAccumulator
- Optimized for complete data streams
- No complex change detection needed
- Faster 1-second time threshold

### SmartTerminalProcessor (`Managers/SmartTerminalProcessor.swift`)
- Processes terminal output from files
- Manages accumulation and batching
- Formats content for OpenAI
- Handles debug logging

### VibeTunnelSocketManager (`Managers/VibeTunnelSocketManager.swift`)
- Manages IPC socket connection
- Coordinates file reader lifecycle
- Handles session discovery
- Sends terminal input commands

## Advantages of File-Based Architecture

1. **100% Data Capture**: No loss from WebSocket debouncing
2. **Local Reliability**: No network issues or disconnections
3. **Simple Implementation**: No complex binary protocol
4. **Complete History**: Full session replay capability
5. **Faster Response**: 1-second vs 2-second accumulation

## Future Improvements

1. **Enhanced Processing**:
   - Command boundary detection
   - ANSI escape sequence parsing
   - Semantic content extraction

3. **Multi-Session Support**:
   - Monitor multiple sessions simultaneously
   - Cross-session context awareness
   - Unified narration

## Performance Characteristics

- **Data Completeness**: 100% capture rate
- **Latency**: Near-instant file reading
- **Reliability**: Local filesystem reliability
- **Memory**: Minimal overhead
- **Scalability**: Limited only by filesystem