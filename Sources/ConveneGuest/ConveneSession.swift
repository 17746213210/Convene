//
//  ConveneSession.swift
//  Convene
//
//  Guest: join a host and exchange UTF-8 strings.
//

import Foundation
import Network

@MainActor
public protocol ConveneSessionDelegate: AnyObject {
    func sessionDidConnect(_ session: ConveneSession)
    func sessionDidDisconnect(_ session: ConveneSession)
    func session(_ session: ConveneSession, didReceive message: String)
    func session(_ session: ConveneSession, didFail error: Error)
}

public extension ConveneSessionDelegate {
    func session(_ session: ConveneSession, didFail error: Error) {}
}

@MainActor
public final class ConveneSession {
    public weak var delegate: ConveneSessionDelegate?
    public private(set) var isConnected = false

    private let configuration: ConveneConfiguration
    private var connection: ConveneConnection?
    private var timeoutWork: DispatchWorkItem?
    private var ignoreClose = false

    public init(configuration: ConveneConfiguration = ConveneConfiguration()) {
        self.configuration = configuration
    }

    public func connect(to device: ConveneDevice) {
        disconnect(notify: isConnected, error: nil)
        let nw = NWConnection(
            to: device.endpoint,
            using: ConveneConfiguration.tcpParameters()
        )
        let connection = ConveneConnection(
            connection: nw,
            pingInterval: configuration.pingInterval,
            pingTimeout: configuration.pingTimeout
        )
        connection.onMessage = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.delegate?.session(self, didReceive: message)
            }
        }
        connection.onReady = { [weak self] in
            Task { @MainActor in
                self?.didBecomeReady()
            }
        }
        connection.onClose = { [weak self] error in
            Task { @MainActor in
                self?.didClose(error)
            }
        }
        self.connection = connection
        scheduleTimeout()
        connection.start()
    }

    public func disconnect() {
        disconnect(notify: isConnected, error: nil)
    }

    @discardableResult
    public func send(_ message: String) -> Bool {
        guard isConnected else {
            delegate?.session(self, didFail: ConveneError.notConnected)
            return false
        }
        connection?.send(message)
        return true
    }

    private func scheduleTimeout() {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isConnected else { return }
                self.disconnect(notify: false, error: ConveneError.timedOut)
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.connectTimeout, execute: work)
    }

    private func didBecomeReady() {
        timeoutWork?.cancel()
        timeoutWork = nil
        isConnected = true
        delegate?.sessionDidConnect(self)
    }

    private func didClose(_ error: Error?) {
        timeoutWork?.cancel()
        timeoutWork = nil
        if ignoreClose {
            ignoreClose = false
            connection = nil
            return
        }
        connection = nil
        let wasConnected = isConnected
        isConnected = false
        if wasConnected {
            delegate?.sessionDidDisconnect(self)
        }
        if let error {
            delegate?.session(self, didFail: error)
        } else if !wasConnected {
            delegate?.session(self, didFail: ConveneError.connectFailed("connection closed"))
        }
    }

    private func disconnect(notify: Bool, error: Error?) {
        timeoutWork?.cancel()
        timeoutWork = nil
        let wasConnected = isConnected
        isConnected = false
        if let connection {
            ignoreClose = true
            connection.cancel(error: error)
        }
        if notify, wasConnected {
            delegate?.sessionDidDisconnect(self)
        }
        if let error {
            delegate?.session(self, didFail: error)
        }
    }
}
