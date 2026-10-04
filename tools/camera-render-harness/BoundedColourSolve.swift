import Accelerate
import Foundation

private enum BoundedColourSolveError: Error { case invalidSystem, didNotConverge }

/// Solve a strictly convex quadratic within coefficient bounds. Active constraints
/// participate in each reduced solve; clipping an unconstrained solution afterward
/// breaks the coupled colour field. Accept only a feasible stationary solution.
func boundedColourSolution(_ matrix: [Double], _ rhs: [Double], bound: Double = 0.5) throws -> [Double] {
    let size = rhs.count
    guard size > 0, size <= Int(Int32.max), matrix.count == size * size,
          matrix.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite), bound.isFinite, bound > 0
    else { throw BoundedColourSolveError.invalidSystem }
    var x = [Double](repeating: 0, count: size), active = [Int](repeating: 0, count: size)
    for _ in 0 ..< 1024 {
        let gradient = (0 ..< size).map { row in
            (0 ..< size).reduce(-rhs[row]) { $0 + matrix[row + size * $1] * x[$1] }
        }
        let free = (0 ..< size).filter { active[$0] == 0 }
        var direction = [Double](repeating: 0, count: size)
        if !free.isEmpty {
            var reduced = free.flatMap { column in free.map { matrix[$0 + size * column] } }
            var step = free.map { -gradient[$0] }
            var triangle: CChar = 76, n = Int32(free.count), columns: Int32 = 1, leading = Int32(free.count), rhsLeading = Int32(free.count), info: Int32 = 0
            reduced.withUnsafeMutableBufferPointer { a in step.withUnsafeMutableBufferPointer { b in
                dposv_(&triangle, &n, &columns, a.baseAddress!, &leading, b.baseAddress!, &rhsLeading, &info)
            }}
            guard info == 0, step.allSatisfy(\.isFinite) else { throw LookCalibrationError.solveFailed(info) }
            for (index, node) in free.enumerated() {
                direction[node] = step[index]
            }
        }
        var fraction = 1.0, hit: Int?
        for node in free where abs(direction[node]) > 1e-14 {
            let edge = direction[node] > 0 ? bound : -bound
            let available = max(0, (edge - x[node]) / direction[node])
            if available < fraction {
                fraction = available
                hit = node
            }
        }
        for node in free {
            x[node] = min(bound, max(-bound, x[node] + fraction * direction[node]))
        }
        if let hit, fraction < 1 {
            active[hit] = direction[hit] > 0 ? 1 : -1
            x[hit] = Double(active[hit]) * bound
            continue
        }
        // The free coefficients are optimal for the current bounds. Release a
        // bound only if its gradient violates the constrained optimum condition.
        var release: Int?, worstViolation = 1e-9
        for node in 0 ..< size where active[node] != 0 {
            let g = (0 ..< size).reduce(-rhs[node]) { $0 + matrix[node + size * $1] * x[$1] }
            let violation = Double(active[node]) * g
            if violation > worstViolation {
                worstViolation = violation
                release = node
            }
        }
        if let release {
            active[release] = 0
            continue
        }
        let maximumFreeGradient = free.map { row in
            abs((0 ..< size).reduce(-rhs[row]) { $0 + matrix[row + size * $1] * x[$1] })
        }.max() ?? 0
        guard maximumFreeGradient <= 1e-9 else { throw BoundedColourSolveError.didNotConverge }
        return x
    }
    throw BoundedColourSolveError.didNotConverge
}
