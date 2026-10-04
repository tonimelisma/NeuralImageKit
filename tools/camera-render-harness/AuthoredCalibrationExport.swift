import CoreImage
import Foundation
import simd

/// Export native-developed calibration observations through the renderer's exact
/// input contract. Registration and reference HEIF access are offline work only.
func exportAuthoredCalibration(_ pair: Pair, input: NativeRAWRecipe,
                               registrationLook: LookModel, output: URL) throws
{
    guard pair.role != .acceptance, pair.session == String(pair.id.prefix(8)), input != .appleDefault else {
        throw LookCalibrationError.invalidTrainingManifest
    }
    let directory = output.appendingPathComponent(pair.id)
    guard !FileManager.default.fileExists(atPath: directory.path) else { throw LookCalibrationError.existingOutput }
    let native = try NativeRAWDevelopment.develop(localData(pair.raw), recipe: input)
    let full = try native.linearFrame()
    let opaque = image(full).settingAlphaOne(in: CGRect(x: 0, y: 0, width: full.width, height: full.height))
    let reduced = scaled(opaque), width = Int(reduced.extent.width.rounded()), height = Int(reduced.extent.height.rounded())
    let source = frame(reduced, width: width, height: height)
    var proxy = source.rgba
    for i in stride(from: 0, to: proxy.count, by: 4) {
        let x = SIMD3(Double(source.rgba[i]), Double(source.rgba[i + 1]), Double(source.rgba[i + 2]))
        let rgb = SIMD3(
            1.660491002108434 * x.x - 0.58764113878855 * x.y - 0.072849863319884 * x.z,
            -0.12455047452159 * x.x + 1.13289989712596 * x.y - 0.008349422604371 * x.z,
            -0.018150763354905 * x.x - 0.100578898008008 * x.y + 1.118729661362913 * x.z
        )
        for c in 0 ..< 3 {
            // The registration comparator clamps negative input to zero. This
            // explicit clamp avoids mislabelling an SDR transfer as extended sRGB.
            let v = max(0, rgb[c])
            proxy[i + c] = Float(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
    }
    let reference = try image(RGBFrame(width: width, height: height, rgba: MetalLook(model: registrationLook).apply(proxy)))
    guard let original = try CIImage(data: localData(pair.target), options: [.applyOrientationProperty: true]) else {
        throw HarnessError.decodeFailed("calibration target")
    }
    let target = try encodedImage(scaled(original))
    guard target.extent.size == reduced.extent.size else { throw HarnessError.incompatibleDimensions }
    let registration = try register(reference, to: target, width: width, height: height)
    let aligned = perspective(reduced, matrix: registration.inverse ? registration.matrix.inverse : registration.matrix,
                              size: CGSize(width: width, height: height), flipY: registration.flipY)
    let sourcePixels = frame(aligned, width: width, height: height), targetPixels = frame(target, width: width, height: height)
    var minimum = Float.infinity, maximum = -Float.infinity, negative = 0, aboveOne = 0
    for i in full.rgba.indices where i % 4 != 3 {
        minimum = min(minimum, full.rgba[i])
        maximum = max(maximum, full.rgba[i])
        negative += full.rgba[i] < 0 ? 1 : 0
        aboveOne += full.rgba[i] > 1 ? 1 : 0
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    /// A recipe is the final completion marker. Interrupted directories are not
    /// valid calibration data and cannot silently be reused or overwritten.
    func write(_ pixels: [Float], name: String) throws {
        var data = Data(capacity: pixels.count * 4)
        for value in pixels {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        try data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
    }
    try write(sourcePixels.rgba, name: "scene-frame.f32")
    try write(targetPixels.rgba, name: "target-frame.f32")
    let recipe: [String: Any] = [
        "contractVersion": 10, "decoder": "9", "sourceNativeWidth": full.width, "sourceNativeHeight": full.height,
        "width": width, "height": height, "nativeLensCorrectionEnabled": native.lensCorrectionEnabled,
        "gamutMappingEnabled": native.gamutMappingEnabled, "shadowBias": native.shadowBias,
        "baselineExposure": native.baselineExposure, "temperature": native.temperature, "tint": native.tint,
        "developmentWorkingSpace": "extended linear sRGB", "workingPrimaries": "ITU-R BT.2020", "workingTransfer": "linear", "registrationMSE": registration.mse,
        "role": pair.role.rawValue, "minimumLinear": minimum, "maximumLinear": maximum,
        "negativeComponentFraction": Double(negative) / Double(full.width * full.height * 3),
        "aboveOneComponentFraction": Double(aboveOne) / Double(full.width * full.height * 3),
    ]
    try JSONSerialization.data(withJSONObject: recipe, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("recipe.json"), options: .withoutOverwriting)
    print("op=authored.export id=\(pair.id) input=\(input.rawValue) native=\(full.width)x\(full.height)")
}
