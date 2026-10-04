import Accelerate
import CoreImage
import CryptoKit
import Foundation
import simd

/// Native training for the explicit look. Sampling is an initializer: only actual
/// native HEIFs can establish photographic acceptance or exact-export capacity.
enum AuthoredCalibration {
    enum DiagnosticScope: String { case withheldRegions, wholeImageExpression }

    private struct Sample {
        let input: SIMD3<Double>
        let target: SIMD3<Double>
        let weight: Double
    }

    private struct Recipe: Decodable {
        let contractVersion: Int
        let decoder: String
        let width: Int
        let height: Int
        let gamutMappingEnabled: Bool
        let nativeLensCorrectionEnabled: Bool
        let shadowBias: Double
        let baselineExposure: Double
        let developmentWorkingSpace: String
        let workingPrimaries: String
        let workingTransfer: String
        let role: String
    }

    static func fit(_ manifest: Manifest, samplesRoot: URL, input: NativeRAWRecipe,
                    mode: AuthoredLook.ToneMode, destination: URL) throws
    {
        let start = Date()
        guard input != .appleDefault, manifest.pairs.count >= 100,
              manifest.pairs.allSatisfy({ $0.role == .training && $0.session == String($0.id.prefix(8)) }),
              Set(manifest.pairs.map(\.id)).count == manifest.pairs.count,
              !FileManager.default.fileExists(atPath: destination.path)
        else { throw LookCalibrationError.invalidTrainingManifest }
        try validate(manifest, output: destination.deletingLastPathComponent())
        var samples = [Sample](), targetResamplingOutOfRangeSamples = 0
        for pair in manifest.pairs {
            let observations = try readSamples(pair, root: samplesRoot, input: input)
            targetResamplingOutOfRangeSamples += observations.clampedTargets
            samples += observations.samples.map { Sample(input: $0.input, target: $0.target, weight: $0.weight / Double(manifest.pairs.count)) }
        }
        let (recipe, loss) = try solve(samples, input: input, mode: mode)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let recipeData = try encoder.encode(recipe)
        try recipeData.write(to: destination, options: .withoutOverwriting)
        let report: [String: Any] = ["kind": "training-only native-input initialization, not exact-export capacity",
                                     "images": manifest.pairs.count, "dateGroups": Set(manifest.pairs.map(\.session)).count,
                                     "samples": samples.count, "targetResamplingOutOfRangeSamples": targetResamplingOutOfRangeSamples, "weightedRGBLoss": loss, "input": input.rawValue, "toneMode": mode.rawValue,
                                     "seconds": Date().timeIntervalSince(start), "recipeSHA256": SHA256.hash(data: recipeData).description]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathExtension("fit.json"), options: .withoutOverwriting)
        print("op=authored.fit complete=true images=\(manifest.pairs.count) samples=\(samples.count) loss=\(loss) seconds=\(Date().timeIntervalSince(start))")
    }

    private static func readSamples(_ pair: Pair, root samplesRoot: URL, input: NativeRAWRecipe,
                                    excluding: [AppearanceLookCard.Region] = [], minimumSamples: Int = 100, colourLook: AuthoredLook? = nil, authoringRegions: [AppearanceLookCard.Region] = []) throws
        -> (samples: [Sample], clampedTargets: Int)
    {
        var targetResamplingOutOfRangeSamples = 0
        let root = samplesRoot.appendingPathComponent(pair.id)
        let recipe = try JSONDecoder().decode(Recipe.self, from: localData(root.appendingPathComponent("recipe.json").path))
        guard recipe.contractVersion == 10, recipe.decoder == "9", recipe.nativeLensCorrectionEnabled,
              recipe.gamutMappingEnabled == (input == .mapped), recipe.shadowBias.isFinite,
              recipe.baselineExposure.isFinite, recipe.workingPrimaries == "ITU-R BT.2020",
              recipe.developmentWorkingSpace == "extended linear sRGB", recipe.workingTransfer == "linear", recipe.role == pair.role.rawValue,
              recipe.width > 0, recipe.height > 0, max(recipe.width, recipe.height) == 768
        else { throw LookCalibrationError.invalidSamples }
        func values(_ name: String) throws -> [Float] {
            let bytes = try localData(root.appendingPathComponent(name).path)
            guard bytes.count == recipe.width * recipe.height * 16 else { throw LookCalibrationError.invalidSamples }
            return bytes.withUnsafeBytes { data in
                stride(from: 0, to: data.count, by: 4).map {
                    Float(bitPattern: UInt32(littleEndian: data.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                }
            }
        }
        let source = try values("scene-frame.f32"), target = try values("target-frame.f32")
        guard source.allSatisfy(\.isFinite), target.allSatisfy(\.isFinite) else { throw LookCalibrationError.invalidSamples }
        if !authoringRegions.isEmpty {
            guard pair.role == .authoring, excluding.isEmpty else { throw LookCalibrationError.invalidTrainingManifest }
            var samples = [Sample]()
            for region in authoringRegions {
                let q = region.rectangle
                let left = max(0, Int(q[0] * Double(recipe.width)))
                let top = max(0, Int(q[1] * Double(recipe.height)))
                let right = min(recipe.width, Int(q[2] * Double(recipe.width)))
                let bottom = min(recipe.height, Int(q[3] * Double(recipe.height)))
                var group = [Sample]()
                let step = max(1, min(4, min(right - left, bottom - top) / 8))
                for row in stride(from: top, to: bottom, by: step) {
                    for col in stride(from: left, to: right, by: step) {
                        let i = (row * recipe.width + col) * 4
                        guard source[i + 3] > 0.999, target[i + 3] > 0.999 else { continue }
                        let input = SIMD3(Double(source[i]), Double(source[i + 1]), Double(source[i + 2]))
                        let output = SIMD3((0 ..< 3).map { min(1.0, max(0.0, Double(target[i + $0]))) })
                        group.append(Sample(input: input, target: output, weight: 1))
                    }
                }
                guard group.count >= 16 else { throw LookCalibrationError.invalidSamples }
                samples += group.map { Sample(input: $0.input, target: $0.target, weight: 1 / Double(group.count * authoringRegions.count)) }
            }
            return (samples, 0)
        }
        var imageSamples = [Sample]()
        // A frozen regular 12x12 interior grid gives each image equal weight;
        // invalid correspondence is omitted, never merely difficult colours.
        for y in 0 ..< 12 {
            for x in 0 ..< 12 {
                let column = Int((Double(x) + 0.5) * Double(recipe.width) / 12)
                let row = Int((Double(y) + 0.5) * Double(recipe.height) / 12)
                let i = (row * recipe.width + column) * 4
                guard source[i + 3] > 0.999, target[i + 3] > 0.999 else { continue }
                let u = Double(column) / Double(recipe.width), v = Double(row) / Double(recipe.height)
                let marginX = 12 / Double(recipe.width), marginY = 12 / Double(recipe.height)
                if excluding.contains(where: { region in
                    let q = region.rectangle
                    return u >= q[0] - marginX && u <= q[2] + marginX && v >= q[1] - marginY && v <= q[3] + marginY
                }) {
                    continue
                }
                let a = SIMD3(Double(source[i]), Double(source[i + 1]), Double(source[i + 2]))
                let rawTarget = SIMD3(Double(target[i]), Double(target[i + 1]), Double(target[i + 2]))
                if (0 ..< 3).contains(where: { rawTarget[$0] < 0 || rawTarget[$0] > 1 }) {
                    targetResamplingOutOfRangeSamples += 1
                }
                // Lanczos reduction can overshoot even an SDR HEIF. Match
                // the scorecard's display-RGB policy without dropping colours.
                // Extended linear source values remain untouched.
                let b = SIMD3(min(1, max(0, rawTarget.x)), min(1, max(0, rawTarget.y)), min(1, max(0, rawTarget.z)))
                imageSamples.append(Sample(input: a, target: b, weight: 1))
            }
        }
        guard imageSamples.count >= minimumSamples else { throw LookCalibrationError.invalidSamples }
        let gridWeight = colourLook == nil ? 1.0 : 0.5
        var observations = imageSamples.map { Sample(input: $0.input, target: $0.target, weight: gridWeight / Double(imageSamples.count)) }
        if let colourLook {
            struct Representative { let index: Int
                let distance: Double
                let chroma: Double
            }
            var centres = [Int: Representative](), saturated = [Int: Representative]()
            let luma = SIMD3<Double>(0.2126, 0.7152, 0.0722)
            for y in stride(from: 12, to: recipe.height - 12, by: 4) {
                for x in stride(from: 12, to: recipe.width - 12, by: 4) {
                    let i = (y * recipe.width + x) * 4
                    guard source[i + 3] > 0.999, target[i + 3] > 0.999 else { continue }
                    let u = Double(x) / Double(recipe.width), v = Double(y) / Double(recipe.height)
                    if excluding.contains(where: { region in
                        let q = region.rectangle
                        return u >= q[0] - 12 / Double(recipe.width) && u <= q[2] + 12 / Double(recipe.width)
                            && v >= q[1] - 12 / Double(recipe.height) && v <= q[3] + 12 / Double(recipe.height)
                    }) {
                        continue
                    }
                    let raw = SIMD3(Double(source[i]), Double(source[i + 1]), Double(source[i + 2]))
                    let value = colourLook.displayLinear(raw)
                    let key = (0 ..< 3).map { c -> Double in
                        let v = min(1, max(0, value[c]))
                        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
                    }
                    let bin = key.map { min(7, Int($0 * 8)) }
                    let node = bin[0] + 8 * bin[1] + 64 * bin[2]
                    let distance = (0 ..< 3).reduce(0.0) { $0 + pow(key[$1] - (Double(bin[$1]) + 0.5) / 8, 2) }
                    let colour = SIMD3(key[0], key[1], key[2]), grey = simd_dot(colour, luma)
                    let chroma = simd_length_squared(colour - SIMD3(repeating: grey))
                    let representative = Representative(index: i, distance: distance, chroma: chroma)
                    if centres[node] == nil || distance < centres[node]!.distance {
                        centres[node] = representative
                    }
                    if saturated[node] == nil || chroma > saturated[node]!.chroma {
                        saturated[node] = representative
                    }
                }
            }
            guard !centres.isEmpty else { throw LookCalibrationError.invalidSamples }
            for node in centres.keys.sorted() {
                let indices = Array(Set([centres[node]!.index, saturated[node]!.index])).sorted()
                for i in indices {
                    let a = SIMD3(Double(source[i]), Double(source[i + 1]), Double(source[i + 2]))
                    let t = SIMD3(Double(target[i]), Double(target[i + 1]), Double(target[i + 2]))
                    targetResamplingOutOfRangeSamples += (0 ..< 3).contains(where: { t[$0] < 0 || t[$0] > 1 }) ? 1 : 0
                    let b = SIMD3(min(1, max(0, t.x)), min(1, max(0, t.y)), min(1, max(0, t.z)))
                    observations.append(Sample(input: a, target: b, weight: 0.5 / Double(centres.count * indices.count)))
                }
            }
        }
        return (observations, targetResamplingOutOfRangeSamples)
    }

    /// Per-image coefficients are offline diagnostic artifacts only. Appearance
    /// regions plus a support buffer are excluded in withheld mode. Whole-image
    /// expression mode reports fitted evidence without a validation claim.
    static func capacity(_ manifest: Manifest, samplesRoot: URL, input: NativeRAWRecipe,
                         mode: AuthoredLook.ToneMode, card: AppearanceLookCard, scope: DiagnosticScope = .withheldRegions, destination: URL) throws
    {
        try card.validate()
        guard input != .appleDefault, !manifest.pairs.isEmpty,
              manifest.pairs.allSatisfy({ $0.role == .regression && $0.session == String($0.id.prefix(8)) && card.regions[$0.id] != nil }),
              Set(manifest.pairs.map(\.id)).count == manifest.pairs.count,
              !FileManager.default.fileExists(atPath: destination.path)
        else { throw LookCalibrationError.invalidTrainingManifest }
        try validate(manifest, output: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for pair in manifest.pairs {
            let excluded = scope == .withheldRegions ? card.regions[pair.id]! : []
            let observations = try readSamples(pair, root: samplesRoot, input: input,
                                               excluding: excluded, minimumSamples: 48)
            let (look, loss) = try solve(observations.samples, input: input, mode: mode)
            try encoder.encode(look).write(to: destination.appendingPathComponent(pair.id + ".json"), options: .withoutOverwriting)
            let report: [String: Any] = ["kind": scope == .withheldRegions ? "offline per-image initialization; actual held-out-region native HEIF validation required" : "whole-image tone expression initializer; fitted pixels are not validation",
                                         "scope": scope.rawValue, "validationEvidence": false,
                                         "id": pair.id, "samples": observations.samples.count, "supportBufferEvaluationPixels": 12,
                                         "excludedRegions": excluded.map(\.name), "weightedRGBLoss": loss,
                                         "targetResamplingOutOfRangeSamples": observations.clampedTargets]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent(pair.id + ".fit.json"), options: .withoutOverwriting)
            print("op=authored.capacity id=\(pair.id) samples=\(observations.samples.count) loss=\(loss)")
        }
    }

    /// Linear least squares initializes the colour stage in its declared linear
    /// space. The ordinary native HEIF renderer decides adoption after gamut/transfer.
    static func fitColour(_ manifest: Manifest, samplesRoot: URL, base: AuthoredLook,
                          regularization: Double, paletteBalanced: Bool = false, coefficientBound: Double = 0.5, destination: URL) throws
    {
        try base.validate()
        guard base.colourCorrection == nil, manifest.pairs.count >= 100,
              manifest.pairs.allSatisfy({ $0.role == .training && $0.session == String($0.id.prefix(8)) }),
              regularization.isFinite, regularization > 0, regularization <= 0.01,
              coefficientBound.isFinite, coefficientBound > 0, coefficientBound <= 1,
              !FileManager.default.fileExists(atPath: destination.path)
        else { throw LookCalibrationError.invalidTrainingManifest }
        try validate(manifest, output: destination.deletingLastPathComponent())
        let start = Date(), nodes = 125
        var normal = [Double](repeating: 0, count: nodes * nodes), rhs = [Double](repeating: 0, count: nodes * 3)
        var sampleCount = 0
        for pair in manifest.pairs {
            let observations = try readSamples(pair, root: samplesRoot, input: base.input, colourLook: paletteBalanced ? base : nil)
            for sample in observations.samples {
                let x = base.displayLinear(sample.input), basis = CreativeColour.basis(x)
                let target = SIMD3(sample.target.x, sample.target.y, sample.target.z)
                func linear(_ v: Double) -> Double {
                    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
                let residual = SIMD3(linear(target.x), linear(target.y), linear(target.z)) - x
                let weight = sample.weight / Double(manifest.pairs.count)
                for a in basis {
                    for channel in 0 ..< 3 {
                        rhs[a.index + channel * nodes] += weight * a.weight * residual[channel]
                    }
                    for b in basis {
                        normal[a.index + b.index * nodes] += weight * a.weight * b.weight
                    }
                }
                sampleCount += 1
            }
        }
        let solved = try solveColour(normal, rhs, regularization: regularization, coefficientBound: coefficientBound)
        let coefficients = solved.coefficients, bounded = solved.bounded
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var object = try JSONSerialization.jsonObject(with: encoder.encode(base)) as! [String: Any]
        object["colourCorrection"] = ["dimension": 5, "coefficients": coefficients]
        let look = try AuthoredLook(json: JSONSerialization.data(withJSONObject: object))
        let bytes = try encoder.encode(look)
        try bytes.write(to: destination, options: .withoutOverwriting)
        let report: [String: Any] = ["kind": "linear colour initializer; actual native HEIF acceptance required", "images": manifest.pairs.count,
                                     "dateGroups": Set(manifest.pairs.map(\.session)).count, "samples": sampleCount,
                                     "regularization": regularization, "sampling": paletteBalanced ? "half spatial grid / half source palette" : "spatial grid", "dimension": 5, "boundedCoefficients": bounded,
                                     "coefficientBound": coefficientBound, "maximumAbsoluteCoefficient": coefficients.map(abs).max()!, "input": base.input.rawValue,
                                     "seconds": Date().timeIntervalSince(start), "recipeSHA256": SHA256.hash(data: bytes).description]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathExtension("fit.json"), options: .withoutOverwriting)
        print("op=authored.colour.fit images=\(manifest.pairs.count) samples=\(sampleCount) bounded=\(bounded) seconds=\(Date().timeIntervalSince(start))")
    }

    /// Diagnostic colour fitting has explicit withheld-region or whole-image
    /// expression scope. These coefficients never enter an inference selector.
    /// Only actual native HEIFs can validate withheld regions.
    static func colourCapacity(_ manifest: Manifest, samplesRoot: URL, base: AuthoredLook,
                               card: AppearanceLookCard, regularization: Double = 0.00003, scope: DiagnosticScope = .withheldRegions, objectiveSpace: DisplayColourObjective = .encodedRGB, destination: URL) throws
    {
        try base.validate()
        try card.validate()
        guard base.colourCorrection == nil, regularization.isFinite, regularization > 0, regularization <= 0.01, !manifest.pairs.isEmpty,
              manifest.pairs.allSatisfy({ $0.role == .regression && $0.session == String($0.id.prefix(8)) && card.regions[$0.id] != nil }),
              Set(manifest.pairs.map(\.id)).count == manifest.pairs.count,
              !FileManager.default.fileExists(atPath: destination.path) else { throw LookCalibrationError.invalidTrainingManifest }
        try validate(manifest, output: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for pair in manifest.pairs {
            let excluded = scope == .withheldRegions ? card.regions[pair.id]! : []
            let observations = try readSamples(pair, root: samplesRoot, input: base.input, excluding: excluded, minimumSamples: 48, colourLook: base)
            var matrix = [Double](repeating: 0, count: 125 * 125), rhs = [Double](repeating: 0, count: 375)
            let samples = observations.samples.map { sample -> DisplayColourObservation in
                let x = base.displayLinear(sample.input)
                return DisplayColourObservation(linear: x, target: sample.target, weight: sample.weight, basis: CreativeColour.basis(x))
            }
            func linear(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            for sample in samples {
                let residual = SIMD3(linear(sample.target.x), linear(sample.target.y), linear(sample.target.z)) - sample.linear
                for a in sample.basis {
                    for c in 0 ..< 3 {
                        rhs[a.index + c * 125] += sample.weight * a.weight * residual[c]
                    }
                    for b in sample.basis {
                        matrix[a.index + b.index * 125] += sample.weight * a.weight * b.weight
                    }
                }
            }
            let initial = try solveColour(matrix, rhs, regularization: regularization)
            var object = try JSONSerialization.jsonObject(with: encoder.encode(base)) as! [String: Any]
            object["colourCorrection"] = ["dimension": 5, "coefficients": initial.coefficients]
            let initialized = try AuthoredLook(json: JSONSerialization.data(withJSONObject: object))
            let result = try refineDisplayColour(samples, initial: initialized, regularization: regularization, objectiveSpace: objectiveSpace)
            object["colourCorrection"] = ["dimension": 5, "coefficients": result.coefficients]
            let look = try AuthoredLook(json: JSONSerialization.data(withJSONObject: object))
            try encoder.encode(look).write(to: destination.appendingPathComponent(pair.id + ".json"), options: .withoutOverwriting)
            let report: [String: Any] = ["kind": scope == .withheldRegions ? "withheld-region colour capacity initializer; actual native validation required" : "whole-image expression fit; fitted pixels are not validation", "id": pair.id,
                                         "scope": scope.rawValue, "objectiveSpace": objectiveSpace.rawValue, "validationEvidence": false,
                                         "samples": samples.count, "excludedRegions": excluded.map(\.name), "supportBufferEvaluationPixels": 12,
                                         "initialObjective": result.initialLoss, "finalObjective": result.loss, "regularization": regularization, "coefficientBound": 0.5]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent(pair.id + ".fit.json"), options: .withoutOverwriting)
            print("op=authored.colour.capacity id=\(pair.id) samples=\(samples.count) objective=\(result.loss)")
        }
    }

    /// Fit one shared camera-render recipe from explicitly weighted paired
    /// examples and broad training. Weighted examples are training evidence.
    static func authorLook(_ manifest: Manifest, samplesRoot: URL, base: AuthoredLook,
                           card: AppearanceLookCard, training: Manifest, trainingRoot: URL, mixture: Double, objectiveSpace: DisplayColourObjective, regularization: Double = 0.00003, destination: URL) throws
    {
        guard mixture.isFinite, (0.0 ... 1.0).contains(mixture), mixture > 0, mixture < 1,
              training.pairs.count >= 100, training.pairs.allSatisfy({ $0.role == .training && $0.session == String($0.id.prefix(8)) }),
              Set(training.pairs.map(\.id)).count == training.pairs.count,
              Set(training.pairs.map(\.session)).isDisjoint(with: Set(manifest.pairs.map(\.session)))
        else { throw LookCalibrationError.invalidTrainingManifest }
        try base.validate()
        try card.validate()
        guard base.colourCorrection == nil, regularization.isFinite, regularization > 0, regularization <= 0.01, !manifest.pairs.isEmpty,
              manifest.pairs.allSatisfy({ $0.role == .authoring && $0.session == String($0.id.prefix(8)) && card.regions[$0.id] != nil }),
              Set(manifest.pairs.map(\.id)).count == manifest.pairs.count,
              !FileManager.default.fileExists(atPath: destination.path) else { throw LookCalibrationError.invalidTrainingManifest }
        try validate(training, output: destination)
        try validate(manifest, output: destination)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var samples = [DisplayColourObservation]()
        for pair in manifest.pairs {
            let observations = try readSamples(pair, root: samplesRoot, input: base.input, minimumSamples: 48, colourLook: base, authoringRegions: card.regions[pair.id]!)
            samples += observations.samples.map { sample in
                let x = base.displayLinear(sample.input)
                return DisplayColourObservation(linear: x, target: sample.target, weight: mixture * sample.weight / Double(manifest.pairs.count), basis: CreativeColour.basis(x))
            }
        }
        for pair in training.pairs {
            let observations = try readSamples(pair, root: trainingRoot, input: base.input, colourLook: base)
            samples += observations.samples.map { sample in
                let x = base.displayLinear(sample.input)
                return DisplayColourObservation(linear: x, target: sample.target, weight: (1 - mixture) * sample.weight / Double(training.pairs.count), basis: CreativeColour.basis(x))
            }
        }
        var matrix = [Double](repeating: 0, count: 125 * 125), rhs = [Double](repeating: 0, count: 375)
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        for sample in samples {
            let residual = SIMD3(linear(sample.target.x), linear(sample.target.y), linear(sample.target.z)) - sample.linear
            for a in sample.basis {
                for c in 0 ..< 3 {
                    rhs[a.index + c * 125] += sample.weight * a.weight * residual[c]
                }
                for b in sample.basis {
                    matrix[a.index + b.index * 125] += sample.weight * a.weight * b.weight
                }
            }
        }
        let initial = try solveColour(matrix, rhs, regularization: regularization)
        var object = try JSONSerialization.jsonObject(with: encoder.encode(base)) as! [String: Any]
        object["colourCorrection"] = ["dimension": 5, "coefficients": initial.coefficients]
        let initialized = try AuthoredLook(json: JSONSerialization.data(withJSONObject: object))
        let result = try refineDisplayColour(samples, initial: initialized, regularization: regularization, objectiveSpace: objectiveSpace)
        object["colourCorrection"] = ["dimension": 5, "coefficients": result.coefficients]
        let look = try AuthoredLook(json: JSONSerialization.data(withJSONObject: object))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try encoder.encode(look).write(to: destination.appendingPathComponent("recipe.json"), options: .withoutOverwriting)
        let report: [String: Any] = try ["kind": "authored-region priorities plus broad training; authors are not validation",
                                         "authoringImages": manifest.pairs.count, "trainingImages": training.pairs.count,
                                         "objectiveSpace": objectiveSpace.rawValue, "authoringFraction": mixture, "samples": samples.count, "regularization": regularization,
                                         "initialObjective": result.initialLoss, "finalObjective": result.loss,
                                         "coefficientBound": 0.5, "recipeSHA256": SHA256.hash(data: encoder.encode(look)).description]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("fit.json"), options: .withoutOverwriting)
        print("op=authored.anchor-priority mixture=\(mixture) trainingImages=\(training.pairs.count) authoringImages=\(manifest.pairs.count) samples=\(samples.count) initial=\(result.initialLoss) final=\(result.loss) validationEvidence=false")
    }

    /// Refine only the existing colour coefficients against the actual final
    /// display function. Sampling, tone, gamut policy and coefficient bounds stay
    /// frozen; offline targets never become runtime parameters or pixel inputs.
    static func refineColour(_ manifest: Manifest, samplesRoot: URL, initial: AuthoredLook,
                             regularization: Double, paletteBalanced: Bool, colourBalance: Double = 0, destination: URL) throws
    {
        try initial.validate()
        guard let colour = initial.colourCorrection, colourBalance.isFinite, (0 ... 1).contains(colourBalance),
              colourBalance == 0 || paletteBalanced, manifest.pairs.count >= 100,
              manifest.pairs.allSatisfy({ $0.role == .training && $0.session == String($0.id.prefix(8)) }),
              Set(manifest.pairs.map(\.id)).count == manifest.pairs.count,
              regularization.isFinite, regularization > 0, regularization <= 0.01,
              colour.coefficients.allSatisfy({ abs($0) <= 0.5 }),
              !FileManager.default.fileExists(atPath: destination.path) else { throw LookCalibrationError.invalidTrainingManifest }
        try validate(manifest, output: destination.deletingLastPathComponent())
        let start = Date()
        var samples = [DisplayColourObservation]()
        for pair in manifest.pairs {
            let observations = try readSamples(pair, root: samplesRoot, input: initial.input, colourLook: paletteBalanced ? initial : nil)
            samples += observations.samples.map {
                let x = initial.displayLinear($0.input)
                return DisplayColourObservation(linear: x, target: $0.target,
                                                weight: $0.weight / Double(manifest.pairs.count), basis: CreativeColour.basis(x))
            }
        }
        samples = try balanceSourceColours(samples, fraction: colourBalance)
        let result = try refineDisplayColour(samples, initial: initial, regularization: regularization)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var object = try JSONSerialization.jsonObject(with: encoder.encode(initial)) as! [String: Any]
        object["colourCorrection"] = ["dimension": 5, "coefficients": result.coefficients]
        let look = try AuthoredLook(json: JSONSerialization.data(withJSONObject: object))
        let bytes = try encoder.encode(look)
        try bytes.write(to: destination, options: .withoutOverwriting)
        let report: [String: Any] = ["kind": "final display RGB objective; actual native HEIF acceptance required",
                                     "images": manifest.pairs.count, "samples": samples.count, "regularization": regularization, "sourceColourBalance": colourBalance,
                                     "sampling": paletteBalanced ? "half spatial grid / half source palette" : "spatial grid",
                                     "initialObjective": result.initialLoss, "finalObjective": result.loss,
                                     "iterations": result.iterations, "coefficientBound": 0.5, "gamutPolicy": initial.gamutPolicy.rawValue,
                                     "seconds": Date().timeIntervalSince(start), "recipeSHA256": SHA256.hash(data: bytes).description]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathExtension("fit.json"), options: .withoutOverwriting)
        print("op=authored.colour.refine complete=true samples=\(samples.count) initial=\(result.initialLoss) final=\(result.loss) seconds=\(Date().timeIntervalSince(start))")
    }

    private static func solveColour(_ matrix: [Double], _ rightHandSide: [Double],
                                    regularization: Double, coefficientBound: Double = 0.5) throws -> (coefficients: [Double], bounded: Int)
    {
        var normal = matrix
        let rhs = rightHandSide
        let nodes = 125
        // Adjacent coefficients vary smoothly; a small ridge fixes the neutral
        // subtraction's nullspace and keeps unobserved colour nodes near identity.
        for node in 0 ..< nodes {
            normal[node + node * nodes] += regularization * 0.1
            for step in [1, 5, 25] {
                let coordinate = node / step % 5
                guard coordinate < 4 else { continue }
                let next = node + step
                normal[node + node * nodes] += regularization
                normal[next + next * nodes] += regularization
                normal[node + next * nodes] -= regularization
                normal[next + node * nodes] -= regularization
            }
        }
        let channels = try (0 ..< 3).map { channel in
            try boundedColourSolution(normal, Array(rhs[channel * nodes ..< (channel + 1) * nodes]), bound: coefficientBound)
        }
        var coefficients = [Double](), bounded = 0
        for node in 0 ..< nodes {
            for channel in 0 ..< 3 {
                let value = channels[channel][node]
                bounded += abs(value) >= coefficientBound - 1e-12 ? 1 : 0
                coefficients.append(value)
            }
        }
        return (coefficients, bounded)
    }

    private static func solve(_ samples: [Sample], input: NativeRAWRecipe,
                              mode: AuthoredLook.ToneMode) throws -> (AuthoredLook, Double)
    {
        let bounds = [(log(0.5), log(2.5)), (log(0.01), log(8.0)), (log(0.3), log(3.0)), (log(0.5), log(1.5))]
        func look(_ parameters: [Double]) throws -> AuthoredLook {
            let object: [String: Any] = ["formatVersion": 5, "gamutPolicy": "smoothRadial", "decoder": "9", "input": input.rawValue,
                                         "exposureEV": 0, "whiteBalanceRGB": [1, 1, 1], "contrast": min(2.5, max(0.5, exp(parameters[0]))),
                                         "tonePivot": min(8, max(0.01, exp(parameters[1]))), "skew": min(3, max(0.3, exp(parameters[2]))), "toneMode": mode.rawValue,
                                         "huePreservation": 0.5, "saturation": min(1.5, max(0.5, exp(parameters[3])))]
            return try AuthoredLook(json: JSONSerialization.data(withJSONObject: object))
        }
        func objective(_ recipe: AuthoredLook) -> Double {
            samples.reduce(0) { result, sample in
                let error = recipe.evaluate(sample.input) - sample.target
                return result + sample.weight * simd_length_squared(error)
            }
        }
        var best: (AuthoredLook, Double)?
        // Skew/pivot interaction makes this nonlinear. Two predeclared starts
        // diagnose optimization sensitivity, selected solely by training loss.
        for initial in [[1.15, 0.65, 1.0, 1.0], [1.3, 0.25, 1.8, 1.0]] {
            var p = initial.map(log), lambda = 0.001
            var current = try look(p), loss = objective(current)
            for iteration in 0 ..< 40 {
                let epsilon = 0.0001
                let upper = (0 ..< 4).map { min(bounds[$0].1, p[$0] + epsilon) }
                let lower = (0 ..< 4).map { max(bounds[$0].0, p[$0] - epsilon) }
                let plus = try (0 ..< 4).map { c -> AuthoredLook in var q = p
                    q[c] = upper[c]
                    return try look(q)
                }
                let minus = try (0 ..< 4).map { c -> AuthoredLook in var q = p
                    q[c] = lower[c]
                    return try look(q)
                }
                var normal = [Double](repeating: 0, count: 16), rhs = [Double](repeating: 0, count: 4)
                for sample in samples {
                    let error = current.evaluate(sample.input) - sample.target
                    let jacobian = (0 ..< 4).map { (plus[$0].evaluate(sample.input) - minus[$0].evaluate(sample.input)) / (upper[$0] - lower[$0]) }
                    for a in 0 ..< 4 {
                        rhs[a] -= sample.weight * simd_dot(jacobian[a], error)
                        for b in 0 ..< 4 {
                            normal[a + 4 * b] += sample.weight * simd_dot(jacobian[a], jacobian[b])
                        }
                    }
                }
                for c in 0 ..< 4 {
                    normal[c + 4 * c] += lambda
                }
                var triangle: CChar = 76, n: Int32 = 4, columns: Int32 = 1, leading: Int32 = 4, rhsLeading: Int32 = 4, info: Int32 = 0
                normal.withUnsafeMutableBufferPointer { a in rhs.withUnsafeMutableBufferPointer { b in
                    dposv_(&triangle, &n, &columns, a.baseAddress!, &leading, b.baseAddress!, &rhsLeading, &info)
                }}
                guard info == 0, rhs.allSatisfy(\.isFinite) else { throw LookCalibrationError.solveFailed(info) }
                let proposed = (0 ..< 4).map { min(bounds[$0].1, max(bounds[$0].0, p[$0] + rhs[$0])) }
                let candidate = try look(proposed), nextLoss = objective(candidate)
                if nextLoss < loss {
                    let improvement = loss - nextLoss
                    p = proposed
                    current = candidate
                    loss = nextLoss
                    lambda = max(1e-8, lambda / 3)
                    if improvement < 1e-10 {
                        break
                    }
                } else {
                    lambda *= 10
                }
                print("op=authored.fit input=\(input.rawValue) mode=\(mode.rawValue) iteration=\(iteration) loss=\(loss)")
                if lambda > 1e8 {
                    break
                }
            }
            if best == nil || loss < best!.1 {
                best = (current, loss)
            }
        }
        guard let best else { throw LookCalibrationError.invalidSamples }
        return best
    }

    static func selfTest() throws {
        func expected(_ value: Double) -> Double {
            let linear = value / (value + 0.4)
            return linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        }
        let samples = (1 ... 40).map { i -> Sample in
            let x = pow(2, Double(i) / 5 - 5)
            return Sample(input: SIMD3(repeating: x), target: SIMD3(repeating: expected(x)), weight: 1 / 40)
        }
        let (fitted, _) = try solve(samples, input: .mapped, mode: .rgbRatio)
        let error = [0.017, 0.19, 0.37, 1.7, 7].map {
            abs(fitted.evaluate(SIMD3(repeating: $0)).x - expected($0))
        }.max()!
        guard error < 0.0001 else { throw ReferenceError.invalidPixels }
        let bounded = try boundedColourSolution([2, 1, 1, 2], [1.9, 0.8])
        guard abs(bounded[0] - 0.5) < 1e-10, abs(bounded[1] - 0.15) < 1e-10 else { throw ReferenceError.invalidPixels }
        print("Bounded colour: coupled optimum differs from post-solve clipping and satisfies the known solution")
        var coefficients = [Double]()
        for b in 0 ... 4 {
            for g in 0 ... 4 {
                for r in 0 ... 4 {
                    coefficients += [0.02 * Double(r - g) / 4, 0.03 * Double(g - b) / 4, 0.015 * Double(b - r) / 4]
                }
            }
        }
        let truth = CreativeColour(dimension: 5, coefficients: coefficients)
        var normal = [Double](repeating: 0, count: 125 * 125), rhs = [Double](repeating: 0, count: 375)
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        // Vertex-only observations leave interior neutral-subtraction ambiguity.
        // Oversample the known smooth field; validation colours remain off-grid.
        for b in 0 ... 8 {
            for g in 0 ... 8 {
                for r in 0 ... 8 {
                    let x = SIMD3(linear(Double(r) / 8), linear(Double(g) / 8), linear(Double(b) / 8))
                    let basis = CreativeColour.basis(x), target = truth.residual(x)
                    for a in basis {
                        for c in 0 ..< 3 {
                            rhs[a.index + c * 125] += a.weight * target[c] / 729
                        }
                        for b in basis {
                            normal[a.index + b.index * 125] += a.weight * b.weight / 729
                        }
                    }
                }
            }
        }
        let solution = try solveColour(normal, rhs, regularization: 1e-10)
        let recovered = CreativeColour(dimension: 5, coefficients: solution.coefficients)
        let colours = [SIMD3<Double>(0.01, 0.4, 0.8), SIMD3(0.2, 0.04, 0.5), SIMD3(0.7, 0.4, 0.03)]
        let colourError = colours.map { simd_length(recovered.residual($0) - truth.residual($0)) }.max()!
        print("op=authored.colour.fixture bounded=\(solution.bounded) maxError=\(colourError)")
        guard solution.bounded == 0, colourError < 1e-6 else { throw ReferenceError.invalidPixels }
        print("Authored colour: known residual recovery on withheld colours pass maxError=\(colourError)")
        print("Authored calibration: independent neutral-curve recovery on withheld intensities pass maxError=\(error)")
    }
}
