import Foundation
import CocoaAsyncSocket
import CocoaLumberjackSwift

/// The TCP socket build upon `GCDAsyncSocket`.
///
/// - warning: This class is not thread-safe.
open class GCDTCPSocket: NSObject, GCDAsyncSocketDelegate, RawTCPSocketProtocol {
    public let socket: GCDAsyncSocket
    fileprivate var enableTLS: Bool = false

    /**
     Initailize an instance with `GCDAsyncSocket`.

     - parameter socket: The socket object to work with. If this is `nil`, then a new `GCDAsyncSocket` instance is created.
     */
    public init(socket: GCDAsyncSocket? = nil) {
        if let socket = socket {
            self.socket = socket
            self.socket.setDelegate(nil, delegateQueue: QueueFactory.getQueue())
            if socket.isConnected {
                sourcePort = Port(port: socket.connectedPort)
                sourceIPAddress = IPAddress(fromString: socket.connectedHost ?? "")
            }
        } else {
            self.socket = GCDAsyncSocket(delegate: nil, delegateQueue: QueueFactory.getQueue(), socketQueue: QueueFactory.getQueue())
            self.socket.isIPv6Enabled = false
        }
        super.init()

        self.socket.synchronouslySetDelegate(self)
    }

    // MARK: RawTCPSocketProtocol implementation

    /// The `RawTCPSocketDelegate` instance.
    weak open var delegate: RawTCPSocketDelegate?

    /// If the socket is connected.
    open var isConnected: Bool {
        return !socket.isDisconnected
    }

    /// The source address.
    open var sourceIPAddress: IPAddress?
    /// The source port.
    open var sourcePort: Port?

    /// The destination address.
    ///
    /// - note: Always returns `nil`.
    open var destinationIPAddress: IPAddress? {
        return nil
    }

    /// The destination port.
    ///
    /// - note: Always returns `nil`.
    open var destinationPort: Port? {
        return nil
    }

    /**
     Connect to remote host.

     - parameter host:        Remote host.
     - parameter port:        Remote port.
     - parameter enableTLS:   Should TLS be enabled.
     - parameter tlsSettings: The settings of TLS.

     - throws: The error occured when connecting to host.
     */
    open func connectTo(host: String, port: Int, enableTLS: Bool = false, tlsSettings: [AnyHashable: Any]? = nil) throws {
        try connectTo(host: host, withPort: port)
        self.enableTLS = enableTLS
        if enableTLS {
            startTLSWith(settings: tlsSettings)
        }
    }

    /**
     Disconnect the socket.

     The socket will disconnect elegantly after any queued writing data are successfully sent.
     */
    open func disconnect() {
        socket.disconnectAfterWriting()
    }

    /**
     Disconnect the socket immediately.
     */
    open func forceDisconnect() {
        socket.disconnect()
    }

    /**
     Send data to remote.

     - parameter data: Data to send.
     - warning: This should only be called after the last write is finished, i.e., `delegate?.didWriteData()` is called.
     */
    open func write(data: Data) {
        write(data: data, withTimeout: -1)
    }

    /**
     Read data from the socket.

     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    open func readData() {
        readData(maxinum: Opt.MAXNWTCPSocketReadDataSize)
    }
    open func readData(maxinum: Int) {
        socket.readData(withTimeout: -1, buffer: nil, bufferOffset: 0, maxLength: UInt(maxinum), tag: 0)
    }

    /**
     Read specific length of data from the socket.

     - parameter length: The length of the data to read.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    open func readDataTo(length: Int) {
        readDataTo(length: length, withTimeout: -1)
    }

    /**
     Read data until a specific pattern (including the pattern).

     - parameter data: The pattern.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    open func readDataTo(data: Data) {
        readDataTo(data: data, maxLength: Opt.MAXNWTCPSocketReadDataSize)
    }

    /**
     Read data until a specific pattern (including the pattern).

     - parameter data: The pattern.
     - parameter maxLength: Ignored since `GCDAsyncSocket` does not support this. The max length of data to scan for the pattern.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    open func readDataTo(data: Data, maxLength: Int) {
        readDataTo(data: data, withTimeout: -1, maxLength: maxLength)
    }

    // MARK: Other helper methods
    /**
     Send data to remote.

     - parameter data: Data to send.
     - parameter timeout: Operation timeout.
     - warning: This should only be called after the last write is finished, i.e., `delegate?.didWriteData()` is called.
     */
    func write(data: Data, withTimeout timeout: Double) {
        guard data.count > 0 else {
            QueueFactory.getQueue().async {
                self.delegate?.didWrite(data: data, by: self)
            }
            return
        }

        let address = Utils.address(of: self)
        writingData[address] = data
        socket.write(data, withTimeout: timeout, tag: address)
    }
    private var writingData = [Int: Data]()

    /**
     Read specific length of data from the socket.

     - parameter length: The length of the data to read.
     - parameter timeout: Operation timeout.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    func readDataTo(length: Int, withTimeout timeout: Double) {
        socket.readData(toLength: UInt(length), withTimeout: timeout, tag: 0)
    }

    /**
     Read data until a specific pattern (including the pattern).

     - parameter data: The pattern.
     - parameter timeout: Operation timeout.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    func readDataTo(data: Data, withTimeout timeout: Double, maxLength: Int) {
        socket.readData(to: data, withTimeout: timeout, maxLength: UInt(maxLength), tag: 0)
    }

    /**
     Connect to remote host.

     - parameter host:        Remote host.
     - parameter port:        Remote port.

     - throws: The error occured when connecting to host.
     */
    func connectTo(host: String, withPort port: Int) throws {
        h = host
        ts = Date()
        try socket.connect(toHost: host, onPort: UInt16(port))
    }

    /**
     Secures the connection using SSL/TLS.

     - parameter settings: TLS settings, refer to documents of `GCDAsyncSocket` for detail.
     */
    func startTLSWith(settings: [AnyHashable: Any]!) {
        if let settings = settings as? [String: NSObject] {
            socket.startTLS(settings)
        } else {
            socket.startTLS(nil)
        }
    }

    // MARK: Delegate methods for GCDAsyncSocket
    open func socket(_ sock: GCDAsyncSocket, didWriteDataWithTag tag: Int) {
        let data = writingData[tag]
        writingData[tag] = nil
        delegate?.didWrite(data: data, by: self)
    }

    open func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        delegate?.didRead(data: data, from: self)
    }

    open func socketDidDisconnect(_ socket: GCDAsyncSocket, withError err: Error?) {
        log("disconnected", done: true);
        if let error = err, error.code != GCDAsyncSocketError.closedError.rawValue {
            DDLogWarn("\(self) disconnected with error, \(error)")
        }
        delegate?.didDisconnectWith(socket: self)
        delegate = nil
        socket.setDelegate(nil, delegateQueue: nil)
    }

    open func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        sourcePort = Port(port: port)
        sourceIPAddress = IPAddress(fromString: host)
        log("connected");
        if !enableTLS {
            delegate?.didConnectWith(socket: self)
        }
    }

    open func socketDidSecure(_ sock: GCDAsyncSocket) {
        if enableTLS {
            delegate?.didConnectWith(socket: self)
        }
    }

    open func socket(_ sock: GCDAsyncSocket, didLookupWithAddress4 address4: Data?, address6: Data?) {
        addr4 = address4
        addr6 = address6
        log("lookup")
    }

    func getIpv4String(_ data: Data?) -> String {
        guard let data = data else { return "" }

        var storage = sockaddr_storage()
        (data as NSData).getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)

        if Int32(storage.ss_family) != AF_INET { return "" }

        let addr4 = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        }
        return String(cString: inet_ntoa(addr4.sin_addr), encoding: .ascii)!
    }
    var addr4: Data?
    var addr6: Data?

    var ts: Date! = nil
    func log(_ what: String, done: Bool = false) {
        guard verbose else { return }
        let now = Date()
        let diff = Int(now.timeIntervalSince(ts!) * 1000.0)
        timestamps[what] = diff
        if done {
            let ip4 = getIpv4String(addr4)
            let ip6 = addr6 != nil
            DDLogInfo("timing: \(h ?? "") \(timestamps) \(ip4) \(ip6)")
        }
    }
    var h: String?
    var timestamps = [String: Int]()

    public var verbose: Bool = false

    private var endpoint: String? {
        guard let port = sourcePort?.value, let host = sourceIPAddress?.presentation else { return nil }
        return "\(host):\(port)"
    }
    open override var description: String {
        let address = Utils.address(of: self)
        let typeName = String(describing: type(of: self))
        let endpoint = self.endpoint ?? ""
        let parent = delegate == nil ? 0 : Utils.address(of: delegate! as AnyObject)
        return String(format: "<%@ %p %p %@>", typeName, address, parent, endpoint)
    }
}
