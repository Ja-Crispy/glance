//
//  CameraDeviceCatalog.swift
//  glance
//
//  Resolves the app's camera preference (flat default, or split by built-in vs. external display) into the device to open.
//

import AVFoundation
import AppKit

struct CameraDevice: Identifiable, Hashable {
    let id: String // AVCaptureDevice.uniqueID
    let name: String
}

enum CameraDeviceCatalog {
    static func availableDevices() -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// True if the currently-active screen is the Mac's built-in display
    /// (vs. an external monitor) — used to pick between the built-in/
    /// external camera overrides.
    static func isUsingBuiltInDisplay() -> Bool {
        guard let screen = NSScreen.main,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return true }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    /// Display-specific override, then flat default, then the system default camera.
    static func resolvedDevice() -> AVCaptureDevice? {
        let settings = GlanceSettings.shared
        let preferredID = isUsingBuiltInDisplay()
            ? (settings.builtInDisplayCameraID ?? settings.defaultCameraID)
            : (settings.externalDisplayCameraID ?? settings.defaultCameraID)

        // Checked against the discovery set instead of being trusted straight from the plist.
        //
        // `AVCaptureDevice(uniqueID:)` opens ANY registered capture device by ID — it applies none
        // of the `deviceTypes` filter that `availableDevices()` uses, and the picker's bounded
        // choices are only enforced on write. App Sandbox is off, so any process running as the
        // user can drop an arbitrary ID into ~/Library/Preferences and choose what this app calls
        // "the camera". That matters more here than anywhere else in the app, because a substituted
        // video stream is the one input every liveness cue is structurally blind to: there is no
        // cover glass to throw the `glossGlare` highlight and no device rectangle in frame for
        // `deviceDetected`, while a recording supplies real blinks, real yaw and real nose parallax,
        // so all three Heavy-mode confirm cues fire honestly.
        //
        // Scope, stated honestly: this closes the arbitrary-ID hole. It does NOT by itself prove the
        // device is a physical camera — a virtual camera that registers as `.external` appears in
        // the discovery set too. Rejecting those needs a separate, user-visible policy; see the
        // `isBuiltIn` helper below, which the unlock path uses to decide what it is willing to trust.
        if let preferredID, availableDevices().contains(where: { $0.id == preferredID }),
           let device = AVCaptureDevice(uniqueID: preferredID) {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }

    /// Whether `device` is the Mac's own built-in camera, as opposed to anything attached,
    /// streamed, or synthesised.
    ///
    /// `.builtInWideAngleCamera` is reported for the physical FaceTime camera and cannot be claimed
    /// by a CoreMediaIO virtual camera, which registers as `.external`. A Continuity Camera is a
    /// real camera on a real iPhone, but it arrives over the network and is explicitly excluded
    /// here — the point of this check is "pixels this Mac's own sensor produced".
    static func isBuiltIn(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .builtInWideAngleCamera
    }
}
