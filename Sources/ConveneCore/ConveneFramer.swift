//
//  ConveneFramer.swift
//  Convene
//
//  1-byte type + 4-byte big-endian length + payload.
//  type 0 = UTF-8 app message; 1 = ping; 2 = pong; 3 = close.
//

import Foundation

enum ConveneFrameType: UInt8 {
    case message = 0
    case ping = 1
    case pong = 2
    case close = 3
}

enum ConveneFrame: Equatable {
    case message(String)
    case ping
    case pong
    case close
}

enum ConveneFramer {
    static let headerSize = 5
    static let maxPayload = 256 * 1024

    static func encode(_ frame: ConveneFrame) -> Data? {
        let type: ConveneFrameType
        let payload: Data
        switch frame {
        case .message(let text):
            type = .message
            payload = Data(text.utf8)
        case .ping:
            type = .ping
            payload = Data()
        case .pong:
            type = .pong
            payload = Data()
        case .close:
            type = .close
            payload = Data()
        }
        guard payload.count <= maxPayload else { return nil }
        var data = Data(count: headerSize)
        data[0] = type.rawValue
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            data.replaceSubrange(1..<headerSize, with: bytes)
        }
        data.append(payload)
        return data
    }

    static func pop(from buffer: inout Data) -> ConveneFrame? {
        guard buffer.count >= headerSize else { return nil }
        guard let type = ConveneFrameType(rawValue: buffer[0]) else {
            buffer.removeAll()
            return nil
        }
        let length = buffer.subdata(in: 1..<headerSize).withUnsafeBytes { raw -> UInt32 in
            raw.load(as: UInt32.self).bigEndian
        }
        guard length <= maxPayload else {
            buffer.removeAll()
            return nil
        }
        let total = headerSize + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: headerSize..<total)
        buffer.removeSubrange(0..<total)
        switch type {
        case .message:
            return .message(String(data: payload, encoding: .utf8) ?? "")
        case .ping:
            return .ping
        case .pong:
            return .pong
        case .close:
            return .close
        }
    }
}
