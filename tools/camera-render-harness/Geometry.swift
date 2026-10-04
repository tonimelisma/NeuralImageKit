import Foundation

struct GeometryScore: Encodable {
    let attempted: Int
    let reliable: Int
    let reliableFraction: Double
    let medianResidualNativePixels: Double?
    let p95ResidualNativePixels: Double?
    let medianCorrelation: Double?
}

/// Independent, local correspondence check after the global Vision registration.
/// Gradient magnitude limits sensitivity to the two renderers' color and tone.
/// Ambiguous or nearly flat patches are rejected and counted, never scored as
/// zero displacement. This is a diagnostic, not a warp applied to the renderer.
func geometryScore(candidate: RGBFrame, target: RGBFrame,
                   nativeLongEdge: Int) throws -> GeometryScore
{
    guard candidate.width == target.width, candidate.height == target.height else {
        throw ScorecardError.dimensionMismatch
    }
    let width = target.width, height = target.height
    let radius = 9, search = 6
    let margin = radius + search + 2
    guard width > 2 * margin, height > 2 * margin else {
        throw ScorecardError.insufficientValidPixels
    }
    func gradient(_ frame: RGBFrame) -> [Double] {
        var gray = [Double](repeating: 0, count: width * height)
        for i in 0 ..< gray.count {
            let j = i * 4
            gray[i] = 0.2126 * Double(frame.rgba[j])
                + 0.7152 * Double(frame.rgba[j + 1])
                + 0.0722 * Double(frame.rgba[j + 2])
        }
        var result = gray
        for y in 1 ..< height - 1 {
            for x in 1 ..< width - 1 {
                let i = y * width + x
                result[i] = hypot(gray[i + 1] - gray[i - 1],
                                  gray[i + width] - gray[i - width])
            }
        }
        return result
    }
    let reference = gradient(target), rendered = gradient(candidate)
    func correlation(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> Double {
        var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
        let n = Double((2 * radius + 1) * (2 * radius + 1))
        for py in -radius ... radius {
            for px in -radius ... radius {
                let a = reference[(y + py) * width + x + px]
                let b = rendered[(y + py + dy) * width + x + px + dx]
                sumA += a
                sumB += b
                sumAA += a * a
                sumBB += b * b
                sumAB += a * b
            }
        }
        let varianceA = sumAA - sumA * sumA / n
        let varianceB = sumBB - sumB * sumB / n
        guard varianceA > 0.005, varianceB > 0.005 else { return -.infinity }
        return (sumAB - sumA * sumB / n) / sqrt(varianceA * varianceB)
    }
    let columns = 8, rows = 5
    var offsets = [(Double, Double)]()
    var correlations = [Double]()
    for row in 0 ..< rows {
        for column in 0 ..< columns {
            let x = margin + (width - 2 * margin) * (2 * column + 1) / (2 * columns)
            let y = margin + (height - 2 * margin) * (2 * row + 1) / (2 * rows)
            var matches = [(Int, Int, Double)]()
            for dy in -search ... search {
                for dx in -search ... search {
                    let value = correlation(x, y, dx, dy)
                    if value.isFinite {
                        matches.append((dx, dy, value))
                    }
                }
            }
            guard let best = matches.max(by: { $0.2 < $1.2 }), best.2 >= 0.70 else {
                continue
            }
            let rival = matches.filter {
                abs($0.0 - best.0) > 1 || abs($0.1 - best.1) > 1
            }.map(\.2).max() ?? -.infinity
            guard best.2 - rival >= 0.025, abs(best.0) < search,
                  abs(best.1) < search else { continue }
            /// Quadratic interpolation around the correlation peak makes the
            /// diagnostic sensitive below one preview pixel. A missing or flat
            /// neighborhood is rejected rather than reported as exact agreement.
            func subpixel(_ before: Double, _ center: Double, _ after: Double) -> Double? {
                let curvature = before - 2 * center + after
                guard before.isFinite, after.isFinite, curvature < -0.0001 else { return nil }
                return max(-1, min(1, 0.5 * (before - after) / curvature))
            }
            guard let finerX = subpixel(correlation(x, y, best.0 - 1, best.1), best.2,
                                        correlation(x, y, best.0 + 1, best.1)),
                let finerY = subpixel(correlation(x, y, best.0, best.1 - 1), best.2,
                                      correlation(x, y, best.0, best.1 + 1))
            else { continue }
            offsets.append((Double(best.0) + finerX, Double(best.1) + finerY))
            correlations.append(best.2)
        }
    }
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
    guard !offsets.isEmpty else {
        return GeometryScore(attempted: columns * rows, reliable: 0,
                             reliableFraction: 0, medianResidualNativePixels: nil,
                             p95ResidualNativePixels: nil, medianCorrelation: nil)
    }
    // Remove only the global translation. A varying residual remains visible as
    // a potential distortion or crop error; an affine fit could hide curvature.
    let dx = median(offsets.map(\.0)), dy = median(offsets.map(\.1))
    let scale = Double(nativeLongEdge) / Double(max(width, height))
    let residuals = offsets.map { hypot($0.0 - dx, $0.1 - dy) * scale }.sorted()
    return GeometryScore(attempted: columns * rows, reliable: offsets.count,
                         reliableFraction: Double(offsets.count) / Double(columns * rows),
                         medianResidualNativePixels: median(residuals),
                         p95ResidualNativePixels: residuals[Int(ceil(Double(residuals.count) * 0.95)) - 1],
                         medianCorrelation: median(correlations))
}
