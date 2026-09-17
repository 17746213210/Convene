//
//  ConveneConnection.swift
//  Convene
//

import Foundation
import Network

public final class ConveneConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let pingInterval: TimeInterval
    private let pingTimeout: TimeInterval
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var lastHeard = Date()
    private var didClose = false
    private var isReady = false

    public var onMessage: ((String) -> Void)?
    public var onReady: (() -> Void)?
    public var onClose: ((Error?) -> Void)?

    public init(
        connection: NWConnection,
        pingInterval: TimeInterval,
        pingTimeout: TimeInterval
    ) {
        self.connection = connection
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        queue = DispatchQueue(label: "convene.connection")
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.handle(state)
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ text: String) {
        queue.async { [weak self] in
            self?.write(.message(text))
        }
    }

    public func cancel(error: Error? = nil) {
        queue.async { [self] in
            self.closeThenFinish(error: error)
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !isReady else { return }
            isReady = true
            lastHeard = Date()
            startHeartbeat()
            receive()
            onReady?()
        case .failed(let error):
            finish(error: error)
        case .cancelled:
            finish(error: nil)
        default:
            break
        }
    }

    private func write(_ frame: ConveneFrame, isComplete: Bool = false, completion: (() -> Void)? = nil) {
        guard isReady, !didClose, let data = ConveneFramer.encode(frame) else {
            completion?()
            return
        }
        connection.send(content: data, contentContext: .defaultMessage, isComplete: isComplete, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(error: error)
                return
            }
            completion?()
        })
    }

    private func closeThenFinish(error: Error?) {
        guard isReady, !didClose else {
            finish(error: error)
            return
        }
        write(.close, isComplete: true) { [self] in
            print("[Convene] close sent")
            self.finish(error: error)
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.didClose else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if let error {
                self.finish(error: error)
                return
            }
            if isComplete {
                self.finish(error: nil)
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while let frame = ConveneFramer.pop(from: &buffer) {
            lastHeard = Date()
            switch frame {
            case .message(let text):
                onMessage?(text)
            case .ping:
                write(.pong)
            case .pong:
                break
            case .close:
                print("[Convene] close received")
                finish(error: nil)
                return
            }
        }
    }

    private func startHeartbeat() {
        guard pingInterval > 0, pingTimeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.didClose else { return }
            if Date().timeIntervalSince(self.lastHeard) > self.pingTimeout {
                self.finish(error: ConveneError.timedOut)
                return
            }
            self.write(.ping)
        }
        timer.resume()
        pingTimer = timer
    }

    private func finish(error: Error?) {
        guard !didClose else { return }
        didClose = true
        pingTimer?.cancel()
        pingTimer = nil
        connection.cancel()
        onClose?(error)
    }
}
