import Foundation

/// VibeTunnel IPC Message Types (matching socket-protocol.ts)
enum MessageType: UInt8 {
    case stdinData = 0x01      // Raw stdin data (keyboard input)
    case controlCmd = 0x02     // Control commands (resize, kill, etc)
    case statusUpdate = 0x03   // Status updates (Claude status, etc)
    case heartbeat = 0x04      // Keep-alive ping/pong
    case error = 0x05          // Error messages
}

/// Message header structure (5 bytes)
/// Format: [1 byte: type] [4 bytes: length (big-endian)]
struct MessageHeader {
    let type: MessageType
    let length: UInt32
    
    var data: Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Data($0) })
        return data
    }
    
    static func parse(from data: Data) -> MessageHeader? {
        guard data.count >= 5 else { return nil }
        
        let type = MessageType(rawValue: data[0]) ?? .error
        let length = data[1..<5].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        return MessageHeader(type: type, length: length)
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
    
    static func createStdinData(_ text: String) -> IPCMessage {
        let payload = text.data(using: .utf8) ?? Data()
        let header = MessageHeader(
            type: .stdinData,
            length: UInt32(payload.count)
        )
        return IPCMessage(header: header, payload: payload)
    }
    
    static func createResize(cols: Int, rows: Int) -> IPCMessage {
        let json = ["cmd": "resize", "cols": cols, "rows": rows] as [String: Any]
        let payload = try! JSONSerialization.data(withJSONObject: json)
        let header = MessageHeader(
            type: .controlCmd,
            length: UInt32(payload.count)
        )
        return IPCMessage(header: header, payload: payload)
    }
    
    static func createHeartbeat() -> IPCMessage {
        let header = MessageHeader(
            type: .heartbeat,
            length: 0
        )
        return IPCMessage(header: header, payload: Data())
    }
    
    static func createStatusUpdate(app: String, status: String) -> IPCMessage {
        let json = ["app": app, "status": status] as [String: Any]
        let payload = try! JSONSerialization.data(withJSONObject: json)
        let header = MessageHeader(
            type: .statusUpdate,
            length: UInt32(payload.count)
        )
        return IPCMessage(header: header, payload: payload)
    }
}