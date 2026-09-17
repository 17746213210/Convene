//
//  ConveneBrowser.swift
//  Convene
//
//  Guest: find hosts on the LAN. Devices arrive on the delegate; start() is async.
//

import Foundation
import Network

@MainActor
public protocol ConveneBrowserDelegate: AnyObject {
    func browser(_ browser: ConveneBrowser, didUpdate devices: [ConveneDevice])
    func browser(_ browser: ConveneBrowser, didFail error: Error)
}

public extension ConveneBrowserDelegate {
    func browser(_ browser: ConveneBrowser, didFail error: Error) {}
}

@MainActor
public final class ConveneBrowser {
    public weak var delegate: ConveneBrowserDelegate?
    public private(set) var devices: [ConveneDevice] = []

    private let configuration: ConveneConfiguration
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "convene.browser")

    public init(configuration: ConveneConfiguration = ConveneConfiguration()) {
        self.configuration = configuration
    }

    public func start() {
        stop(notify: false)
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: configuration.serviceType, domain: nil),
            using: ConveneConfiguration.browseParameters()
        )
        browser.browseResultsChangedHandler = { [weak self, configuration] results, _ in
            print("[Convene] browse \(results.count) raw")
            let devices = parseBrowseResults(results, configuration: configuration)
            print("[Convene] keep \(devices.count) \(devices.map(\.name))")
            Task { @MainActor in
                guard let self else { return }
                self.devices = devices
                self.delegate?.browser(self, didUpdate: devices)
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
    }

    public func stop() {
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        browser?.cancel()
        browser = nil
        devices = []
        if notify {
            delegate?.browser(self, didUpdate: [])
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
