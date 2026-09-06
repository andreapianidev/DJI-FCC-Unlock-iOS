import ExternalAccessory
import Foundation

/// Everything the UI needs to know about a discovered MFi accessory.
struct AccessoryInfo: Sendable, Identifiable, Equatable {
    var id: Int
    var name: String
    var manufacturer: String
    var modelNumber: String
    var serialNumber: String
    var firmwareRevision: String
    var hardwareRevision: String
    var protocolStrings: [String]

    /// Protocol strings the accessory advertises that this build is allowed to
    /// open, meaning they are listed in `UISupportedExternalAccessoryProtocols`.
    var openableProtocols: [String] {
        let declared = Set(ExternalAccessoryTransport.declaredProtocols)
        return protocolStrings.filter { declared.contains($0) }
    }

    /// Protocol strings the accessory advertises that this build cannot open
    /// because they are missing from Info.plist. Worth showing: if the command
    /// channel is one of these, adding it and rebuilding is the whole fix.
    var undeclaredProtocols: [String] {
        let declared = Set(ExternalAccessoryTransport.declaredProtocols)
        return protocolStrings.filter { !declared.contains($0) }
    }

    var looksLikeDji: Bool {
        manufacturer.uppercased().contains("DJI")
            || protocolStrings.contains { $0.lowercased().hasPrefix("com.dji") }
    }

    init(accessory: EAAccessory) {
        id = Int(accessory.connectionID)
        name = accessory.name
        manufacturer = accessory.manufacturer
        modelNumber = accessory.modelNumber
        serialNumber = accessory.serialNumber
        firmwareRevision = accessory.firmwareRevision
        hardwareRevision = accessory.hardwareRevision
        protocolStrings = accessory.protocolStrings
    }
}

enum TransportError: LocalizedError {
    case noAccessory
    case noOpenableProtocol(advertised: [String])
    case sessionRefused(String)
    case streamsUnavailable

    var errorDescription: String? {
        switch self {
        case .noAccessory:
            return "No MFi accessory is connected. Plug the phone into the TOP USB port of the controller."
        case .noOpenableProtocol(let advertised):
            if advertised.isEmpty {
                return "The accessory advertises no protocols this app can open."
            }
            return "None of the accessory's protocols are declared in Info.plist. It advertises: \(advertised.joined(separator: ", "))"
        case .sessionRefused(let proto):
            return "iOS refused a session for \(proto). Close DJI Fly and try again."
        case .streamsUnavailable:
            return "The session opened but gave no streams."
        }
    }
}

/// MFi transport, the iOS counterpart of the Android AOA accessory pipe.
///
/// The Android build is the USB accessory and the controller is the USB host.
/// iOS has no equivalent, so the same bytes travel over an `EASession`: the
/// controller is an MFi accessory, the app opens a session on one of its
/// protocol strings and gets a pair of streams. The DUMPL frames, the RCLink
/// envelope, the bootstrap handshake and the keepalives are all unchanged.
///
/// Both streams are scheduled on a private run loop thread and only ever
/// touched from it. `write` appends to a buffer from any thread and pokes that
/// thread, which is the pattern Apple's own EADemo uses.
final class ExternalAccessoryTransport: NSObject, DumplTransport, StreamDelegate, @unchecked Sendable {

    // MARK: Discovery

    /// Protocol strings this build is allowed to open, from Info.plist.
    static var declaredProtocols: [String] {
        Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols") as? [String] ?? []
    }

    /// Every accessory iOS currently reports as connected.
    @MainActor
    static func connectedAccessories() -> [AccessoryInfo] {
        EAAccessoryManager.shared().connectedAccessories.map(AccessoryInfo.init(accessory:))
    }

    /// The accessory most likely to be a DJI controller, preferring a DJI
    /// manufacturer string over a bare `com.dji.*` protocol match.
    @MainActor
    static func preferredAccessory() -> EAAccessory? {
        let all = EAAccessoryManager.shared().connectedAccessories
        if let dji = all.first(where: { $0.manufacturer.uppercased().contains("DJI") }) { return dji }
        return all.first { accessory in
            accessory.protocolStrings.contains { $0.lowercased().hasPrefix("com.dji") }
        }
    }

    /// Ranks the protocols worth trying for command traffic.
    ///
    /// Video carries the camera feed and is listed last: a session on it will
    /// open, but the command parser is not on the other end of it.
    static func rankedProtocols(for accessory: EAAccessory) -> [String] {
        let declared = Set(declaredProtocols)
        let advertised = accessory.protocolStrings.filter { declared.contains($0) }
        // Explicit order rather than a heuristic. logiclink first because the
        // name says command channel and it is the one the public SDK list
        // never mentions; video last because a session on it opens and then
        // carries the camera feed, with no command parser behind it.
        let priority = ["com.dji.logiclink", "com.dji.protocol", "com.dji.common", "com.dji.fly", "com.dji.video"]
        func rank(_ proto: String) -> Int {
            if let index = priority.firstIndex(of: proto) { return index }
            let p = proto.lowercased()
            if p.contains("video") { return priority.count + 1 }
            return priority.count
        }
        return advertised.sorted { rank($0) < rank($1) }
    }

    // MARK: Identity

    let name: String
    let kind = "MFi-EA"
    let protocolString: String
    let accessoryInfo: AccessoryInfo

    // MARK: State

    private let session: EASession
    private let running = Protected(false)
    private let outBuffer = Protected([UInt8]())
    private let route = Protected(RCLink.defaultRoute)
    private let serial = Protected("")
    private let listener = Protected<(@Sendable (DumplResponse) -> Void)?>(nil)
    private let framing = Protected(Framing.rclink)
    private let asciiWindow = Protected("")

    private var parser = DumplStreamParser()
    private var ioThread: Thread?
    private var keepaliveTimer: Timer?

    var isOpen: Bool { running.value }
    var currentRoute: [UInt8] { route.value }
    var detectedSerial: String { serial.value }

    var keepaliveFraming: Framing {
        get { framing.value }
        set { framing.value = newValue }
    }

    // MARK: Lifecycle

    /// Opens a session on the first protocol the accessory and this build agree on.
    init(accessory: EAAccessory, preferredProtocol: String? = nil) throws {
        let candidates: [String]
        if let preferredProtocol, accessory.protocolStrings.contains(preferredProtocol) {
            candidates = [preferredProtocol]
        } else {
            candidates = Self.rankedProtocols(for: accessory)
        }
        guard !candidates.isEmpty else {
            throw TransportError.noOpenableProtocol(advertised: accessory.protocolStrings)
        }

        var opened: (EASession, String)?
        for candidate in candidates {
            let maybe: EASession? = EASession(accessory: accessory, forProtocol: candidate)
            if let session = maybe, session.inputStream != nil, session.outputStream != nil {
                opened = (session, candidate)
                break
            }
        }
        guard let (session, candidate) = opened else {
            throw TransportError.sessionRefused(candidates.joined(separator: ", "))
        }

        self.session = session
        self.protocolString = candidate
        self.accessoryInfo = AccessoryInfo(accessory: accessory)
        let model = accessory.modelNumber.isEmpty ? accessory.name : accessory.modelNumber
        self.name = "MFi: \(accessory.manufacturer)/\(model) [\(candidate)]"
        super.init()
    }

    func setFrameListener(_ listener: (@Sendable (DumplResponse) -> Void)?) {
        self.listener.value = listener
    }

    func start() {
        guard !running.value else { return }
        running.value = true
        let thread = Thread(target: self, selector: #selector(ioThreadMain), object: nil)
        thread.name = "FreeFCC-EA-IO"
        thread.qualityOfService = .userInitiated
        ioThread = thread
        thread.start()
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        guard running.value, !bytes.isEmpty else { return false }
        outBuffer.withLock { $0.append(contentsOf: bytes) }
        if let ioThread, !ioThread.isFinished {
            perform(#selector(pump), on: ioThread, with: nil, waitUntilDone: false)
            return true
        }
        return false
    }

    func close() {
        guard running.value else { return }
        running.value = false
        if let ioThread, !ioThread.isFinished {
            perform(#selector(teardown), on: ioThread, with: nil, waitUntilDone: false)
        } else {
            teardown()
        }
    }

    // MARK: IO thread

    @objc private func ioThreadMain() {
        let runLoop = RunLoop.current
        runLoop.add(Port(), forMode: .default)

        guard let input = session.inputStream, let output = session.outputStream else {
            running.value = false
            return
        }

        input.delegate = self
        output.delegate = self
        input.schedule(in: runLoop, forMode: .default)
        output.schedule(in: runLoop, forMode: .default)
        input.open()
        output.open()

        // The controller wants the first keepalive one interval in, not the
        // instant the link comes up, so the timer starts fired-forward.
        let timer = Timer(
            fireAt: Date(timeIntervalSinceNow: Keepalive.intervalSeconds),
            interval: Keepalive.intervalSeconds,
            target: self,
            selector: #selector(sendKeepalive),
            userInfo: nil,
            repeats: true
        )
        runLoop.add(timer, forMode: .default)
        keepaliveTimer = timer

        while running.value && !Thread.current.isCancelled {
            runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
        }

        teardown()
    }

    @objc private func teardown() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        if let input = session.inputStream {
            input.delegate = nil
            input.close()
            input.remove(from: RunLoop.current, forMode: .default)
        }
        if let output = session.outputStream {
            output.delegate = nil
            output.close()
            output.remove(from: RunLoop.current, forMode: .default)
        }
        running.value = false
        outBuffer.value = []
    }

    @objc private func sendKeepalive() {
        guard running.value else { return }
        for frame in Keepalive.frames(framing: framing.value, route: route.value) {
            outBuffer.withLock { $0.append(contentsOf: frame) }
        }
        pump()
    }

    /// Drains the outbound buffer into the stream, as far as it will take.
    @objc private func pump() {
        guard running.value, let output = session.outputStream else { return }
        while output.hasSpaceAvailable {
            let chunk = outBuffer.withLock { buffer -> [UInt8] in
                buffer.isEmpty ? [] : Array(buffer.prefix(4096))
            }
            if chunk.isEmpty { break }
            let written = chunk.withUnsafeBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return output.write(base, maxLength: chunk.count)
            }
            if written <= 0 { break }
            outBuffer.withLock { $0.removeFirst(written) }
            if written < chunk.count { break }
        }
    }

    // MARK: StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            drainInput()
        case .hasSpaceAvailable:
            pump()
        case .errorOccurred, .endEncountered:
            running.value = false
        default:
            break
        }
    }

    private func drainInput() {
        guard let input = session.inputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let read = input.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            handleInbound(Array(buffer[0..<read]))
            if read < buffer.count { break }
        }
    }

    private func handleInbound(_ bytes: [UInt8]) {
        scanForSerial(bytes)
        let frames = parser.feed(bytes)
        if let seen = parser.lastRoute { route.value = seen }
        guard let sink = listener.value else { return }
        for frame in frames {
            if let response = DumplResponse(frame: frame) {
                sink(response)
            }
        }
    }

    // MARK: Serial sniffing

    private static let serialPattern = try? NSRegularExpression(pattern: "1581[0-9A-Z]{12,18}")
    private static let modelPattern = try? NSRegularExpression(pattern: "W[AM][0-9]{3}")

    /// Aircraft serials and model codes travel as plain ASCII inside the
    /// telemetry stream, so a rolling window over the raw bytes finds them
    /// without having to decode the telemetry itself.
    private func scanForSerial(_ bytes: [UInt8]) {
        guard serial.value.isEmpty else { return }
        let text = String(bytes.map { Character(UnicodeScalar($0)) })
        let window = asciiWindow.withLock { buffer -> String in
            buffer += text
            if buffer.count > 32_768 { buffer.removeFirst(buffer.count - 16_384) }
            return buffer
        }
        let range = NSRange(window.startIndex..<window.endIndex, in: window)
        if let match = Self.serialPattern?.firstMatch(in: window, range: range),
           let found = Range(match.range, in: window) {
            serial.value = String(window[found])
            return
        }
        if let match = Self.modelPattern?.firstMatch(in: window, range: range),
           let found = Range(match.range, in: window) {
            serial.value = String(window[found])
        }
    }
}
