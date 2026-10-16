//
//  ConveneHost.swift
//  Convene
//
//  Publish on the LAN and exchange UTF-8 strings with one guest.
//

import Foundation
import Network
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
    private let queue = DispatchQueue(label: "convene.host")
    private var publishing = false
    private var foregroundObserver: NSObjectProtocol?

    public init(configuration: ConveneConfiguration = ConveneConfiguration()) {
        self.configuration = configuration
        deviceId = UUID().uuidString
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    public func start(displayName: String) {
        publishing = true
        self.displayName = displayName
        watchForeground()
        clearGuest(notify: true)
        openListener()
    }

    public func stop() {
        publishing = false
        unwatchForeground()
        clearGuest(notify: true)
        closeListener()
    }

    private func openListener() {
        closeListener()
        do {
            let listener = try NWListener(using: ConveneConfiguration.browseParameters())
            listener.service = NWListener.Service(
                name: displayName,
                type: configuration.serviceType,
                domain: nil,
                txtRecord: txtRecord()
            )
            listener.newConnectionHandler = { [weak self, weak listener] nw in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else {
                        nw.cancel()
                        return
                    }
                    self.accept(nw)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    self.handleListener(state)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            print("[Convene] host start name=\(displayName) type=\(configuration.serviceType) app=\(configuration.applicationId)")
        } catch {
            delegate?.host(self, didFail: ConveneError.listenerFailed(error.localizedDescription))
        }
    }

    private func closeListener() {
        listener?.cancel()
        listener = nil
        isDiscoverable = false
    }

    private func watchForeground() {
        guard foregroundObserver == nil else { return }
        #if os(iOS) || os(tvOS)
        let name = UIApplication.willEnterForegroundNotification
        #elseif os(macOS)
        let name = NSApplication.willBecomeActiveNotification
        #else
        return
        #endif
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.publishing else { return }
                self.clearGuest(notify: self.hasGuest)
                self.openListener()
            }
        }
    }

    private func unwatchForeground() {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
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
                guard self.connection === connection else { return }
                self.connection = nil
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
        let old = connection
        connection = nil
        old?.cancel()
        if notify, wasConnected {
            delegate?.hostDidDisconnectGuest(self)
        }
    }
}
