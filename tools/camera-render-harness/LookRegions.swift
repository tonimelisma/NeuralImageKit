import Foundation

/// Offline appearance measurements. These anchor regions never enter inference.
/// RGBFrame row order matches exported PNG top-left coordinates, verified at runtime.
struct AppearanceLookCard: Decodable {
    struct Region: Decodable {
        let name: String
        let rectangle: [Double]
    }

    let formatVersion: Int
    let maximumLightnessDifference: Double
    let maximumMedianDE00: Double
    let maximumChromaDifference: Double
    let maximumSensitivityDE00: Double
    let regions: [String: [Region]]

    func validate() throws {
        guard formatVersion == 5,
              [maximumLightnessDifference, maximumMedianDE00, maximumChromaDifference, maximumSensitivityDE00]
              .allSatisfy({ $0.isFinite && $0 > 0 }),
              !regions.isEmpty,
              regions.values.allSatisfy({ list in
                  !list.isEmpty && list.allSatisfy {
                      !$0.name.isEmpty && $0.rectangle.count == 4 && $0.rectangle.allSatisfy { $0.isFinite && (0 ... 1).contains($0) }
                          && $0.rectangle[0] < $0.rectangle[2] && $0.rectangle[1] < $0.rectangle[3]
                  }
              })
        else { throw HarnessError.invalidManifest }
    }
}

/// Pixelwise mean DE00 is the matching gate. Median-colour diagnostics cannot
/// detect differences that cancel across a region.
struct AppearanceRegionReport: Encodable {
    let formatVersion = 7
    let correspondencePolicy = "native-gradient-NCC; ambiguous-only Gaussian sigma 1.2 retry"
    let geometryBaselineSHA256: String
    let scores: [AppearanceRegionScore]
}

struct AppearanceRegionScore: Encodable {
    let name: String
    let pixelCount: Int
    let validFraction: Double
    let deltaMedianLightness: Double
    let deltaMedianA: Double
    let deltaMedianB: Double
    let deltaMedianChroma: Double
    let medianLabDE00: Double
    let meanLowFrequencyDE00: Double
    let p95LowFrequencyDE00: Double
    let unregisteredMeanLowFrequencyDE00: Double
    let meanDE00Sensitivity: Double?
    let matchingOutcome: String
    let matchingPasses: Bool
    let sensitivityDE00: Double?
    let placementSensitivityDE00: Double
    let unregisteredMedianLabDE00: Double
    let correspondence: RegionCorrespondence
    let diagnosticOutcome: String
    let diagnosticPasses: Bool
}

func appearanceRegionScores(candidate: RGBFrame, target: RGBFrame,
                            regions: [AppearanceLookCard.Region], card: AppearanceLookCard,
                            correspondences: [RegionCorrespondence]? = nil) throws -> [AppearanceRegionScore]
{
    try card.validate()
    guard candidate.width == target.width, candidate.height == target.height,
          correspondences == nil || correspondences?.count == regions.count
    else {
        throw ScorecardError.dimensionMismatch
    }
    let a = gaussianBlur(candidate), b = gaussianBlur(target)
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    func patch(_ image: RGBFrame, _ region: AppearanceLookCard.Region, dx: Double, dy: Double) throws -> (Lab, Int, Double) {
        let rect = region.rectangle
        let x0 = max(0, min(image.width - 1, Int(rect[0] * Double(image.width))))
        let x1 = max(x0 + 1, min(image.width, Int(rect[2] * Double(image.width))))
        let y0 = max(0, min(image.height - 1, Int(rect[1] * Double(image.height))))
        let y1 = max(y0 + 1, min(image.height, Int(rect[3] * Double(image.height))))
        var lightness = [Double](), redGreen = [Double](), yellowBlue = [Double]()
        let count = (x1 - x0) * (y1 - y0)
        var valid = 0
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let u = Double(x) + dx, v = Double(y) + dy
                guard u >= 0, v >= 0, u <= Double(image.width - 1), v <= Double(image.height - 1) else { continue }
                let ix = Int(u), iy = Int(v), fx = u - Double(ix), fy = v - Double(iy)
                var rgba = [Double](repeating: 0, count: 4)
                for (ox, oy, weight) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
                    let i = (min(image.height - 1, iy + oy) * image.width + min(image.width - 1, ix + ox)) * 4
                    for c in 0 ..< 4 {
                        rgba[c] += Double(image.rgba[i + c]) * weight
                    }
                }
                guard rgba.allSatisfy(\.isFinite), rgba[3] > 0.999 else { continue }
                let lab = Lab.srgb(min(1, max(0, rgba[0])), min(1, max(0, rgba[1])), min(1, max(0, rgba[2])))
                lightness.append(lab.l)
                redGreen.append(lab.a)
                yellowBlue.append(lab.b)
                valid += 1
            }
        }
        guard valid > 0 else { throw ScorecardError.insufficientValidPixels }
        return (Lab(l: median(lightness), a: median(redGreen), b: median(yellowBlue)), count, Double(valid) / Double(count))
    }
    func meanError(_ region: AppearanceLookCard.Region, dx: Double, dy: Double) throws -> (mean: Double, p95: Double, coverage: Double) {
        let q = region.rectangle
        let x0 = max(0, Int(q[0] * Double(a.width))), x1 = min(a.width, Int(q[2] * Double(a.width)))
        let y0 = max(0, Int(q[1] * Double(a.height))), y1 = min(a.height, Int(q[3] * Double(a.height)))
        var errors = [Double]()
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let u = Double(x) + dx, v = Double(y) + dy
                guard u >= 0, v >= 0, u <= Double(a.width - 1), v <= Double(a.height - 1) else { continue }
                let ix = Int(u), iy = Int(v), fx = u - Double(ix), fy = v - Double(iy)
                var rgba = SIMD4<Double>(repeating: 0)
                for (ox, oy, weight) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
                    let i = (min(a.height - 1, iy + oy) * a.width + min(a.width - 1, ix + ox)) * 4
                    for c in 0 ..< 4 {
                        rgba[c] += Double(a.rgba[i + c]) * weight
                    }
                }
                let j = (y * b.width + x) * 4
                guard (0 ..< 4).allSatisfy({ rgba[$0].isFinite && b.rgba[j + $0].isFinite }), rgba.w > 0.999, b.rgba[j + 3] > 0.999 else { continue }
                let ca = Lab.srgb(min(1, max(0, rgba.x)), min(1, max(0, rgba.y)), min(1, max(0, rgba.z)))
                let cb = Lab.srgb(min(1, max(0, Double(b.rgba[j]))), min(1, max(0, Double(b.rgba[j + 1]))), min(1, max(0, Double(b.rgba[j + 2]))))
                errors.append(ciede2000(ca, cb))
            }
        }
        guard !errors.isEmpty else { throw ScorecardError.insufficientValidPixels }
        errors.sort()
        return (errors.reduce(0, +) / Double(errors.count), errors[Int(ceil(Double(errors.count) * 0.95)) - 1], Double(errors.count) / Double((x1 - x0) * (y1 - y0)))
    }
    return try regions.enumerated().map { index, region in
        let correspondence = correspondences?[index] ?? .unknown
        let (unregistered, count, _) = try patch(a, region, dx: 0, dy: 0)
        let (cb, _, validB) = try patch(b, region, dx: 0, dy: 0)
        let dx = correspondence.dx ?? 0, dy = correspondence.dy ?? 0
        let (ca, _, validA) = try patch(a, region, dx: dx, dy: dy)
        let de = ciede2000(ca, cb)
        let pixelError = try meanError(region, dx: dx, dy: dy)
        let unregisteredError = try meanError(region, dx: 0, dy: 0)
        var meanSensitivity: Double?
        if let radius = correspondence.supportRadius {
            var maximum = 0.0
            for sx in [-radius, 0, radius] {
                for sy in [-radius, 0, radius] {
                    let error = try meanError(region, dx: dx + sx, dy: dy + sy)
                    maximum = error.coverage == 1 ? max(maximum, abs(error.mean - pixelError.mean)) : .infinity
                }
            }
            meanSensitivity = maximum.isFinite ? maximum : nil
        }
        let matchingPasses = pixelError.coverage == 1 && pixelError.mean <= 2
            && meanSensitivity != nil && meanSensitivity! <= card.maximumSensitivityDE00
        var sensitivity: Double?
        if let radius = correspondence.supportRadius {
            var maximum = 0.0
            for sx in [-radius, 0, radius] {
                for sy in [-radius, 0, radius] {
                    let (shiftA, _, coverage) = try patch(a, region, dx: dx + sx, dy: dy + sy)
                    maximum = coverage == 1 ? max(maximum, abs(ciede2000(shiftA, cb) - de)) : .infinity
                }
            }
            sensitivity = maximum.isFinite ? maximum : nil
        }
        // Moving both patches preserves their correspondence. This measures
        // spatial variation in the appearance residual, not geometry uncertainty.
        // Report it for diagnosis; only the measured relative support is a gate.
        var placementSensitivity = 0.0
        for sx in [-4.0, 0, 4.0] {
            for sy in [-4.0, 0, 4.0] {
                let (shiftA, _, _) = try patch(a, region, dx: dx + sx, dy: dy + sy)
                let (shiftB, _, _) = try patch(b, region, dx: sx, dy: sy)
                placementSensitivity = max(placementSensitivity, abs(ciede2000(shiftA, shiftB) - de))
            }
        }
        let deltaL = ca.l - cb.l
        let deltaC = hypot(ca.a, ca.b) - hypot(cb.a, cb.b)
        let valid = min(validA, validB)
        let passes = valid == 1 && abs(deltaL) <= card.maximumLightnessDifference
            && abs(deltaC) <= card.maximumChromaDifference && de <= card.maximumMedianDE00
            && sensitivity != nil && sensitivity! <= card.maximumSensitivityDE00
        return AppearanceRegionScore(name: region.name, pixelCount: count, validFraction: valid,
                                     deltaMedianLightness: deltaL, deltaMedianA: ca.a - cb.a,
                                     deltaMedianB: ca.b - cb.b, deltaMedianChroma: deltaC,
                                     medianLabDE00: de, meanLowFrequencyDE00: pixelError.mean, p95LowFrequencyDE00: pixelError.p95,
                                     unregisteredMeanLowFrequencyDE00: unregisteredError.mean,
                                     meanDE00Sensitivity: meanSensitivity,
                                     matchingOutcome: meanSensitivity == nil ? "inconclusive" : matchingPasses ? "pass" : "fail",
                                     matchingPasses: matchingPasses,
                                     sensitivityDE00: sensitivity, placementSensitivityDE00: placementSensitivity,
                                     unregisteredMedianLabDE00: ciede2000(unregistered, cb), correspondence: correspondence,
                                     diagnosticOutcome: sensitivity == nil ? "inconclusive" : passes ? "pass" : "fail", diagnosticPasses: passes)
    }
}

func appearanceRegionSelfTest() throws {
    let region = AppearanceLookCard.Region(name: "top-left", rectangle: [0, 0, 0.5, 0.5])
    let card = AppearanceLookCard(formatVersion: 5, maximumLightnessDifference: 2, maximumMedianDE00: 3,
                                  maximumChromaDifference: 3, maximumSensitivityDE00: 1,
                                  regions: ["synthetic": [region]])
    let malformed = AppearanceLookCard(formatVersion: 5, maximumLightnessDifference: 2, maximumMedianDE00: 3,
                                       maximumChromaDifference: 3, maximumSensitivityDE00: 1,
                                       regions: ["synthetic": [.init(name: "unsafe", rectangle: [0, 0, 1e300, 0.5])]])
    do {
        try malformed.validate()
        throw ReferenceError.invalidPixels
    } catch HarnessError.invalidManifest {}
    let pixels: [Float] = (0 ..< 64 * 64).flatMap { i -> [Float] in
        let x = i % 64, y = i / 64
        return x < 32 && y < 32 ? [0.5, 0.5, 0.5, 1] : [0.1, 0.1, 0.1, 1]
    }
    let image = RGBFrame(width: 64, height: 64, rgba: pixels)
    let same = try appearanceRegionScores(candidate: image, target: image, regions: [region], card: card, correspondences: [.identity])
    guard same[0].diagnosticPasses, same[0].medianLabDE00 == 0, same[0].pixelCount == 1024 else {
        throw ReferenceError.invalidPixels
    }
    guard same[0].matchingPasses, same[0].meanLowFrequencyDE00 == 0 else { throw ReferenceError.invalidPixels }
    // Matching median colours can conceal a reversed colour arrangement. The
    // per-pixel gate must reject this despite identical median Lab coordinates.
    let whole = AppearanceLookCard.Region(name: "whole", rectangle: [0, 0, 1, 1])
    let leftRight = RGBFrame(width: 64, height: 64, rgba: (0 ..< 4096).flatMap { i -> [Float] in
        i % 64 < 32 ? [0.8, 0.1, 0.1, 1] : [0.1, 0.1, 0.8, 1]
    })
    let reversed = RGBFrame(width: 64, height: 64, rgba: (0 ..< 4096).flatMap { i -> [Float] in
        i % 64 < 32 ? [0.1, 0.1, 0.8, 1] : [0.8, 0.1, 0.1, 1]
    })
    let cancellation = try appearanceRegionScores(candidate: reversed, target: leftRight, regions: [whole], card: card, correspondences: [.identity])[0]
    print("op=regions.cancellation median=\(cancellation.medianLabDE00) mean=\(cancellation.meanLowFrequencyDE00) pass=\(cancellation.matchingPasses)")
    guard cancellation.medianLabDE00 < 1e-4, cancellation.meanLowFrequencyDE00 > 20,
          !cancellation.matchingPasses else { throw ReferenceError.invalidPixels }
    let unknown = try appearanceRegionScores(candidate: image, target: image, regions: [region], card: card)
    guard !unknown[0].diagnosticPasses, !unknown[0].matchingPasses, unknown[0].sensitivityDE00 == nil, unknown[0].correspondence.status == .inconclusive else { throw ReferenceError.invalidPixels }
    // A steep photographic gradient must pass a proven identity correspondence.
    let gradient = RGBFrame(width: 64, height: 64, rgba: (0 ..< 4096).flatMap { i -> [Float] in
        let v = Float(i % 64) / 63
        return [v, v * v, 1 - v, 1]
    })
    guard try appearanceRegionScores(candidate: gradient, target: gradient, regions: [region], card: card, correspondences: [.identity])[0].diagnosticPasses else { throw ReferenceError.invalidPixels }
    var altered = pixels
    for y in 0 ..< 32 {
        for x in 0 ..< 32 {
            for c in 0 ..< 3 {
                altered[(y * 64 + x) * 4 + c] = 0.8
            }
        }
    }
    let different = try appearanceRegionScores(candidate: RGBFrame(width: 64, height: 64, rgba: altered), target: image, regions: [region], card: card, correspondences: [.identity])
    guard !different[0].diagnosticPasses, different[0].deltaMedianLightness > 20 else { throw ReferenceError.invalidPixels }
    let interior = AppearanceLookCard.Region(name: "interior", rectangle: [0.25, 0.25, 0.75, 0.75])
    let ramp = RGBFrame(width: 64, height: 64, rgba: (0 ..< 4096).flatMap { i -> [Float] in
        let v = Float(0.2 + 0.6 * Double(i % 64) / 63)
        return [v, v, v, 1]
    })
    let contrast = RGBFrame(width: 64, height: 64, rgba: (0 ..< 4096).flatMap { i -> [Float] in
        let v = Float(0.2 + 0.6 * Double(i % 64) / 63 + 0.006 * (Double(i % 64) - 31.5))
        return [v, v, v, 1]
    })
    let placed = try appearanceRegionScores(candidate: contrast, target: ramp, regions: [interior], card: card, correspondences: [.identity])
    let uncertain = RegionCorrespondence(status: .measuredLocal, dx: 0, dy: 0, supportRadius: 4, reliableMatches: 1, supportPaddingNativePixels: 0)
    let relative = try appearanceRegionScores(candidate: contrast, target: ramp, regions: [interior], card: card, correspondences: [uncertain])
    guard placed[0].diagnosticPasses, placed[0].placementSensitivityDE00 > 1,
          !relative[0].diagnosticPasses, (relative[0].sensitivityDE00 ?? 0) > 1 else { throw ReferenceError.invalidPixels }
    print("Appearance regions: coordinates, identity, visible-lightness rejection and separate placement/relative-uncertainty fixtures pass")
}
