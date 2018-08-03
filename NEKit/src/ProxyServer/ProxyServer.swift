import Foundation
import CocoaAsyncSocket
import Resolver
import CocoaLumberjackSwift

/**
 The base proxy server class.
 
 This proxy does not listen on any port.
 */
open class ProxyServer: NSObject, TunnelDelegate {
    public typealias TunnelArray = [Tunnel]

    /// The port of proxy server.
    open let port: Port

    /// The address of proxy server.
    open let address: IPAddress?

    /// The type of the proxy server.
    ///
    /// This can be set to anything describing the proxy server.
    open let type: String

    /// The description of proxy server.
    open override var description: String {
        return "<\(type) at \(address!.description):\(port.value)>"
    }

    open var observer: Observer<ProxyServerEvent>?

    public var tunnels: TunnelArray = []

    /**
     Create an instance of proxy server.
     
     - parameter address: The address of proxy server.
     - parameter port:    The port of proxy server.
     
     - warning: If you are using Network Extension, you have to set address or you may not able to connect to the proxy server.
     */
    public init(address: IPAddress?, port: Port) {
        self.address = address
        self.port = port
        type = "\(Swift.type(of: self))"

        super.init()

        self.observer = ObserverFactory.currentFactory?.getObserverForProxyServer(self)
    }

    /**
     Start the proxy server.
     
     - throws: The error occured when starting the proxy server.
     */
    open func start() throws {
        QueueFactory.executeOnQueueSynchronizedly {
            GlobalIntializer.initalize()
            self.observer?.signal(.started(self))
        }
    }

    /**
     Stop the proxy server.
     */
    open func stop() {
        QueueFactory.executeOnQueueSynchronizedly {
            for tunnel in tunnels {
                tunnel.forceClose()
            }

            observer?.signal(.stopped(self))
        }
    }

    /**
     Delegate method when the proxy server accepts a new ProxySocket from local.
     
     When implementing a concrete proxy server, e.g., HTTP proxy server, the server should listen on some port and then wrap the raw socket in a corresponding ProxySocket subclass, then call this method.
     
     - parameter socket: The accepted proxy socket.
     */
    open func didAcceptNewSocket(_ socket: ProxySocket) {
        observer?.signal(.newSocketAccepted(socket, onServer: self))
        let tunnel = Tunnel(proxySocket: socket)
        tunnel.delegate = self
        tunnels.append(tunnel)
        tunnel.openTunnel()
    }

    // MARK: TunnelDelegate implementation

    /**
     Delegate method when a tunnel closed. The server will remote it internally.
     
     - parameter tunnel: The closed tunnel.
     */
    func tunnelDidClose(_ tunnel: Tunnel) {
        observer?.signal(.tunnelClosed(tunnel, onServer: self))
        guard let index = tunnels.index(of: tunnel) else {
            // things went strange
            return
        }

        Historian.shared.record(tunnel: tunnel)
        tunnels.remove(at: index)
    }

    public func dump() -> [ConnectionRecord] {
        var i = 1;
        let name = String(describing: self)
        let total = tunnels.count
        var connections = [ConnectionRecord]()
        for tunnel in tunnels {
            DDLogInfo("\(name) \(i)/\(total). \(tunnel)")
            i += 1

            let record = ConnectionRecord(tunnel: tunnel)
            connections.append(record)
        }
        return connections
    }
}
