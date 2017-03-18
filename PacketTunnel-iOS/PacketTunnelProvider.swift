//
//  PacketTunnelProvider.swift
//  PacketTunnel-iOS
//
//  Created by Samuel Zhang on 3/5/17.
//
//

import NetworkExtension
import NEKit
import CocoaLumberjackSwift

class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var proxyService: ProxyService? = {
        guard let configString = load(key: configKey) else {
            return nil
        }
        guard let config = loadConfiguration(content: configString) else { return nil }
        return ProxyService(config: config, provider: self)
    }()
    var tunController: TUNController {
        return (proxyService?.tunController)!
    }
    var serverController: ServerController {
        return proxyService!.serverController
    }
    var servers: [String: TimeInterval] {
        var servers: [String: TimeInterval] = [:]
        self.serverController.servers.forEach({ (server) in
            servers[server.0] = server.1
        })
        return servers
    }

    var getServersHandler: APIHandler? = nil
    var switchServerHandler: APIHandler? = nil
    var autoSelectHandler: APIHandler? = nil
    func removeApis() {
        getServersHandler?(); getServersHandler = nil
        switchServerHandler?(); switchServerHandler = nil
        autoSelectHandler?(); autoSelectHandler = nil
    }
    func addApis() {
        getServersHandler = addAPI(id: getServersId) { (_) -> NSCoding? in
            return self.servers as NSCoding?
        }
        switchServerHandler = addAPI(id: switchProxyId, callback: { (server) -> NSCoding? in
            let server = server as! String
            DDLogInfo("switch to server \(server)")
            self.serverController.currentServer = server
            return true as NSCoding?
        })
        autoSelectHandler = addAPIAsync(id: autoSelectId) { (input, done) in
            self.serverController.autoSelect(callback: { (err, server) in
                DDLogInfo("autoSelect callback \(err) \(server)")
                if server != nil { return }

                let output = self.servers
                done(output as NSCoding?)
            })
        }
    }

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        DDLogInfo("startTunnel \(self) \(options)")
        NSLog("log file \(logFile)")

        self.addObserver(self, forKeyPath: "defaultPath", options: [.new], context: nil)
        proxyService?.start()

        setTunnelNetworkSettings(tunController.getTunnelSettings()) { (error) in
            if error != nil {
                DDLogError("setTunnelNetworkSettings error:\(error)")
                return
            }
            self.addApis()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        DDLogInfo("stopTunnel \(self) \(reason)")
        NSLog("log file \(logFile)")
        self.removeObserver(self, forKeyPath: "defaultPath")
        proxyService?.stop()
        removeApis()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        if let handler = completionHandler {
            handler(messageData)
        }
    }

    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        DDLogDebug("defaultPath changed")
        proxyService?.restart()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        DDLogInfo("about to sleep...")
        proxyService?.stop()
        completionHandler()
    }

    override func wake() {
        DDLogInfo("about to wake...")
        proxyService?.start()
    }

    deinit {
        DDLogDebug("deinit \(self)")
    }
}
