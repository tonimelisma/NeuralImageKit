import CoreImage
import CryptoKit
import Foundation

/// Native encoded source range, before profile clamping. The signed classes stay
/// separate; a count is an association diagnostic, never proof of error cause.
func nativeRangeCounts(_ pixels: RGBFrame, rectangle: CGRect) -> [String: Any] {
    let x0 = max(0, Int(rectangle.minX.rounded(.up))), y0 = max(0, Int(rectangle.minY.rounded(.up)))
    let x1 = min(pixels.width, Int(rectangle.maxX.rounded(.down))), y1 = min(pixels.height, Int(rectangle.maxY.rounded(.down)))
    var negative = [0, 0, 0], aboveDomain = [0, 0, 0], aboveDisplay = [0, 0, 0]
    var affected = 0, count = 0
    if x1 > x0, y1 > y0 {
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let i = (y * pixels.width + x) * 4
                var clipped = false
                for c in 0 ..< 3 {
                    let value = pixels.rgba[i + c]
                    if value < 0 {
                        negative[c] += 1
                        clipped = true
                    }
                    if value > 1.25 {
                        aboveDomain[c] += 1
                        clipped = true
                    }
                    if value > 1 {
                        aboveDisplay[c] += 1
                    }
                }
                if clipped {
                    affected += 1
                }
                count += 1
            }
        }
    }
    return ["pixels": count, "negativeRGB": negative, "aboveDomainRGB": aboveDomain,
            "aboveDisplayRGB": aboveDisplay, "affectedPixels": affected,
            "affectedFraction": count > 0 ? Double(affected) / Double(count) : 0]
}

func nativeInputRangeAudit(_ pair: Pair, card: AppearanceLookCard, geometryReport: Data,
                           geometryBaseline: Data, destination: URL) throws
{
    try card.validate()
    guard pair.role == .regression, pair.session == String(pair.id.prefix(8)),
          !FileManager.default.fileExists(atPath: destination.path), let regions = card.regions[pair.id],
          let report = try JSONSerialization.jsonObject(with: geometryReport) as? [String: Any],
          report["formatVersion"] as? Int == 7, let rows = report["scores"] as? [[String: Any]], rows.count == regions.count,
          let digest = report["geometryBaselineSHA256"] as? String, digest == SHA256.hash(data: geometryBaseline).description
    else { throw HarnessError.invalidManifest }
    try validate(Manifest(pairs: [pair]), output: destination)
    let span = RenderingSignpost.rendering.beginInterval("NativeInputRange")
    defer { RenderingSignpost.rendering.endInterval("NativeInputRange", span) }
    let started = Date()
    try Task.checkCancellation()
    let developed = try NativeRAWDevelopment.develop(localData(pair.raw), recipe: .mapped)
    let encoded = try encodedImage(developed.image)
    let pixels = frame(encoded, width: Int(encoded.extent.width.rounded()), height: Int(encoded.extent.height.rounded()))
    guard pixels.rgba.allSatisfy(\.isFinite) else { throw HarnessError.malformedReferenceData }
    let reduced = scaled(developed.image)
    let sx = Double(pixels.width) / reduced.extent.width.rounded(), sy = Double(pixels.height) / reduced.extent.height.rounded()
    var summaries = [[String: Any]]()
    for (region, row) in zip(regions, rows) {
        guard row["name"] as? String == region.name else { throw HarnessError.invalidManifest }
        guard let sensitivity = row["meanDE00Sensitivity"] as? Double, sensitivity.isFinite, sensitivity >= 0,
              sensitivity <= card.maximumSensitivityDE00,
              let correspondence = row["correspondence"] as? [String: Any], correspondence["status"] as? String == "measured-local",
              let dx = correspondence["dx"] as? Double, let dy = correspondence["dy"] as? Double, dx.isFinite, dy.isFinite
        else { summaries.append(["name": region.name, "coverage": "unknown-or-sensitive"])
            continue
        }
        let q = region.rectangle
        let rectangle = CGRect(x: (q[0] * reduced.extent.width.rounded() + 8 + dx) * sx,
                               y: (q[1] * reduced.extent.height.rounded() + 8 + dy) * sy,
                               width: max(0, (q[2] - q[0]) * reduced.extent.width.rounded() - 16) * sx,
                               height: max(0, (q[3] - q[1]) * reduced.extent.height.rounded() - 16) * sy)
        summaries.append(["name": region.name, "coverage": "fixed-reliable", "sourceRange": nativeRangeCounts(pixels, rectangle: rectangle)])
    }
    let output: [String: Any] = ["contractVersion": 1, "id": pair.id, "validationEvidence": false,
                                 "scope": "RAW-only native source-range diagnostic; no camera target read; association not causation",
                                 "geometryBaselineSHA256": digest, "inputDomain": [0, 1.25], "nativeWidth": pixels.width, "nativeHeight": pixels.height,
                                 "whole": nativeRangeCounts(pixels, rectangle: encoded.extent), "regions": summaries,
                                 "elapsedMs": Date().timeIntervalSince(started) * 1000]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .withoutOverwriting)
    RenderingLog.rendering.noticeOperation("matching.nativeInputRange", phase: "complete", fields: [
        "id": pair.id, "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
    ])
}

func nativeInputRangeSelfTest() throws {
    let pixels = RGBFrame(width: 3, height: 1, rgba: [-0.1, 0, 0.5, 1, 1.25, 1.251, 1.1, 1, 0.2, 0.3, 0.4, 1])
    let counts = nativeRangeCounts(pixels, rectangle: CGRect(x: 0, y: 0, width: 3, height: 1))
    guard counts["negativeRGB"] as? [Int] == [1, 0, 0], counts["aboveDomainRGB"] as? [Int] == [0, 1, 0],
          counts["aboveDisplayRGB"] as? [Int] == [1, 1, 1], counts["affectedPixels"] as? Int == 2,
          nativeRangeCounts(pixels, rectangle: .zero)["pixels"] as? Int == 0
    else { throw HarnessError.malformedReferenceData }
    print("Native input range: signed negative, above-domain, above-display, affected-pixel and empty-region counts pass")
}
