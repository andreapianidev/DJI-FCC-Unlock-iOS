import ExternalAccessory
import Foundation
import Observation
import UIKit

/// Where the app is in the connect / apply / release cycle.
enum AppStatus: String, Sendable {
    case idle
    case disconnected
    case connecting
    case connected
    case applying
    case fccEnabled
    /// Every frame went out and nothing came back. Not the same as success,
    /// and not the same as failure either.
    case sentUnconfirmed
    case restoring
    case released
}

/// One self-contained attempt at switching the radio: a sender byte and a
/// framing, sent as a complete open-write-close pass of the profile.
struct CommandPath: Sendable, Equatable {
    var sender: Int
    var framing: Framing

    var label: String { String(format: "profile@%02X/%@", sender, framing.label) }
}

/// How much of the path space an apply should sweep.
enum FramingMode: String, Sendable, CaseIterable, Identifiable {
    case sweep
    case rclinkOnly
    case rawOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sweep: return "Sweep both"
        case .rclinkOnly: return "RCLink only"
        case .rawOnly: return "Raw DUML only"
        }
    }

    var framings: [Framing] {
        switch self {
        case .sweep: return [.rclink, .raw]
        case .rclinkOnly: return [.rclink]
        case .rawOnly: return [.raw]
        }
    }
}

/// Owns all app state and the whole business flow.
///
/// The connect side lives on the main actor because ExternalAccessory does.
/// The frame bursts live on a private serial queue and sleep with
/// `Thread.sleep`, because the profile only lands if the 21 frames fit inside
/// the service-mode window that frame 1 opens and frame 21 closes. At 30ms per
/// frame a pass runs about 0.65 seconds; scheduling those delays through the
/// cooperative pool would stretch them, and a stretched burst is exactly the
/// case where every write succeeds and the radio quietly stays on CE.
@MainActor
@Observable
final class FccController {

    // MARK: Tunables

    /// Sender byte from the captured sequence, device 2 index 4. The widest
    /// set of field reports come from builds using this.
    nonisolated static let senderCapture = 0x82
    /// Sender byte on network 0, what bootstrap and keepalive use.
    nonisolated static let senderNet0 = 0x02
    /// Sender byte for the single-command WLM radio switch.
    nonisolated static let senderWlm = 0xA2
    /// How long Connect keeps looking for the accessory.
    nonisolated static let connectTimeout: TimeInterval = 15

    // MARK: Observable state

    private(set) var status: AppStatus = .idle
    private(set) var message = ""
    private(set) var transportName = ""
    private(set) var transportKind = ""
    private(set) var isConnected = false
    private(set) var isFccEnabled = false
    private(set) var isBusy = false
    private(set) var busyProgress: Double = 0
    private(set) var logMessages: [String] = []
    private(set) var accessories: [AccessoryInfo] = []
    private(set) var detectedSerial = ""
    private(set) var winningPath: CommandPath?
    private(set) var profile: Profile?
    private(set) var protocolInUse = ""

    var autoFcc = false {
        didSet {
            guard autoFcc != oldValue else { return }
            defaults.set(autoFcc, forKey: Keys.autoFcc)
            log(autoFcc ? "Auto-FCC enabled" : "Auto-FCC disabled")
        }
    }

    /// Which MFi protocol to open, empty meaning let the ranking choose.
    ///
    /// Kept switchable at runtime because the ranking is an educated guess:
    /// logiclink reads like a command channel and video certainly is not one,
    /// but only the response counts settle it, and finding out should not
    /// cost a rebuild.
    var preferredProtocol: String = "" {
        didSet {
            guard preferredProtocol != oldValue else { return }
            defaults.set(preferredProtocol, forKey: Keys.preferredProtocol)
            log(preferredProtocol.isEmpty ? "Protocol set to auto" : "Protocol pinned to \(preferredProtocol)")
        }
    }

    var framingMode: FramingMode = .sweep {
        didSet {
            guard framingMode != oldValue else { return }
            defaults.set(framingMode.rawValue, forKey: Keys.framingMode)
            log("Framing set to \(framingMode.label)")
        }
    }

    // MARK: Private state

    private enum Keys {
        static let autoFcc = "auto_fcc"
        static let framingMode = "framing_mode"
        static let preferredProtocol = "preferred_protocol"
    }

    private let defaults = UserDefaults.standard
    private let engineQueue = DispatchQueue(label: "com.andreapiani.freefcc.engine", qos: .userInitiated)

    /// Shared with the engine queue, so it must not be plain stored state.
    private let transportBox = Protected<(any DumplTransport)?>(nil)
    private let ackKeys = Protected(Set<Int>())
    private let ackHits = Protected(0)
    private let preferredPath = Protected(CommandPath(sender: FccController.senderCapture, framing: .rclink))
    private let repeatCancelled = Protected(true)
    /// Interfaces present before the cable went in, so the diff after it does
    /// is unambiguous.
    private let baselineInterfaces = Protected(Set<String>())
    /// Every inbound frame tallied by sender, destination and command, so the
    /// real conversation on the link can be read rather than guessed at.
    private let frameCensus = Protected([Int: Int]())

    private var repeatTimer: DispatchSourceTimer?
    private var serialPollTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() {
        autoFcc = defaults.bool(forKey: Keys.autoFcc)
        if let raw = defaults.string(forKey: Keys.framingMode), let mode = FramingMode(rawValue: raw) {
            framingMode = mode
        }
        preferredProtocol = defaults.string(forKey: Keys.preferredProtocol) ?? ""
        DiagnosticLog.shared.startSession(header: [
            "FreeFCC iOS 1.0 build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")",
            "Device \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)",
            "Started \(ISO8601DateFormatter().string(from: Date()))",
            "Declared protocols: \(ExternalAccessoryTransport.declaredProtocols.joined(separator: ", "))"
        ])
        EAAccessoryManager.shared().registerForLocalNotifications()
        baselineInterfaces.value = Set(NetworkProbe.interfaces().map(\.summary))
        loadProfile()
        refreshAccessories()
        status = .disconnected
        message = "Not connected."

        if autoFcc {
            log("Auto-FCC enabled, connecting and applying")
            Task { await autoConnectAndApply() }
        }
    }

    private func loadProfile() {
        do {
            profile = try ProfileLoader.load(ProfileLoader.fccProfileName)
        } catch {
            log("Failed to load FCC profile: \(error.localizedDescription)")
        }
    }

    /// Re-reads the accessory list. Cheap, and the connect screen calls it on
    /// every EA connect and disconnect notification.
    func refreshAccessories() {
        let found = ExternalAccessoryTransport.connectedAccessories()
        let changed = found != accessories
        accessories = found
        guard changed else { return }
        if found.isEmpty {
            log("No MFi accessory visible to this app (0 of any manufacturer)")
        } else {
            for accessory in found {
                log("Accessory: \(accessory.manufacturer) \(accessory.modelNumber.isEmpty ? accessory.name : accessory.modelNumber)")
                log("  protocols: \(accessory.protocolStrings.joined(separator: ", "))")
                if !accessory.undeclaredProtocols.isEmpty {
                    log("  not declared in Info.plist: \(accessory.undeclaredProtocols.joined(separator: ", "))")
                }
            }
        }
    }

    /// Called when iOS reports the accessory went away under us.
    func accessoryDisconnected() {
        refreshAccessories()
        guard isConnected else { return }
        stopRepeat()
        transportBox.value?.close()
        transportBox.value = nil
        isConnected = false
        status = .disconnected
        message = "The accessory was unplugged."
        log("Accessory disconnected")
    }

    // MARK: Connect

    func connect() {
        guard !isConnected else { return }
        Task { await connectFlow(announce: true) }
    }

    private func autoConnectAndApply() async {
        try? await Task.sleep(for: .seconds(1))
        guard await connectFlow(announce: false) else { return }
        try? await Task.sleep(for: .milliseconds(500))
        enableFcc()
    }

    @discardableResult
    private func connectFlow(announce: Bool) async -> Bool {
        status = .connecting
        message = "Connecting to the controller..."
        if announce {
            log("Connecting to the controller...")
            log("Close DJI Fly and plug the phone into the TOP USB port.")
        }

        let deadline = Date().addingTimeInterval(Self.connectTimeout)
        var warned = false

        while Date() < deadline {
            refreshAccessories()
            if let accessory = ExternalAccessoryTransport.preferredAccessory() {
                do {
                    log("Accessory advertises: \(accessory.protocolStrings.joined(separator: ", "))")
                    let transport = try ExternalAccessoryTransport(
                        accessory: accessory,
                        preferredProtocol: preferredProtocol.isEmpty ? nil : preferredProtocol
                    )
                    transport.keepaliveFraming = preferredPath.value.framing
                    transport.setFrameListener { [weak self] response in
                        self?.handleResponseOffMain(response)
                    }
                    transport.start()
                    transportBox.value = transport
                    transportName = transport.name
                    transportKind = transport.kind
                    protocolInUse = transport.protocolString
                    isConnected = true
                    status = .connected
                    message = "Connected. Ready to apply FCC."
                    log("Connected over \(transport.protocolString)")
                    sendBootstrap()
                    log("Bootstrap handshake sent")
                    startSerialPoll()
                    if isFccEnabled {
                        log("Resuming FCC repeat")
                        startRepeat()
                    }
                    return true
                } catch {
                    log(error.localizedDescription)
                    status = .disconnected
                    message = error.localizedDescription
                    isConnected = false
                    return false
                }
            }

            if !warned {
                warned = true
                log("No accessory yet, retrying for \(Int(Self.connectTimeout))s")
                log("If DJI Fly is holding the link, close it now")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        status = .disconnected
        isConnected = false
        message = "Controller not found. Close DJI Fly, plug into the TOP USB port, then tap Connect."
        log("Connection failed, no DJI accessory detected")
        return false
    }

    /// Sends the 2-frame handshake that unlocks the command session.
    private func sendBootstrap() {
        guard let transport = transportBox.value else { return }
        for frame in Bootstrap.frames(framing: preferredPath.value.framing) {
            transport.write(frame)
        }
    }

    private func startSerialPoll() {
        serialPollTask?.cancel()
        serialPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let found = self.transportBox.value?.detectedSerial ?? ""
                if !found.isEmpty, found != self.detectedSerial {
                    self.detectedSerial = found
                    self.log("Aircraft detected: \(found)")
                }
                if !self.isConnected { return }
            }
        }
    }

    // MARK: Apply

    func enableFcc() {
        guard requireConnection() else { return }
        guard let profile else {
            log("FCC profile is missing from the bundle")
            return
        }
        status = .applying
        isBusy = true
        busyProgress = 0
        message = "Enabling FCC mode..."
        log("Enabling FCC mode...")

        let paths = commandPaths()
        engineQueue.async { [weak self] in
            self?.applyFccSync(profile: profile, paths: paths)
        }
    }

    /// The paths one apply sweeps, in the order they are tried.
    private func commandPaths() -> [CommandPath] {
        framingMode.framings.flatMap { framing in
            [Self.senderCapture, Self.senderNet0].map { CommandPath(sender: $0, framing: framing) }
        }
    }

    private nonisolated func applyFccSync(profile: Profile, paths: [CommandPath]) {
        guard let transport = transportBox.value else {
            finishApply(anyWrite: false, acks: 0)
            return
        }

        let framings = Array(Set(paths.map(\.framing)))
        let totalSends = paths.count * profile.rounds * profile.frames.count + framings.count
        let counter = Protected(0)

        postLog("Sweeping \(paths.count) path\(paths.count == 1 ? "" : "s") x \(profile.rounds) rounds @ \(profile.interFrameDelayMs)ms/frame")

        var anyWrite = false
        var best: (path: CommandPath, acks: Int)?

        for path in paths {
            armAckWatch(profile.frames.map { ($0.cmdSet << 8) | $0.cmdId })
            let wrote = sendPass(transport: transport, profile: profile, path: path) {
                let sent = counter.withLock { value -> Int in
                    value += 1
                    return value
                }
                self.postProgress(Double(sent) / Double(totalSends))
            }
            if wrote { anyWrite = true }
            let acks = readAckWatch(windowMs: profile.readWindowMs)
            postLog("\(path.label): \(acks) response\(acks == 1 ? "" : "s")")
            if acks > (best?.acks ?? 0) {
                best = (path, acks)
            }
        }

        // The WLM single-command switch goes last so it can never delay
        // service-mode entry for the profile passes.
        var wlmAcks = 0
        for framing in framings {
            armAckWatch([(0x51 << 8) | 0x04])
            let frame = DumplBuilder.buildFrame(
                DumplFrame(sender: Self.senderWlm, cmdType: 0x40, cmdSet: 0x51, cmdId: 0x04, dst: 0xEE)
            )
            if transport.write(RCLink.encode(frame, framing: framing, route: transport.currentRoute)) {
                anyWrite = true
            }
            let sent = counter.withLock { value -> Int in
                value += 1
                return value
            }
            postProgress(Double(sent) / Double(totalSends))
            let acks = readAckWatch(windowMs: profile.readWindowMs)
            wlmAcks += acks
            postLog("WLM 0x51/04/\(framing.label): \(acks) response\(acks == 1 ? "" : "s")")
        }

        if let best {
            preferredPath.value = best.path
            transport.keepaliveFraming = best.path.framing
            postLog("Controller answered on \(best.path.label), repeat will use that path")
            postWinner(best.path)
        } else if wlmAcks == 0 {
            postLog("No responses on any path. The controller is not relaying to the aircraft, which is not the same as FCC being rejected.")
        }

        let rx = transport.rxStats
        postLog("RX: \(rx.bytes) bytes, \(rx.framesDecoded) frames decoded")
        postLog("TX: \(rx.bytesWritten) of \(rx.bytesQueued) bytes actually written, \(rx.pumps) pumps")
        if rx.bytesWritten < rx.bytesQueued {
            postLog("Backlog of \(rx.bytesQueued - rx.bytesWritten) bytes never left the phone")
        }

        // How the far end frames what it sends is the best available guide to
        // how it expects to be spoken to.
        postLog("Inbound framing: \(rx.envelopes) RCLink envelopes, \(rx.bareFrames) bare frames, \(rx.skippedBytes) bytes skipped resyncing")
        postLog("First bytes on the link:")
        postLog(rx.previewHex)

        let census = frameCensus.value
        let top = census.sorted { $0.value > $1.value }.prefix(15)
        postLog("Inbound frames by kind, \(census.count) distinct:")
        for (key, count) in top {
            postLog(String(
                format: "  %02X->%02X set=%02X id=%02X  x%d",
                (key >> 24) & 0xFF, (key >> 16) & 0xFF, (key >> 8) & 0xFF, key & 0xFF, count
            ))
        }
        if rx.framesDecoded == 0 && rx.bytes > 0 {
            // The link is carrying data the parser cannot make sense of, which
            // is a framing problem, not an aircraft that ignored us. The head
            // of the stream says which framing it actually is.
            postLog("Inbound bytes but no frame decoded. First bytes:")
            postLog(rx.previewHex)
        }
        finishApply(anyWrite: anyWrite, acks: (best?.acks ?? 0) + wlmAcks)
    }

    /// Unlocks the flight controller for parameter writes. Sent once per pass:
    /// sending it before every FLYCONTROLLER frame stretched the burst far
    /// past the service-mode window.
    private nonisolated func sendAssistantUnlock(transport: any DumplTransport, path: CommandPath) {
        let unlock = DumplBuilder.buildFrame(
            DumplFrame(sender: path.sender, cmdType: 0x40, cmdSet: 0x03, cmdId: 0xDF, dst: 0x03, payload: [0x01, 0x00, 0x00, 0x00])
        )
        transport.write(RCLink.encode(unlock, framing: path.framing, route: transport.currentRoute))
        Thread.sleep(forTimeInterval: 0.06)
    }

    /// Sends one self-contained pass: frame 1 opens service mode, frame 21
    /// closes it, everything between has to land inside that window.
    @discardableResult
    private nonisolated func sendPass(
        transport: any DumplTransport,
        profile: Profile,
        path: CommandPath,
        onFrameSent: (() -> Void)? = nil
    ) -> Bool {
        var anyWrite = false
        let route = transport.currentRoute
        sendAssistantUnlock(transport: transport, path: path)
        for _ in 0..<profile.rounds {
            for definition in profile.frames {
                let frame = ProfileLoader.buildFrame(definition, sender: path.sender, cmdType: profile.cmdType)
                if transport.write(RCLink.encode(frame, framing: path.framing, route: route)) {
                    anyWrite = true
                }
                onFrameSent?()
                if profile.interFrameDelay > 0 { Thread.sleep(forTimeInterval: profile.interFrameDelay) }
            }
            if profile.interRoundDelay > 0 { Thread.sleep(forTimeInterval: profile.interRoundDelay) }
        }
        return anyWrite
    }

    // MARK: Response accounting

    private nonisolated func armAckWatch(_ keys: [Int]) {
        ackKeys.value = Set(keys)
        ackHits.value = 0
    }

    private nonisolated func readAckWatch(windowMs: Int) -> Int {
        Thread.sleep(forTimeInterval: max(Double(windowMs), 50) / 1000)
        let hits = ackHits.value
        ackKeys.value = []
        return hits
    }

    /// Runs on the transport's IO thread, so it only touches the boxes.
    private nonisolated func handleResponseOffMain(_ response: DumplResponse) {
        let key = (response.sender << 24) | (response.dst << 16) | (response.cmdSet << 8) | response.cmdId
        frameCensus.withLock { $0[key, default: 0] += 1 }

        // The controller streams telemetry non-stop. Logging every frame buries
        // the useful lines, so only responses to commands we just sent count.
        guard response.isResponse, ackKeys.value.contains(response.ackKey) else { return }
        ackHits.withLock { $0 += 1 }
        let payload = response.payload.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let suffix = payload.isEmpty ? "" : " [\(payload)]"
        postLog(String(
            format: "RSP %02X→%02X seq=%d set=%02X id=%02X%@",
            response.sender, response.dst, response.seq, response.cmdSet, response.cmdId, suffix
        ))
    }

    // MARK: Repeat

    /// Re-sends the winning pass on an interval so the radio goes back to FCC
    /// after something resets it. Two resets get reported: DJI Fly
    /// reconnecting, and the aircraft dropping to CE the moment it sets its
    /// home point on GPS lock. Re-applying is the known remedy for both.
    private func startRepeat() {
        stopRepeat()
        guard let profile else { return }
        repeatCancelled.value = false
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        let interval = Double(profile.repeatIntervalMs) / 1000
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.repeatTick(profile: profile)
        }
        timer.resume()
        repeatTimer = timer
    }

    private nonisolated func repeatTick(profile: Profile) {
        guard !repeatCancelled.value, let transport = transportBox.value, transport.isOpen else { return }
        let path = preferredPath.value
        sendPass(transport: transport, profile: profile, path: path)
        let wlm = DumplBuilder.buildFrame(
            DumplFrame(sender: Self.senderWlm, cmdType: 0x40, cmdSet: 0x51, cmdId: 0x04, dst: 0xEE)
        )
        transport.write(RCLink.encode(wlm, framing: path.framing, route: transport.currentRoute))
    }

    private func stopRepeat() {
        repeatCancelled.value = true
        repeatTimer?.cancel()
        repeatTimer = nil
    }

    // MARK: CE restore

    func disableFcc() {
        guard requireConnection() else { return }
        stopRepeat()
        status = .restoring
        isBusy = true
        busyProgress = 0
        message = "Restoring CE mode..."
        log("Restoring CE mode...")

        let framings = framingMode.framings
        engineQueue.async { [weak self] in
            guard let self else { return }
            do {
                let restore = try ProfileLoader.load(ProfileLoader.ceRestoreProfileName)
                self.restoreSync(profile: restore, framings: framings)
            } catch {
                self.postLog("CE restore failed: \(error.localizedDescription)")
                self.finishRestore(succeeded: false)
            }
        }
    }

    private nonisolated func restoreSync(profile: Profile, framings: [Framing]) {
        guard let transport = transportBox.value else {
            finishRestore(succeeded: false)
            return
        }
        var anyWrite = false
        // Restore on both sender bytes for the same reason apply sweeps both.
        for framing in framings {
            for sender in [profile.sender, Self.senderNet0] {
                for definition in profile.frames {
                    let frame = ProfileLoader.buildFrame(definition, sender: sender, cmdType: profile.cmdType)
                    if transport.write(RCLink.encode(frame, framing: framing, route: transport.currentRoute)) {
                        anyWrite = true
                    }
                    if profile.interFrameDelay > 0 { Thread.sleep(forTimeInterval: profile.interFrameDelay) }
                }
            }
        }
        finishRestore(succeeded: anyWrite)
    }

    // MARK: Release

    /// Closes the session without touching the radio state.
    ///
    /// iOS lets this app keep the session open in the background, so DJI Fly
    /// can usually run alongside it. When it cannot, this hands the link back
    /// without unplugging the cable; the radio keeps whatever region was last
    /// applied.
    func releaseSession() {
        stopRepeat()
        serialPollTask?.cancel()
        serialPollTask = nil
        transportBox.value?.close()
        transportBox.value = nil
        isConnected = false
        isBusy = false
        transportKind = ""
        transportName = ""
        protocolInUse = ""
        status = .released
        message = "Session released. Open DJI Fly now and check the Transmission tab."
        log("Session released, DJI Fly can connect now")
        log("Repeat stopped. If the radio flips back to CE, reconnect and re-apply.")
    }

    // MARK: Helpers

    private func requireConnection() -> Bool {
        if isConnected, transportBox.value != nil { return true }
        log("Connect to the controller first")
        return false
    }

    func clearLog() {
        logMessages = []
    }

    /// Whole log as one block, for the share sheet on the Log tab.
    var logExport: String {
        var lines = ["FreeFCC iOS log"]
        if !transportName.isEmpty { lines.append("Transport: \(transportName)") }
        if !protocolInUse.isEmpty { lines.append("Protocol: \(protocolInUse)") }
        if !detectedSerial.isEmpty { lines.append("Aircraft: \(detectedSerial)") }
        if let winningPath { lines.append("Answered on: \(winningPath.label)") }
        for accessory in accessories {
            lines.append("Accessory: \(accessory.manufacturer) \(accessory.modelNumber) fw \(accessory.firmwareRevision)")
            lines.append("Protocols: \(accessory.protocolStrings.joined(separator: ", "))")
        }
        lines.append("")
        lines.append(contentsOf: logMessages.reversed())
        return lines.joined(separator: "\n")
    }

    // MARK: Diagnostics

    /// Reports what the phone can actually see, which is the question when
    /// Connect finds nothing.
    ///
    /// Two channels are checked, because iOS hides the first one from us
    /// unless we guessed right. `connectedAccessories` only ever returns
    /// accessories advertising a protocol string this build declared in
    /// Info.plist, so an empty list means either no MFi accessory at all or
    /// one speaking a string we did not declare, and nothing distinguishes
    /// those from inside the app. A new network interface, on the other hand,
    /// is visible whatever it calls itself: if the controller comes up as a
    /// USB network gadget the way the smart controllers do, it shows up here
    /// and needs no MFi programme membership to talk to.
    func runDiagnostics() {
        log("Diagnostics")
        log("  declared protocols: \(ExternalAccessoryTransport.declaredProtocols.joined(separator: ", "))")

        let accessories = ExternalAccessoryTransport.connectedAccessories()
        log("  MFi accessories visible: \(accessories.count)")
        for accessory in accessories {
            log("  - \(accessory.manufacturer) \(accessory.name) model \(accessory.modelNumber) fw \(accessory.firmwareRevision)")
            log("    protocols: \(accessory.protocolStrings.joined(separator: ", "))")
        }

        let interfaces = NetworkProbe.interfaces()
        let baseline = baselineInterfaces.value
        let fresh = interfaces.filter { !baseline.contains($0.summary) }
        log("  network interfaces: \(interfaces.count), new since launch: \(fresh.count)")
        for interface in interfaces where !interface.isLoopback {
            let marker = baseline.contains(interface.summary) ? " " : "*"
            log("  \(marker) \(interface.summary)")
        }

        let candidates = fresh.filter(\.isCandidate)
        guard !candidates.isEmpty else {
            log("  no new usable interface, so no USB network gadget appeared")
            return
        }
        log("  probing TCP \(NetworkProbe.djiCommandPort) on the new interfaces")
        engineQueue.async { [weak self] in
            for interface in candidates {
                for peer in NetworkProbe.candidatePeers(for: interface) {
                    let reachable = NetworkProbe.canReach(host: peer, port: NetworkProbe.djiCommandPort)
                    self?.postLog("  \(peer):\(NetworkProbe.djiCommandPort) \(reachable ? "OPEN" : "closed")")
                }
            }
            self?.postLog("  probe done")
        }
    }

    /// Hunts for a destination that answers the one command that matters.
    ///
    /// On an RC-N3 the profile splits cleanly in two: every peripheral write
    /// is acknowledged, and the frames that actually move the region are not.
    /// RADIO 6/114 sets the region and commits it, and GENERAL set 0 carries
    /// the country codes; those four frames draw no response while the
    /// fourteen around them do. A command that is simply refused would still
    /// answer, so silence points at the frame never reaching a component that
    /// handles it, which makes the destination byte the thing to vary.
    ///
    /// The destinations come from the census of who is actually talking on
    /// this link, plus the ones the profile already names. Both request types
    /// are tried, since a component that ignores a fire-and-forget request
    /// may still answer one that demands an acknowledgement.
    func probeRegionCommand() {
        guard requireConnection() else { return }
        log("Probing RADIO 6/114 across destinations")
        let destinations = [0x01, 0x02, 0x03, 0x04, 0x06, 0x07, 0x08, 0x09,
                            0x0A, 0x0E, 0x0F, 0x12, 0x1F, 0x20, 0x27, 0x28,
                            0x92, 0xE9, 0xEE]
        let payload: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
        engineQueue.async { [weak self] in
            guard let self, let transport = self.transportBox.value else { return }
            var hits = [String]()
            for cmdType in [0x20, 0x40] {
                for dst in destinations {
                    self.armAckWatch([(0x06 << 8) | 114])
                    let frame = DumplBuilder.buildFrame(
                        DumplFrame(sender: Self.senderNet0, cmdType: cmdType,
                                   cmdSet: 0x06, cmdId: 114, dst: dst, payload: payload)
                    )
                    transport.write(RCLink.encode(frame, framing: .rclink, route: transport.currentRoute))
                    let acks = self.readAckWatch(windowMs: 120)
                    if acks > 0 {
                        let line = String(format: "  dst %02X type %02X: %d responses", dst, cmdType, acks)
                        hits.append(line)
                        self.postLog(line)
                    }
                }
            }
            if hits.isEmpty {
                self.postLog("  no destination answered 6/114 on either request type")
                self.postLog("  the region command is not reaching anything that handles it")
            } else {
                self.postLog("  probe done, \(hits.count) destination(s) answered")
            }
        }
    }

    private func log(_ text: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        let entry = "[\(stamp)] \(text)"
        logMessages.insert(entry, at: 0)
        if logMessages.count > 200 { logMessages.removeLast(logMessages.count - 200) }
        // Also to the unified log and the container file, so a run on real
        // hardware can be read back after the fact instead of retyped.
        DiagnosticLog.shared.append(entry)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: Hops back to the main actor

    private nonisolated func postLog(_ text: String) {
        Task { @MainActor [weak self] in self?.log(text) }
    }

    private nonisolated func postProgress(_ value: Double) {
        Task { @MainActor [weak self] in self?.busyProgress = min(max(value, 0), 1) }
    }

    private nonisolated func postWinner(_ path: CommandPath) {
        Task { @MainActor [weak self] in self?.winningPath = path }
    }

    /// Reports the outcome without inflating it.
    ///
    /// Writes reaching the transport is not the aircraft accepting anything.
    /// Treating the two as the same is how an app ends up showing a green FCC
    /// badge over a radio that never left CE, so a silent sweep gets its own
    /// state rather than borrowing the successful one.
    private nonisolated func finishApply(anyWrite: Bool, acks: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBusy = false
            self.busyProgress = acks > 0 ? 1 : 0
            if acks > 0 {
                self.status = .fccEnabled
                self.isFccEnabled = true
                self.message = "FCC applied and the controller answered. Check Transmission in DJI Fly."
                self.log("FCC applied, starting repeat to hold it")
                self.startRepeat()
            } else if anyWrite {
                self.status = .sentUnconfirmed
                self.isFccEnabled = false
                self.message = "Sequence sent, nothing answered. Check Transmission in DJI Fly: if it reads FCC anyway, tap Hold."
                self.log("Sent with no response on any path, not claiming FCC")
            } else {
                self.status = .connected
                self.message = "FCC apply failed. Is the aircraft powered on and linked?"
                self.log("FCC apply failed, no frame reached the transport")
            }
        }
    }

    /// Starts the re-apply loop on the user's say-so, for the case where the
    /// radio took the sequence without answering it.
    func holdFcc() {
        guard requireConnection() else { return }
        isFccEnabled = true
        status = .fccEnabled
        message = "Holding FCC by re-applying on an interval."
        log("Hold requested, starting repeat despite no responses")
        startRepeat()
    }

    private nonisolated func finishRestore(succeeded: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBusy = false
            self.status = .connected
            if succeeded {
                self.isFccEnabled = false
                self.message = "CE mode restored"
                self.log("CE mode restored")
            } else {
                self.message = "CE restore failed"
                self.log("CE restore failed")
            }
        }
    }
}
