import Foundation

/// Synthetic models exercise predictor boundaries without any media reads.
func conditionalProfileSelfTest() throws {
    let curve = (0 ..< 49).map { Double($0) * 1.25 / 48 }
    let base: [String: Any] = ["formatVersion": 2, "decoder": "9", "dimension": 9, "domain": [0, 1.25],
                               "curveKnots": curve, "curvesRGB": [curve, curve, curve],
                               "residualLUT": Array(repeating: Array(repeating: Array(repeating: [0.0, 0, 0], count: 9), count: 9), count: 9),
                               "neutralSettings": ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0]]
    for kind in [ConditionalProfile.Kind.constant, .wb, .iso, .wbISO] {
        let fields = (0 ..< ConditionalProfile.fieldCount(kind)).map { f in
            (0 ..< 81).map { _ in Double(f) * 0.02 }
        }
        var object: [String: Any] = ["formatVersion": 1, "kind": kind.rawValue, "base": base,
                                     "miredKnots": [125, 200, 400], "isoStops": [0, 7], "fields": fields]
        let model = try ConditionalProfile(data: JSONSerialization.data(withJSONObject: object))
        for temperature in [100.0, 2500, 4000, 5000, 8000, 100_000] {
            for iso in [1.0, 100, 800, 12800, 100_000] {
                let weights = try ConditionalProfile.weights(kind: kind, temperature: temperature, iso: iso)
                guard weights.count == fields.count, weights.allSatisfy({ $0 >= 0 && $0 <= 1 }),
                      abs(weights.reduce(0, +) - 1) < 1e-12 else { throw HarnessError.malformedReferenceData }
                let expected = 0.2 + weights.indices.reduce(0) { $0 + weights[$1] * Double($1) * 0.02 }
                let selected = try model.model(temperature: temperature, iso: iso)
                let cpu = try selected.evaluateRGB([0.2, 0.2, 0.2])
                let gpu = try MetalLook(model: selected).apply([0.2, 0.2, 0.2, 0.7])
                guard cpu.allSatisfy({ abs($0 - expected) < 1e-12 }),
                      (0 ..< 3).allSatisfy({ abs(Double(gpu[$0]) - expected) < 2e-6 }), gpu[3] == Float(0.7)
                else { throw HarnessError.malformedReferenceData }
            }
        }
        object["fields"] = [[Double](repeating: 0.26, count: 81)]
        do {
            _ = try ConditionalProfile(data: JSONSerialization.data(withJSONObject: object))
            throw HarnessError.malformedReferenceData
        } catch ReferenceError.unsupportedModel {}
    }
    for kind in [ConditionalProfile.Kind.wb, .wbISO] {
        do {
            _ = try ConditionalProfile.weights(kind: kind, temperature: .nan, iso: 100)
            throw HarnessError.malformedReferenceData
        } catch HarnessError.invalidManifest {}
    }
    for kind in [ConditionalProfile.Kind.iso, .wbISO] {
        do {
            _ = try ConditionalProfile.weights(kind: kind, temperature: 5000, iso: 0)
            throw HarnessError.malformedReferenceData
        } catch HarnessError.invalidManifest {}
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conditional-guards-\(UUID().uuidString)")
    for role in [PairRole.selection, .regression, .acceptance] {
        let manifest = Manifest(pairs: (0 ..< 100).map { Pair(id: "sample\($0)", raw: "/missing/\($0).arw", target: "/unread/\($0).hif", session: "synthetic", role: role) })
        do {
            try fitConditionalProfile(manifest, root: directory, metadata: Data(), baseData: Data(), kind: .wbISO, destination: directory)
            throw HarnessError.malformedReferenceData
        } catch HarnessError.invalidManifest {}
    }
    guard !FileManager.default.fileExists(atPath: directory.path) else { throw HarnessError.malformedReferenceData }
    let training = Manifest(pairs: (0 ..< 100).map { Pair(id: "sample\($0)", raw: "/missing/\($0).arw", target: "/unread/\($0).hif", session: "synthetic", role: .training) })
    let record: [String: Any] = ["id": "sample0", "status": "verified", "iso": 100]
    do {
        try fitConditionalProfile(training, root: directory, metadata: JSONSerialization.data(withJSONObject: [record, record]), baseData: JSONSerialization.data(withJSONObject: base), kind: .wbISO, destination: directory)
        throw HarnessError.malformedReferenceData
    } catch HarnessError.invalidManifest {}
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try fitConditionalProfile(training, root: directory, metadata: Data(), baseData: Data(), kind: .wbISO, destination: directory)
        throw HarnessError.malformedReferenceData
    } catch HarnessError.invalidManifest {}
    print("Conditional profile: convex endpoints, input rejection, CPU/Metal and training-role boundaries pass")
}
