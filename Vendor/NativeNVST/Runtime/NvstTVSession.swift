@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Darwin
import Foundation
import os

/// Owns one native session, including the media sockets, audio engine, and gamepad polling.
@MainActor
public final class NvstTVSession {
    public typealias FrameHandler = @Sendable (CVPixelBuffer, CMTime) -> Void
    private let frameHandler: FrameHandler
    private let failureHandler: @MainActor @Sendable (String) -> Void
    private var control: NvstRtspSession?
    private var reserver: NvstLocalBundleReserver?
    private var bundle: NvstTVBundle?
    private var video: NvstTVVideo?
    private var gamepad: NvstTVGamepad?
    private var startedAt: UInt64 = 0
    private var setupFailure: Error?
    private var generation: UInt64 = 0

    public init(onFrame: @escaping FrameHandler, onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        frameHandler = onFrame
        failureHandler = onFailure
    }

    public func start(sessionID: String, endpoints: [String], width: Int, height: Int, framesPerSecond: Int, codec: String, bitrateKbps: Int) async throws {
        guard reserver == nil else { throw SessionError.alreadyStarted }
        generation &+= 1
        let attempt = generation
        startedAt = DispatchTime.now().uptimeNanoseconds
        let identity = try NvstDtlsIdentity(commonName: "CloudNow")
        let reserver = NvstLocalBundleReserver(dtlsFingerprint: identity.fingerprint) { [weak self] handoff, _, _ in
            await self?.prepareBundle(handoff, identity: identity, attempt: attempt)
        }
        self.reserver = reserver
        let negotiator = NvstRtspNegotiator(reserver: reserver, isDecodable: { !$0.isSurround })
        do {
            let control = try await negotiator.negotiate(
                NvstRtspNegotiationInput(
                    sessionID: sessionID, rtspsEndpoints: endpoints, resolution: "\(width)x\(height)",
                    fps: framesPerSecond, codec: codec, bitrateKbps: bitrateKbps, maximumBitrateKbps: bitrateKbps,
                    audioChannelCount: 2, rtcpOnSctp: false
                ),
                onVideoReady: { [weak self] _ in
                    guard let self else { throw CancellationError() }
                    try await self.prepareVideo(attempt: attempt)
                },
                onAnnounceReady: { [weak self] _ in
                    guard let self else { throw CancellationError() }
                    try await self.beginVideo(attempt: attempt)
                }
            )
            guard generation == attempt, !Task.isCancelled else {
                await control.release("native-cancelled")
                throw CancellationError()
            }
            self.control = control
        } catch {
            if generation == attempt { stop() }
            throw error
        }
    }

    public func stop() {
        generation &+= 1
        gamepad?.stop()
        gamepad = nil
        bundle?.stop()
        bundle = nil
        video?.stop()
        video = nil
        reserver?.release()
        reserver = nil
        setupFailure = nil
        if let control {
            self.control = nil
            Task { await control.release("native-stopped") }
        }
    }

    private func prepareBundle(_ handoff: NVSTVideoHandoff, identity: NvstDtlsIdentity, attempt: UInt64) -> NvstBundleReservation? {
        guard generation == attempt, let reserver else { return nil }
        gamepad?.stop()
        gamepad = nil
        bundle?.stop()
        bundle = nil
        video?.stop()
        video = nil
        setupFailure = nil
        do {
            let video = try NvstTVVideo(handoff: handoff, descriptor: reserver.takeMjolnirDescriptor(), onFrame: frameHandler)
            let bundle = try NvstTVBundle(handoff: handoff, identity: identity, framesReceived: { [weak video] in
                UInt32(truncatingIfNeeded: video?.framesReceived ?? 0)
            }, reportFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.stop()
                    self.failureHandler(message)
                }
            })
            self.video = video
            self.bundle = bundle
            return NvstBundleReservation(
                bundlePort: bundle.port, mjolnirPort: handoff.mjolnirUDPPort ?? handoff.clientUDPPort,
                localAddress: bundle.localAddress, dtlsFingerprint: identity.fingerprint
            )
        } catch {
            setupFailure = error
            return nil
        }
    }

    private func prepareVideo(attempt: UInt64) throws {
        guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
        if let setupFailure { throw setupFailure }
        guard let video, let bundle else { throw SessionError.mediaUnavailable }
        try video.start()
        gamepad = NvstTVGamepad(bundle: bundle, startedAt: startedAt)
    }

    private func beginVideo(attempt: UInt64) throws {
        guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
        video?.beginHolePunch()
    }

    private enum SessionError: LocalizedError {
        case alreadyStarted
        case mediaUnavailable

        var errorDescription: String? {
            switch self {
            case .alreadyStarted: "This native session has already started."
            case .mediaUnavailable: "The server did not negotiate the native audio and controller channels."
            }
        }
    }
}

private final class NvstTVVideo: @unchecked Sendable {
    private let receiver: NvstMjolnirReceiver
    private let decoder: NvstVideoToolboxDecoder
    private var unstartedDescriptor: Int32
    private let decodeQueue = DispatchQueue(label: "com.owenselles.CloudNow.nvst-video", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var stopped = false
        var pending = 0
        var needsKeyframe = false
    }

    init(handoff: NVSTVideoHandoff, descriptor: Int32, onFrame: @escaping NvstTVSession.FrameHandler) throws {
        do {
            receiver = try NvstMjolnirReceiver(handoff: handoff, sendsReceiverReports: true, existingDescriptor: descriptor)
        } catch {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw error
        }
        decoder = NvstVideoToolboxDecoder(codec: handoff.codec)
        unstartedDescriptor = descriptor
        decoder.onPixelBuffer = { [weak self] pixels, timestamp, _ in
            guard self?.state.withLock({ !$0.stopped }) == true else { return }
            onFrame(pixels, timestamp)
        }
        receiver.onAccessUnit = { [weak self] unit in self?.enqueue(unit) }
    }

    var framesReceived: UInt64 { receiver.stats.framesEmitted }

    deinit {
        if unstartedDescriptor >= 0 { Darwin.close(unstartedDescriptor) }
    }

    func start() throws {
        try receiver.start()
        unstartedDescriptor = -1
    }

    func beginHolePunch() { receiver.beginHolePunch() }

    func stop() {
        state.withLock { $0.stopped = true }
        receiver.stop()
        decodeQueue.async { [decoder] in decoder.invalidate() }
    }

    private func enqueue(_ unit: NvstAccessUnit) {
        let decision = state.withLock { state -> (decode: Bool, requestKeyframe: Bool) in
            guard !state.stopped else { return (false, false) }
            if state.pending >= 6 {
                let request = !state.needsKeyframe
                state.needsKeyframe = true
                return (false, request)
            }
            guard !state.needsKeyframe || unit.isKeyframe else { return (false, false) }
            state.needsKeyframe = false
            state.pending += 1
            return (true, false)
        }
        if decision.requestKeyframe { receiver.requestKeyframe() }
        guard decision.decode else { return }
        decodeQueue.async { [weak self] in
            guard let self else { return }
            defer { self.state.withLock { $0.pending -= 1 } }
            guard self.state.withLock({ !$0.stopped }) else { return }
            _ = try? self.decoder.decode(unit)
        }
    }
}
