//
//  ConveneSession.swift
//  Convene
//
//  Guest: join a host and exchange UTF-8 strings.
//

import Foundation
import Network
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
    /// `connect` 之后、`disconnect` 之前为 true。进后台把连接掐掉时，回前台还要接着发。
    private var wantsConnection = false
    private var target: ConveneDevice?
    private var suspendedClose = false
    /// 后台把已建立的连接掐掉时，先不通知上层，等回前台重连失败再补一次断开。
    private var hiddenDisconnect = false
    private var resumeAttempted = false
    private var leftForeground = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    public init(configuration: ConveneConfiguration = ConveneConfiguration()) {
        self.configuration = configuration
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func connect(to device: ConveneDevice) {
        wantsConnection = true
        target = device
        suspendedClose = false
        hiddenDisconnect = false
        resumeAttempted = false
        watchLifecycle()
        beginConnection(to: device)
    }

    private func beginConnection(to device: ConveneDevice) {
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
        let ended = isConnected || hiddenDisconnect
        wantsConnection = false
        target = nil
        suspendedClose = false
        hiddenDisconnect = false
        resumeAttempted = false
        unwatchLifecycle()
        disconnect(notify: false, error: nil)
        if ended {
            delegate?.sessionDidDisconnect(self)
        }
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
                if self.wantsConnection && (self.leftForeground || !Self.applicationIsActive) {
                    self.suspendedClose = true
                    self.disconnect(notify: false, error: nil)
                    return
                }
                self.failConnection(ConveneError.timedOut)
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.connectTimeout, execute: work)
    }

    private func didBecomeReady() {
        timeoutWork?.cancel()
        timeoutWork = nil
        isConnected = true
        suspendedClose = false
        hiddenDisconnect = false
        resumeAttempted = false
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
        if wantsConnection, let target {
            if leftForeground || !Self.applicationIsActive {
                suspendedClose = true
                if wasConnected {
                    hiddenDisconnect = true
                }
                return
            }
            if !resumeAttempted {
                resumeAttempted = true
                beginConnection(to: target)
                return
            }
        }
        resumeAttempted = false
        suspendedClose = false
        failConnection(error, wasConnected: wasConnected)
    }

    private func failConnection(_ error: Error?, wasConnected: Bool = false) {
        let ended = wasConnected || hiddenDisconnect
        wantsConnection = false
        target = nil
        suspendedClose = false
        hiddenDisconnect = false
        resumeAttempted = false
        unwatchLifecycle()
        disconnect(notify: false, error: nil)
        if ended {
            delegate?.sessionDidDisconnect(self)
        }
        if let error {
            delegate?.session(self, didFail: error)
        } else if !wasConnected {
            delegate?.session(self, didFail: ConveneError.connectFailed("connection closed"))
        }
    }

    private func resumeAfterForeground() {
        guard wantsConnection, let target else { return }
        guard !isConnected || suspendedClose else { return }
        suspendedClose = false
        resumeAttempted = true
        beginConnection(to: target)
    }

    private func watchLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        #if os(iOS) || os(tvOS)
        let names: [(Notification.Name, SelectorAction)] = [
            (UIApplication.willResignActiveNotification, .leave),
            (UIApplication.willEnterForegroundNotification, .resume),
            (UIApplication.didBecomeActiveNotification, .active),
        ]
        #elseif os(macOS)
        let names: [(Notification.Name, SelectorAction)] = [
            (NSApplication.willResignActiveNotification, .leave),
            (NSApplication.didBecomeActiveNotification, .active),
        ]
        #else
        return
        #endif
        for (name, action) in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    switch action {
                    case .leave:
                        self.leftForeground = true
                    case .resume:
                        self.resumeAfterForeground()
                    case .active:
                        self.leftForeground = false
                        self.resumeAfterForeground()
                    }
                }
            }
            lifecycleObservers.append(token)
        }
    }

    private func unwatchLifecycle() {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        leftForeground = false
    }

    private enum SelectorAction {
        case leave
        case resume
        case active
    }

    private static var applicationIsActive: Bool {
        #if os(iOS) || os(tvOS)
        return UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        return NSApplication.shared.isActive
        #else
        return true
        #endif
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
