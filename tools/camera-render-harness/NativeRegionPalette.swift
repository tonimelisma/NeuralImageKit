import CoreImage
import CryptoKit
import Foundation

/// Uniform source samples describe training coverage, not photographic accuracy.
/// Keep signed source counts alongside the runtime-domain sample projection.
private func nativeRegionPalette(_ pixels: RGBFrame, rectangle: CGRect, maximumSamples: Int = 4096) throws -> [[Double]] {
    guard maximumSamples > 0, rectangle.minX.isFinite, rectangle.minY.isFinite,
          rectangle.maxX.isFinite, rectangle.maxY.isFinite else { throw HarnessError.invalidManifest }
    let x0 = Int(min(Double(pixels.width), max(0, rectangle.minX.rounded(.up)))), x1 = Int(min(Double(pixels.width), max(0, rectangle.maxX.rounded(.down))))
    let y0 = Int(min(Double(pixels.height), max(0, rectangle.minY.rounded(.up)))), y1 = Int(min(Double(pixels.height), max(0, rectangle.maxY.rounded(.down))))
    guard x1 > x0, y1 > y0 else { return [] }
    let count = (x1 - x0) * (y1 - y0), step = max(1, Int(ceil(Double(count) / Double(maximumSamples))))
    var samples = [[Double]]()
    for index in stride(from: 0, to: count, by: step) {
        let x = x0 + index % (x1 - x0), y = y0 + index / (x1 - x0), i = (y * pixels.width + x) * 4
        guard (0 ..< 4).allSatisfy({ pixels.rgba[i + $0].isFinite }), pixels.rgba[i + 3] > 0.999 else { throw HarnessError.malformedReferenceData }
        samples.append((0 ..< 3).map { min(1.25, max(0, Double(pixels.rgba[i + $0]))) })
    }
    return samples
}

/// Geometry comes from a fixed RAW-derived baseline; targets are not read here.
/// Full region support matches the frozen colour rectangles, including small
/// saturated objects that an inset fitting stencil could entirely omit.
func exportNativeRegionPalette(_ pair: Pair, card: AppearanceLookCard, geometryReport: Data,
                               geometryBaseline: Data, destination: URL) throws
{
    try card.validate()
    guard pair.role == .selection || pair.role == .regression,
          !FileManager.default.fileExists(atPath: destination.path), let regions = card.regions[pair.id],
          let report = try JSONSerialization.jsonObject(with: geometryReport) as? [String: Any],
          report["formatVersion"] as? Int == 7, let rows = report["scores"] as? [[String: Any]], rows.count == regions.count,
          let digest = report["geometryBaselineSHA256"] as? String, digest == SHA256.hash(data: geometryBaseline).description else { throw HarnessError.invalidManifest }
    try validate(Manifest(pairs: [pair]), output: destination)
    let span = RenderingSignpost.rendering.beginInterval("NativeRegionPalette")
    defer { RenderingSignpost.rendering.endInterval("NativeRegionPalette", span) }
    let development = try NativeRAWDevelopment.develop(localData(pair.raw), recipe: .mapped)
    let encoded = try encodedImage(development.image), reduced = scaled(development.image)
    let pixels = frame(encoded, width: Int(encoded.extent.width), height: Int(encoded.extent.height))
    guard pixels.rgba.allSatisfy(\.isFinite) else { throw HarnessError.malformedReferenceData }
    let sx = Double(pixels.width) / reduced.extent.width.rounded(), sy = Double(pixels.height) / reduced.extent.height.rounded()
    var summaries = [[String: Any]]()
    for (region, row) in zip(regions, rows) {
        guard row["name"] as? String == region.name else { throw HarnessError.invalidManifest }
        guard let sensitivity = row["meanDE00Sensitivity"] as? Double, sensitivity.isFinite, sensitivity >= 0,
              sensitivity <= card.maximumSensitivityDE00,
              let correspondence = row["correspondence"] as? [String: Any], correspondence["status"] as? String == "measured-local",
              let dx = correspondence["dx"] as? Double, let dy = correspondence["dy"] as? Double, dx.isFinite, dy.isFinite
        else { summaries.append(["name": region.name, "coverage": "unknown-or-sensitive"])
            continue
        }
        let q = region.rectangle
        let rectangle = CGRect(x: (q[0] * reduced.extent.width.rounded() + dx) * sx,
                               y: (q[1] * reduced.extent.height.rounded() + dy) * sy,
                               width: (q[2] - q[0]) * Double(pixels.width), height: (q[3] - q[1]) * Double(pixels.height))
        try summaries.append(["name": region.name, "coverage": "fixed-reliable-full-region",
                              "sourceRange": nativeRangeCounts(pixels, rectangle: rectangle),
                              "runtimeDomainSamples": nativeRegionPalette(pixels, rectangle: rectangle)])
    }
    let result: [String: Any] = ["contractVersion": 1, "id": pair.id, "validationEvidence": false,
                                 "scope": "RAW-only full-region source palette; training coverage diagnostic, not colour acceptance",
                                 "geometryBaselineSHA256": digest, "inputDomain": [0, 1.25], "nativeWidth": pixels.width, "nativeHeight": pixels.height,
                                 "nativeTemperature": development.temperature, "nativeTint": development.tint, "regions": summaries]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .withoutOverwriting)
    RenderingLog.rendering.noticeOperation("matching.nativeRegionPalette", phase: "complete", fields: ["regions": String(summaries.count)])
}

private func nativePreparationDifferences(_ a: RGBFrame, _ b: RGBFrame, regions: [AppearanceLookCard.Region], preparation: String) throws -> [[String: Any]] {
    guard a.width == b.width, a.height == b.height else { throw HarnessError.incompatibleDimensions }
    guard a.rgba.allSatisfy(\.isFinite), b.rgba.allSatisfy(\.isFinite) else { throw HarnessError.malformedReferenceData }
    let width = a.width, height = a.height
    var rows = [[String: Any]]()
    for region in regions {
        let q = region.rectangle
        let x0 = Int(q[0] * Double(width)), x1 = Int(q[2] * Double(width))
        let y0 = Int(q[1] * Double(height)), y1 = Int(q[3] * Double(height))
        var errors = [Double](), absolute = [Double](repeating: 0, count: 3), signed = absolute
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let i = (y * width + x) * 4
                for c in 0 ..< 3 {
                    let delta = Double(a.rgba[i + c]) - Double(b.rgba[i + c])
                    signed[c] += delta
                    absolute[c] += abs(delta)
                }
                errors.append(ciede2000(Lab.srgb(min(1, max(0, Double(a.rgba[i]))), min(1, max(0, Double(a.rgba[i + 1]))), min(1, max(0, Double(a.rgba[i + 2])))), Lab.srgb(min(1, max(0, Double(b.rgba[i]))), min(1, max(0, Double(b.rgba[i + 1]))), min(1, max(0, Double(b.rgba[i + 2]))))))
            }
        }
        guard !errors.isEmpty else { throw HarnessError.malformedReferenceData }
        errors.sort()
        let count = Double(errors.count)
        rows.append(["name": region.name, "preparation": preparation, "samples": errors.count, "meanDisplayClampedSourceDE00": errors.reduce(0,+) / count,
                     "p95DisplayClampedSourceDE00": errors[Int(ceil(count * 0.95)) - 1], "meanSignedNativeMinusReducedRGB": signed.map { $0 / count }, "meanAbsoluteRGB": absolute.map { $0 / count }])
    }
    return rows
}

/// Compare calibration's reduced decoder tap with full native development.
/// This is input consistency evidence; neither image is a camera reference.
func auditNativeCalibrationSource(_ pair: Pair, card: AppearanceLookCard, profile: ConditionalProfile? = nil, destination: URL) throws {
    try card.validate()
    guard pair.role == .selection || pair.role == .regression,
          !FileManager.default.fileExists(atPath: destination.path), let regions = card.regions[pair.id]
    else { throw HarnessError.invalidManifest }
    try validate(Manifest(pairs: [pair]), output: destination)
    let span = RenderingSignpost.rendering.beginInterval("CalibrationSourceAudit")
    defer { RenderingSignpost.rendering.endInterval("CalibrationSourceAudit", span) }
    let started = Date()
    let bytes = try localData(pair.raw)
    let development = try NativeRAWDevelopment.develop(bytes, recipe: .mapped)
    let encoded = try encodedImage(development.image)
    let full = frame(encoded, width: Int(encoded.extent.width), height: Int(encoded.extent.height))
    guard full.rgba.allSatisfy(\.isFinite) else { throw HarnessError.malformedReferenceData }
    let tagged = CIImage(bitmapData: full.rgba.withUnsafeBytes { Data($0) }, bytesPerRow: full.width * 16,
                         size: CGSize(width: full.width, height: full.height), format: .RGBAf, colorSpace: encodedSpace)
    let nativeReducedImage = try encodedImage(scaled(tagged))
    guard let raw = CIRAWFilter(imageData: bytes, identifierHint: nil) else { throw HarnessError.decodeFailed("source audit") }
    let decoder = CIRAWDecoderVersion(rawValue: "9")
    guard raw.supportedDecoderVersions.contains(decoder) else { throw HarnessError.decoderUnavailable }
    raw.decoderVersion = decoder
    raw.isDraftModeEnabled = false
    raw.scaleFactor = Float(768 / max(raw.nativeSize.width, raw.nativeSize.height))
    raw.boostAmount = 0
    raw.localToneMapAmount = 0
    raw.contrastAmount = 0
    raw.sharpnessAmount = 0
    raw.isGamutMappingEnabled = true
    raw.isLensCorrectionEnabled = raw.isLensCorrectionSupported
    guard let low = raw.outputImage else { throw HarnessError.decodeFailed("source audit") }
    let lowReducedImage = try encodedImage(scaled(low))
    guard nativeReducedImage.extent.size == lowReducedImage.extent.size else { throw HarnessError.incompatibleDimensions }
    let width = Int(nativeReducedImage.extent.width), height = Int(nativeReducedImage.extent.height)
    /// Preserve the current calibration Gaussian radius for both source taps.
    func pixels(_ image: CIImage) -> RGBFrame {
        frame(image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2]).cropped(to: image.extent), width: width, height: height)
    }
    let a = pixels(nativeReducedImage), b = pixels(lowReducedImage)
    var rows = try nativePreparationDifferences(a, b, regions: regions, preparation: "native-source versus reduced-decoder-source")
    if let profile {
        let metal = try MetalLook(model: profile.model(development: development))
        func apply(_ frame: RGBFrame) throws -> RGBFrame {
            try RGBFrame(width: frame.width, height: frame.height, rgba: metal.apply(frame.rgba))
        }
        func tagged(_ frame: RGBFrame) -> CIImage {
            CIImage(bitmapData: frame.rgba.withUnsafeBytes { Data($0) }, bytesPerRow: frame.width * 16,
                    size: CGSize(width: frame.width, height: frame.height), format: .RGBAf, colorSpace: encodedSpace)
        }
        let nativeMapped = try apply(full)
        let nativePrepared = try pixels(encodedImage(scaled(tagged(nativeMapped))))
        let lowMapped = try apply(frame(lowReducedImage, width: width, height: height))
        let lowPrepared = pixels(tagged(lowMapped))
        let pointInitializer = try apply(b)
        rows += try nativePreparationDifferences(nativePrepared, lowPrepared, regions: regions, preparation: "native look-before-reduction versus reduced decoder look-before-blur")
        rows += try nativePreparationDifferences(nativePrepared, pointInitializer, regions: regions, preparation: "native look-before-reduction versus current point-RGB training initializer")
    }
    let result: [String: Any] = ["contractVersion": 1, "id": pair.id, "validationEvidence": false,
                                 "scope": "RAW-only native/reduced source and optional frozen-model preparation audit; no camera target read; not HEIF matching",
                                 "calibrationGaussianRadius": 1.2, "regions": rows]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .withoutOverwriting)
    RenderingLog.rendering.noticeOperation("matching.calibrationSourceAudit", phase: "complete", fields: ["regions": String(rows.count), "elapsedMs": String(Date().timeIntervalSince(started) * 1000)])
}

func nativeRegionPaletteSelfTest() throws {
    let pixels = RGBFrame(width: 2, height: 2, rgba: [-0.1, 0.5, 1.4, 1, 0.2, 0.3, 0.4, 1, 0.6, 0.7, 0.8, 1, 0.9, 1, 1.1, 1])
    let all = try nativeRegionPalette(pixels, rectangle: CGRect(x: 0, y: 0, width: 2, height: 2))
    let small = try nativeRegionPalette(pixels, rectangle: CGRect(x: 0, y: 0, width: 1, height: 1))
    let capped = try nativeRegionPalette(pixels, rectangle: CGRect(x: 0, y: 0, width: 2, height: 2), maximumSamples: 1)
    guard all.count == 4, small == [[0, 0.5, 1.25]], capped == small,
          try nativeRegionPalette(pixels, rectangle: .zero).isEmpty else { throw HarnessError.malformedReferenceData }
    let whole = AppearanceLookCard.Region(name: "whole", rectangle: [0, 0, 1, 1])
    let same = try nativePreparationDifferences(pixels, pixels, regions: [whole], preparation: "identity")
    guard same[0]["meanDisplayClampedSourceDE00"] as? Double == 0,
          same[0]["p95DisplayClampedSourceDE00"] as? Double == 0 else { throw HarnessError.malformedReferenceData }
    var shifted = pixels.rgba
    for i in stride(from: 0, to: shifted.count, by: 4) {
        shifted[i + 1] += 0.1
    }
    let changed = try nativePreparationDifferences(RGBFrame(width: 2, height: 2, rgba: shifted), pixels, regions: [whole], preparation: "green shift")
    guard let signed = changed[0]["meanSignedNativeMinusReducedRGB"] as? [Double],
          abs(signed[1] - 0.1) < 1e-6, (changed[0]["meanDisplayClampedSourceDE00"] as? Double ?? 0) > 1
    else { throw HarnessError.malformedReferenceData }
    let frame = RGBFrame(width: 512, height: 768, rgba: Array(repeating: [Float(0.5), 0.5, 0.5, 1], count: 512 * 768).flatMap(\.self))
    var regions = (0 ..< 8).map { AppearanceLookCard.Region(name: "area\($0)", rectangle: [0.1, 0.1, 0.3, 0.3]) }
    regions.append(.init(name: "tiny cyan", rectangle: [0.25, 0.779296875, 0.265625, 0.802734375]))
    let rows: [[String: Any]] = regions.map { ["name": $0.name, "meanDE00Sensitivity": 0.0, "correspondence": ["status": "measured-local", "dx": 0.0, "dy": 0.0]] }
    let support = try nativeMatchingObservations(regions: regions, rows: rows, target: frame, maximumSensitivity: 1)
    let tiny = support.samples.filter { $0.y > 550 }
    guard support.regions.contains("tiny cyan"), tiny.count == 144, tiny.allSatisfy({ $0.regionIndex == 8 }), abs(tiny.reduce(0) { $0 + $1.weight } - 1) < 1e-12,
          support.samples.count <= 9 * 1024 else { throw HarnessError.malformedReferenceData }
    let id = "20260101_120000"
    let card = AppearanceLookCard(formatVersion: 5, maximumLightnessDifference: 2, maximumMedianDE00: 3,
                                  maximumChromaDifference: 3, maximumSensitivityDE00: 1, regions: [id: [.init(name: "small", rectangle: [0, 0, 0.1, 0.1])]])
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("palette-test-\(UUID().uuidString)")
    for role in [PairRole.training, .acceptance] {
        let pair = Pair(id: id, raw: "/missing.arw", target: "/unread.heif", session: "20260101", role: role)
        do {
            try exportNativeRegionPalette(pair, card: card, geometryReport: Data(), geometryBaseline: Data(), destination: destination)
            throw HarnessError.malformedReferenceData
        } catch HarnessError.invalidManifest {}
    }
    for role in [PairRole.training, .acceptance] {
        let pair = Pair(id: id, raw: "/missing.arw", target: "/unread.heif", session: "20260101", role: role)
        do {
            try auditNativeCalibrationSource(pair, card: card, destination: destination)
            throw HarnessError.malformedReferenceData
        } catch HarnessError.invalidManifest {}
    }
    guard !FileManager.default.fileExists(atPath: destination.path),
          try nativeRegionPalette(pixels, rectangle: CGRect(x: 1e300, y: 1e300, width: 1, height: 1)).isEmpty
    else { throw HarnessError.malformedReferenceData }
    print("Native palette: small full-region support, domain projection, sample cap and empty support pass")
}
