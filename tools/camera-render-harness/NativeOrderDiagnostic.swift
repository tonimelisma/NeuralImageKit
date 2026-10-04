import CoreImage
import CryptoKit
import Foundation

/// Development-only order audit. The shared Metal look runs on native RAW
/// pixels before managed reduction. A previously exported HEIF checks this
/// pre-encoding observation independently; target pixels never enter the look.
func nativeOrderDiagnostic(_ pair: Pair, recipe: AuthoredLook,
                           candidateURL: URL, destination: URL) throws
{
    guard pair.role == .selection || pair.role == .regression,
          !FileManager.default.fileExists(atPath: destination.path)
    else { throw HarnessError.invalidManifest }
    try validate(Manifest(pairs: [pair]), output: destination)
    let span = RenderingSignpost.rendering.beginInterval("NativeOrderAudit")
    defer { RenderingSignpost.rendering.endInterval("NativeOrderAudit", span) }
    let started = Date()
    try Task.checkCancellation()
    let development = try NativeRAWDevelopment.develop(localData(pair.raw), recipe: recipe.input)
    let full = try development.linearFrame()
    let look = try MetalAuthoredLook(recipe)
    // Runtime emits encoded sRGB numbers and tags them at the HEIF writer.
    // Recreate that boundary explicitly before colour-managed Lanczos reduction.
    let transformed = try look.apply(full.rgba)
    try Task.checkCancellation()
    let native = try nativeOrderReducedFrame(RGBFrame(width: full.width, height: full.height, rgba: transformed))
    // Existing initializer: numerically reduce linear BT.2020 first, then look.
    let linearReduced = scaled(image(full).settingAlphaOne(in: CGRect(x: 0, y: 0, width: full.width, height: full.height)))
    let small = frame(linearReduced, width: Int(linearReduced.extent.width.rounded()),
                      height: Int(linearReduced.extent.height.rounded()))
    let initializer = try RGBFrame(width: small.width, height: small.height, rgba: look.apply(small.rgba))
    guard let exportedImage = try CIImage(data: localData(candidateURL.path), options: [.applyOrientationProperty: true]),
          let targetImage = try CIImage(data: localData(pair.target), options: [.applyOrientationProperty: true]),
          zeroOrigin(exportedImage).extent.size == CGSize(width: full.width, height: full.height),
          zeroOrigin(targetImage).extent.size == CGSize(width: full.width, height: full.height)
    else { throw HarnessError.incompatibleDimensions }
    let exported = try matchingReducedFrame(exportedImage), target = try matchingReducedFrame(targetImage)
    func score(_ a: RGBFrame, _ b: RGBFrame) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(colorScore(candidate: a, target: b)))
    }
    let report: [String: Any] = try [
        "contractVersion": 1, "id": pair.id, "role": pair.role.rawValue,
        "validationEvidence": false, "registered": false,
        "nativeWidth": full.width, "nativeHeight": full.height,
        "nativePreencodingVsExport": score(native, exported),
        "reducedInitializerVsNativeOrder": score(initializer, native),
        "nativePreencodingVsTarget": score(native, target),
        "exportVsTarget": score(exported, target),
        "reducedInitializerVsTarget": score(initializer, target),
        "elapsedMs": Date().timeIntervalSince(started) * 1000,
    ]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination, options: .withoutOverwriting)
    RenderingLog.rendering.noticeOperation("matching.nativeOrderAudit", phase: "complete", fields: [
        "id": pair.id, "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
    ])
    print("op=matching.nativeOrderAudit id=\(pair.id) native=\(full.width)x\(full.height) output=\(destination.path)")
}

func matchingReducedFrame(_ source: CIImage) throws -> RGBFrame {
    let reduced = try encodedImage(scaled(source))
    return frame(reduced, width: Int(reduced.extent.width.rounded()),
                 height: Int(reduced.extent.height.rounded()))
}

private func nativeOrderReducedFrame(_ pixels: RGBFrame) throws -> RGBFrame {
    let tagged = CIImage(bitmapData: pixels.rgba.withUnsafeBytes { Data($0) },
                         bytesPerRow: pixels.width * 16,
                         size: CGSize(width: pixels.width, height: pixels.height),
                         format: .RGBAf, colorSpace: displaySpace)
    return try matchingReducedFrame(tagged)
}

enum NativeRefinementControls: String { case toneOnly, toneAndNormalization }

enum NativeRefinementObjective: String { case normalizedLab, meanAndTailDE00 }

struct NativeMatchingObservation {
    let x: Double
    let y: Double
    let target: SIMD3<Double>
    let weight: Double
    let regionIndex: Int
}

/// Shared fixed correspondence and equal-region sampling for native-order fitting.
/// Full scored regions have up to1024 uniform points each. An inset would erase
/// small saturated objects. No source-noise or target-error exclusion changes
/// these observations; Gaussian support comes from the already blurred full frame.
func nativeMatchingObservations(regions: [AppearanceLookCard.Region], rows: [[String: Any]],
                                target: RGBFrame, maximumSensitivity: Double) throws
    -> (samples: [NativeMatchingObservation], regions: [String])
{
    var observations = [NativeMatchingObservation](), reliable = [String]()
    for (region, row) in zip(regions, rows) {
        guard row["name"] as? String == region.name else { throw HarnessError.invalidManifest }
        guard let sensitivity = row["meanDE00Sensitivity"] as? Double, sensitivity.isFinite, sensitivity >= 0,
              sensitivity <= maximumSensitivity,
              let correspondence = row["correspondence"] as? [String: Any],
              correspondence["status"] as? String == "measured-local",
              let dx = correspondence["dx"] as? Double, let dy = correspondence["dy"] as? Double,
              dx.isFinite, dy.isFinite else { continue }
        let q = region.rectangle
        var samples = [NativeMatchingObservation]()
        let x0 = Int(q[0] * Double(target.width)), x1 = Int(q[2] * Double(target.width))
        let y0 = Int(q[1] * Double(target.height)), y1 = Int(q[3] * Double(target.height))
        guard x1 > x0, y1 > y0 else { continue }
        var step = max(1, Int(ceil(sqrt(Double((x1 - x0) * (y1 - y0)) / 1024))))
        while ((x1 - x0 + step - 1) / step) * ((y1 - y0 + step - 1) / step) > 1024 {
            step += 1
        }
        for y in stride(from: y0, to: y1, by: step) {
            for x in stride(from: x0, to: x1, by: step) {
                let u = Double(x) + dx, v = Double(y) + dy
                guard u >= 0, v >= 0, u < Double(target.width - 1), v < Double(target.height - 1) else { continue }
                let i = (y * target.width + x) * 4
                let rgb = SIMD3(Double(target.rgba[i]), Double(target.rgba[i + 1]), Double(target.rgba[i + 2]))
                guard (0 ..< 3).allSatisfy({ rgb[$0].isFinite }) else { throw HarnessError.malformedReferenceData }
                let bounded = SIMD3(min(1, max(0, rgb.x)), min(1, max(0, rgb.y)), min(1, max(0, rgb.z)))
                samples.append(NativeMatchingObservation(x: u, y: v, target: DisplayColourObjective.normalizedLab.coordinates(bounded), weight: 1, regionIndex: reliable.count))
            }
        }
        guard !samples.isEmpty else { continue }
        reliable.append(region.name)
        observations += samples.map { NativeMatchingObservation(x: $0.x, y: $0.y, target: $0.target, weight: 1 / Double(samples.count), regionIndex: $0.regionIndex) }
    }
    guard reliable.count >= 8, observations.count >= 128 else { throw HarnessError.registrationFailed }
    return (observations, reliable)
}

/// Prediction follows native look, managed Lanczos reduction, then the frozen
/// encoded-space Gaussian. This shares the measured loss across model families.
private func nativeMatchingLoss(_ pixels: RGBFrame, observations: [NativeMatchingObservation],
                                regionCount: Int, objective: NativeRefinementObjective) -> Double
{
    var total = 0.0
    var errors = [(distance: Double, weight: Double)]()
    for sample in observations {
        let coordinates = nativeMatchingCoordinates(pixels, sample: sample)
        let e = coordinates - sample.target
        if objective == .normalizedLab {
            total += sample.weight * (e.x * e.x + e.y * e.y + e.z * e.z)
        } else {
            let prediction = coordinates * 100
            let reference = sample.target * 100
            let distance = ciede2000(Lab(l: prediction.x, a: prediction.y, b: prediction.z),
                                     Lab(l: reference.x, a: reference.y, b: reference.z))
            errors.append((distance, sample.weight / Double(regionCount)))
        }
    }
    if objective == .normalizedLab {
        total /= Double(regionCount)
    } else {
        let mean = errors.reduce(0) { $0 + $1.distance * $1.weight }
        var remaining = 0.05, tail = 0.0
        for error in errors.sorted(by: { $0.distance > $1.distance }) where remaining > 0 {
            let mass = min(remaining, error.weight)
            tail += mass * error.distance
            remaining -= mass
        }
        total = mean + 0.25 * tail / 0.05
    }
    return total
}

/// One interpolation/clamp/Lab boundary for scalar loss and distance Jacobians.
private func nativeMatchingCoordinates(_ pixels: RGBFrame, sample: NativeMatchingObservation) -> SIMD3<Double> {
    let x = Int(sample.x), y = Int(sample.y), fx = sample.x - Double(x), fy = sample.y - Double(y)
    var rgb = SIMD3<Double>(repeating: 0)
    for (ox, oy, weight) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
        let i = ((y + oy) * pixels.width + x + ox) * 4
        rgb += SIMD3(Double(pixels.rgba[i]), Double(pixels.rgba[i + 1]), Double(pixels.rgba[i + 2])) * weight
    }
    let bounded = SIMD3(min(1, max(0, rgb.x)), min(1, max(0, rgb.y)), min(1, max(0, rgb.z)))
    return DisplayColourObjective.normalizedLab.coordinates(bounded)
}

/// Same frozen samples and interpolation as the scalar native loss. The solver
/// differentiates observed distances, never reduced-input look parameters.
func nativeMatchingDistances(_ pixels: RGBFrame, observations: [NativeMatchingObservation]) -> [Double] {
    var errors = [Double]()
    for sample in observations {
        let prediction = nativeMatchingCoordinates(pixels, sample: sample) * 100
        let reference = sample.target * 100
        errors.append(ciede2000(Lab(l: prediction.x, a: prediction.y, b: prediction.z),
                                Lab(l: reference.x, a: reference.y, b: reference.z)))
    }
    return errors
}

/// Signed metric components share the same correspondence and colour boundary.
func nativeMatchingResiduals(_ pixels: RGBFrame, observations: [NativeMatchingObservation]) -> [SIMD3<Double>] {
    observations.map { sample in
        let prediction = nativeMatchingCoordinates(pixels, sample: sample) * 100, reference = sample.target * 100
        return ciede2000Residual(Lab(l: prediction.x, a: prediction.y, b: prediction.z),
                                 Lab(l: reference.x, a: reference.y, b: reference.z))
    }
}

/// Same samples and exact metric norm; Cartesian direction avoids a polar
/// residual basis singularity at achromatic pixels. Photographic gates are fixed.
func nativeMatchingCartesianResiduals(_ pixels: RGBFrame, observations: [NativeMatchingObservation]) -> [SIMD3<Double>] {
    observations.map { sample in
        let prediction = nativeMatchingCoordinates(pixels, sample: sample) * 100, reference = sample.target * 100
        return ciede2000CartesianResidual(Lab(l: prediction.x, a: prediction.y, b: prediction.z),
                                          Lab(l: reference.x, a: reference.y, b: reference.z))
    }
}

/// Bounded whole-image expression diagnostic, not an inference recipe. Geometry
/// and reliability come from the unchanged RAW baseline report. Existing tone
/// controls and optionally two input colour-balance gains vary offline.
func refineNativeOrder(_ pair: Pair, base: AuthoredLook, card: AppearanceLookCard,
                       geometryReport: Data, controls: NativeRefinementControls = .toneOnly,
                       objective: NativeRefinementObjective = .normalizedLab, destination: URL) throws
{
    try card.validate()
    guard pair.role == .regression, pair.session == String(pair.id.prefix(8)),
          !FileManager.default.fileExists(atPath: destination.path),
          let regions = card.regions[pair.id],
          let report = try JSONSerialization.jsonObject(with: geometryReport) as? [String: Any],
          report["formatVersion"] as? Int == 7,
          let rows = report["scores"] as? [[String: Any]], rows.count == regions.count,
          let digest = report["geometryBaselineSHA256"] as? String, !digest.isEmpty
    else { throw HarnessError.invalidManifest }
    try validate(Manifest(pairs: [pair]), output: destination)
    try Task.checkCancellation()
    let span = RenderingSignpost.rendering.beginInterval("NativeOrderRefine")
    defer { RenderingSignpost.rendering.endInterval("NativeOrderRefine", span) }
    let started = Date()
    let full = try NativeRAWDevelopment.develop(localData(pair.raw), recipe: base.input).linearFrame()
    guard let decoded = try CIImage(data: localData(pair.target), options: [.applyOrientationProperty: true]),
          zeroOrigin(decoded).extent.size == CGSize(width: full.width, height: full.height)
    else { throw HarnessError.incompatibleDimensions }
    let target = try gaussianBlur(matchingReducedFrame(decoded))
    let (observations, reliable) = try nativeMatchingObservations(regions: regions, rows: rows, target: target,
                                                                  maximumSensitivity: card.maximumSensitivityDE00)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let baseObject = try JSONSerialization.jsonObject(with: encoder.encode(base)) as! [String: Any]
    let names = ["contrast", "tonePivot", "skew", "saturation"]
    let bounds = [0.5 ... 2.5, 0.01 ... 8, 0.3 ... 3, 0.5 ... 1.5, 0.5 ... 2, 0.5 ... 2]
    func recipe(_ parameters: [Double]) throws -> AuthoredLook {
        var object = baseObject
        for (i, name) in names.enumerated() {
            object[name] = min(bounds[i].upperBound, max(bounds[i].lowerBound, exp(parameters[i])))
        }
        if controls == .toneAndNormalization {
            object["whiteBalanceRGB"] = [min(2, max(0.5, exp(parameters[4]))), base.whiteBalanceRGB[1], min(2, max(0.5, exp(parameters[5])))]
        }
        return try AuthoredLook(json: JSONSerialization.data(withJSONObject: object))
    }
    var evaluations = [[String: Any]]()
    func loss(_ look: AuthoredLook) throws -> Double {
        try Task.checkCancellation()
        let transformed = try MetalAuthoredLook(look).apply(full.rgba)
        let pixels = try gaussianBlur(nativeOrderReducedFrame(RGBFrame(width: full.width, height: full.height, rgba: transformed)))
        let total = nativeMatchingLoss(pixels, observations: observations, regionCount: reliable.count, objective: objective)
        evaluations.append(["loss": total, "contrast": look.contrast, "tonePivot": look.tonePivot, "skew": look.skew, "saturation": look.saturation, "whiteBalanceRGB": look.whiteBalanceRGB])
        print("op=matching.nativeOrderRefine id=\(pair.id) controls=\(controls.rawValue) objective=\(objective.rawValue) evaluation=\(evaluations.count) loss=\(total)")
        return total
    }
    var parameters = [log(base.contrast), log(base.tonePivot), log(base.skew), log(base.saturation)]
    if controls == .toneAndNormalization {
        parameters += [log(base.whiteBalanceRGB[0]), log(base.whiteBalanceRGB[2])]
    }
    var best = try loss(base)
    let initial = best
    // Two fixed passes and both directions: 17 or 25 native evaluations.
    // This is a local correction diagnostic, not a claim of global convergence.
    for step in [0.08, 0.04] {
        for c in parameters.indices {
            let current = parameters
            for direction in [-1.0, 1.0] {
                var trial = current
                trial[c] += direction * step * (c < 4 ? 1 : 0.5)
                let measured = try loss(recipe(trial))
                if measured < best {
                    best = measured
                    parameters = trial
                }
            }
        }
    }
    let fitted = try recipe(parameters)
    let result: [String: Any] = ["contractVersion": 2, "id": pair.id, "validationEvidence": false, "controls": controls.rawValue, "objective": objective.rawValue,
                                 "scope": "whole-image expression; fitted targets are not validation",
                                 "geometryBaselineSHA256": digest, "reliableRegions": reliable,
                                 "samples": observations.count, "initialLoss": initial, "loss": best,
                                 "evaluations": evaluations, "elapsedMs": Date().timeIntervalSince(started) * 1000]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("fit.json"), options: .withoutOverwriting)
    try encoder.encode(fitted).write(to: destination.appendingPathComponent("recipe.json"), options: .withoutOverwriting)
    RenderingLog.rendering.noticeOperation("matching.nativeOrderRefine", phase: "complete", fields: [
        "id": pair.id, "controls": controls.rawValue, "objective": objective.rawValue, "evaluations": String(evaluations.count), "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
    ])
}

/// Six affine directions and optionally three smooth channel-curve bends inside
/// existing coefficients; no new runtime stage or capacity. Each trial uses native input and the shared measured loss.
enum NativeProfileRefinementControls: String { case affine, affineAndCurves }

func refineNativeProfileOrder(_ pair: Pair, baseData: Data, card: AppearanceLookCard,
                              geometryReport: Data, geometryBaseline: Data,
                              controls: NativeProfileRefinementControls = .affine, destination: URL) throws
{
    try card.validate()
    _ = try LookModel(json: baseData)
    guard pair.role == .regression, pair.session == String(pair.id.prefix(8)),
          !FileManager.default.fileExists(atPath: destination.path),
          let regions = card.regions[pair.id],
          let report = try JSONSerialization.jsonObject(with: geometryReport) as? [String: Any],
          report["formatVersion"] as? Int == 7,
          let rows = report["scores"] as? [[String: Any]], rows.count == regions.count,
          let digest = report["geometryBaselineSHA256"] as? String,
          digest == SHA256.hash(data: geometryBaseline).description
    else { throw HarnessError.invalidManifest }
    try validate(Manifest(pairs: [pair]), output: destination)
    try Task.checkCancellation()
    let span = RenderingSignpost.rendering.beginInterval("NativeProfileOrderRefine")
    defer { RenderingSignpost.rendering.endInterval("NativeProfileOrderRefine", span) }
    let started = Date()
    let developed = try NativeRAWDevelopment.develop(localData(pair.raw), recipe: .mapped)
    let input = try encodedImage(developed.image)
    let full = frame(input, width: Int(input.extent.width.rounded()), height: Int(input.extent.height.rounded()))
    guard let decoded = try CIImage(data: localData(pair.target), options: [.applyOrientationProperty: true]),
          zeroOrigin(decoded).extent.size == CGSize(width: full.width, height: full.height)
    else { throw HarnessError.incompatibleDimensions }
    let target = try gaussianBlur(matchingReducedFrame(decoded))
    let (observations, reliable) = try nativeMatchingObservations(regions: regions, rows: rows, target: target,
                                                                  maximumSensitivity: card.maximumSensitivityDE00)
    var evaluations = [[String: Any]]()
    func modelData(_ parameters: [Double]) throws -> Data {
        try adjustedNativeProfile(baseData, gains: Array(parameters.prefix(3)).map(exp), offsets: Array(parameters[3 ..< 6]),
                                  curveBends: controls == .affineAndCurves ? Array(parameters.suffix(3)) : [0, 0, 0])
    }
    func loss(_ parameters: [Double]) throws -> Double {
        try Task.checkCancellation()
        let model = try LookModel(json: modelData(parameters))
        let transformed = try MetalLook(model: model).apply(full.rgba)
        let pixels = try gaussianBlur(nativeOrderReducedFrame(RGBFrame(width: full.width, height: full.height, rgba: transformed)))
        let value = nativeMatchingLoss(pixels, observations: observations, regionCount: reliable.count, objective: .meanAndTailDE00)
        evaluations.append(["parameters": parameters, "loss": value])
        print("op=matching.nativeProfileOrder id=\(pair.id) evaluation=\(evaluations.count) loss=\(value)")
        return value
    }
    let count = controls == .affine ? 6 : 9
    var parameters = [Double](repeating: 0, count: count)
    var best = try loss(parameters)
    let initial = best
    for step in [0.04, 0.02] {
        for channel in 0 ..< count {
            let current = parameters
            for direction in [-1.0, 1.0] {
                var trial = current
                let limits = channel < 3 ? log(0.5) ... log(2) : -0.1 ... 0.1
                trial[channel] = min(limits.upperBound, max(limits.lowerBound, trial[channel] + direction * step * ((3 ..< 6).contains(channel) ? 0.25 : 1)))
                let value = try loss(trial)
                if value < best {
                    best = value
                    parameters = trial
                }
            }
        }
    }
    let result: [String: Any] = ["contractVersion": 1, "id": pair.id, "validationEvidence": false,
                                 "scope": "bounded directions in existing profile; target-assisted expression only",
                                 "controls": controls.rawValue,
                                 "objective": NativeRefinementObjective.meanAndTailDE00.rawValue,
                                 "geometryBaselineSHA256": digest, "baseModelSHA256": SHA256.hash(data: baseData).description,
                                 "reliableRegions": reliable, "samples": observations.count,
                                 "parameters": parameters, "initialLoss": initial, "loss": best,
                                 "evaluations": evaluations, "elapsedMs": Date().timeIntervalSince(started) * 1000]
    try Task.checkCancellation()
    let fitted = try modelData(parameters)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("fit.json"), options: .withoutOverwriting)
    try fitted.write(to: destination.appendingPathComponent("model.json"), options: .withoutOverwriting)
    RenderingLog.rendering.noticeOperation("matching.nativeProfileOrder", phase: "complete", fields: [
        "id": pair.id, "controls": controls.rawValue, "evaluations": String(evaluations.count), "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
    ])
}

/// Gains scale both additive components; offsets are a constant LUT field. The
/// affine transform precedes the existing output clamp, exactly in format 2.
/// Bends add 4*t*(1-t) to each channel curve, with t its bounded original knot.
/// Gain >=0.5 and abs(bend)<=0.1 preserve monotonicity of a monotone base curve.
func adjustedNativeProfile(_ data: Data, gains: [Double], offsets: [Double], curveBends: [Double] = [0, 0, 0]) throws -> Data {
    guard gains.count == 3, offsets.count == 3, curveBends.count == 3,
          gains.allSatisfy({ $0.isFinite && (0.5 ... 2).contains($0) }), offsets.allSatisfy(\.isFinite),
          curveBends.allSatisfy({ $0.isFinite && abs($0) <= 0.1 })
    else { throw HarnessError.invalidManifest }
    let base = try LookModel(json: data)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object["curvesRGB"] = (0 ..< 3).map { c in base.curvesRGB[c].map { value in
        let t = min(1, max(0, value))
        return value * gains[c] + curveBends[c] * 4 * t * (1 - t)
    } }
    var lut = [[[[Double]]]]()
    for r in 0 ..< 9 {
        var green = [[[Double]]]()
        for g in 0 ..< 9 {
            var blue = [[Double]]()
            for b in 0 ..< 9 {
                blue.append((0 ..< 3).map { c in base.residualLUT[r][g][b][c] * gains[c] + offsets[c] })
            }
            green.append(blue)
        }
        lut.append(green)
    }
    object["residualLUT"] = lut
    object["note"] = "Native-order affine profile expression; target-assisted, not inference validation."
    let result = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    _ = try LookModel(json: result)
    return result
}

/// Affine directions must preserve identity at zero and the existing clamp order.
/// Synthetic expected colours exercise both curve and constant-LUT contributions.
func nativeProfileObservationSelfTest() throws {
    let knots = (0 ..< 49).map { Double($0) * 1.25 / 48 }
    let curve = knots.map { min(1, $0) }
    let object: [String: Any] = ["formatVersion": 2, "decoder": "9", "dimension": 9, "domain": [0, 1.25],
                                 "curveKnots": knots, "curvesRGB": [curve, curve, curve],
                                 "residualLUT": Array(repeating: Array(repeating: Array(repeating: [0.0, 0, 0], count: 9), count: 9), count: 9),
                                 "neutralSettings": ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0]]
    let data = try JSONSerialization.data(withJSONObject: object)
    let base = try LookModel(json: data)
    let identity = try LookModel(json: adjustedNativeProfile(data, gains: [1, 1, 1], offsets: [0, 0, 0]))
    let gains = [1.25, 0.7, 1.1], offsets = [-0.01, 0.02, 0.04]
    let changed = try LookModel(json: adjustedNativeProfile(data, gains: gains, offsets: offsets))
    var inputs = [Float](), expected = [[Double]]()
    for k in 0 ..< 24 {
        let rgb = [Double(k) / 24, Double(23 - k) / 24, Double(k % 7) / 7]
        guard try identity.evaluateRGB(rgb) == base.evaluateRGB(rgb) else { throw HarnessError.malformedReferenceData }
        let value = try changed.evaluateRGB(rgb)
        let wanted = (0 ..< 3).map { min(1, max(0, rgb[$0] * gains[$0] + offsets[$0])) }
        guard zip(value, wanted).allSatisfy({ abs($0 - $1) < 1e-12 }) else { throw HarnessError.malformedReferenceData }
        inputs += rgb.map(Float.init) + [1]
        expected.append(wanted)
    }
    let gpu = try MetalLook(model: changed).apply(inputs)
    for (i, wanted) in expected.enumerated() {
        guard (0 ..< 3).allSatisfy({ abs(Double(gpu[i * 4 + $0]) - wanted[$0]) < 2e-6 }), gpu[i * 4 + 3] == 1
        else { throw HarnessError.malformedReferenceData }
    }
    do {
        _ = try adjustedNativeProfile(data, gains: [1, -1, 1], offsets: [0, 0, 0])
        throw HarnessError.malformedReferenceData
    } catch HarnessError.invalidManifest {}
    let bends = [0.1, -0.1, 0.08]
    let bentData = try adjustedNativeProfile(data, gains: [0.5, 0.5, 0.5], offsets: [0, 0, 0], curveBends: bends)
    let bent = try LookModel(json: bentData)
    for k in 0 ..< 49 {
        let actual = try bent.evaluateRGB([knots[k], knots[k], knots[k]])
        for c in 0 ..< 3 {
            let wanted = curve[k] * 0.5 + bends[c] * 4 * curve[k] * (1 - curve[k])
            guard abs(actual[c] - wanted) < 1e-12 else { throw HarnessError.malformedReferenceData }
        }
    }
    guard bent.curvesRGB.allSatisfy({ zip($0, $0.dropFirst()).allSatisfy { $0 <= $1 } })
    else { throw HarnessError.malformedReferenceData }
    let id = "20260101_120000"
    let card = AppearanceLookCard(formatVersion: 5, maximumLightnessDifference: 2, maximumMedianDE00: 3,
                                  maximumChromaDifference: 3, maximumSensitivityDE00: 1,
                                  regions: [id: [.init(name: "fixed", rectangle: [0, 0, 1, 1])]])
    let report = try JSONSerialization.data(withJSONObject: ["formatVersion": 7, "scores": [["name": "fixed"]], "geometryBaselineSHA256": "wrong"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("camera-native-observation-test-\(UUID().uuidString)")
    for role in [PairRole.acceptance, .regression] {
        let pair = Pair(id: id, raw: "/synthetic-native-observations/missing.arw", target: "/synthetic-native-observations/unread.heif", session: "20260101", role: role)
        do {
            try refineNativeProfileOrder(pair, baseData: data, card: card, geometryReport: report, geometryBaseline: Data(), destination: root)
            throw HarnessError.malformedReferenceData
        } catch HarnessError.invalidManifest {}
    }
    guard !FileManager.default.fileExists(atPath: root.path) else { throw HarnessError.malformedReferenceData }
    print("Native curve directions: known knot colours, monotonicity, acceptance and wrong-baseline guards pass")
    print("Native profile affine directions: zero identity, expected CPU/Metal colours, alpha and invalid-gain rejection pass")
}
