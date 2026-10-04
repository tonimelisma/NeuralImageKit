import CoreImage
import CryptoKit
import Foundation
import ImageIO
import simd

/// A single RAW-metadata selector blends shared colour fields; no photo lookup.
/// Reciprocal-temperature and log-ISO interpolation is continuous and convex,
/// keeping every selected coefficient inside the trained field bounds.
struct ConditionalProfile {
    enum Kind: String { case constant, wb, iso, wbISO }
    let kind: Kind
    var fieldCount: Int {
        Self.fieldCount(kind)
    }

    static func fieldCount(_ kind: Kind) -> Int {
        switch kind
        { case .constant: 1
        case .wb: 3
        case .iso: 2
        case .wbISO: 6 }
    }

    let baseData: Data
    let fields: [[Double]]

    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["formatVersion"] as? Int == 1,
              let name = object["kind"] as? String, let kind = Kind(rawValue: name),
              let base = object["base"] as? [String: Any], let fields = object["fields"] as? [[Double]],
              object["miredKnots"] as? [Double] == [125, 200, 400],
              object["isoStops"] as? [Double] == [0, 7],
              fields.count == Self.fieldCount(kind),
              fields.allSatisfy({ $0.count == 81 && $0.allSatisfy { $0.isFinite && abs($0) <= 0.25 } })
        else { throw ReferenceError.unsupportedModel }
        let baseData = try JSONSerialization.data(withJSONObject: base, options: [.sortedKeys])
        _ = try LookModel(json: baseData)
        self.kind = kind
        self.baseData = baseData
        self.fields = fields
    }

    static func weights(kind: Kind, temperature: Double, iso: Double) throws -> [Double] {
        if kind == .constant {
            return [1]
        }
        guard kind == .iso || (temperature.isFinite && temperature > 0),
              kind == .wb || (iso.isFinite && iso > 0) else { throw HarnessError.invalidManifest }
        let mired = kind == .iso ? 200 : min(400, max(125, 1_000_000 / temperature))
        let knots = [125.0, 200, 400], low = mired <= 200 ? 0 : 1
        let t = (mired - knots[low]) / (knots[low + 1] - knots[low])
        let highISO = kind == .wb ? 0 : min(1, max(0, log2(iso / 100) / 7))
        if kind == .iso {
            return [1 - highISO, highISO]
        }
        if kind == .wb {
            var result = [Double](repeating: 0, count: 3)
            result[low] = 1 - t
            result[low + 1] = t
            return result
        }
        var result = [Double](repeating: 0, count: 6)
        for (node, amount) in [(low, 1 - t), (low + 1, t)] {
            result[node * 2] = amount * (1 - highISO)
            result[node * 2 + 1] = amount * highISO
        }
        return result
    }

    func model(temperature: Double, iso: Double) throws -> LookModel {
        let weights = try Self.weights(kind: kind, temperature: temperature, iso: iso)
        let coefficients = (0 ..< 81).map { i in
            min(0.25, max(-0.25, fields.indices.reduce(0) { $0 + fields[$1][i] * weights[$1] }))
        }
        return try LookModel(json: nativeFieldProfile(baseData, coefficients: coefficients))
    }

    func model(development: NativeRAWDevelopment) throws -> LookModel {
        if kind == .constant {
            return try model(temperature: 1, iso: 1)
        }
        if kind == .wb {
            return try model(temperature: Double(development.temperature), iso: 1)
        }
        let exif = development.properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        guard let values = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
              let iso = values.first?.doubleValue else { throw HarnessError.invalidManifest }
        return try model(temperature: Double(development.temperature), iso: iso)
    }
}

/// Same endpoint-inclusive training observations and base profile for both
/// controls. Target access belongs to offline sample export, never inference.
func fitConditionalProfile(_ manifest: Manifest, root: URL, metadata: Data, baseData: Data,
                           kind: ConditionalProfile.Kind, destination: URL) throws
{
    guard manifest.pairs.count >= 100, manifest.pairs.allSatisfy({ $0.role == .training }),
          !FileManager.default.fileExists(atPath: destination.path),
          let records = try JSONSerialization.jsonObject(with: metadata) as? [[String: Any]] else { throw HarnessError.invalidManifest }
    try validate(manifest, output: root)
    try validate(manifest, output: destination)
    let span = RenderingSignpost.rendering.beginInterval("SharedConditionalFit")
    defer { RenderingSignpost.rendering.endInterval("SharedConditionalFit", span) }
    let base = try LookModel(json: baseData), started = Date(), count = ConditionalProfile.fieldCount(kind), n = count * 27
    var normal = [Double](repeating: 0, count: n * n), rhs = Array(repeating: [Double](repeating: 0, count: n), count: 3)
    var samples = 0
    var metadataByID = [String: Double]()
    for record in records {
        guard let id = record["id"] as? String, record["status"] as? String == "verified",
              let iso = record["iso"] as? Double, iso > 0, iso.isFinite,
              metadataByID.updateValue(iso, forKey: id) == nil else { throw HarnessError.invalidManifest }
    }
    for pair in manifest.pairs {
        try Task.checkCancellation()
        guard let recipe = try JSONSerialization.jsonObject(with: localData(root.appendingPathComponent(pair.id).appendingPathComponent("recipe.json").path)) as? [String: Any] else { throw HarnessError.invalidManifest }
        guard let temperature = recipe["temperature"] as? Double, let iso = metadataByID[pair.id] else { throw HarnessError.invalidManifest }
        let features = try ConditionalProfile.weights(kind: kind, temperature: temperature, iso: iso)
        let points = try calibrationSamples(Manifest(pairs: [pair]), root: root, sampling: .modelDomain)
        for point in points {
            let q = point.input / 1.25 * 2
            let lo = SIMD3(min(1, Int(q.x)), min(1, Int(q.y)), min(1, Int(q.z)))
            let fraction = q - SIMD3(Double(lo.x), Double(lo.y), Double(lo.z))
            var basis = [(Int, Double)]()
            for r in 0 ... 1 {
                for g in 0 ... 1 {
                    for b in 0 ... 1 {
                        let node = (lo.x + r) * 9 + (lo.y + g) * 3 + lo.z + b
                        let weight = (r == 0 ? 1 - fraction.x : fraction.x) * (g == 0 ? 1 - fraction.y : fraction.y) * (b == 0 ? 1 - fraction.z : fraction.z)
                        for feature in features.indices where features[feature] * weight > 0 {
                            basis.append((feature * 27 + node, features[feature] * weight))
                        }
                    }
                }
            }
            let prediction = try base.evaluateRGB([point.input.x, point.input.y, point.input.z], clampOutput: false)
            for (a, wa) in basis {
                for c in 0 ..< 3 {
                    rhs[c][a] += point.weight * wa * (point.target[c] - prediction[c])
                }
                for (b, wb) in basis {
                    normal[a + n * b] += point.weight * wa * wb
                }
            }
            samples += 1
        }
        print("op=conditional.exportedObservations id=\(pair.id) samples=\(samples)")
    }
    /// Fixed positive ridge and neighbour priors in colour and metadata grids.
    func connect(_ a: Int, _ b: Int) {
        normal[a + n * a] += 10
        normal[b + n * b] += 10
        normal[a + n * b] -= 10
        normal[b + n * a] -= 10
    }
    for field in 0 ..< count {
        for r in 0 ..< 3 {
            for g in 0 ..< 3 {
                for b in 0 ..< 3 {
                    let node = r * 9 + g * 3 + b, a = field * 27 + node
                    normal[a + n * a] += 2
                    for (step, coordinate) in [(9, r), (3, g), (1, b)] where coordinate < 2 {
                        connect(a, a + step)
                    }
                    if kind == .wb, field < 2 {
                        connect(a, a + 27)
                    }
                    if kind == .iso, field == 0 {
                        connect(a, a + 27)
                    }
                    if kind == .wbISO {
                        if field % 2 == 0 {
                            connect(a, a + 27)
                        }
                        if field < 4 {
                            connect(a, a + 54)
                        }
                    }
                }
            }
        }
    }
    let channels = try (0 ..< 3).map { try boundedColourSolution(normal, rhs[$0], bound: 0.25) }
    let fields = (0 ..< count).map { f in (0 ..< 81).map { i in channels[i % 3][f * 27 + i / 3] } }
    let object: [String: Any] = try ["formatVersion": 1, "kind": kind.rawValue,
                                     "base": JSONSerialization.jsonObject(with: baseData), "miredKnots": [125, 200, 400], "isoStops": [0, 7], "fields": fields]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    _ = try ConditionalProfile(data: data)
    let report: [String: Any] = try ["scope": "shared RAW metadata field predictor; RGB surrogate; native validation required",
                                     "validationEvidence": false, "kind": kind.rawValue,
                                     "captureAuditSHA256": SHA256.hash(data: metadata).description,
                                     "trainingManifestSHA256": SHA256.hash(data: JSONSerialization.data(withJSONObject: manifest.pairs.map { ["id": $0.id, "raw": $0.raw, "target": $0.target, "session": $0.session, "role": $0.role.rawValue] }, options: [.sortedKeys])).description, "images": manifest.pairs.count, "samples": samples,
                                     "fieldDimension": 3, "coefficientBound": 0.25, "ridge": 2, "neighborPenalty": 10,
                                     "baseSHA256": SHA256.hash(data: baseData).description, "modelSHA256": SHA256.hash(data: data).description,
                                     "elapsedMs": Date().timeIntervalSince(started) * 1000]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try data.write(to: destination.appendingPathComponent("model.json"), options: .withoutOverwriting)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("fit.json"), options: .withoutOverwriting)
    RenderingLog.rendering.noticeOperation("calibration.sharedConditional", phase: "complete", fields: ["kind": kind.rawValue, "images": String(manifest.pairs.count), "samples": String(samples), "elapsedMs": String(Date().timeIntervalSince(started) * 1000)])
    print("op=conditional.fit kind=\(kind.rawValue) samples=\(samples) elapsedMs=\(Date().timeIntervalSince(started) * 1000)")
}
