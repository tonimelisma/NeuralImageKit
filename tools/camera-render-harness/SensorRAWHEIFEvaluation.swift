import CoreImage
import Foundation

/// Compare the file emitted by the standalone sensor renderer, not an in-memory
/// approximation. Measurement never registers away native lens discrepancies.
func evaluateSensorRAWHEIF(_ pair: Pair, output: URL,
                           look: SensorRenderingLook = .nativeDefault) throws -> [String: Any]
{
    let rawURL = URL(fileURLWithPath: pair.raw)
    let targetURL = URL(fileURLWithPath: pair.target)
    let pairDirectory = output.appendingPathComponent(pair.id)
    try FileManager.default.createDirectory(at: pairDirectory, withIntermediateDirectories: true)
    let heifURL = pairDirectory.appendingPathComponent("candidate.heic")
    let start = Date()
    let result = try CameraSensorRAWHEIFRenderer.render(
        rawURL: rawURL, destinationURL: heifURL,
        mediaRoots: [rawURL.deletingLastPathComponent(), targetURL.deletingLastPathComponent()],
        look: look
    )
    let renderMs = Date().timeIntervalSince(start) * 1000
    guard let candidate = try CIImage(data: localData(heifURL.path),
                                      options: [.applyOrientationProperty: true]),
        let target = try CIImage(data: localData(pair.target),
                                 options: [.applyOrientationProperty: true])
    else { throw HarnessError.decodeFailed("candidate or target HEIF") }
    let candidateNative = zeroOrigin(candidate)
    let targetNative = zeroOrigin(target)
    guard candidateNative.extent.size == targetNative.extent.size else {
        throw HarnessError.incompatibleDimensions
    }
    let native = try nativeGeometryScore(source: candidateNative, target: targetNative) { crop in
        let encoded = try encodedImage(crop)
        return frame(encoded, width: 192, height: 192)
    }
    let candidateSmall = try encodedImage(scaled(candidateNative))
    let targetSmall = try encodedImage(scaled(targetNative))
    let width = Int(targetSmall.extent.width.rounded())
    let height = Int(targetSmall.extent.height.rounded())
    guard candidateSmall.extent.size == targetSmall.extent.size else {
        throw HarnessError.incompatibleDimensions
    }
    let color = try colorScore(
        candidate: frame(candidateSmall, width: width, height: height),
        target: frame(targetSmall, width: width, height: height)
    )
    try writePNG(candidateSmall, to: pairDirectory.appendingPathComponent("candidate.png"))
    try writePNG(targetSmall, to: pairDirectory.appendingPathComponent("camera.png"))
    for (name, x, y) in [
        ("top-left", 0, 0), ("top-right", result.width - 512, 0),
        ("bottom-left", 0, result.height - 512),
        ("bottom-right", result.width - 512, result.height - 512),
    ] {
        let region = CGRect(x: x, y: y, width: 512, height: 512)
        try writePNG(candidateNative.cropped(to: region),
                     to: pairDirectory.appendingPathComponent("candidate-\(name).png"))
        try writePNG(targetNative.cropped(to: region),
                     to: pairDirectory.appendingPathComponent("camera-\(name).png"))
    }
    let score = try JSONSerialization.jsonObject(with: JSONEncoder().encode(color))
    let geometry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(native))
    return [
        "id": pair.id, "session": pair.session, "role": pair.role.rawValue,
        "contractVersion": result.contractVersion,
        "look": result.look,
        "decoderVersion": result.decoderVersion,
        "nativeRecipe": result.nativeRecipe,
        "nativeTemperature": result.nativeTemperature, "nativeTint": result.nativeTint,
        "nativeBaselineExposure": result.nativeBaselineExposure, "nativeShadowBias": result.nativeShadowBias,
        "nativeGamutMappingEnabled": result.nativeGamutMappingEnabled,
        "lensModel": result.lensModel.map { $0 as Any } ?? NSNull(),
        "nativeLensCorrectionSupported": result.nativeLensCorrectionSupported,
        "focalLengthMM": result.focalLengthMM.map { $0 as Any } ?? NSNull(),
        "nativeLensCorrectionEnabled": result.nativeLensCorrectionEnabled,
        "nativeWidth": result.width, "nativeHeight": result.height,
        "renderMs": renderMs,
        "color": score, "nativeGeometry": geometry,
    ]
}
