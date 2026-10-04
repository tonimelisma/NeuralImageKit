import Foundation
import simd

/// Offline observations freeze normalization, tone and colour lookup coordinates.
/// Only the fixed 5-cubed residual is optimized through the runtime display stage.
struct DisplayColourObservation {
    let linear: SIMD3<Double>
    let target: SIMD3<Double>
    let weight: Double
    let basis: [(index: Int, weight: Double)]
}

/// Reweight the existing observations by source-colour coverage, without reading
/// target colour or selecting more pixels. The image-weighted objective remains
/// the other mixture component; rare source bins cannot silently disappear into it.
func balanceSourceColours(_ samples: [DisplayColourObservation], fraction: Double) throws -> [DisplayColourObservation] {
    guard fraction.isFinite, (0 ... 1).contains(fraction), !samples.isEmpty,
          samples.allSatisfy({ sample in sample.weight.isFinite && sample.weight > 0 && (0 ..< 3).allSatisfy { sample.linear[$0].isFinite } })
    else { throw LookCalibrationError.invalidSamples }
    if fraction == 0 {
        return samples
    }
    func key(_ x: SIMD3<Double>) -> Int {
        let bins = (0 ..< 3).map { c -> Int in
            let v = min(1, max(0, x[c]))
            let encoded = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            return min(7, Int(encoded * 8))
        }
        return bins[0] + bins[1] * 8 + bins[2] * 64
    }
    let keys = samples.map { key($0.linear) }
    var mass = [Int: Double]()
    for (sample, bin) in zip(samples, keys) {
        mass[bin, default: 0] += sample.weight
    }
    let total = samples.reduce(0) { $0 + $1.weight }
    guard total.isFinite, total > 0 else { throw LookCalibrationError.invalidSamples }
    return zip(samples, keys).map { sample, bin in
        let weight = (1 - fraction) * sample.weight + fraction * total * sample.weight / (Double(mass.count) * mass[bin]!)
        return DisplayColourObservation(linear: sample.linear, target: sample.target, weight: weight, basis: sample.basis)
    }
}

/// The offline fitting objective is explicit. Normalized D65 CIELAB is a DE76
/// least-squares proxy; the release scorecard still measures CIEDE2000 separately.
enum DisplayColourObjective: String {
    case encodedRGB, normalizedLab

    func coordinates(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        switch self {
        case .encodedRGB: return rgb
        case .normalizedLab:
            let lab = Lab.srgb(rgb.x, rgb.y, rgb.z)
            return SIMD3(lab.l, lab.a, lab.b) / 100
        }
    }
}

func refineDisplayColour(_ samples: [DisplayColourObservation], initial: AuthoredLook,
                         regularization: Double, objectiveSpace: DisplayColourObjective = .encodedRGB) throws -> (coefficients: [Double], initialLoss: Double, loss: Double, iterations: Int)
{
    try initial.validate()
    let size = 375
    guard let colour = initial.colourCorrection, !samples.isEmpty,
          regularization.isFinite, regularization > 0, regularization <= 0.01,
          colour.coefficients.allSatisfy({ abs($0) <= 0.5 }),
          samples.allSatisfy({ sample in sample.weight.isFinite && sample.weight > 0 && (0 ..< 3).allSatisfy { sample.linear[$0].isFinite && sample.target[$0].isFinite } && sample.basis.allSatisfy { (0 ..< 125).contains($0.index) && $0.weight.isFinite } })
    else { throw LookCalibrationError.invalidSamples }
    // A graph Laplacian plus a small ridge is the same regularizer as the linear
    // initializer, expanded to interleaved RGB coefficients. It also fixes the
    // neutral-protection nullspace without introducing image-specific parameters.
    var penalty = [Double](repeating: 0, count: size * size)
    for node in 0 ..< 125 {
        for channel in 0 ..< 3 {
            let a = node * 3 + channel
            penalty[a + size * a] += regularization * 0.1
            for step in [1, 5, 25] where node / step % 5 < 4 {
                let b = (node + step) * 3 + channel
                penalty[a + size * a] += regularization
                penalty[b + size * b] += regularization
                penalty[a + size * b] -= regularization
                penalty[b + size * a] -= regularization
            }
        }
    }
    func corrected(_ sample: DisplayColourObservation, _ coefficients: [Double]) -> SIMD3<Double> {
        sample.basis.reduce(sample.linear) { x, node in
            let i = node.index * 3
            return x + SIMD3(coefficients[i], coefficients[i + 1], coefficients[i + 2]) * node.weight
        }
    }
    func objective(_ coefficients: [Double]) -> Double {
        var total = samples.reduce(0.0) { sum, sample in
            let error = objectiveSpace.coordinates(initial.prepareDisplay(corrected(sample, coefficients))) - objectiveSpace.coordinates(sample.target)
            return sum + sample.weight * simd_length_squared(error)
        }
        for a in 0 ..< size {
            for b in 0 ..< size {
                total += coefficients[a] * penalty[a + size * b] * coefficients[b]
            }
        }
        return total
    }
    var coefficients = colour.coefficients, loss = objective(coefficients), damping = 0.0001
    let initialLoss = loss
    var iterations = 0
    for iteration in 0 ..< 8 {
        iterations += 1
        var normal = penalty, gradient = [Double](repeating: 0, count: size)
        for a in 0 ..< size {
            for b in 0 ..< size {
                gradient[a] += penalty[a + size * b] * coefficients[b]
            }
        }
        for sample in samples {
            let x = corrected(sample, coefficients), prediction = objectiveSpace.coordinates(initial.prepareDisplay(x)), error = prediction - objectiveSpace.coordinates(sample.target)
            let epsilon = 0.00001
            let derivative = (0 ..< 3).map { c -> SIMD3<Double> in
                var up = x, down = x
                up[c] += epsilon
                down[c] -= epsilon
                return (objectiveSpace.coordinates(initial.prepareDisplay(up)) - objectiveSpace.coordinates(initial.prepareDisplay(down))) / (2 * epsilon)
            }
            var gram = [Double](repeating: 0, count: 9)
            for c in 0 ..< 3 {
                for d in 0 ..< 3 {
                    gram[c + 3 * d] = sample.weight * simd_dot(derivative[c], derivative[d])
                }
            }
            for a in sample.basis {
                for c in 0 ..< 3 {
                    let row = a.index * 3 + c
                    gradient[row] += sample.weight * a.weight * simd_dot(derivative[c], error)
                    for b in sample.basis {
                        let weight = a.weight * b.weight
                        for d in 0 ..< 3 {
                            normal[row + size * (b.index * 3 + d)] += weight * gram[c + 3 * d]
                        }
                    }
                }
            }
        }
        for a in 0 ..< size {
            normal[a + size * a] += damping
        }
        let rhs = (0 ..< size).map { a in
            (0 ..< size).reduce(-gradient[a]) { $0 + normal[a + size * $1] * coefficients[$1] }
        }
        // Solve for absolute coefficients so box constraints participate in the
        // coupled step. Accept only a reduction of the true nonlinear objective.
        let proposed = try boundedColourSolution(normal, rhs, bound: 0.5)
        let next = objective(proposed)
        if next < loss {
            let improvement = loss - next
            coefficients = proposed
            loss = next
            damping = max(1e-8, damping / 3)
            print("op=authored.colour.refine iteration=\(iteration) accepted=true objective=\(loss)")
            if improvement < 1e-10 {
                break
            }
        } else {
            damping *= 10
            print("op=authored.colour.refine iteration=\(iteration) accepted=false objective=\(loss)")
        }
    }
    return (coefficients, initialLoss, loss, iterations)
}

func displayColourRefinementSelfTest() throws {
    var coefficients = [Double]()
    for b in 0 ... 4 {
        for g in 0 ... 4 {
            for r in 0 ... 4 {
                coefficients += [0.04 * Double(r - g), 0.03 * Double(g - b), 0.02 * Double(b - r)]
            }
        }
    }
    let truth = CreativeColour(dimension: 5, coefficients: coefficients)
    let object: [String: Any] = ["formatVersion": 5, "decoder": "9", "input": "mapped", "gamutPolicy": "radialProjection",
                                 "exposureEV": 0, "whiteBalanceRGB": [1, 1, 1], "contrast": 1, "tonePivot": 0.4, "skew": 1,
                                 "toneMode": "perChannel", "huePreservation": 0.5, "saturation": 1,
                                 "colourCorrection": ["dimension": 5, "coefficients": [Double](repeating: 0, count: 375)]]
    let initial = try AuthoredLook(json: JSONSerialization.data(withJSONObject: object))
    var samples = [DisplayColourObservation]()
    for b in 0 ... 8 {
        for g in 0 ... 8 {
            for r in 0 ... 8 {
                let x = SIMD3(Double(r) / 8, Double(g) / 8, Double(b) / 8)
                samples.append(DisplayColourObservation(linear: x, target: initial.prepareDisplay(x + truth.residual(x)), weight: 1 / 729, basis: CreativeColour.basis(x)))
            }
        }
    }
    let result = try refineDisplayColour(samples, initial: initial, regularization: 1e-9)
    let fitted = CreativeColour(dimension: 5, coefficients: result.coefficients)
    let withheld = [SIMD3<Double>(0.03, 0.72, 0.95), SIMD3(0.8, 0.1, 0.41), SIMD3(0.2, 0.6, 0.3), SIMD3(0.5, 0.5, 0.5)]
    let error = withheld.map { x in simd_length(initial.prepareDisplay(x + fitted.residual(x)) - initial.prepareDisplay(x + truth.residual(x))) }.max()!
    guard result.loss < result.initialLoss / 100, error < 0.002, result.coefficients.allSatisfy({ abs($0) <= 0.5 }) else { throw ReferenceError.invalidPixels }
    let perceptual = try refineDisplayColour(samples, initial: initial, regularization: 1e-9, objectiveSpace: .normalizedLab)
    let perceptualField = CreativeColour(dimension: 5, coefficients: perceptual.coefficients)
    let perceptualError = withheld.map { x in simd_length(initial.prepareDisplay(x + perceptualField.residual(x)) - initial.prepareDisplay(x + truth.residual(x))) }.max()!
    guard perceptual.loss < perceptual.initialLoss / 100, perceptualError < 0.002,
          perceptual.coefficients.allSatisfy({ abs($0) <= 0.5 }) else { throw ReferenceError.invalidPixels }
    print("Perceptual display fitting: bounded known-field recovery on withheld colours maxError=\(perceptualError)")
    // Repeating a frequent source colour must not overwhelm a rare colour in
    // the global-coverage objective. Compare resulting fields, not histogram internals.
    let colours = [SIMD3<Double>(0.6, 0.1, 0.05), SIMD3(0.02, 0.6, 0.9)]
    func observation(_ x: SIMD3<Double>, _ weight: Double) -> DisplayColourObservation {
        DisplayColourObservation(linear: x, target: initial.prepareDisplay(x + truth.residual(x)), weight: weight, basis: CreativeColour.basis(x))
    }
    let sparse = colours.map { observation($0, 0.5) }
    let repeated = (0 ..< 64).map { _ in observation(colours[0], 1 / 65) } + [observation(colours[1], 1 / 65)]
    let first = try refineDisplayColour(balanceSourceColours(sparse, fraction: 1), initial: initial, regularization: 0.00003)
    let second = try refineDisplayColour(balanceSourceColours(repeated, fraction: 1), initial: initial, regularization: 0.00003)
    guard zip(first.coefficients, second.coefficients).allSatisfy({ abs($0 - $1) < 1e-8 }) else { throw ReferenceError.invalidPixels }
    let changedTargets = repeated.map { DisplayColourObservation(linear: $0.linear, target: SIMD3(repeating: 0), weight: $0.weight, basis: $0.basis) }
    let a = try balanceSourceColours(repeated, fraction: 0.5), b = try balanceSourceColours(changedTargets, fraction: 0.5)
    guard zip(a, b).allSatisfy({ $0.weight == $1.weight }), abs(a.reduce(0) { $0 + $1.weight } - 1) < 1e-12 else { throw ReferenceError.invalidPixels }
    print("Source-colour objective: repeated-colour fit invariance, target-independent weighting and conserved total mass pass")
    print("Final display fitting: bounded known-field recovery on withheld colours maxError=\(error)")
}
