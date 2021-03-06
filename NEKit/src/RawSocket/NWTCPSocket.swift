import Foundation
import NetworkExtension
import CocoaLumberjackSwift

/// The TCP socket build upon `NWTCPConnection`.
///
/// - warning: This class is not thread-safe.
public class NWTCPSocket: NSObject, RawTCPSocketProtocol {
    private var connection: NWTCPConnection?

    private var writePending = false
    private var closeAfterWriting = false
    private var cancelled = false

    private var scanner: StreamScanner!
    private var scanning: Bool = false
    private var readDataPrefix: Data?
    private var remoteEndpoint: NWHostEndpoint?

    // MARK: RawTCPSocketProtocol implementation

    /// The `RawTCPSocketDelegate` instance.
    weak open var delegate: RawTCPSocketDelegate?

    /// If the socket is connected.
    public var isConnected: Bool {
        return connection != nil && connection!.state == .connected
    }

    /// The source address.
    ///
    /// - note: Always returns `nil`.
    public var sourceIPAddress: IPAddress? {
        return nil
    }

    /// The source port.
    ///
    /// - note: Always returns `nil`.
    public var sourcePort: Port? {
        return nil
    }

    /// The destination address.
    ///
    /// - note: Always returns `nil`.
    public var destinationIPAddress: IPAddress? {
        return nil
    }

    /// The destination port.
    ///
    /// - note: Always returns `nil`.
    public var destinationPort: Port? {
        return nil
    }

    /**
     Connect to remote host.
     
     - parameter host:        Remote host.
     - parameter port:        Remote port.
     - parameter enableTLS:   Should TLS be enabled.
     - parameter tlsSettings: The settings of TLS.
     
     - throws: Never throws.
     */
    public func connectTo(host: String, port: Int, enableTLS: Bool, tlsSettings: [AnyHashable: Any]?) throws {
        let endpoint = NWHostEndpoint(hostname: host, port: "\(port)")
        remoteEndpoint = endpoint
        let tlsParameters = NWTLSParameters()
        if let tlsSettings = tlsSettings as? [String: AnyObject] {
            tlsParameters.setValuesForKeys(tlsSettings)
        }

        guard let connection = RawSocketFactory.TunnelProvider?.createTCPConnection(to: endpoint, enableTLS: enableTLS, tlsParameters: tlsParameters, delegate: nil) else {
            // This should only happen when the extension is already stopped and `RawSocketFactory.TunnelProvider` is set to `nil`.
            return
        }

        self.connection = connection
        connection.addObserver(self, forKeyPath: "state", options: [.initial, .new], context: nil)
    }

    /**
     Disconnect the socket.
     
     The socket will disconnect elegantly after any queued writing data are successfully sent.
     */
    public func disconnect() {
        cancelled = true

        if connection == nil  || connection!.state == .cancelled {
            delegate?.didDisconnectWith(socket: self)
        } else {
            closeAfterWriting = true
            checkStatus()
        }
    }

    /**
     Disconnect the socket immediately.
     */
    public func forceDisconnect() {
        cancelled = true

        if connection == nil  || connection!.state == .cancelled {
            delegate?.didDisconnectWith(socket: self)
        } else {
            cancel()
        }
    }

    /**
     Send data to remote.
     
     - parameter data: Data to send.
     - warning: This should only be called after the last write is finished, i.e., `delegate?.didWriteData()` is called.
     */
    public func write(data: Data) {
        guard !cancelled else {
            return
        }

        guard data.count > 0 else {
            QueueFactory.getQueue().async {
                self.delegate?.didWrite(data: data, by: self)
            }
            return
        }

        send(data: data)
    }

    /**
     Read data from the socket.
     
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    open func readData() {
        readData(maxinum: Opt.MAXNWTCPSocketReadDataSize)
    }
    public func readData(maxinum: Int) {
        readMinimum(1, maxinum: maxinum)
    }

    /**
     Read specific length of data from the socket.
     
     - parameter length: The length of the data to read.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readDataTo(length: Int) {
        readMinimum(length, maxinum: length)
    }
    private func readMinimum(_ mininum: Int, maxinum: Int) {
        guard !cancelled else {
            return
        }
        connection!.readMinimumLength(mininum, maximumLength: maxinum) { data, error in
            if let err = error {
                DDLogError("\(self) got an error when reading data: \(err).")
                self.queueCall {
                    self.disconnect()
                }
                return
            }
            if data != nil {
                self.readCallback(data: data)
            }
        }
    }

    /**
     Read data until a specific pattern (including the pattern).
     
     - parameter data: The pattern.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readDataTo(data: Data) {
        readDataTo(data: data, maxLength: 0)
    }

    // Actually, this method is available as `- (void)readToPattern:(id)arg1 maximumLength:(unsigned int)arg2 completionHandler:(id /* block */)arg3;`
    // which is sadly not available in public header for some reason I don't know.
    // I don't want to do it myself since This method is not trival to implement and I don't like reinventing the wheel.
    // Here is only the most naive version, which may not be the optimal if using with large data blocks.
    /**
     Read data until a specific pattern (including the pattern).
     
     - parameter data: The pattern.
     - parameter maxLength: The max length of data to scan for the pattern.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readDataTo(data: Data, maxLength: Int) {
        guard !cancelled else {
            return
        }

        var maxLength = maxLength
        if maxLength == 0 {
            maxLength = Opt.MAXNWTCPScanLength
        }
        scanner = StreamScanner(pattern: data, maximumLength: maxLength)
        scanning = true
        readData()
    }

    private func queueCall(_ block: @escaping () -> Void) {
        QueueFactory.getQueue().async(execute: block)
    }

    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "state" else {
            return
        }
        DDLogDebug("\(self) connection state changed to \(connection!.state).")

        switch connection!.state {
        case .connected:
            queueCall {
                self.delegate?.didConnectWith(socket: self)
            }
        case .disconnected:
            cancelled = true
            cancel()
        case .cancelled:
            cancelled = true
            queueCall {
                let delegate = self.delegate
                self.delegate = nil
                delegate?.didDisconnectWith(socket: self)
            }
        default:
            break
        }
    }

    private func readCallback(data: Data?) {
        guard !cancelled else {
            return
        }

        queueCall {
            guard let data = self.consumeReadData(data) else {
                // remote read is closed, but this is okay, nothing need to be done, if this socket is read again, then error occurs.
                return
            }

            if self.scanning {
                guard let (match, rest) = self.scanner.addAndScan(data) else {
                    self.readData()
                    return
                }

                self.scanner = nil
                self.scanning = false

                guard let matchData = match else {
                    // do not find match in the given length, stop now
                    return
                }

                self.readDataPrefix = rest
                self.delegate?.didRead(data: matchData, from: self)
            } else {
                self.delegate?.didRead(data: data, from: self)
            }
        }
    }

    private func send(data: Data) {
        writePending = true
        self.connection!.write(data) { error in
            self.queueCall {
                self.writePending = false

                guard error == nil else {
                    DDLogError("\(self) got an error when writing data: \(error!). \(self.state).")
                    self.disconnect()
                    return
                }

                self.delegate?.didWrite(data: data, by: self)
                self.checkStatus()
            }
        }
    }

    private var state: NWTCPConnectionState {
        return connection?.state ?? .invalid
    }

    private func consumeReadData(_ data: Data?) -> Data? {
        defer {
            readDataPrefix = nil
        }

        if readDataPrefix == nil {
            return data
        }

        if data == nil {
            return readDataPrefix
        }

        var wholeData = readDataPrefix!
        wholeData.append(data!)
        return wholeData
    }

    private func cancel() {
        connection?.cancel()
    }

    private func checkStatus() {
        if closeAfterWriting && !writePending {
            cancel()
        }
    }

    deinit {
        guard let connection = connection else {
            return
        }

        connection.removeObserver(self, forKeyPath: "state")
    }

    open override var description: String {
        let address = Utils.address(of: self)
        let typeName = String(describing: type(of: self))
        let endpoint = remoteEndpoint != nil ? " \(remoteEndpoint!)" : ""
        let parent = delegate == nil ? 0 : Utils.address(of: delegate! as AnyObject)
        return String(format: "<%@ %p %p %@>", typeName, address, parent, endpoint)
    }
}

extension NWTCPConnectionState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .cancelled:
            return "canceled"
        case .connected:
            return "connected"
        case .connecting:
            return "connecting"
        case .disconnected:
            return "disconnected"
        case .invalid:
            return "invalid"
        case .waiting:
            return "waiting"
        }
    }
}
