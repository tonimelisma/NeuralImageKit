import Foundation

struct RGBFrame {
    let width: Int
    let height: Int
    let rgba: [Float]

    init(width: Int, height: Int, rgba: [Float]) {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4)
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

struct ColorScore: Codable {
    let validFraction: Double
    let clippedFraction: Double
    let meanLowFrequencyDE00: Double
    let p95LowFrequencyDE00: Double
    let meanUnblurredDE00: Double
    let p95UnblurredDE00: Double
}

enum ScorecardError: Error {
    case dimensionMismatch
    case insufficientValidPixels
}

/// Fixed Gaussian sigma, with explicit kernel support and edge extension. Core
/// Image's blur radius is not used as an undocumented substitute for sigma.
func gaussianBlur(_ frame: RGBFrame, sigma: Double = 1.2) -> RGBFrame {
    let radius = Int(ceil(3 * sigma))
    let weights = (-radius ... radius).map { offset in
        exp(-Double(offset * offset) / (2 * sigma * sigma))
    }
    let total = weights.reduce(0, +)
    let kernel = weights.map { Float($0 / total) }
    let w = frame.width, h = frame.height
    var horizontal = [Float](repeating: 0, count: frame.rgba.count)
    var output = horizontal
    for y in 0 ..< h {
        for x in 0 ..< w {
            let base = (y * w + x) * 4
            for offset in -radius ... radius {
                let sampleX = min(w - 1, max(0, x + offset))
                let source = (y * w + sampleX) * 4
                let weight = kernel[offset + radius]
                for channel in 0 ..< 4 {
                    horizontal[base + channel] += frame.rgba[source + channel] * weight
                }
            }
        }
    }
    for y in 0 ..< h {
        for x in 0 ..< w {
            let base = (y * w + x) * 4
            for offset in -radius ... radius {
                let sampleY = min(h - 1, max(0, y + offset))
                let source = (sampleY * w + x) * 4
                let weight = kernel[offset + radius]
                for channel in 0 ..< 4 {
                    output[base + channel] += horizontal[source + channel] * weight
                }
            }
        }
    }
    return RGBFrame(width: w, height: h, rgba: output)
}

func colorScore(candidate: RGBFrame, target: RGBFrame, inset: Int = 8) throws -> ColorScore {
    guard candidate.width == target.width, candidate.height == target.height else {
        throw ScorecardError.dimensionMismatch
    }
    let candidateLow = gaussianBlur(candidate)
    let targetLow = gaussianBlur(target)
    let width = candidate.width, height = candidate.height
    let totalPixels = max(0, width - 2 * inset) * max(0, height - 2 * inset)
    guard totalPixels > 0 else { throw ScorecardError.insufficientValidPixels }
    var lowErrors = [Double](), highErrors = [Double]()
    lowErrors.reserveCapacity(totalPixels)
    highErrors.reserveCapacity(totalPixels)
    var clipped = 0
    func lab(_ pixels: [Float], _ offset: Int) -> Lab {
        Lab.srgb(
            min(1, max(0, Double(pixels[offset]))),
            min(1, max(0, Double(pixels[offset + 1]))),
            min(1, max(0, Double(pixels[offset + 2])))
        )
    }
    for y in inset ..< height - inset {
        for x in inset ..< width - inset {
            let index = (y * width + x) * 4
            let raw = candidate.rgba, reference = target.rgba
            // A homographic warp leaves transparent/outside samples. Exclude
            // correspondence failures, never samples because their colors differ.
            guard raw[index + 3] > 0.99, reference[index + 3] > 0.99,
                  candidateLow.rgba[index + 3] > 0.999,
                  targetLow.rgba[index + 3] > 0.999,
                  (0 ..< 4).allSatisfy({ raw[index + $0].isFinite && reference[index + $0].isFinite })
            else { continue }
            if (0 ..< 3).contains(where: {
                raw[index + $0] <= 0 || raw[index + $0] >= 1
                    || reference[index + $0] <= 0 || reference[index + $0] >= 1
            }) {
                clipped += 1
            }
            lowErrors.append(ciede2000(lab(candidateLow.rgba, index), lab(targetLow.rgba, index)))
            highErrors.append(ciede2000(lab(raw, index), lab(reference, index)))
        }
    }
    guard lowErrors.count >= totalPixels / 2, !lowErrors.isEmpty else {
        throw ScorecardError.insufficientValidPixels
    }
    lowErrors.sort()
    highErrors.sort()
    func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }
    func p95(_ values: [Double]) -> Double {
        values[Int(ceil(Double(values.count) * 0.95)) - 1]
    }
    return ColorScore(
        validFraction: Double(lowErrors.count) / Double(totalPixels),
        clippedFraction: Double(clipped) / Double(lowErrors.count),
        meanLowFrequencyDE00: mean(lowErrors),
        p95LowFrequencyDE00: p95(lowErrors),
        meanUnblurredDE00: mean(highErrors),
        p95UnblurredDE00: p95(highErrors)
    )
}
