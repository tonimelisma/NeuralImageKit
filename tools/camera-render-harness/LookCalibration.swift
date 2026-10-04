// Calibration for the named RAW 9 encoded-sRGB baseline, outside the app.
// Originals are read through the materialization gate; sampled pixels remain
// private. Capture verification precedes export. Shared fitting is training-only;
// explicitly labelled native expression diagnostics use regression roles. Both
// use Apple's LAPACK instead of a separate numerical dependency.
import Accelerate
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import simd

enum LookCalibrationError: Error {
    case invalidTrainingManifest, existingOutput, invalidSamples, solveFailed(Int32)
}

private struct CalibrationRecipe: Codable {
    let contractVersion: Int
    let decoder: String
    let sourcePreparation: String
    let nativeLensCorrectionSupported: Bool
    let samples: Int
    let nativeLensCorrectionEnabled: Bool
    let calibrationBlurRadius: Double
    let evaluationLongEdge: Int
    let neutralSettings: [String: Double]
    let samplingPolicy: String
}

enum CalibrationSampling: String {
    case interior, modelDomain
    var contractVersion: Int {
        self == .interior ? 3 : 4
    }
}

/// Change training support explicitly without changing runtime clamping or scoring.
/// Domain endpoints are valid inputs to the model and must not disappear simply
/// because a saturated source channel is zero or the camera output is clipped.
func calibrationPairValues(input: [Float], target: [Float], sampling: CalibrationSampling) -> [Float]? {
    guard input.count == 3, target.count == 3, (input + target).allSatisfy(\.isFinite) else { return nil }
    if sampling == .interior {
        guard input.allSatisfy({ $0 > 0.005 && $0 < 1.245 }), target.allSatisfy({ $0 > 0.005 && $0 < 0.99 }) else { return nil }
        return input + target
    }
    return input.map { min(1.25, max(0, $0)) } + target.map { min(1, max(0, $0)) }
}

/// Runtime look application emits opaque pixels. Native half-float conversion
/// can round opaque alpha just below one; retain RGB and mark only a verified
/// opaque frame before resampling. Registration still creates excluded borders.
func nativeCalibrationImage(_ pixels: RGBFrame) throws -> CIImage {
    guard pixels.width > 0, pixels.height > 0,
          pixels.rgba.count == pixels.width * pixels.height * 4,
          isFiniteOpaqueNativeFrame(pixels)
    else { throw LookCalibrationError.invalidSamples }
    let tagged = CIImage(bitmapData: pixels.rgba.withUnsafeBytes { Data($0) },
                         bytesPerRow: pixels.width * 16,
                         size: CGSize(width: pixels.width, height: pixels.height),
                         format: .RGBAf, colorSpace: encodedSpace)
    return tagged.settingAlphaOne(in: tagged.extent)
}

func exportLookCalibrationPair(_ pair: Pair, output: URL, sampling: CalibrationSampling = .interior) throws {
    guard pair.role == .training else { throw LookCalibrationError.invalidTrainingManifest }
    let directory = output.appendingPathComponent(pair.id)
    guard !FileManager.default.fileExists(atPath: directory.path) else {
        throw LookCalibrationError.existingOutput
    }
    let span = RenderingSignpost.rendering.beginInterval("NativeCalibrationExport")
    defer { RenderingSignpost.rendering.endInterval("NativeCalibrationExport", span) }
    let started = Date()
    let rawBytes = try localData(pair.raw)
    let development = try NativeRAWDevelopment.develop(rawBytes, recipe: .mapped)
    let targetBytes = try localData(pair.target)
    guard let original = CIImage(data: targetBytes, options: [.applyOrientationProperty: true])
    else { throw HarnessError.decodeFailed("calibration HEIF") }
    // encodedImage forces native sensor development before Lanczos can reduce
    // it. Tag those encoded numbers for the same colour-managed reduction used
    // by evaluation; no reduced CIRAWFilter tap participates in fitting.
    let native = try encodedImage(development.image)
    let pixels = frame(native, width: Int(native.extent.width), height: Int(native.extent.height))
    let tagged = try nativeCalibrationImage(pixels)
    let source = try encodedImage(scaled(tagged))
    let target = try encodedImage(scaled(original))
    guard source.extent.size == target.extent.size else { throw HarnessError.incompatibleDimensions }
    let width = Int(target.extent.width.rounded()), height = Int(target.extent.height.rounded())
    let aligned = try register(source, to: target, width: width, height: height)
    /// This radius preserves the saved baseline's calibration recipe. It is not
    /// the independently specified Gaussian sigma used by the release scorecard.
    func samples(_ input: CIImage) -> RGBFrame {
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])
            .cropped(to: target.extent)
        return frame(blurred, width: width, height: height)
    }
    let input = samples(aligned.image), reference = samples(target)
    func alphaRange(_ values: [Float]) -> String {
        let alpha = stride(from: 3, to: values.count, by: 4).map { values[$0] }
        return "\(alpha.min() ?? .nan):\(alpha.max() ?? .nan)"
    }
    print("op=calibration.sampleSupport nativeAlpha=\(alphaRange(pixels.rgba)) inputAlpha=\(alphaRange(input.rgba)) targetAlpha=\(alphaRange(reference.rgba))")
    var values = [Float]()
    for row in 0 ..< 50 {
        for column in 0 ..< 50 {
            let x = min(width - 9, max(8, Int((Double(column) + 0.5) * Double(width) / 50)))
            let y = min(height - 9, max(8, Int((Double(row) + 0.5) * Double(height) / 50)))
            let i = (y * width + x) * 4
            guard input.rgba[i + 3] > 0.999, reference.rgba[i + 3] > 0.999 else { continue }
            let sourceRGB = Array(input.rgba[i ..< i + 3])
            let targetRGB = Array(reference.rgba[i ..< i + 3])
            guard let retained = calibrationPairValues(input: sourceRGB, target: targetRGB, sampling: sampling) else { continue }
            values += retained
        }
    }
    guard values.count >= 500 * 6 else {
        print("op=calibration.insufficientSamples retained=\(values.count / 6) registrationMSE=\(aligned.mse)")
        throw LookCalibrationError.invalidSamples
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var bytes = Data(capacity: values.count * 4)
    for value in values {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
    }
    try bytes.write(to: directory.appendingPathComponent("samples.f32"), options: .withoutOverwriting)
    let recipe: [String: Any] = [
        "contractVersion": sampling.contractVersion, "samplingPolicy": sampling.rawValue, "decoder": "9", "samples": values.count / 6,
        "sourcePreparation": "native-encoded-srgb-before-reduction",
        "nativeLensCorrectionSupported": development.lensCorrectionSupported,
        "nativeLensCorrectionEnabled": development.lensCorrectionEnabled, "registrationMSE": aligned.mse,
        "calibrationBlurRadius": 1.2, "evaluationLongEdge": 768,
        "neutralSettings": ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0],
        "temperature": development.temperature, "tint": development.tint,
        "baselineExposure": development.baselineExposure, "shadowBias": development.shadowBias,
    ]
    try JSONSerialization.data(withJSONObject: recipe, options: [.sortedKeys])
        .write(to: directory.appendingPathComponent("recipe.json"), options: .withoutOverwriting)
    RenderingLog.rendering.noticeOperation("calibration.export", phase: "complete", fields: [
        "sourcePreparation": "native-encoded-srgb-before-reduction",
        "samples": String(values.count / 6), "decoder": "9",
        "nativeLensSupported": String(development.lensCorrectionSupported),
        "nativeLensEnabled": String(development.lensCorrectionEnabled),
        "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
    ])
    print("op=calibration.export id=\(pair.id) samples=\(values.count / 6) decoder=9")
}

struct CalibrationSample {
    let input: SIMD3<Double>
    let target: SIMD3<Double>
    let weight: Double
}

func calibrationSamples(_ manifest: Manifest, root: URL, sampling: CalibrationSampling = .interior) throws -> [CalibrationSample] {
    var result = [CalibrationSample]()
    for pair in manifest.pairs {
        let path = root.appendingPathComponent(pair.id).appendingPathComponent("samples.f32")
        let data = try localData(path.path)
        guard data.count % 24 == 0, (500 ... 2500).contains(data.count / 24) else {
            throw LookCalibrationError.invalidSamples
        }
        let recipePath = root.appendingPathComponent(pair.id).appendingPathComponent("recipe.json")
        guard let recipeData = try? localData(recipePath.path),
              let recipe = try? JSONDecoder().decode(CalibrationRecipe.self, from: recipeData),
              recipe.contractVersion == sampling.contractVersion, recipe.decoder == "9",
              recipe.samplingPolicy == sampling.rawValue,
              recipe.samples == data.count / 24,
              recipe.sourcePreparation == "native-encoded-srgb-before-reduction",
              recipe.nativeLensCorrectionEnabled == recipe.nativeLensCorrectionSupported,
              recipe.calibrationBlurRadius == 1.2, recipe.evaluationLongEdge == 768,
              recipe.neutralSettings == ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0]
        else { throw LookCalibrationError.invalidSamples }
        let values: [Double] = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))))
            }
        }
        for i in stride(from: 0, to: values.count, by: 6) {
            let x = SIMD3(values[i], values[i + 1], values[i + 2])
            let y = SIMD3(values[i + 3], values[i + 4], values[i + 5])
            guard (0 ..< 3).allSatisfy({ c in
                guard x[c].isFinite, y[c].isFinite else { return false }
                if sampling == .interior {
                    return x[c] > 0.005 && x[c] < 1.245 && y[c] > 0.005 && y[c] < 0.99
                }
                return (0 ... 1.25).contains(x[c]) && (0 ... 1).contains(y[c])
            }) else { throw LookCalibrationError.invalidSamples }
            result.append(CalibrationSample(input: x, target: y, weight: 2500 / Double(data.count / 24)))
        }
    }
    return result
}

private func isotonic(_ values: [Double], weights: [Double]) -> [Double] {
    struct Block {
        var first: Int, last: Int
        var weight: Double, total: Double
    }
    var blocks = [Block]()
    for i in values.indices {
        blocks.append(Block(first: i, last: i, weight: weights[i], total: values[i] * weights[i]))
        while blocks.count > 1 {
            let left = blocks[blocks.count - 2], right = blocks[blocks.count - 1]
            guard left.total / left.weight > right.total / right.weight else { break }
            blocks.removeLast(2)
            blocks.append(Block(first: left.first, last: right.last,
                                weight: left.weight + right.weight, total: left.total + right.total))
        }
    }
    var result = values
    for block in blocks {
        for i in block.first ... block.last {
            result[i] = block.total / block.weight
        }
    }
    return result
}

func fitLookCalibration(_ manifest: Manifest, samplesRoot: URL, destination: URL, sampling: CalibrationSampling = .interior) throws {
    guard manifest.pairs.count >= 100, manifest.pairs.allSatisfy({ $0.role == .training }) else {
        throw LookCalibrationError.invalidTrainingManifest
    }
    try validate(manifest, output: samplesRoot)
    try validate(manifest, output: destination.deletingLastPathComponent())
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw LookCalibrationError.existingOutput
    }
    let started = Date(), samples = try calibrationSamples(manifest, root: samplesRoot, sampling: sampling)
    let data = try calibrationModel(samples, note: "RAW 9 encoded-sRGB baseline; fitted only from verified private training captures.")
    try data.write(to: destination, options: .withoutOverwriting)
    print("op=calibration.fit images=\(manifest.pairs.count) samples=\(samples.count) seconds=\(Date().timeIntervalSince(started))")
}

/// Reuse the constrained profile solver for a camera-wide training candidate.
/// The training manifest owns eligibility; held-out photographs never enter this
/// owner. Native HEIF scoring must select the result before runtime promotion.
func fitJointLookCalibration(_ manifest: Manifest, samplesRoot: URL, initialData: Data, destination: URL, sampling: CalibrationSampling = .interior) throws {
    guard manifest.pairs.count >= 100, manifest.pairs.allSatisfy({ $0.role == .training }) else {
        throw LookCalibrationError.invalidTrainingManifest
    }
    try validate(manifest, output: samplesRoot)
    try validate(manifest, output: destination)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw LookCalibrationError.existingOutput
    }
    let initial = try LookModel(json: initialData)
    let started = Date(), samples = try calibrationSamples(manifest, root: samplesRoot, sampling: sampling)
    let fitted = try jointProfileCalibration(samples, initial: initial)
    var model = try JSONSerialization.jsonObject(with: fitted.data) as! [String: Any]
    model["note"] = "Shared RAW 9 training candidate; separate verified HEIF targets; native held-out evaluation required."
    let data = try JSONSerialization.data(withJSONObject: model, options: [.prettyPrinted, .sortedKeys])
    let report: [String: Any] = ["contractVersion": 1, "validationEvidence": false,
                                 "scope": "shared training-only joint curve and residual profile", "samplingPolicy": sampling.rawValue,
                                 "images": manifest.pairs.count, "shootDateGroups": Set(manifest.pairs.map(\.session)).count,
                                 "samples": samples.count, "initialModelSHA256": SHA256.hash(data: initialData).description,
                                 "modelSHA256": SHA256.hash(data: data).description,
                                 "equalImageWeight": 2500, "curveIdentityWeight": 1, "residualRidge": 2, "neighborSmoothness": 10,
                                 "objective": "RGB least-squares surrogate; not native HEIF DE00", "channels": fitted.diagnostics,
                                 "elapsedMs": Date().timeIntervalSince(started) * 1000]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try data.write(to: destination.appendingPathComponent("model.json"), options: .withoutOverwriting)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("fit.json"), options: .withoutOverwriting)
    RenderingLog.rendering.noticeOperation("calibration.sharedJoint", phase: "complete", fields: [
        "images": String(manifest.pairs.count), "samples": String(samples.count),
        "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
    ])
}

/// The same curve/LUT solve serves reproducible baseline fitting and explicitly
/// labelled capacity diagnostics. Native observation construction stays separate.
private func calibrationModel(_ samples: [CalibrationSample], note: String) throws -> Data {
    let knots = (0 ..< 49).map { Double($0) * 1.25 / 48 }
    var curves = [[Double]]()
    for c in 0 ..< 3 {
        var count = [Double](repeating: 0, count: 49), total = count
        for sample in samples {
            let bin = max(0, min(48, Int((sample.input[c] / 1.25 * 48).rounded(.toNearestOrEven))))
            count[bin] += sample.weight
            total[bin] += sample.weight * sample.target[c]
        }
        let weights = count.map { $0 + 1 }
        let values = (0 ..< 49).map { (total[$0] + min(1, max(0, knots[$0]))) / weights[$0] }
        curves.append(isotonic(values, weights: weights))
    }
    let size = 729
    // Column-major normal equations and three RHS columns are LAPACK's storage
    // contract. The positive ridge makes a Cholesky solve well-defined even for
    // palette regions with no training observations.
    var normal = [Double](repeating: 0, count: size * size)
    var rhs = [Double](repeating: 0, count: size * 3)
    for sample in samples {
        var residual = sample.target
        for c in 0 ..< 3 {
            let q = max(0, min(1.25, sample.input[c])) / 1.25 * 48
            let i = min(47, Int(q)), f = q - Double(i)
            residual[c] -= curves[c][i] * (1 - f) + curves[c][i + 1] * f
        }
        let q = simd_clamp(sample.input / 1.25 * 8, SIMD3(repeating: 0), SIMD3(repeating: 8))
        let low = SIMD3(min(7, Int(q.x)), min(7, Int(q.y)), min(7, Int(q.z)))
        let f = q - SIMD3<Double>(Double(low.x), Double(low.y), Double(low.z))
        var nodes = [(Int, Double)]()
        for r in 0 ... 1 {
            for g in 0 ... 1 {
                for b in 0 ... 1 {
                    let node = (low.x + r) * 81 + (low.y + g) * 9 + low.z + b
                    let weight = (r == 0 ? 1 - f.x : f.x) * (g == 0 ? 1 - f.y : f.y) * (b == 0 ? 1 - f.z : f.z)
                    nodes.append((node, weight))
                }
            }
        }
        for (a, wa) in nodes {
            let weight = sample.weight * wa
            for c in 0 ..< 3 {
                rhs[a + c * size] += weight * residual[c]
            }
            for (b, wb) in nodes {
                normal[a + b * size] += weight * wb
            }
        }
    }
    for r in 0 ..< 9 {
        for g in 0 ..< 9 {
            for b in 0 ..< 9 {
                let a = r * 81 + g * 9 + b
                normal[a + a * size] += 2
                for (step, coordinate) in [(81, r), (9, g), (1, b)] where coordinate < 8 {
                    let other = a + step
                    normal[a + a * size] += 10
                    normal[other + other * size] += 10
                    normal[a + other * size] -= 10
                    normal[other + a * size] -= 10
                }
            }
        }
    }
    var triangle: CChar = 76, n = Int32(size), columns: Int32 = 3
    var leading = Int32(size), rhsLeading = Int32(size), info: Int32 = 0
    normal.withUnsafeMutableBufferPointer { matrix in
        rhs.withUnsafeMutableBufferPointer { values in
            dposv_(&triangle, &n, &columns, matrix.baseAddress!, &leading, values.baseAddress!, &rhsLeading, &info)
        }
    }
    guard info == 0, rhs.allSatisfy(\.isFinite) else { throw LookCalibrationError.solveFailed(info) }
    let lut = (0 ..< 9).map { r in (0 ..< 9).map { g in (0 ..< 9).map { b in
        (0 ..< 3).map { rhs[r * 81 + g * 9 + b + $0 * size] }
    } } }
    let object: [String: Any] = [
        "formatVersion": 2, "decoder": "9", "dimension": 9, "domain": [0, 1.25],
        "curveKnots": knots, "curvesRGB": curves, "residualLUT": lut,
        "neutralSettings": ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0],
        "note": note,
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    _ = try LookModel(json: data)
    return data
}

enum NativeProfileSolve: String { case sequential, jointProjected }

/// Per-image expression witness using the renderer's actual native encoded input.
/// Source pixels are sampled before any image reduction; interpolation affects
/// only the already-rendered camera target at fixed independent correspondences.
func nativeProfileCapacity(_ pair: Pair, card: AppearanceLookCard,
                           geometryReport: Data, geometryBaseline: Data, solve: NativeProfileSolve = .sequential, destination: URL) throws
{
    try card.validate()
    guard pair.role == .regression, pair.session == String(pair.id.prefix(8)),
          !FileManager.default.fileExists(atPath: destination.path),
          let regions = card.regions[pair.id],
          let report = try JSONSerialization.jsonObject(with: geometryReport) as? [String: Any],
          report["formatVersion"] as? Int == 7,
          let rows = report["scores"] as? [[String: Any]], rows.count == regions.count,
          let digest = report["geometryBaselineSHA256"] as? String,
          digest == SHA256.hash(data: geometryBaseline).description
    else { throw LookCalibrationError.invalidTrainingManifest }
    try validate(Manifest(pairs: [pair]), output: destination)
    try Task.checkCancellation()
    let span = RenderingSignpost.rendering.beginInterval("NativeProfileCapacity")
    defer { RenderingSignpost.rendering.endInterval("NativeProfileCapacity", span) }
    let started = Date()
    let development = try NativeRAWDevelopment.develop(localData(pair.raw), recipe: .mapped)
    let encoded = try encodedImage(development.image)
    let source = frame(encoded, width: Int(encoded.extent.width.rounded()), height: Int(encoded.extent.height.rounded()))
    guard let original = try CIImage(data: localData(pair.target), options: [.applyOrientationProperty: true]),
          original.extent.size == encoded.extent.size else { throw HarnessError.incompatibleDimensions }
    let target = try frame(encodedImage(original), width: source.width, height: source.height)
    let scale = Double(max(source.width, source.height)) / 768
    var samples = [CalibrationSample](), counts = [String: Int](), clamped = 0, rejectedVariation = 0
    for (region, row) in zip(regions, rows) {
        guard row["name"] as? String == region.name else { throw HarnessError.invalidManifest }
        guard let sensitivity = row["meanDE00Sensitivity"] as? Double, sensitivity.isFinite, sensitivity >= 0,
              sensitivity <= card.maximumSensitivityDE00,
              let correspondence = row["correspondence"] as? [String: Any],
              correspondence["status"] as? String == "measured-local",
              let dx = correspondence["dx"] as? Double, let dy = correspondence["dy"] as? Double,
              dx.isFinite, dy.isFinite else { continue }
        let q = region.rectangle, padding = 8 * scale
        let x0 = q[0] * Double(source.width) + padding, x1 = q[2] * Double(source.width) - padding
        let y0 = q[1] * Double(source.height) + padding, y1 = q[3] * Double(source.height) - padding
        guard x1 > x0, y1 > y0 else { continue }
        var count = 0
        for row in 0 ..< 24 {
            for column in 0 ..< 24 {
                let sx = Int((x0 + (Double(column) + 0.5) * (x1 - x0) / 24 + dx * scale).rounded())
                let sy = Int((y0 + (Double(row) + 0.5) * (y1 - y0) / 24 + dy * scale).rounded())
                let u = Double(sx) - dx * scale, v = Double(sy) - dy * scale
                guard sx >= 0, sy >= 0, sx < source.width, sy < source.height,
                      u >= 0, v >= 0, u < Double(target.width - 1), v < Double(target.height - 1) else { continue }
                let i = (sy * source.width + sx) * 4
                let raw = SIMD3(Double(source.rgba[i]), Double(source.rgba[i + 1]), Double(source.rgba[i + 2]))
                // Native point fitting is more geometry-sensitive than blurred
                // scoring. Exclude source edges using a fixed source-only rule,
                // never target error, and retain those areas in native checking.
                var low = raw, high = raw
                for oy in [-4, 0, 4] {
                    for ox in [-4, 0, 4] {
                        let j = (min(source.height - 1, max(0, sy + oy)) * source.width + min(source.width - 1, max(0, sx + ox))) * 4
                        let rgb = SIMD3(Double(source.rgba[j]), Double(source.rgba[j + 1]), Double(source.rgba[j + 2]))
                        guard (0 ..< 3).allSatisfy({ rgb[$0].isFinite }) else { throw LookCalibrationError.invalidSamples }
                        low = simd_min(low, rgb)
                        high = simd_max(high, rgb)
                    }
                }
                if (0 ..< 3).contains(where: { high[$0] - low[$0] > 0.03 }) {
                    rejectedVariation += 1
                    continue
                }
                let ix = Int(u), iy = Int(v), fx = u - Double(ix), fy = v - Double(iy)
                var reference = SIMD4<Double>(repeating: 0)
                for (ox, oy, weight) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
                    let j = ((iy + oy) * target.width + ix + ox) * 4
                    for c in 0 ..< 4 {
                        reference[c] += Double(target.rgba[j + c]) * weight
                    }
                }
                guard (0 ..< 3).allSatisfy({ raw[$0].isFinite }), (0 ..< 4).allSatisfy({ reference[$0].isFinite }),
                      source.rgba[i + 3] > 0.999, reference.w > 0.999 else { throw LookCalibrationError.invalidSamples }
                clamped += (0 ..< 3).contains(where: { raw[$0] < 0 || raw[$0] > 1.25 }) ? 1 : 0
                let input = simd_clamp(raw, SIMD3(repeating: 0), SIMD3(repeating: 1.25))
                let output = simd_clamp(SIMD3(reference.x, reference.y, reference.z), SIMD3(repeating: 0), SIMD3(repeating: 1))
                samples.append(CalibrationSample(input: input, target: output, weight: 1))
                count += 1
            }
        }
        if count > 0 {
            counts[region.name] = count
        }
    }
    guard counts.count >= 8, samples.count >= 500 else { throw HarnessError.registrationFailed }
    try Task.checkCancellation()
    let initial = try calibrationModel(samples, note: "Native per-image camera-profile expression witness; target-assisted, not automatic inference or validation.")
    let refined = solve == .jointProjected ? try jointProfileCalibration(samples, initial: LookModel(json: initial)) : nil
    let model = refined?.data ?? initial
    let modelObject = try LookModel(json: model)
    let loss = try samples.reduce(0.0) { value, sample in
        let prediction = try modelObject.evaluateRGB([sample.input.x, sample.input.y, sample.input.z])
        let e = SIMD3(prediction[0], prediction[1], prediction[2]) - sample.target
        return value + e.x * e.x + e.y * e.y + e.z * e.z
    } / Double(samples.count)
    let result: [String: Any] = [
        "contractVersion": 2, "id": pair.id, "validationEvidence": false, "solve": solve.rawValue,
        "solverDiagnostics": refined?.diagnostics ?? [],
        "scope": "native per-image profile expression; fitted pixels are not validation",
        "geometryBaselineSHA256": digest, "regionSamples": counts, "samples": samples.count,
        "sourceInput": "native encoded extended sRGB, clamped to model domain [0,1.25]",
        "sourceClampedFraction": Double(clamped) / Double(samples.count),
        "sourceVariationLimit": 0.03, "rejectedSourceVariation": rejectedVariation,
        "nativeWidth": source.width, "nativeHeight": source.height,
        "weightedRGBLoss": loss, "ridge": 2, "neighborSmoothness": 10,
        "elapsedMs": Date().timeIntervalSince(started) * 1000,
    ]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("fit.json"), options: .withoutOverwriting)
    try model.write(to: destination.appendingPathComponent("model.json"), options: .withoutOverwriting)
    RenderingLog.rendering.noticeOperation("matching.nativeProfileCapacity", phase: "complete", fields: [
        "id": pair.id, "samples": String(samples.count), "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
    ])
    print("op=matching.nativeProfileCapacity id=\(pair.id) samples=\(samples.count) loss=\(loss)")
}

/// The runtime interpolator is affine in its channel-curve and residual-table
/// coefficients before output clamping. Solve that RGB least-squares surrogate
/// jointly, retaining monotone channel curves and the existing identity/smoothness
/// priors. The finite iteration budget and projected gradient are reported; this
/// does not establish a global optimum for native HEIF DE00.
private func jointProfileCalibration(_ samples: [CalibrationSample], initial: LookModel) throws -> (data: Data, diagnostics: [[String: Any]]) {
    let size = 778
    var channels = [[Double]](), diagnostics = [[String: Any]]()
    for channel in 0 ..< 3 {
        var normal = [Double](repeating: 0, count: size * size), rhs = [Double](repeating: 0, count: size)
        for sample in samples {
            let q = simd_clamp(sample.input / 1.25 * 8, SIMD3(repeating: 0), SIMD3(repeating: 8))
            let low = SIMD3(min(7, Int(q.x)), min(7, Int(q.y)), min(7, Int(q.z)))
            let f = q - SIMD3(Double(low.x), Double(low.y), Double(low.z))
            let position = min(48, max(0, sample.input[channel] / 1.25 * 48))
            let knot = min(47, Int(position)), fraction = position - Double(knot)
            var basis = [(knot, 1 - fraction), (knot + 1, fraction)]
            for r in 0 ... 1 {
                for g in 0 ... 1 {
                    for b in 0 ... 1 {
                        let node = 49 + (low.x + r) * 81 + (low.y + g) * 9 + low.z + b
                        let weight = (r == 0 ? 1 - f.x : f.x) * (g == 0 ? 1 - f.y : f.y) * (b == 0 ? 1 - f.z : f.z)
                        basis.append((node, weight))
                    }
                }
            }
            for (a, wa) in basis {
                rhs[a] += sample.weight * wa * sample.target[channel]
                for (b, wb) in basis {
                    normal[a + size * b] += sample.weight * wa * wb
                }
            }
        }
        for i in 0 ..< 49 {
            normal[i + size * i] += 1
            rhs[i] += min(1, Double(i) * 1.25 / 48)
        }
        for r in 0 ..< 9 {
            for g in 0 ..< 9 {
                for b in 0 ..< 9 {
                    let a = 49 + r * 81 + g * 9 + b
                    normal[a + size * a] += 2
                    for (step, coordinate) in [(81, r), (9, g), (1, b)] where coordinate < 8 {
                        let other = a + step
                        normal[a + size * a] += 10
                        normal[other + size * other] += 10
                        normal[a + size * other] -= 10
                        normal[other + size * a] -= 10
                    }
                }
            }
        }
        let rowSums = (0 ..< size).map { row in (0 ..< size).reduce(0.0) { $0 + abs(normal[row + size * $1]) } }
        let lipschitz = rowSums.max()!
        func gradient(_ values: [Double]) -> [Double] {
            var result = rhs.map { -$0 }
            for b in 0 ..< size {
                let v = values[b], column = size * b
                for a in 0 ..< size {
                    result[a] += normal[a + column] * v
                }
            }
            return result
        }
        func objective(_ values: [Double]) -> Double {
            let g = gradient(values)
            return (0 ..< size).reduce(0) { $0 + 0.5 * values[$1] * (g[$1] - rhs[$1]) }
        }
        func proposal(_ values: [Double]) -> [Double] {
            let g = gradient(values)
            var next = zip(values, g).map { $0 - $1 / lipschitz }
            let curve = isotonic(Array(next.prefix(49)), weights: [Double](repeating: 1, count: 49))
            next.replaceSubrange(0 ..< 49, with: curve)
            return next
        }
        var values = initial.curvesRGB[channel] + initial.residualLUT.flatMap { $0.flatMap { $0.map { $0[channel] } } }
        var extrapolated = values, momentum = 1.0, loss = objective(values)
        let initialLoss = loss
        var projectedGradient = Double.infinity, iterations = 0, restarts = 0
        for iteration in 0 ..< 600 {
            try Task.checkCancellation()
            iterations = iteration + 1
            var next = proposal(extrapolated), measured = objective(next)
            if measured > loss {
                momentum = 1
                next = proposal(values)
                measured = objective(next)
                restarts += 1
            }
            guard measured.isFinite, next.allSatisfy(\.isFinite), measured <= loss + 1e-8 else { throw LookCalibrationError.invalidSamples }
            let nextMomentum = (1 + sqrt(1 + 4 * momentum * momentum)) / 2
            extrapolated = zip(next, values).map { $0 + (momentum - 1) / nextMomentum * ($0 - $1) }
            values = next
            loss = measured
            momentum = nextMomentum
            if iterations % 20 == 0 || iterations == 600 {
                let projected = proposal(values)
                projectedGradient = zip(values, projected).map { abs($0 - $1) * lipschitz }.max()!
                if projectedGradient < 1e-6 {
                    break
                }
            }
        }
        channels.append(values)
        diagnostics.append(["channel": channel, "iterations": iterations, "initialQuadraticObjective": initialLoss,
                            "quadraticObjective": loss, "projectedGradientInfinityNorm": projectedGradient,
                            "convergedSurrogate": projectedGradient < 1e-6, "restarts": restarts])
        print("op=matching.profileJoint channel=\(channel) iterations=\(iterations) projectedGradient=\(projectedGradient)")
    }
    var lut = [[[[Double]]]]()
    for r in 0 ..< 9 {
        var greenRows = [[[Double]]]()
        for g in 0 ..< 9 {
            var blueRows = [[Double]]()
            for b in 0 ..< 9 {
                let node = 49 + r * 81 + g * 9 + b
                blueRows.append((0 ..< 3).map { channels[$0][node] })
            }
            greenRows.append(blueRows)
        }
        lut.append(greenRows)
    }
    let object: [String: Any] = ["formatVersion": 2, "decoder": "9", "dimension": 9, "domain": [0, 1.25],
                                 "curveKnots": initial.curveKnots, "curvesRGB": channels.map { Array($0.prefix(49)) },
                                 "residualLUT": lut, "neutralSettings": initial.neutralSettings,
                                 "note": "Native per-image joint RGB-profile expression witness; not automatic inference or validation."]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    _ = try LookModel(json: data)
    return (data, diagnostics)
}

/// Recover a known constrained optimum from a deliberately biased initializer.
/// Identity targets match the curve prior and zero residual-table penalties, so
/// failure here identifies a solver defect rather than limited photographic data.
func nativeProfileSolverSelfTest() throws {
    var samples = [CalibrationSample]()
    for r in 0 ..< 9 {
        for g in 0 ..< 9 {
            for b in 0 ..< 9 {
                let input = SIMD3(Double(r), Double(g), Double(b)) * (1.25 / 8)
                samples.append(CalibrationSample(input: input, target: simd_min(input, SIMD3(repeating: 1)), weight: 1))
            }
        }
    }
    let initialData = try calibrationModel(samples, note: "Synthetic numerical recovery fixture")
    var object = try JSONSerialization.jsonObject(with: initialData) as! [String: Any]
    object["residualLUT"] = Array(repeating: Array(repeating: Array(repeating: [0.1, -0.1, 0.05], count: 9), count: 9), count: 9)
    let initial = try LookModel(json: JSONSerialization.data(withJSONObject: object))
    let result = try jointProfileCalibration(samples, initial: initial)
    let fitted = try LookModel(json: result.data)
    var maximumError = 0.0
    for sample in samples {
        let prediction = try fitted.evaluateRGB([sample.input.x, sample.input.y, sample.input.z])
        for channel in 0 ..< 3 {
            maximumError = max(maximumError, abs(prediction[channel] - sample.target[channel]))
        }
    }
    guard maximumError < 1e-5, result.diagnostics.allSatisfy({ $0["convergedSurrogate"] as? Bool == true }),
          fitted.curvesRGB.allSatisfy({ curve in zip(curve, curve.dropFirst()).allSatisfy { $0 <= $1 } })
    else { throw HarnessError.malformedReferenceData }
    print("Native joint profile: biased initializer recovers known monotone identity optimum; maxError=\(maximumError)")
}
