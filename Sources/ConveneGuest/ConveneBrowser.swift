//
//  ConveneBrowser.swift
//  Convene
//
//  Guest: find hosts on the LAN. Devices arrive on the delegate; start() is async.
//

import Darwin
import Foundation
import Network
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
public protocol ConveneBrowserDelegate: AnyObject {
    /// `_convene._tcp`：自家 App 已在跑。
    func browser(_ browser: ConveneBrowser, didUpdate devices: [ConveneDevice])
    /// `_airplay._tcp`：Apple TV 硬件。和 App 是否打开无关。
    func browser(_ browser: ConveneBrowser, didUpdateAirPlay devices: [ConveneAirPlayDevice])
    func browser(_ browser: ConveneBrowser, didFail error: Error)
}

public extension ConveneBrowserDelegate {
    func browser(_ browser: ConveneBrowser, didUpdateAirPlay devices: [ConveneAirPlayDevice]) {}
    func browser(_ browser: ConveneBrowser, didFail error: Error) {}
}

@MainActor
public final class ConveneBrowser {
    public weak var delegate: ConveneBrowserDelegate?
    public private(set) var devices: [ConveneDevice] = []
    public private(set) var airPlayDevices: [ConveneAirPlayDevice] = []

    private let configuration: ConveneConfiguration
    private var browser: NWBrowser?
    private var airPlayBrowser: NWBrowser?
    private let addressResolver = ConveneAddressResolver()
    private var resolveGeneration = 0
    private let queue = DispatchQueue(label: "convene.browser")
    /// `start()` 之后、`stop()` 之前为 true。进后台时系统会取消 NWBrowser，回前台靠这个标记决定要不要继续找。
    private var browsing = false
    private var foregroundObserver: NSObjectProtocol?

    public init(configuration: ConveneConfiguration = ConveneConfiguration()) {
        self.configuration = configuration
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    public func start() {
        browsing = true
        watchForeground()
        openBrowsers()
    }

    public func stop() {
        browsing = false
        unwatchForeground()
        tearDown(notify: true)
    }

    /// 重新建立 Bonjour 浏览。已在查找中时调用不会清掉「还在查找」的标记。
    private func openBrowsers() {
        tearDown(notify: false)
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: configuration.serviceType, domain: nil),
            using: ConveneConfiguration.browseParameters()
        )
        browser.browseResultsChangedHandler = { [weak self, configuration] results, _ in
            print("[Convene] browse \(results.count) raw")
            let devices = parseBrowseResults(results, configuration: configuration)
            print("[Convene] keep \(devices.count) \(devices.map(\.name))")
            let endpoints = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.endpoint) })
            Task { @MainActor in
                guard let self else { return }
                self.publishConvene(devices, endpoints: endpoints)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            print("[Convene] browser \(String(describing: state))")
            guard case .failed(let error) = state else { return }
            Task { @MainActor in
                guard let self else { return }
                self.delegate?.browser(self, didFail: error)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        startAirPlayBrowse()
    }

    private func startAirPlayBrowse() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil),
            using: ConveneConfiguration.browseParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let drafts = parseAirPlayResults(results)
            print("[Convene] airplay keep \(drafts.count) \(drafts.map(\.device.name))")
            Task { @MainActor in
                guard let self else { return }
                self.publishAirPlay(drafts)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            print("[Convene] airplay browser \(String(describing: state))")
            guard case .failed(let error) = state else { return }
            Task { @MainActor in
                guard let self else { return }
                self.delegate?.browser(self, didFail: error)
            }
        }
        browser.start(queue: .main)
        airPlayBrowser = browser
    }

    private func publishConvene(_ parsed: [ConveneDevice], endpoints: [String: NWEndpoint]) {
        let generation = resolveGeneration
        resolveHosts(endpoints) { [weak self] hosts in
            guard let self, generation == self.resolveGeneration else { return }
            let updated = parsed.map { device in
                var copy = device
                copy.host = hosts[device.id] ?? ""
                return copy
            }
            print("[Convene] app hosts \(updated.map { "\($0.name)=\($0.host)" })")
            self.devices = updated
            self.delegate?.browser(self, didUpdate: updated)
        }
    }

    private func publishAirPlay(_ drafts: [(device: ConveneAirPlayDevice, endpoint: NWEndpoint)]) {
        let generation = resolveGeneration
        let endpoints = Dictionary(uniqueKeysWithValues: drafts.map { ($0.device.id, $0.endpoint) })
        resolveHosts(endpoints) { [weak self] hosts in
            guard let self, generation == self.resolveGeneration else { return }
            let updated = drafts.map { draft in
                var copy = draft.device
                copy.host = hosts[draft.device.id] ?? ""
                return copy
            }
            print("[Convene] airplay hosts \(updated.map { "\($0.name)=\($0.host)" })")
            self.airPlayDevices = updated
            self.delegate?.browser(self, didUpdateAirPlay: updated)
        }
    }

    private func resolveHosts(_ endpoints: [String: NWEndpoint], completion: @escaping ([String: String]) -> Void) {
        if endpoints.isEmpty {
            completion([:])
            return
        }
        let box = ConveneHostBox()
        let counter = ConveneResolveCounter(endpoints.count)
        for (id, endpoint) in endpoints {
            guard let parts = bonjourParts(endpoint) else {
                if counter.decrement() {
                    completion(box.snapshot())
                }
                continue
            }
            addressResolver.resolve(name: parts.name, type: parts.type, domain: parts.domain) { host in
                box.set(id, host)
                if counter.decrement() {
                    let hosts = box.snapshot()
                    Task { @MainActor in
                        completion(hosts)
                    }
                }
            }
        }
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
                guard let self, self.browsing else { return }
                self.openBrowsers()
            }
        }
    }

    private func unwatchForeground() {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
    }

    private func tearDown(notify: Bool) {
        resolveGeneration += 1
        addressResolver.cancelAll()
        browser?.cancel()
        browser = nil
        airPlayBrowser?.cancel()
        airPlayBrowser = nil
        devices = []
        airPlayDevices = []
        if notify {
            delegate?.browser(self, didUpdate: [])
            delegate?.browser(self, didUpdateAirPlay: [])
        }
    }
}

private func parseBrowseResults(
    _ results: Set<NWBrowser.Result>,
    configuration: ConveneConfiguration
) -> [ConveneDevice] {
    results.compactMap { result -> ConveneDevice? in
        let endpoint = result.endpoint
        let name: String
        if case .service(let serviceName, _, _, _) = endpoint {
            name = serviceName
        } else {
            name = String(describing: endpoint)
        }
        var deviceId = name
        var applicationId = ""
        if case .bonjour(let txt) = result.metadata {
            if let id = txt["id"], !id.isEmpty {
                deviceId = id
            }
            applicationId = txt["app"] ?? ""
        }
        if !configuration.applicationId.isEmpty,
           !applicationId.isEmpty,
           applicationId != configuration.applicationId {
            print("[Convene] skip \(name) app=\(applicationId)")
            return nil
        }
        return ConveneDevice(
            id: deviceId,
            name: name,
            applicationId: applicationId,
            endpoint: endpoint
        )
    }
    .sorted { $0.name < $1.name }
}

private func bonjourParts(_ endpoint: NWEndpoint) -> (name: String, type: String, domain: String)? {
    guard case .service(let name, let type, let domain, _) = endpoint else {
        return nil
    }
    let serviceType = type.hasSuffix(".") ? type : type + "."
    let serviceDomain = domain.hasSuffix(".") ? domain : domain + "."
    return (name, serviceType, serviceDomain)
}

private func parseAirPlayResults(_ results: Set<NWBrowser.Result>) -> [(device: ConveneAirPlayDevice, endpoint: NWEndpoint)] {
    results.compactMap { result -> (device: ConveneAirPlayDevice, endpoint: NWEndpoint)? in
        let name: String
        if case .service(let serviceName, _, _, _) = result.endpoint {
            name = serviceName
        } else {
            name = String(describing: result.endpoint)
        }
        var model = ""
        var deviceId = ""
        if case .bonjour(let txt) = result.metadata {
            model = txt["model"] ?? ""
            deviceId = txt["deviceid"] ?? txt["deviceId"] ?? ""
        }
        guard model.lowercased().hasPrefix("appletv") else {
            return nil
        }
        let device = ConveneAirPlayDevice(
            id: deviceId.isEmpty ? name : deviceId,
            name: name,
            model: model
        )
        return (device, result.endpoint)
    }
    .sorted { $0.device.name < $1.device.name }
}

/// 只把解析出的地址字符串送回主线程，NetService 留在回调里。
private final class ConveneAddressResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var services: [ObjectIdentifier: NetService] = [:]
    private var completions: [ObjectIdentifier: (String) -> Void] = [:]

    func resolve(name: String, type: String, domain: String, completion: @escaping (String) -> Void) {
        let service = NetService(domain: domain, type: type, name: name)
        let identifier = ObjectIdentifier(service)
        lock.lock()
        services[identifier] = service
        completions[identifier] = completion
        lock.unlock()
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func cancelAll() {
        lock.lock()
        let all = Array(services.values)
        services.removeAll()
        completions.removeAll()
        lock.unlock()
        for service in all {
            service.stop()
            service.delegate = nil
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        finish(sender, host: machineKey(sender))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(sender, host: "")
    }

    private func finish(_ sender: NetService, host: String) {
        let identifier = ObjectIdentifier(sender)
        lock.lock()
        let completion = completions.removeValue(forKey: identifier)
        services.removeValue(forKey: identifier)
        lock.unlock()
        sender.delegate = nil
        sender.stop()
        completion?(host)
    }

    private func machineKey(_ service: NetService) -> String {
        if let host = ipv4Host(service), !host.isEmpty {
            return host
        }
        return (service.hostName ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func ipv4Host(_ service: NetService) -> String? {
        guard let addresses = service.addresses else {
            return nil
        }
        for data in addresses {
            var storage = sockaddr_storage()
            let size = min(data.count, MemoryLayout<sockaddr_storage>.size)
            _ = withUnsafeMutableBytes(of: &storage) { dest in
                data.copyBytes(to: dest.bindMemory(to: UInt8.self), count: size)
            }
            guard storage.ss_family == sa_family_t(AF_INET) else {
                continue
            }
            var addr4 = sockaddr_in()
            withUnsafeBytes(of: storage) { raw in
                _ = memcpy(&addr4, raw.baseAddress, MemoryLayout<sockaddr_in>.size)
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = addr4.sin_addr
            inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN))
            let host = String(cString: buffer)
            if !host.isEmpty, host != "0.0.0.0" {
                return host
            }
        }
        return nil
    }
}

private final class ConveneHostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String: String] = [:]

    func set(_ id: String, _ host: String) {
        lock.lock()
        hosts[id] = host
        lock.unlock()
    }

    func snapshot() -> [String: String] {
        lock.lock()
        let copy = hosts
        lock.unlock()
        return copy
    }
}

private final class ConveneResolveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int

    init(_ count: Int) {
        left = count
    }

    func decrement() -> Bool {
        lock.lock()
        left -= 1
        let done = left == 0
        lock.unlock()
        return done
    }
}
