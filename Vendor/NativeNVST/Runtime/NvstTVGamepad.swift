import Foundation
import GameController

/// Polls the primary extended gamepad without changing any other controller's input handlers.
@MainActor
final class NvstTVGamepad {
    private let bundle: NvstTVBundle
    private let startedAt: UInt64
    private var task: Task<Void, Never>?
    private var sequence: UInt16 = 0
    private var wasConnected = false

    init(bundle: NvstTVBundle, startedAt: UInt64) {
        self.bundle = bundle
        self.startedAt = startedAt
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    deinit {
        task?.cancel()
    }

    func stop() {
        task?.cancel()
        task = nil
        if wasConnected {
            send(nil)
            wasConnected = false
        }
    }

    private func poll() {
        let pad = GCController.controllers().lazy.compactMap(\.extendedGamepad).first
        guard pad != nil || wasConnected else { return }
        wasConnected = pad != nil
        send(pad)
    }

    private func send(_ pad: GCExtendedGamepad?) {
        sequence &+= 1
        let timestamp = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000
        let buttonMask = pad.map(Self.buttons) ?? 0
        bundle.sendGamepad(NvstGamepadPacket(
            sequence: sequence, timestampMicroseconds: timestamp, buttons: buttonMask,
            leftTrigger: NvstGamepadPacket.trigger(pad?.leftTrigger.value ?? 0),
            rightTrigger: NvstGamepadPacket.trigger(pad?.rightTrigger.value ?? 0),
            leftStickX: NvstGamepadPacket.axis(pad?.leftThumbstick.xAxis.value ?? 0),
            leftStickY: NvstGamepadPacket.axis(pad?.leftThumbstick.yAxis.value ?? 0),
            rightStickX: NvstGamepadPacket.axis(pad?.rightThumbstick.xAxis.value ?? 0),
            rightStickY: NvstGamepadPacket.axis(pad?.rightThumbstick.yAxis.value ?? 0),
            connectedBitmap: pad == nil ? 0 : NvstGamepadPacket.connectedBitmap
        ))
    }

    private static func buttons(_ pad: GCExtendedGamepad) -> UInt16 {
        typealias Button = NvstGamepadPacket.Button
        let mapping: [(GCControllerButtonInput?, UInt16)] = [
            (pad.dpad.up, Button.dPadUp), (pad.dpad.down, Button.dPadDown),
            (pad.dpad.left, Button.dPadLeft), (pad.dpad.right, Button.dPadRight),
            (pad.buttonA, Button.a), (pad.buttonB, Button.b), (pad.buttonX, Button.x), (pad.buttonY, Button.y),
            (pad.buttonMenu, Button.start), (pad.buttonOptions, Button.back), (pad.buttonHome, Button.guide),
            (pad.leftShoulder, Button.leftShoulder), (pad.rightShoulder, Button.rightShoulder),
            (pad.leftThumbstickButton, Button.leftThumb), (pad.rightThumbstickButton, Button.rightThumb),
        ]
        return mapping.reduce(0) { $1.0?.isPressed == true ? $0 | $1.1 : $0 }
    }
}
