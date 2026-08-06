import AVFoundation
import CoreGraphics

@MainActor
final class Presentation {
    var activeOverride: Bool?

    var active: Bool {
        activeOverride ?? (Presentation.mirroring() || Presentation.cameraInUse())
    }

    static func mirroring() -> Bool {
        CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0
    }

    static func cameraInUse() -> Bool {
        var devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices

        if let preferred = AVCaptureDevice.default(for: .video),
            !devices.contains(where: { $0.uniqueID == preferred.uniqueID })
        {
            devices.append(preferred)
        }
        return devices.contains { $0.isInUseByAnotherApplication }
    }
}
