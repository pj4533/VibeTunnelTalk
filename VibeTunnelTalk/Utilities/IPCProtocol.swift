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
    
    static func createHeartbeat() -> IPCMessage {
        let header = MessageHeader(
            type: .heartbeat,
            flags: 0,
            reserved: 0,
            length: 0
        )
        return IPCMessage(header: header, payload: Data())
    }
}