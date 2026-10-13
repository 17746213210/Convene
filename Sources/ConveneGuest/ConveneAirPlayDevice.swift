//
//  ConveneAirPlayDevice.swift
//  Convene
//
//  Apple TV hardware found on _airplay._tcp. This is not a Convene host.
//

import Foundation

public struct ConveneAirPlayDevice: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var model: String
    /// 解析后的 IPv4，用来和 Convene App 认成同一台机器。
    public var host: String

    public init(id: String, name: String, model: String, host: String = "") {
        self.id = id
        self.name = name
        self.model = model
        self.host = host
    }
}
