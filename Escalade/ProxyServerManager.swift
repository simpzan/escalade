//
//  ProxyServerManager.swift
//  Escalade
//
//  Created by Samuel Zhang on 2/9/17.
//
//

import Foundation
import NEKit
import CocoaLumberjackSwift

class ProxyServerManager: NSObject {

    public init(thePort: UInt16 = 0) {
        if thePort > 0 { port = thePort }
        let addr = IPAddress(fromString: address)
        socks5Server = NATProxyServer(address: addr, port: NEKit.Port(port: port))
        let httpAddr = IPAddress(fromString: "127.0.0.1")
        httpServer = GCDHTTPProxyServer(address: httpAddr, port: NEKit.Port(port: port + 1))
    }

    public var port: UInt16 = 19990

    public let address: String = interfaceIp

    public let socks5Server: GCDProxyServer?
    public let httpServer: GCDHTTPProxyServer?

    public func stopProxyServers() {
        socks5Server?.stop()
        httpServer?.stop()
    }
    
    public func dump() -> [ConnectionRecord] {
        guard let sock5 = socks5Server, let http = httpServer else { return [] }
        let sock5Connections = sock5.dump()
        let httpConnections = http.dump()
        return sock5Connections + httpConnections
    }

    public func startProxyServers() {
        do {
            try socks5Server?.start()
            try httpServer?.start()
            DDLogInfo("proxy servers started at \(port)");
        } catch let error {
            DDLogError("Encounter an error when starting proxy server. \(error)")
        }
    }
}
