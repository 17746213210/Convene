//
//  ConveneConfiguration.swift
//  Convene
//

import Foundation
import Network

/// Host and guest must share the same `serviceType` and `applicationId`.
public struct ConveneConfiguration: Equatable, Sendable {
    public var serviceType: String
    public var domain: String
    public var applicationId: String
    public var pingInterval: TimeInterval
    public var pingTimeout: TimeInterval
    public var connectTimeout: TimeInterval

    public init(
        serviceType: String = "_convene._tcp",
        domain: String = "local.",
        applicationId: String = "",
        pingInterval: TimeInterval = 5,
        pingTimeout: TimeInterval = 15,
        connectTimeout: TimeInterval = 10
    ) {
        self.serviceType = serviceType
        self.domain = domain
        self.applicationId = applicationId
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        self.connectTimeout = connectTimeout
    }

    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        if #available(iOS 14.0, tvOS 14.0, macOS 11.0, *) {
            tcp.connectionTimeout = 10
        }
        let parameters = NWParameters(tls: nil, tcp: tcp)
        ht_applyLAN(parameters)
        return parameters
    }

    /// Bonjour browse/advertise. Keep this off AWDL and IPv6 link-local.
    public static func browseParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        ht_applyLAN(parameters)
        return parameters
    }

    private static func ht_applyLAN(_ parameters: NWParameters) {
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = false
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
    }
}
