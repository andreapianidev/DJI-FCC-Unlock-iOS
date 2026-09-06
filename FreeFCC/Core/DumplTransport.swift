import Foundation

/// A bidirectional byte pipe to a DJI controller or aircraft.
///
/// The Android original has two implementations, USB accessory (AOA) and USB
/// VCOM bulk. Neither exists on iOS: the only sanctioned link to an MFi
/// accessory is an `EASession`, so this protocol has a single production
/// implementation plus a loopback used by the tests.
protocol DumplTransport: AnyObject, Sendable {
    /// Human-readable identity of the far end, shown in the UI.
    var name: String { get }
    /// Short transport tag, shown next to the version in the header.
    var kind: String { get }
    /// False once the link has dropped or been closed.
    var isOpen: Bool { get }
    /// Route bytes last seen from the controller, echoed back on writes.
    var currentRoute: [UInt8] { get }
    /// Aircraft serial or model code sniffed out of the telemetry stream.
    var detectedSerial: String { get }
    /// What the inbound side has actually seen, which is the difference
    /// between a link that is silent and one that is talking in a shape the
    /// parser does not recognise.
    var rxStats: RxStats { get }
    /// Framing used for the keepalive frames the transport sends on its own.
    var keepaliveFraming: Framing { get set }

    /// Installs the callback that receives every decoded inbound frame.
    func setFrameListener(_ listener: (@Sendable (DumplResponse) -> Void)?)
    /// Starts the reader, writer and keepalive.
    func start()
    /// Queues already-encoded bytes for transmission.
    @discardableResult func write(_ bytes: [UInt8]) -> Bool
    /// Tears the link down.
    func close()
}

/// What came back up the link.
///
/// Bytes arriving while no frame decodes is the signal that matters: it means
/// the channel is alive and the framing assumption is wrong, which reads
/// identically to "the aircraft ignored us" if you only count responses.
struct RxStats: Sendable {
    var bytes = 0
    var framesDecoded = 0
    /// Bytes handed to `write`, and bytes the stream actually took. A gap
    /// between them is the difference between "the aircraft ignored us" and
    /// "we never spoke", which no response count can tell apart.
    var bytesQueued = 0
    var bytesWritten = 0
    var pumps = 0
    /// Framing actually observed on the way in.
    var envelopes = 0
    var bareFrames = 0
    var skippedBytes = 0
    /// First bytes seen on the link, kept for a hex dump. The wire format is
    /// readable straight off this.
    var preview: [UInt8] = []

    var previewHex: String {
        preview.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// Small lock-guarded box, used to share state across the transport threads.
final class Protected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

/// The keepalive pair the controller expects every 2.5 seconds.
///
/// Without these the RCLink session is dropped mid-sequence, which reads in the
/// log exactly like a rejected FCC write.
enum Keepalive {
    static let intervalSeconds: TimeInterval = 2.5
    static let payload: [UInt8] = [0x01, 0x01, 0x00, 0xFF, 0xFF, 0x20, 0x00, 0x00]

    /// Builds the two keepalive frames, already encoded for the wire.
    static func frames(framing: Framing, route: [UInt8]) -> [[UInt8]] {
        [0x06, 0x0E].map { dst in
            let frame = DumplBuilder.buildFrame(
                DumplFrame(sender: 0x02, cmdType: 0x40, cmdSet: 0x06, cmdId: 0x77, dst: dst, payload: payload)
            )
            return RCLink.encode(frame, framing: framing, route: route)
        }
    }
}

/// The 2-frame bootstrap handshake sent immediately after the link opens.
///
/// Frame 1 goes to component 0x1F, frame 2 broadcasts to 0x00. The controller
/// ignores every later command until it has seen both.
enum Bootstrap {
    static let payload: [UInt8] = [0x00, 0x00, 0x01]

    static func frames(framing: Framing, route: [UInt8] = RCLink.defaultRoute) -> [[UInt8]] {
        [0x1F, 0x00].map { dst in
            let frame = DumplBuilder.buildFrame(
                DumplFrame(sender: 0x02, cmdType: 0x40, cmdSet: 0x00, cmdId: 0x00, dst: dst, payload: payload)
            )
            return RCLink.encode(frame, framing: framing, route: route)
        }
    }
}
