//
//  ConveneDevice.swift
//  Convene
//

import Foundation
import Network

public struct ConveneDevice: Hashable, Identifiable {
    public var id: String
    public var name: String
    public var applicationId: String
    public var endpoint: NWEndpoint
    /// 解析后的 IPv4，用来和 AirPlay 设备认成同一台机器。
    public var host: String

    public init(id: String, name: String, applicationId: String = "", endpoint: NWEndpoint, host: String = "") {
        self.id = id
        self.name = name
        self.applicationId = applicationId
        self.endpoint = endpoint
        self.host = host
    }
}
