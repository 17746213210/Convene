//
//  ConveneHost.swift
//  Convene
//
//  Publish on the LAN and exchange UTF-8 strings with one guest.
//

import Foundation
import Network

@MainActor
public protocol ConveneHostDelegate: AnyObject {
    func hostDidConnectGuest(_ host: ConveneHost)
    func hostDidDisconnectGuest(_ host: ConveneHost)
    func host(_ host: ConveneHost, didReceive message: String)
    func host(_ host: ConveneHost, didFail error: Error)
}

public extension ConveneHostDelegate {
    func host(_ host: ConveneHost, didFail error: Error) {}
}

@MainActor
public final class ConveneHost {
    public weak var delegate: ConveneHostDelegate?
    public private(set) var isDiscoverable = false
    public private(set) var hasGuest = false
    public let deviceId: String
    public private(set) var displayName: String = ""

    private let configuration: ConveneConfiguration
    private var listener: NWListener?
    private var connection: ConveneConnection?
    private var ignoreClose = false
    private let queue = DispatchQueue(label: "convene.host")

    public init(configuration: ConveneConfiguration = ConveneConfiguration()) {
        self.configuration = configuration
        deviceId = UUID().uuidString
    }

    public func start(displayName: String) {
        stop()
        self.displayName = displayName
        do {
            let listener = try NWListener(using: ConveneConfiguration.browseParameters())
            listener.service = NWListener.Service(
                name: displayName,
                type: configuration.serviceType,
                domain: nil,
                txtRecord: txtRecord()
            )
            listener.newConnectionHandler = { [weak self] nw in
                MainActor.assumeIsolated {
                    self?.accept(nw)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    self?.handleListener(state)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            print("[Convene] host start name=\(displayName) type=\(configuration.serviceType) app=\(configuration.applicationId)")
        } catch {
            delegate?.host(self, didFail: ConveneError.listenerFailed(error.localizedDescription))
        }
    }

    public func stop() {
        clearGuest(notify: true)
        listener?.cancel()
        listener = nil
        isDiscoverable = false
    }

    @discardableResult
    public func send(_ message: String) -> Bool {
        guard hasGuest else { return false }
        connection?.send(message)
        return true
    }

    private func txtRecord() -> NWTXTRecord {
        var record = NWTXTRecord()
        record["id"] = deviceId
        if !configuration.applicationId.isEmpty {
            record["app"] = configuration.applicationId
        }
        return record
    }

    private func handleListener(_ state: NWListener.State) {
        print("[Convene] host \(String(describing: state))")
        switch state {
        case .ready:
            isDiscoverable = true
        case .failed(let error):
            isDiscoverable = false
            delegate?.host(self, didFail: ConveneError.listenerFailed(error.localizedDescription))
        case .cancelled:
            isDiscoverable = false
        default:
            break
        }
    }

    private func accept(_ nw: NWConnection) {
        if hasGuest {
            print("[Convene] guest in use, drop extra connection")
            nw.cancel()
            return
        }
        clearGuest(notify: false)
        let connection = makeConnection(nw)
        self.connection = connection
        connection.start()
    }

    private func makeConnection(_ nw: NWConnection) -> ConveneConnection {
        let connection = ConveneConnection(
            connection: nw,
            pingInterval: configuration.pingInterval,
            pingTimeout: configuration.pingTimeout
        )
        connection.onMessage = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.delegate?.host(self, didReceive: message)
            }
        }
        connection.onReady = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hasGuest = true
                self.delegate?.hostDidConnectGuest(self)
            }
        }
        connection.onClose = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.connection = nil
                if self.ignoreClose {
                    self.ignoreClose = false
                    self.hasGuest = false
                    return
                }
                let wasConnected = self.hasGuest
                self.hasGuest = false
                if wasConnected {
                    self.delegate?.hostDidDisconnectGuest(self)
                }
                if let error, !wasConnected {
                    self.delegate?.host(self, didFail: error)
                }
            }
        }
        return connection
    }

    private func clearGuest(notify: Bool) {
        let wasConnected = hasGuest
        hasGuest = false
        if let connection {
            ignoreClose = true
            connection.cancel()
        }
        if notify, wasConnected {
            delegate?.hostDidDisconnectGuest(self)
        }
    }
}
