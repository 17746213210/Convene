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

    public init(id: String, name: String, applicationId: String = "", endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.applicationId = applicationId
        self.endpoint = endpoint
    }
}
