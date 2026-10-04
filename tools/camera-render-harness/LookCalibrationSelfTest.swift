import CoreImage
import Foundation

/// Invalid calibration inputs must stop before producing a model or reading
/// media. The only bytes here are synthetic sampled-pixel fixtures in a private
/// temporary directory; the declared originals do not exist.
func lookCalibrationSelfTest() throws {
    guard calibrationPairValues(input: [-0.1, 0.6, 1.4], target: [0, 0.8, 1], sampling: .interior) == nil,
          calibrationPairValues(input: [-0.1, 0.6, 1.4], target: [0, 0.8, 1], sampling: .modelDomain) == [0, 0.6, 1.25, 0, 0.8, 1],
          calibrationPairValues(input: [.nan, 0, 0], target: [0, 0, 0], sampling: .modelDomain) == nil
    else { throw HarnessError.malformedReferenceData }
    let opaque = RGBFrame(width: 128, height: 96, rgba: Array(repeating: [Float(0.3), 0.5, 0.7, 0.9995117], count: 128 * 96).flatMap(\.self))
    guard isFiniteOpaqueNativeFrame(opaque) else { throw HarnessError.malformedReferenceData }
    for invalid in [Float(0.95), 1.1, .nan, .infinity] {
        var values = opaque.rgba
        values[3] = invalid
        guard !isFiniteOpaqueNativeFrame(RGBFrame(width: 128, height: 96, rgba: values)) else {
            throw HarnessError.malformedReferenceData
        }
    }
    var nonfiniteRGB = opaque.rgba
    nonfiniteRGB[0] = .nan
    guard !isFiniteOpaqueNativeFrame(RGBFrame(width: 128, height: 96, rgba: nonfiniteRGB)) else {
        throw HarnessError.malformedReferenceData
    }
    let prepared = try nativeCalibrationImage(opaque)
    let reduced = try encodedImage(scaled(prepared, longEdge: 32))
    let reducedPixels = frame(reduced, width: 32, height: 24)
    guard stride(from: 3, to: reducedPixels.rgba.count, by: 4).allSatisfy({ reducedPixels.rgba[$0] > 0.999 }) else {
        throw HarnessError.malformedReferenceData
    }
    var transparent = opaque.rgba
    transparent[3] = 0.9
    do {
        _ = try nativeCalibrationImage(RGBFrame(width: 128, height: 96, rgba: transparent))
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidSamples {}
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("camera-calibration-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func manifest(_ role: PairRole) -> Manifest {
        Manifest(pairs: (0 ..< 100).map {
            Pair(id: "sample\($0)", raw: "/synthetic-calibration-originals/\($0).arw",
                 target: "/synthetic-calibration-originals/\($0).hif", session: "synthetic", role: role)
        })
    }
    let destination = root.appendingPathComponent("model.json")
    do {
        try fitLookCalibration(manifest(.acceptance), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidTrainingManifest {}
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw HarnessError.malformedReferenceData
    }
    for role in [PairRole.acceptance, .selection, .regression] {
        do {
            try fitJointLookCalibration(manifest(role), samplesRoot: root, initialData: Data(), destination: destination)
            throw HarnessError.malformedReferenceData
        } catch LookCalibrationError.invalidTrainingManifest {}
    }
    let input = root.appendingPathComponent("sample0")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    let samples = input.appendingPathComponent("samples.f32")
    try Data([1, 2, 3]).write(to: samples)
    do {
        try fitLookCalibration(manifest(.training), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidSamples {}
    var invalid = [Float](repeating: 0.5, count: 500 * 6)
    let recipe: [String: Any] = [
        "contractVersion": 3, "decoder": "9", "samples": 500, "samplingPolicy": "interior",
        "sourcePreparation": "native-encoded-srgb-before-reduction",
        "nativeLensCorrectionSupported": true,
        "nativeLensCorrectionEnabled": true, "calibrationBlurRadius": 1.2,
        "evaluationLongEdge": 768,
        "neutralSettings": ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0],
    ]
    let recipePath = input.appendingPathComponent("recipe.json")
    try JSONSerialization.data(withJSONObject: recipe).write(to: recipePath)
    invalid[0] = .nan
    try invalid.withUnsafeBytes { try Data($0).write(to: samples) }
    do {
        try fitLookCalibration(manifest(.training), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidSamples {}
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw HarnessError.malformedReferenceData
    }
    invalid[0] = 0.5
    try invalid.withUnsafeBytes { try Data($0).write(to: samples) }
    var wrongRecipe = recipe
    wrongRecipe["decoder"] = "8"
    try JSONSerialization.data(withJSONObject: wrongRecipe).write(to: recipePath)
    do {
        try fitLookCalibration(manifest(.training), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidSamples {}
    for change in ["contractVersion", "sourcePreparation", "nativeLensCorrectionEnabled"] {
        var mismatched = recipe
        switch change {
        case "contractVersion": mismatched[change] = 2
        case "sourcePreparation": mismatched[change] = "reduced-decoder"
        default: mismatched[change] = false
        }
        try JSONSerialization.data(withJSONObject: mismatched).write(to: recipePath)
        do {
            _ = try calibrationSamples(manifest(.training), root: root)
            throw HarnessError.malformedReferenceData
        } catch LookCalibrationError.invalidSamples {}
    }
    try JSONSerialization.data(withJSONObject: recipe).write(to: recipePath)
    guard try calibrationSamples(Manifest(pairs: [manifest(.training).pairs[0]]), root: root).count == 500 else {
        throw HarnessError.malformedReferenceData
    }
    var unsupportedLensRecipe = recipe
    unsupportedLensRecipe["nativeLensCorrectionSupported"] = false
    unsupportedLensRecipe["nativeLensCorrectionEnabled"] = false
    try JSONSerialization.data(withJSONObject: unsupportedLensRecipe).write(to: recipePath)
    guard try calibrationSamples(Manifest(pairs: [manifest(.training).pairs[0]]), root: root).count == 500 else {
        throw HarnessError.malformedReferenceData
    }
    var domainRecipe = recipe
    domainRecipe["contractVersion"] = 4
    domainRecipe["samplingPolicy"] = "modelDomain"
    try JSONSerialization.data(withJSONObject: domainRecipe).write(to: recipePath)
    do {
        try fitLookCalibration(manifest(.training), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidSamples {}
    try JSONSerialization.data(withJSONObject: recipe).write(to: recipePath)
    do {
        try fitLookCalibration(manifest(.training), samplesRoot: root, destination: destination, sampling: .modelDomain)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidSamples {}
    let existing = Data("preserve calibration".utf8)
    try existing.write(to: destination)
    do {
        try fitLookCalibration(manifest(.training), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.existingOutput {}
    guard try Data(contentsOf: destination) == existing else { throw HarnessError.malformedReferenceData }
    let unsupported = root.appendingPathComponent("unsupported.arw")
    try Data("synthetic unsupported image".utf8).write(to: unsupported)
    let pair = Pair(id: "unsupported", raw: unsupported.path,
                    target: root.appendingPathComponent("unread-target.hif").path,
                    session: "synthetic", role: .training)
    do {
        try exportLookCalibrationPair(pair, output: root)
        throw HarnessError.malformedReferenceData
    } catch CameraSensorRAWHEIFRenderer.Failure.unsupportedOriginal {}
    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(pair.id).path) else {
        throw HarnessError.malformedReferenceData
    }
    let diagnosticID = "20260101_120000"
    let diagnosticCard = AppearanceLookCard(formatVersion: 5, maximumLightnessDifference: 2, maximumMedianDE00: 3,
                                            maximumChromaDifference: 3, maximumSensitivityDE00: 1,
                                            regions: [diagnosticID: [.init(name: "fixed", rectangle: [0, 0, 1, 1])]])
    let diagnosticReport = try JSONSerialization.data(withJSONObject: ["formatVersion": 7,
                                                                       "scores": [["name": "fixed"]],
                                                                       "geometryBaselineSHA256": "wrong baseline hash"])
    let diagnosticDestination = root.appendingPathComponent("native-profile")
    for role in [PairRole.acceptance, .regression] {
        let diagnosticPair = Pair(id: diagnosticID, raw: "/synthetic-calibration-originals/missing.arw",
                                  target: "/synthetic-calibration-originals/unread.heif", session: "20260101", role: role)
        do {
            try nativeProfileCapacity(diagnosticPair, card: diagnosticCard, geometryReport: diagnosticReport,
                                      geometryBaseline: Data("declared baseline".utf8), destination: diagnosticDestination)
            throw HarnessError.malformedReferenceData
        } catch LookCalibrationError.invalidTrainingManifest {}
        guard !FileManager.default.fileExists(atPath: diagnosticDestination.path) else { throw HarnessError.malformedReferenceData }
    }
    print("Native profile: acceptance and wrong-baseline rejection precede nonexistent original reads")
    try nativeProfileSolverSelfTest()
    print("Calibration holdout-role, malformed/non-finite sample, unsupported original and no-overwrite fixtures: pass")
}
