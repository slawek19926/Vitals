// MediaEngine.swift - informacje o sprzętowych kodekach wideo (VideoToolbox)
import Foundation
import VideoToolbox
import CoreMedia

enum MediaEngine {
    struct Codec { let name: String; let type: CMVideoCodecType }
    static let codecs: [Codec] = [
        Codec(name: "H.264 / AVC", type: kCMVideoCodecType_H264),
        Codec(name: "HEVC / H.265", type: kCMVideoCodecType_HEVC),
        Codec(name: "ProRes 422", type: kCMVideoCodecType_AppleProRes422),
        Codec(name: "ProRes 4444", type: kCMVideoCodecType_AppleProRes4444),
        Codec(name: "ProRes RAW", type: kCMVideoCodecType_AppleProResRAW),
        Codec(name: "AV1", type: kCMVideoCodecType_AV1),
        Codec(name: "VP9", type: kCMVideoCodecType_VP9),
        Codec(name: "JPEG", type: kCMVideoCodecType_JPEG),
    ]

    /// Sprzętowe dekodowanie: nazwa → tak/nie
    static func hardwareDecoders() -> [(String, Bool)] {
        codecs.map { ($0.name, VTIsHardwareDecodeSupported($0.type)) }
    }

    /// Sprzętowe kodery (z listy VideoToolbox, flaga IsHardwareAccelerated)
    static func hardwareEncoders() -> [String] {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let arr = list as? [[String: Any]] else { return [] }
        var names: [String] = []
        for e in arr {
            let hw = (e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) ?? false
            guard hw, let name = e[kVTVideoEncoderList_DisplayName as String] as? String else { continue }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
}
