import Foundation
import simd

/// The public diagnostic must keep appearance-validation pixels out of its fit,
/// reject acceptance roles, and never reuse an existing output directory.
func authoredCapacitySelfTest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("authored-capacity-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = "20260101_120000", width = 768, height = 64
    let samples = root.appendingPathComponent("samples"), folder = samples.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let pair = Pair(id: id, raw: root.appendingPathComponent("media/original.arw").path,
                    target: root.appendingPathComponent("media/reference.heif").path,
                    session: "20260101", role: .regression)
    let region = AppearanceLookCard.Region(name: "withheld", rectangle: [0, 0, 0.5, 0.5])
    let card = AppearanceLookCard(formatVersion: 5, maximumLightnessDifference: 2, maximumMedianDE00: 3,
                                  maximumChromaDifference: 3, maximumSensitivityDE00: 1, regions: [id: [region]])
    var source = [Float](), target = [Float]()
    for y in 0 ..< height {
        for x in 0 ..< width {
            let v = 0.01 + Double(x) / Double(width)
            let linear = v / (v + 0.4)
            let encoded = Float(1.055 * pow(linear, 1 / 2.4) - 0.055)
            source += [Float(v), Float(v), Float(v), 1]
            target += x < width / 2 && y < height / 2 ? [0.95, 0.1, 0.4, 1] : [encoded, encoded, encoded, 1]
        }
    }
    func write(_ values: [Float], name: String) throws {
        try values.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent(name)) }
    }
    try write(source, name: "scene-frame.f32")
    try write(target, name: "target-frame.f32")
    let recipe: [String: Any] = ["contractVersion": 10, "decoder": "9", "width": width, "height": height,
                                 "gamutMappingEnabled": true, "nativeLensCorrectionEnabled": true, "shadowBias": 3,
                                 "baselineExposure": 0.4, "workingPrimaries": "ITU-R BT.2020", "workingTransfer": "linear",
                                 "developmentWorkingSpace": "extended linear sRGB", "role": "regression"]
    try JSONSerialization.data(withJSONObject: recipe).write(to: folder.appendingPathComponent("recipe.json"))
    let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
    try AuthoredCalibration.capacity(Manifest(pairs: [pair]), samplesRoot: samples, input: .mapped,
                                     mode: .perChannel, card: card, destination: first)
    let expressionFirst = root.appendingPathComponent("expression-first")
    try AuthoredCalibration.capacity(Manifest(pairs: [pair]), samplesRoot: samples, input: .mapped,
                                     mode: .perChannel, card: card, scope: .wholeImageExpression, destination: expressionFirst)
    let expressionReport = try JSONSerialization.jsonObject(with: localData(expressionFirst.appendingPathComponent(id + ".fit.json").path)) as! [String: Any]
    guard expressionReport["validationEvidence"] as? Bool == false,
          expressionReport["excludedRegions"] as? [String] == [],
          expressionReport["scope"] as? String == "wholeImageExpression" else { throw ReferenceError.invalidPixels }
    for y in 0 ..< height / 2 {
        for x in 0 ..< width / 2 {
            let i = (y * width + x) * 4
            target.replaceSubrange(i ..< i + 3, with: [Float(0.02), 0.9, 0.03])
        }
    }
    try write(target, name: "target-frame.f32")
    try AuthoredCalibration.capacity(Manifest(pairs: [pair]), samplesRoot: samples, input: .mapped,
                                     mode: .perChannel, card: card, destination: second)
    guard try localData(first.appendingPathComponent(id + ".json").path) == localData(second.appendingPathComponent(id + ".json").path) else {
        throw ReferenceError.invalidPixels
    }
    let expressionSecond = root.appendingPathComponent("expression-second")
    try AuthoredCalibration.capacity(Manifest(pairs: [pair]), samplesRoot: samples, input: .mapped,
                                     mode: .perChannel, card: card, scope: .wholeImageExpression, destination: expressionSecond)
    let expressionA = try AuthoredLook(json: localData(expressionFirst.appendingPathComponent(id + ".json").path))
    let expressionB = try AuthoredLook(json: localData(expressionSecond.appendingPathComponent(id + ".json").path))
    guard simd_length(expressionA.evaluate(SIMD3(repeating: 0.25)) - expressionB.evaluate(SIMD3(repeating: 0.25))) > 1e-5 else {
        throw ReferenceError.invalidPixels
    }
    let acceptance = Pair(id: id, raw: pair.raw, target: pair.target, session: pair.session, role: .acceptance)
    do {
        try AuthoredCalibration.capacity(Manifest(pairs: [acceptance]), samplesRoot: samples, input: .mapped,
                                         mode: .perChannel, card: card, destination: root.appendingPathComponent("forbidden"))
        throw ReferenceError.invalidPixels
    } catch LookCalibrationError.invalidTrainingManifest {}
    do {
        try AuthoredCalibration.capacity(Manifest(pairs: [pair]), samplesRoot: samples, input: .mapped,
                                         mode: .perChannel, card: card, destination: first)
        throw ReferenceError.invalidPixels
    } catch LookCalibrationError.invalidTrainingManifest {}
    let baseObject: [String: Any] = ["formatVersion": 5, "decoder": "9", "input": "mapped", "gamutPolicy": "smoothRadial",
                                     "exposureEV": 0, "whiteBalanceRGB": [1, 1, 1], "contrast": 1, "tonePivot": 0.4, "skew": 1,
                                     "toneMode": "perChannel", "huePreservation": 0.5, "saturation": 1]
    let base = try AuthoredLook(json: JSONSerialization.data(withJSONObject: baseObject))
    var colourSource = [Float](), colourTarget = [Float]()
    for y in 0 ..< height {
        for x in 0 ..< width {
            let v = SIMD3<Double>(0.05 + Double(x) / Double(width), 0.03 + Double(y) / Double(height), 0.02 + 0.3 * Double(x) / Double(width))
            let expected = base.evaluate(v)
            colourSource += [Float(v.x), Float(v.y), Float(v.z), 1]
            colourTarget += [Float(expected.x), Float(expected.y), Float(expected.z), 1]
        }
    }
    try write(colourSource, name: "scene-frame.f32")
    try write(colourTarget, name: "target-frame.f32")
    let colourFirst = root.appendingPathComponent("colour-first"), colourSecond = root.appendingPathComponent("colour-second")
    try AuthoredCalibration.colourCapacity(Manifest(pairs: [pair]), samplesRoot: samples, base: base, card: card, destination: colourFirst)
    for y in 0 ..< height / 2 {
        for x in 0 ..< width / 2 {
            let i = (y * width + x) * 4
            colourTarget.replaceSubrange(i ..< i + 3, with: [Float(0.99), 0.04, 0.81])
        }
    }
    try write(colourTarget, name: "target-frame.f32")
    try AuthoredCalibration.colourCapacity(Manifest(pairs: [pair]), samplesRoot: samples, base: base, card: card, destination: colourSecond)
    guard try localData(colourFirst.appendingPathComponent(id + ".json").path) == localData(colourSecond.appendingPathComponent(id + ".json").path) else { throw ReferenceError.invalidPixels }
    do {
        try AuthoredCalibration.colourCapacity(Manifest(pairs: [acceptance]), samplesRoot: samples, base: base, card: card, destination: root.appendingPathComponent("colour-forbidden"))
        throw ReferenceError.invalidPixels
    } catch LookCalibrationError.invalidTrainingManifest {}
    do {
        try AuthoredCalibration.colourCapacity(Manifest(pairs: [pair]), samplesRoot: samples, base: base, card: card, destination: colourFirst)
        throw ReferenceError.invalidPixels
    } catch LookCalibrationError.invalidTrainingManifest {}
    print("Colour capacity: spatial/palette withheld-region mutation independence, acceptance rejection and no overwrite pass")
    print("Authored capacity: withheld-region mutation independence, acceptance rejection and no overwrite pass")
    let training = Manifest(pairs: (0 ..< 100).map { index in
        Pair(id: "20251231_\(String(format: "%06d", index))", raw: pair.raw, target: pair.target, session: "20251231", role: .training)
    })
    for forbiddenRole in [PairRole.selection, .acceptance, .regression] {
        let forbidden = Pair(id: id, raw: pair.raw, target: pair.target, session: "20260101", role: forbiddenRole)
        do {
            try AuthoredCalibration.authorLook(Manifest(pairs: [forbidden]), samplesRoot: samples, base: base,
                                               card: card, training: training, trainingRoot: samples, mixture: 0.5, objectiveSpace: .encodedRGB, destination: root.appendingPathComponent("author-forbidden"))
            throw ReferenceError.invalidPixels
        } catch LookCalibrationError.invalidTrainingManifest {}
    }
    let author = Pair(id: id, raw: pair.raw, target: pair.target, session: "20260101", role: .authoring)
    let leakedTraining = Manifest(pairs: (0 ..< 100).map { index in
        Pair(id: "20260101_\(String(format: "%06d", index))", raw: pair.raw, target: pair.target, session: "20260101", role: .training)
    })
    do {
        try AuthoredCalibration.authorLook(Manifest(pairs: [author]), samplesRoot: samples, base: base,
                                           card: card, training: leakedTraining, trainingRoot: samples, mixture: 0.5, objectiveSpace: .encodedRGB, destination: root.appendingPathComponent("author-leaked"))
        throw ReferenceError.invalidPixels
    } catch LookCalibrationError.invalidTrainingManifest {}
    print("Authoring: selection/acceptance/regression rejection and capture-date leakage rejection pass")
}
