import Foundation

/// Finite-budget offline fit of an existing profile subspace. The callback owns
/// native image observation; this boundary owns coefficients, derivatives and
/// the bounded quadratic solve. Every accepted step decreases the actual loss.
struct NativeFieldResult {
    let coefficients: [Double]
    let status: String
    let initialLoss: Double
    let loss: Double
    let derivativeChecks: [[String: Double]]
    let iterations: [[String: Any]]
    let regionMeans: [Double]
}

func nativeFieldMeanTail(_ distances: [Double], weights: [Double]) -> (loss: Double, effectiveWeights: [Double]) {
    let mean = zip(distances, weights).reduce(0) { $0 + $1.0 * $1.1 }
    var remaining = 0.05, tail = 0.0, effective = weights
    for i in distances.indices.sorted(by: { distances[$0] > distances[$1] }) where remaining > 0 {
        let mass = min(remaining, weights[i])
        tail += mass * distances[i]
        effective[i] += 5 * mass
        remaining -= mass
    }
    return (mean + 0.25 * tail / 0.05, effective)
}

enum NativeFieldObjective: String { case meanTail, regionFeasibility, regionMeanSquared }

/// Squared excess of equal-region means. Feasibility uses target1.9; training
/// uses target0 to keep learning from already passing regions. HEIF gates stay separate.
func nativeFieldRegionalLoss(_ distances: [Double], weights: [Double], groups: [Int], target: Double = 1.9) throws
    -> (loss: Double, effectiveWeights: [Double], means: [Double])
{
    guard target.isFinite, target >= 0, !distances.isEmpty, distances.count == weights.count, groups.count == weights.count,
          distances.allSatisfy({ $0.isFinite && $0 >= 0 }), weights.allSatisfy({ $0.isFinite && $0 > 0 }),
          abs(weights.reduce(0, +) - 1) < 1e-8, groups.allSatisfy({ $0 >= 0 && $0 < groups.count })
    else { throw HarnessError.invalidManifest }
    let count = Set(groups).count
    guard groups.max() == count - 1 else { throw HarnessError.invalidManifest }
    var masses = [Double](repeating: 0, count: count), totals = masses
    for i in distances.indices {
        masses[groups[i]] += weights[i]
        totals[groups[i]] += weights[i] * distances[i]
    }
    guard masses.allSatisfy({ $0 > 0 }) else { throw HarnessError.invalidManifest }
    let means = zip(totals, masses).map { $0 / $1 }, excess = means.map { max(0, $0 - target) }
    let effective = distances.indices.map { 2 * excess[groups[$0]] * weights[$0] / masses[groups[$0]] / Double(count) }
    let loss = excess.reduce(0) { $0 + $1 * $1 } / Double(count)
    guard loss.isFinite, means.allSatisfy(\.isFinite), effective.allSatisfy(\.isFinite)
    else { throw HarnessError.invalidManifest }
    return (loss, effective, means)
}

/// Unit edges and0.1 identity ridge on each RGB component. The pooled objective
/// penalizes the absolute field; regional objectives use this positive matrix only to
/// stabilize displacement, without competing against a region's colour limit.
private func nativeFieldPenalty() -> [Double] {
    var matrix = [Double](repeating: 0, count: 81 * 81)
    for r in 0 ..< 3 {
        for g in 0 ..< 3 {
            for b in 0 ..< 3 {
                for c in 0 ..< 3 {
                    let i = (r * 9 + g * 3 + b) * 3 + c
                    matrix[i + 81 * i] += 0.1
                    for (rr, gg, bb) in [(r + 1, g, b), (r, g + 1, b), (r, g, b + 1)] where rr < 3 && gg < 3 && bb < 3 {
                        let j = (rr * 9 + gg * 3 + bb) * 3 + c
                        matrix[i + 81 * i] += 1
                        matrix[j + 81 * j] += 1
                        matrix[i + 81 * j] -= 1
                        matrix[j + 81 * i] -= 1
                    }
                }
            }
        }
    }
    return matrix
}

func solveNativeField(weights: [Double], objective: NativeFieldObjective = .meanTail, groups: [Int] = [], initial: [Double] = Array(repeating: 0, count: 81), observe: ([Double]) throws -> [SIMD3<Double>]) throws -> NativeFieldResult {
    guard initial.count == 81, initial.allSatisfy({ $0.isFinite && abs($0) <= 0.25 }), !weights.isEmpty, weights.allSatisfy({ $0.isFinite && $0 > 0 }), abs(weights.reduce(0, +) - 1) < 1e-8
    else { throw HarnessError.invalidManifest }
    if objective != .meanTail {
        _ = try nativeFieldRegionalLoss(Array(repeating: 0, count: weights.count), weights: weights, groups: groups)
    }
    let n = 81, bound = 0.25, step = 0.001, penalty = nativeFieldPenalty()
    func observed(_ x: [Double]) throws -> [SIMD3<Double>] {
        try Task.checkCancellation()
        let result = try observe(x)
        guard result.count == weights.count, result.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        else { throw HarnessError.malformedReferenceData }
        return result
    }
    func penaltyGradient(_ x: [Double]) -> [Double] {
        (0 ..< n).map { row in (0 ..< n).reduce(0) { $0 + penalty[row + n * $1] * x[$1] } }
    }
    func regional(_ errors: [SIMD3<Double>]) throws -> (loss: Double, effectiveWeights: [Double], means: [Double]) {
        try nativeFieldRegionalLoss(errors.map(nativeResidualNorm), weights: weights, groups: groups, target: objective == .regionMeanSquared ? 0 : 1.9)
    }
    func means(_ errors: [SIMD3<Double>]) throws -> [Double] {
        groups.isEmpty ? [] : try regional(errors).means
    }
    func loss(_ errors: [SIMD3<Double>], _ x: [Double]) throws -> Double {
        if objective != .meanTail {
            return try regional(errors).loss
        }
        return nativeFieldMeanTail(errors.map(nativeResidualNorm), weights: weights).loss + 0.5 * zip(x, penaltyGradient(x)).reduce(0) { $0 + $1.0 * $1.1 }
    }
    func derivative(_ x: [Double], column: Int, h: Double) throws -> [SIMD3<Double>] {
        var lo = x, hi = x
        lo[column] = max(-bound, x[column] - h)
        hi[column] = min(bound, x[column] + h)
        let a = try observed(lo), b = try observed(hi), width = hi[column] - lo[column]
        return zip(a, b).map { ($1 - $0) / width }
    }
    var x = initial, errors = try observed(x)
    let initial = try loss(errors, x)
    var best = initial, checks = [[String: Double]](), iterations = [[String: Any]]()
    // Representative dark, middle and bright cube nodes, all output channels.
    // Half-step disagreement is a measurement diagnostic, not an acceptance gate.
    for node in [0, 13, 26] {
        for c in 0 ..< 3 {
            let column = node * 3 + c
            let a = try derivative(x, column: column, h: step), b = try derivative(x, column: column, h: step / 2)
            let norm = sqrt(zip(b, weights).reduce(0) { $0 + nativeResidualDot($1.0, $1.0) * $1.1 })
            let difference = sqrt((0 ..< weights.count).reduce(0) { $0 + nativeResidualDot(a[$1] - b[$1], a[$1] - b[$1]) * weights[$1] })
            checks.append(["column": Double(column), "halfStepRMS": norm, "relativeRMSDifference": difference / max(norm, 1e-12), "RMSDifference": difference, "fullBoundDifference": difference * bound])
        }
    }
    guard !checks.contains(where: { $0["fullBoundDifference"]! > 0.05 && $0["relativeRMSDifference"]! > 0.25 }) else {
        return try NativeFieldResult(coefficients: x, status: "derivative-calibration-failed", initialLoss: initial,
                                     loss: best, derivativeChecks: checks, iterations: iterations, regionMeans: means(errors))
    }
    var status = "iteration-budget-exhausted"
    for iteration in 0 ..< 6 {
        if objective == .regionFeasibility, try regional(errors).means.allSatisfy({ $0 <= 1.9 }) {
            status = "sampled-region-targets-satisfied"
            break
        }
        let jacobian = try (0 ..< n).map { try derivative(x, column: $0, h: step) }
        let effective = objective != .meanTail ? try regional(errors).effectiveWeights :
            nativeFieldMeanTail(errors.map(nativeResidualNorm), weights: weights).effectiveWeights
        // Stabilize curvature near zero, but retain the actual objective's
        // first derivative in the quadratic. Flooring both the step's residual
        // and curvature would change its fixed point and stall small corrections.
        let weighted = errors.indices.map { effective[$0] / max(nativeResidualNorm(errors[$0]), 0.1) }
        var matrix = penalty, rhs = [Double](repeating: 0, count: n)
        for column in 0 ..< n {
            for row in 0 ... column {
                let value = errors.indices.reduce(0) { $0 + weighted[$1] * nativeResidualDot(jacobian[row][$1], jacobian[column][$1]) }
                matrix[row + n * column] += value
                if row != column {
                    matrix[column + n * row] += value
                }
            }
        }
        // Regional objectives have no absolute model penalty competing with
        // target matching. The positive prior matrix stabilizes displacement.
        var gradient = objective != .meanTail ? [Double](repeating: 0, count: n) : penaltyGradient(x)
        for column in 0 ..< n {
            gradient[column] += errors.indices.reduce(0) { $0 + effective[$1] * nativeResidualDot(jacobian[column][$1], errors[$1]) / max(nativeResidualNorm(errors[$1]), 1e-12) }
        }
        let projected = (0 ..< n).map { abs(x[$0] - min(bound, max(-bound, x[$0] - gradient[$0]))) }.max()!
        if projected < 1e-5 {
            status = "projected-gradient-converged"
            iterations.append(["iteration": iteration, "loss": best, "projectedGradientInfinity": projected])
            break
        }
        // Solve for an absolute bounded position: H * proposed = H * x - g.
        // The stabilized Hessian controls step length; g remains the declared
        // mean/tail distance plus prior gradient, including current tail weights.
        rhs = (0 ..< n).map { row in
            (0 ..< n).reduce(-gradient[row]) { $0 + matrix[row + n * $1] * x[$1] }
        }
        let proposed = try boundedColourSolution(matrix, rhs, bound: bound)
        var trials = [[String: Double]](), accepted = false
        // Twenty bounded halvings can resolve a small correction rather than
        // declaring failure because all five coarse trial fractions overshoot.
        for halving in 0 ..< 20 {
            let fraction = pow(0.5, Double(halving))
            let trial = zip(x, proposed).map { $0 + fraction * ($1 - $0) }
            let candidate = try observed(trial), value = try loss(candidate, trial)
            trials.append(["fraction": fraction, "loss": value])
            if value < best {
                x = trial
                errors = candidate
                best = value
                accepted = true
                break
            }
        }
        iterations.append(["iteration": iteration, "loss": best, "preStepProjectedGradientInfinity": projected,
                           "accepted": accepted, "trials": trials])
        FileHandle.standardOutput.write(Data("op=matching.nativeFieldIteration iteration=\(iteration) loss=\(best) accepted=\(accepted)\n".utf8))
        if !accepted {
            status = "line-search-stalled"
            break
        }
    }
    if objective == .regionFeasibility, try regional(errors).means.allSatisfy({ $0 <= 1.9 }) {
        status = "sampled-region-targets-satisfied"
    }
    return try NativeFieldResult(coefficients: x, status: status, initialLoss: initial, loss: best,
                                 derivativeChecks: checks, iterations: iterations, regionMeans: means(errors))
}
