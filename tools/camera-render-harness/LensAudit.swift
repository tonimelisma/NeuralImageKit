import CoreImage
import Foundation

struct LensAuditRecord: Encodable {
    let id: String
    let session: String
    let role: String
    let nativeWidth: Int
    let nativeHeight: Int
    let correctionSupported: Bool
    let correctionEnabledByDefault: Bool
    let enabledToCamera: NativeGeometryScore
    let disabledToCamera: NativeGeometryScore
    let enabledToDisabled: NativeGeometryScore
}

/// Decode the same RAW twice with only CIRAWFilter's lens correction switch
/// changed. This isolates the native correction exposed by Apple's decoder from
/// tone, sharpening and the fixed color model used elsewhere in the harness.
func lensAudit(_ pair: Pair) throws -> LensAuditRecord {
    let rawData = try localData(pair.raw)
    let targetData = try localData(pair.target)
    let decoder = CIRAWDecoderVersion(rawValue: "9")
    func neutralFilter(correction: Bool?) throws -> CIRAWFilter {
        guard let filter = CIRAWFilter(imageData: rawData,
                                       identifierHint: nil),
            filter.supportedDecoderVersions.contains(decoder)
        else { throw HarnessError.decoderUnavailable }
        filter.decoderVersion = decoder
        filter.scaleFactor = 1
        filter.boostAmount = 0
        filter.localToneMapAmount = 0
        filter.contrastAmount = 0
        filter.sharpnessAmount = 0
        if let correction {
            filter.isLensCorrectionEnabled = correction
        }
        return filter
    }
    let original = try neutralFilter(correction: nil)
    let enabled = try neutralFilter(correction: true)
    let disabled = try neutralFilter(correction: false)
    guard let enabledImage = enabled.outputImage, let disabledImage = disabled.outputImage,
          let targetImage = CIImage(data: targetData,
                                    options: [.applyOrientationProperty: true])
    else { throw HarnessError.decodeFailed("native lens audit output") }
    let corrected = zeroOrigin(enabledImage)
    let uncorrected = zeroOrigin(disabledImage)
    let camera = zeroOrigin(targetImage)
    guard corrected.extent.size == uncorrected.extent.size,
          corrected.extent.size == camera.extent.size
    else { throw HarnessError.incompatibleDimensions }
    func score(_ source: CIImage, _ target: CIImage) throws -> NativeGeometryScore {
        try nativeGeometryScore(source: source, target: target) { crop in
            try frame(encodedImage(zeroOrigin(crop)), width: 192, height: 192)
        }
    }
    return try LensAuditRecord(
        id: pair.id, session: pair.session, role: pair.role.rawValue,
        nativeWidth: Int(camera.extent.width), nativeHeight: Int(camera.extent.height),
        correctionSupported: original.isLensCorrectionSupported,
        correctionEnabledByDefault: original.isLensCorrectionEnabled,
        enabledToCamera: score(corrected, camera),
        disabledToCamera: score(uncorrected, camera),
        enabledToDisabled: score(corrected, uncorrected)
    )
}
