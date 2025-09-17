# VibeTunnelTalk Data Flow Architecture

## Overview

VibeTunnelTalk creates a voice interface for Claude Code sessions by monitoring terminal output and enabling voice control. The application uses a simplified polling-based architecture that leverages VibeTunnel's server-side terminal processing capabilities.

## Architecture Components

### 1. Terminal Buffer Streaming

VibeTunnelTalk connects to VibeTunnel sessions through two primary mechanisms:

#### IPC Socket (Control Channel)
- **Path**: `~/.vibetunnel/control/{session-id}/ipc.sock`
- **Purpose**: Sends keyboard input and control commands to the terminal
- **Protocol**: Binary message format with 5-byte header
- **Direction**: VibeTunnelTalk → VibeTunnel

#### WebSocket Stream (Data Channel)
- **Endpoint**: `ws://localhost:4020/buffers`
- **Purpose**: Receives real-time terminal buffer updates as binary data
- **Protocol**: WebSocket with binary frame streaming
- **Connection**: Persistent connection with automatic reconnection
- **Direction**: VibeTunnel → VibeTunnelTalk

The WebSocket implementation includes:
- JWT authentication via both query parameter and Authorization header
- Binary buffer format with magic bytes (0xBF for frames, 0x5654 for buffers)
- Automatic reconnection with exponential backoff
- Session subscription management via JSON messages
- Ping-based connection health monitoring

### 2. Buffer Snapshot Structure

VibeTunnel provides a complete terminal snapshot that includes:

```swift
struct BufferSnapshot {
    let cols: Int           // Terminal width in columns
    let rows: Int           // Terminal height in rows
    let viewportY: Int      // Current scroll position
    let cursorX: Int        // Cursor X position
    let cursorY: Int        // Cursor Y position
    let cells: [[BufferCell]] // 2D grid of terminal cells
}

struct BufferCell {
    let char: String        // The actual character
    let width: Int          // Character width (1 or 2 for wide chars)
    let fg: Int?           // Foreground color (ANSI palette index)
    let bg: Int?           // Background color (ANSI palette index)
    let attributes: Int?    // Text attributes (bold, italic, etc.)
}
```

This snapshot represents the **exact text content** displayed in Claude's terminal, with all formatting preserved. VibeTunnel handles all the complex ANSI escape sequence parsing, terminal emulation, and buffer management on the server side.

### 3. Smart Terminal Processing

The Smart Terminal Processor is the brain of the narration system, converting raw buffer snapshots into intelligent voice narration.

#### Processing Pipeline

1. **Buffer Reception**
   - `BufferWebSocketClient` maintains persistent WebSocket connection
   - Receives real-time binary buffer updates as they occur
   - Decodes binary format to `BufferSnapshot` structures
   - No need for ANSI parsing or terminal emulation

2. **Text Extraction**
   - Processor extracts plain text from the 2D cell grid
   - Preserves logical structure (lines, indentation)
   - Trims unnecessary whitespace while maintaining formatting

3. **Intelligent Accumulation**
   - Uses `BufferAccumulator` with configurable thresholds
   - Size threshold: Sends when 100+ characters have changed
   - Time threshold: Sends after 2 seconds of inactivity
   - Prevents overwhelming the voice interface with rapid changes

4. **Change Detection & Filtering**
   - Compares accumulated content with previously sent content
   - Calculates character-level differences
   - Skips updates when OpenAI is currently speaking
   - Queues changes during speech for later processing

#### Data Reduction
The processor achieves significant data reduction:
- Only sends meaningful changes, not every buffer update
- Filters out UI chrome and redundant updates
- Typically achieves 80-90% reduction in data sent to OpenAI

### 4. Voice Narration Pipeline

Once significant changes are detected, they flow through the voice narration system.

#### OpenAI Integration
The processed terminal updates are sent to OpenAI's Realtime API:

1. **Context Formatting**: Terminal content is wrapped with context markers
2. **Intelligent Analysis**: OpenAI analyzes what Claude is doing
3. **Narrative Generation**: Creates appropriate voice narration
4. **Speech Synthesis**: Converts narration to natural speech

#### Narration Characteristics
- **Activity Awareness**: Recognizes when Claude is thinking, coding, debugging
- **Contextual Relevance**: Focuses on important changes, ignores noise
- **Natural Pacing**: Narrates at appropriate moments without interrupting
- **Concise Summaries**: Provides useful information without overwhelming detail

### 5. Voice Command Processing

The reverse flow enables voice control of Claude through natural speech.

#### Audio Pipeline
1. **Capture**: Mac's microphone captures voice at 24kHz PCM16 mono
2. **Streaming**: Audio streams continuously to OpenAI while speaking
3. **Recognition**: OpenAI converts speech to text in real-time
4. **Intent Analysis**: Determines what action the user wants

#### Command Execution
1. **Command Generation**: OpenAI creates appropriate terminal commands
2. **IPC Transmission**: Commands sent through Unix domain socket
3. **Terminal Injection**: VibeTunnel injects input into Claude's terminal
4. **Response Monitoring**: Buffer updates show command results

### 6. System Synchronization

The real-time architecture maintains synchronization through:

#### WebSocket Streaming
- Real-time buffer updates as they occur
- Binary protocol for efficient data transfer
- Complete buffer snapshots ensure state consistency
- Cursor position and viewport tracked for context

#### Connection Management
- IPC socket for reliable command delivery
- WebSocket with automatic reconnection and exponential backoff
- Session re-subscription after reconnection
- Graceful handling of connection loss

#### Response Coordination
- Updates queue while OpenAI is speaking
- Accumulated changes sent after speech completes
- Maintains conversational flow without interruption

## Data Flow Summary

The complete data flow creates a continuous feedback loop:

1. **Terminal State** → VibeTunnel maintains complete terminal buffer
2. **Buffer Streaming** → WebSocket delivers real-time buffer updates
3. **Binary Decoding** → BufferWebSocketClient decodes binary frames to snapshots
4. **Intelligent Accumulation** → BufferAccumulator batches changes based on size/time
5. **Text Extraction** → Smart processor extracts plain text from cell grid
6. **Voice Narration** → OpenAI generates and speaks contextual narration
7. **Voice Commands** → User speech interpreted by OpenAI
8. **Command Execution** → Commands sent via IPC socket to terminal
9. **Terminal Update** → Claude responds, triggering new buffer updates
10. **Cycle Continues** → WebSocket immediately streams the changes

## Key Architecture Benefits

### Simplicity
- No complex ANSI parsing or terminal emulation needed
- VibeTunnel handles all terminal complexity server-side
- Clean separation between data fetching and processing

### Reliability
- WebSocket provides immediate, real-time updates
- Complete state in each snapshot (no state synchronization issues)
- Automatic reconnection with exponential backoff
- Clear error handling and session management

### Performance
- Efficient binary buffer format for minimal overhead
- Intelligent accumulation reduces OpenAI API calls
- Real-time streaming eliminates polling latency
- Size and time thresholds optimize responsiveness

### Maintainability
- Minimal code surface area
- Clear data flow with single source of truth
- Well-defined interfaces between components

## Technical Implementation

### Core Components

1. **BufferWebSocketClient** (`Services/WebSocket/BufferWebSocketClient.swift`)
   - Maintains persistent WebSocket connection to `/buffers` endpoint
   - Handles binary message decoding with magic byte validation
   - Manages session subscriptions and automatic reconnection
   - Publishes buffer updates to subscribers

2. **VibeTunnelBufferService** (`Services/VibeTunnelBufferService.swift`)
   - Legacy HTTP polling implementation (deprecated)
   - Kept for compatibility with TerminalBufferView
   - Being phased out in favor of WebSocket streaming

3. **SmartTerminalProcessor** (`Managers/SmartTerminalProcessor.swift`)
   - Subscribes to WebSocket buffer updates
   - Uses BufferAccumulator for intelligent batching
   - Extracts and compares text content
   - Manages communication with OpenAI

4. **BufferAccumulator** (`Services/BufferAccumulator.swift`)
   - Accumulates buffer changes based on size/time thresholds
   - Prevents overwhelming OpenAI with rapid updates
   - Configurable thresholds for different use cases

5. **VibeTunnelSocketManager** (`Managers/VibeTunnelSocketManager.swift`)
   - Manages IPC socket connection
   - Sends terminal input commands
   - Coordinates WebSocket client lifecycle

6. **OpenAIRealtimeManager** (`Managers/OpenAIRealtimeManager.swift`)
   - WebSocket connection to OpenAI Realtime API
   - Audio streaming and speech synthesis
   - Voice command processing

This architecture provides a robust, maintainable foundation for voice-controlled terminal interaction while leveraging VibeTunnel's powerful terminal processing capabilities.