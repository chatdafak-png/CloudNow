import Foundation

/// The stereo audio and controller channels of a native tvOS session.
final class NvstTVBundle: @unchecked Sendable {
    private static let controlChannel: UInt16 = 0
    private static let inputChannel: UInt16 = 10
    private let worker = DispatchQueue(label: "com.owenselles.CloudNow.nvst-bundle")
    private let transport: NvstDtlsTransport
    private let reportFailure: @Sendable (String) -> Void
    private let framesReceived: @Sendable () -> UInt32
    private var association: NvstSctpAssociation?
    private var audioPipeline: NvstAudioReceivePipeline?
    private var audioOutput: NvstTVAudioOutput?
    private var keepAlive: DispatchSourceTimer?
    private var hasInputVersion = false
    private var inputEnabled = false
    private var registeredBitmap: UInt16?
    private var closed = false

    var port: UInt16 { transport.localPort }
    var localAddress: String? { transport.localAddress }

    init(
        handoff: NVSTVideoHandoff, identity: NvstDtlsIdentity,
        framesReceived: @escaping @Sendable () -> UInt32,
        reportFailure: @escaping @Sendable (String) -> Void
    ) throws {
        guard let ice = handoff.iceCredentials, let fingerprint = ice.remoteDTLSFingerprint, !fingerprint.isEmpty else {
            throw BundleError.missingPeerFingerprint
        }
        self.reportFailure = reportFailure
        self.framesReceived = framesReceived
        let handshake = try NvstDtlsHandshake(role: .client, identity: identity, expectedPeerFingerprint: fingerprint)
        let reservation = try NvstUdpPortReservation.bindEphemeral()
        let transport = try NvstDtlsTransport(
            handshake: handshake, descriptor: reservation.takeDescriptor(),
            localAddress: NvstRoutedIPv4.discover(), localPort: reservation.port,
            peerAddress: handoff.videoPeerIP, peerPort: handoff.videoPeerPort
        )
        self.transport = transport
        transport.natt = NvstDtlsTransport.NattIdentity(
            remoteUfrag: ice.remoteUsernameFragment, localUfrag: ice.localUsernameFragment,
            integrityKey: Data(ice.remotePassword.utf8)
        )
        transport.onSecureAudio = { [weak self] packet in
            self?.worker.async { [weak self] in self?.audioPipeline?.ingest(packet) }
        }
        transport.onApplicationData = { [weak self] packet in
            self?.worker.async { [weak self] in self?.receiveApplicationData(packet) }
        }
        transport.onHandshakeComplete = { [weak self] in
            self?.worker.async { [weak self] in self?.startChannels() }
        }
        transport.onHandshakeFailure = { [weak self] error in
            let description = error.localizedDescription
            self?.worker.async { [weak self] in self?.fail(description) }
        }
        transport.start()
    }

    deinit {
        keepAlive?.cancel()
        association?.close()
        transport.close()
    }

    func stop() {
        worker.async { [self] in close() }
    }

    func sendGamepad(_ packet: NvstGamepadPacket) {
        worker.async { [weak self] in self?.writeGamepad(packet) }
    }

    private func startChannels() {
        guard !closed, association == nil else { return }
        do {
            let (keys, profile) = try transport.exportedKeys()
            let inbound = NvstAudioSrtpDirection.directions(from: keys).inbound
            let srtp = try NvstAudioSrtp(masterKey: inbound.key, masterSalt: inbound.salt, profile: profile)
            let pipeline = try NvstAudioReceivePipeline(srtp: srtp, layout: .stereo)
            audioOutput = try NvstTVAudioOutput(pipeline: pipeline)
            audioPipeline = pipeline
            let transport = transport
            let sctp = try NvstSctpAssociation { [weak transport] packet in
                try? transport?.sendEncrypted(packet)
            }
            sctp.onInboundMessage = { [weak self] message in
                guard NvstRemoteInput.protocolVersion(in: message.payload) != nil else { return }
                self?.worker.async { [weak self] in self?.hasInputVersion = true }
            }
            association = sctp
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func receiveApplicationData(_ packet: Data) {
        guard let association else { return }
        association.feedInbound(packet)
        _ = association.drainInbound()
        if association.isEstablished {
            try? association.openChannels()
        }
        if association.isChannelOpen(Self.controlChannel), keepAlive == nil {
            let timer = DispatchSource.makeTimerSource(queue: worker)
            timer.schedule(deadline: .now(), repeating: .seconds(Int(NvstControlCommand.pingBackIntervalSeconds)))
            timer.setEventHandler { [weak self] in self?.sendKeepAlive() }
            keepAlive = timer
            timer.resume()
        }
    }

    private func sendKeepAlive() {
        _ = sendControl(.pingBackAck(streamValue: framesReceived()))
    }

    private func writeGamepad(_ packet: NvstGamepadPacket) {
        guard hasInputVersion, let association, association.isChannelOpen(Self.inputChannel) else { return }
        if !inputEnabled {
            guard sendControl(NvstInputActivation.enableInput(counter: 1, isEnabled: false)),
                  registerGamepads(packet), sendControl(.windowStateChange()), sendControl(.systemStateChange()),
                  sendControl(NvstInputActivation.enableInput(counter: 2)) else { return }
            inputEnabled = true
        } else if registeredBitmap != packet.connectedBitmap, !registerGamepads(packet) {
            return
        }
        guard let data = try? packet.command.encoded else { return }
        try? association.send(data, streamID: Self.inputChannel, ppid: NvstSctpAssociation.PPID.binary)
    }

    private func registerGamepads(_ packet: NvstGamepadPacket) -> Bool {
        let command = NvstInputActivation.deviceDescriptor(
            timestampMicroseconds: packet.timestampMicroseconds, connectedBitmap: packet.connectedBitmap
        )
        guard sendControl(command) else { return false }
        registeredBitmap = packet.connectedBitmap
        return true
    }

    private func sendControl(_ command: NvstControlCommand) -> Bool {
        guard let association, let data = try? command.encoded else { return false }
        return (try? association.send(data, streamID: Self.controlChannel, ppid: NvstSctpAssociation.PPID.binary)) != nil
    }

    private func fail(_ description: String) {
        guard !closed else { return }
        close()
        reportFailure(description)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        keepAlive?.cancel()
        keepAlive = nil
        association?.close()
        association = nil
        audioOutput = nil
        audioPipeline = nil
        transport.close()
    }

    private enum BundleError: Error {
        case missingPeerFingerprint
    }
}
