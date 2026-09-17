//
//  ConveneError.swift
//  Convene
//

import Foundation

public enum ConveneError: Error, Equatable, LocalizedError {
    case listenerFailed(String)
    case connectFailed(String)
    case timedOut
    case notConnected
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .listenerFailed(let message):
            return "Convene listener failed: \(message)"
        case .connectFailed(let message):
            return "Convene connect failed: \(message)"
        case .timedOut:
            return "Convene connection timed out"
        case .notConnected:
            return "Convene is not connected"
        case .disconnected:
            return "Convene disconnected"
        }
    }
}
