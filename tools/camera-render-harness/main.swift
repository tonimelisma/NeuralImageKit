import CoreImage
import CryptoKit
import Darwin
import Foundation
import ImageIO
import simd
import Vision

enum PairRole: String, Decodable { case training, authoring, selection, regression, acceptance }

struct Pair: Decodable {
    let id: String
    let raw: String
    let target: String
    let session: String
    let role: PairRole
}

struct Manifest: Decodable { let pairs: [Pair] }

enum HarnessError: Error {
    case usage, unavailableOriginal, decodeFailed(String), decoderUnavailable
    case incompatibleDimensions, registrationFailed, malformedReferenceData
    case invalidManifest, partialEvaluation
}

let numericContext = CIContext(options: [
    .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
    .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
])
let colorContext = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .cacheIntermediates: false,
])
let encodedSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
let displaySpace = CGColorSpace(name: CGColorSpace.sRGB)!

func localData(_ path: String) throws -> Data {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          (info.st_flags & 0x4000_0000) == 0
    else { throw HarnessError.unavailableOriginal }
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

func zeroOrigin(_ image: CIImage) -> CIImage {
    image.transformed(by: CGAffineTransform(
        translationX: -image.extent.minX, y: -image.extent.minY
    ))
}

func scaled(_ image: CIImage, longEdge: CGFloat = 768) -> CIImage {
    let original = zeroOrigin(image)
    let factor = longEdge / max(original.extent.width, original.extent.height)
    return zeroOrigin(original.applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1,
    ]))
}

func encodedImage(_ image: CIImage) throws -> CIImage {
    guard image.extent.width.isFinite, image.extent.height.isFinite,
          !image.extent.isEmpty
    else {
        throw HarnessError.decodeFailed("invalid extent \(image.extent)")
    }
    guard let cg = colorContext.createCGImage(image, from: image.extent,
                                              format: .RGBAh, colorSpace: encodedSpace)
    else { throw HarnessError.decodeFailed("encoded image conversion") }
    return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
}

func frame(_ image: CIImage, width: Int, height: Int) -> RGBFrame {
    var pixels = [Float](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { bytes in
        numericContext.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                              bounds: CGRect(x: 0, y: 0, width: width, height: height),
                              format: .RGBAf, colorSpace: nil)
    }
    return RGBFrame(width: width, height: height, rgba: pixels)
}

func image(_ pixels: RGBFrame) -> CIImage {
    CIImage(bitmapData: pixels.rgba.withUnsafeBytes { Data($0) },
            bytesPerRow: pixels.width * 16,
            size: CGSize(width: pixels.width, height: pixels.height),
            format: .RGBAf, colorSpace: nil)
}

func registrationImage(_ image: CIImage) throws -> CGImage {
    guard let cg = numericContext.createCGImage(image, from: image.extent,
                                                format: .RGBA8, colorSpace: displaySpace)
    else { throw HarnessError.decodeFailed("registration image conversion") }
    return cg
}

/// Vision reports a homography in its image-coordinate convention. Test its two
/// directions and y-axis conventions against the same fixed interior; record the
/// selected orientation rather than allowing a silent registration fallback.
func perspective(_ image: CIImage, matrix: simd_float3x3,
                 size: CGSize, flipY: Bool) -> CIImage
{
    let width = image.extent.width, height = image.extent.height
    func point(_ x: CGFloat, _ y: CGFloat) -> CIVector {
        let py = flipY ? height - y : y
        let v = matrix * SIMD3<Float>(Float(x / width * size.width),
                                      Float(py / height * size.height), 1)
        let mappedX = CGFloat(v.x / v.z) / size.width * width
        let mappedY = CGFloat(v.y / v.z) / size.height * height
        return CIVector(x: mappedX, y: flipY ? height - mappedY : mappedY)
    }
    return image.applyingFilter("CIPerspectiveTransform", parameters: [
        "inputTopLeft": point(0, height),
        "inputTopRight": point(width, height),
        "inputBottomLeft": point(0, 0),
        "inputBottomRight": point(width, 0),
    ])
}

func interiorMSE(_ a: RGBFrame, _ b: RGBFrame) -> Double {
    var total = 0.0, count = 0
    for y in 16 ..< a.height - 16 {
        for x in 16 ..< a.width - 16 {
            let index = (y * a.width + x) * 4
            guard a.rgba[index + 3] > 0.99 else { continue }
            for channel in 0 ..< 3 {
                let delta = Double(a.rgba[index + channel] - b.rgba[index + channel])
                total += delta * delta
                count += 1
            }
        }
    }
    return count == 0 ? .infinity : total / Double(count)
}

func register(_ source: CIImage, to target: CIImage, width: Int, height: Int)
    throws -> (image: CIImage, mse: Double, matrix: simd_float3x3, inverse: Bool, flipY: Bool)
{
    let request = try VNHomographicImageRegistrationRequest(
        targetedCGImage: registrationImage(source), options: [:]
    )
    try VNImageRequestHandler(cgImage: registrationImage(target), options: [:])
        .perform([request])
    guard let matrix = request.results?.first?.warpTransform else {
        throw HarnessError.registrationFailed
    }
    let targetFrame = frame(target, width: width, height: height)
    var best: (CIImage, Double, Bool, Bool)?
    for inverse in [false, true] {
        for flip in [false, true] {
            let aligned = perspective(source, matrix: inverse ? matrix.inverse : matrix,
                                      size: CGSize(width: width, height: height), flipY: flip)
            let error = interiorMSE(frame(aligned, width: width, height: height), targetFrame)
            if best == nil || error < best!.1 {
                best = (aligned, error, inverse, flip)
            }
        }
    }
    guard let best, best.1.isFinite else { throw HarnessError.registrationFailed }
    return (best.0, best.1, matrix, best.2, best.3)
}

func writePNG(_ image: CIImage, to url: URL) throws {
    try numericContext.writePNGRepresentation(of: image, to: url,
                                              format: .RGBA8, colorSpace: displaySpace)
}

/// Four unregistered, native-resolution corners. These reveal real detail and
/// geometry errors instead of magnifying the 768-pixel evaluation previews.
func writeNativeCorners(rawData: Data, target: CIImage, decoder: CIRAWDecoderVersion,
                        model: LookModel, directory: URL)
    throws -> (width: Int, height: Int, geometry: NativeGeometryScore)
{
    guard let defaultRaw = CIRAWFilter(imageData: rawData,
                                       identifierHint: nil),
        let neutralRaw = CIRAWFilter(imageData: rawData,
                                     identifierHint: nil),
        defaultRaw.supportedDecoderVersions.contains(decoder),
        neutralRaw.supportedDecoderVersions.contains(decoder)
    else { throw HarnessError.decoderUnavailable }
    defaultRaw.decoderVersion = decoder
    defaultRaw.scaleFactor = 1
    neutralRaw.decoderVersion = decoder
    neutralRaw.scaleFactor = 1
    neutralRaw.boostAmount = 0
    neutralRaw.localToneMapAmount = 0
    neutralRaw.contrastAmount = 0
    neutralRaw.sharpnessAmount = 0
    guard let defaultImage = defaultRaw.outputImage,
          let neutralImage = neutralRaw.outputImage
    else {
        throw HarnessError.decodeFailed("native RAW output")
    }
    let apple = zeroOrigin(defaultImage), neutral = zeroOrigin(neutralImage)
    let reference = zeroOrigin(target)
    guard apple.extent.size == reference.extent.size,
          neutral.extent.size == reference.extent.size,
          reference.extent.width >= 1024, reference.extent.height >= 1024
    else { throw HarnessError.incompatibleDimensions }
    let width = Int(reference.extent.width), height = Int(reference.extent.height)
    let geometry = try nativeGeometryScore(source: neutral, target: reference) { crop in
        let encoded = try encodedImage(zeroOrigin(crop))
        return frame(encoded, width: 192, height: 192)
    }
    let size = 512
    let corners: [(String, Int, Int)] = [
        ("tl", 0, height - size), ("tr", width - size, height - size),
        ("bl", 0, 0), ("br", width - size, 0),
    ]
    for (name, x, y) in corners {
        let rect = CGRect(x: x, y: y, width: size, height: size)
        let cropDirectory = directory.appendingPathComponent("native-" + name)
        try FileManager.default.createDirectory(at: cropDirectory, withIntermediateDirectories: true)
        let appleCrop = try encodedImage(zeroOrigin(apple.cropped(to: rect)))
        let neutralCrop = try encodedImage(zeroOrigin(neutral.cropped(to: rect)))
        let cameraCrop = try encodedImage(zeroOrigin(reference.cropped(to: rect)))
        let neutralFrame = frame(neutralCrop, width: size, height: size)
        let fixedCrop = try image(apply(model, to: neutralFrame))
        try writePNG(appleCrop, to: cropDirectory.appendingPathComponent("apple.png"))
        try writePNG(neutralCrop, to: cropDirectory.appendingPathComponent("neutral.png"))
        try writePNG(fixedCrop, to: cropDirectory.appendingPathComponent("fixed-model.png"))
        try writePNG(cameraCrop, to: cropDirectory.appendingPathComponent("camera.png"))
    }
    return (width, height, geometry)
}

func apply(_ model: LookModel, to source: RGBFrame) throws -> RGBFrame {
    var pixels = source.rgba
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let rgb = try model.evaluateRGB([
            Double(pixels[index]), Double(pixels[index + 1]), Double(pixels[index + 2]),
        ])
        pixels[index] = Float(rgb[0])
        pixels[index + 1] = Float(rgb[1])
        pixels[index + 2] = Float(rgb[2])
    }
    return RGBFrame(width: source.width, height: source.height, rgba: pixels)
}

func evaluate(_ pair: Pair, model: LookModel, output: URL) throws -> [String: Any] {
    // Both original reads are preceded immediately by the SF_DATALESS gate.
    let rawData = try localData(pair.raw)
    let targetData = try localData(pair.target)
    guard let raw = CIRAWFilter(imageData: rawData,
                                identifierHint: nil)
    else { throw HarnessError.decodeFailed("RAW filter") }
    guard let targetOriginal = CIImage(data: targetData,
                                       options: [.applyOrientationProperty: true])
    else { throw HarnessError.decodeFailed("Camera target") }
    let decoder = CIRAWDecoderVersion(rawValue: "9")
    guard raw.supportedDecoderVersions.contains(decoder) else {
        throw HarnessError.decoderUnavailable
    }
    raw.decoderVersion = decoder
    raw.scaleFactor = Float(768 / max(raw.nativeSize.width, raw.nativeSize.height))
    guard let appleOutput = raw.outputImage else { throw HarnessError.decodeFailed("Apple RAW output") }
    let apple = try encodedImage(scaled(appleOutput))
    // A fresh RAW filter owns each development. On this host, reusing a scaled
    // RAW 9 filter after rendering can change its next output's extent, even
    // without changing controls. Never derive a comparator from that state.
    guard let neutralRaw = CIRAWFilter(imageData: rawData,
                                       identifierHint: nil),
        neutralRaw.supportedDecoderVersions.contains(decoder)
    else { throw HarnessError.decoderUnavailable }
    neutralRaw.decoderVersion = decoder
    neutralRaw.scaleFactor = Float(768 / max(neutralRaw.nativeSize.width, neutralRaw.nativeSize.height))
    neutralRaw.boostAmount = 0
    neutralRaw.localToneMapAmount = 0
    neutralRaw.contrastAmount = 0
    neutralRaw.sharpnessAmount = 0
    guard let neutralOutput = neutralRaw.outputImage else { throw HarnessError.decodeFailed("neutral RAW output") }
    let neutral = try encodedImage(scaled(neutralOutput))
    let target = try encodedImage(scaled(targetOriginal))
    let width = Int(target.extent.width.rounded())
    let height = Int(target.extent.height.rounded())
    guard Int(neutral.extent.width.rounded()) == width,
          Int(neutral.extent.height.rounded()) == height,
          Int(apple.extent.width.rounded()) == width,
          Int(apple.extent.height.rounded()) == height
    else { throw HarnessError.incompatibleDimensions }
    let neutralFrame = frame(neutral, width: width, height: height)
    let filtered = try image(apply(model, to: neutralFrame))
    let registration = try register(filtered, to: target, width: width, height: height)
    let matrixTarget = registration.image
    // These are measurement-only coordinates. Viewer images below remain in each
    // renderer's original output geometry for honest full-frame inspection.
    let alignedNeutral = perspective(neutral,
                                     matrix: registration.inverse ? registration.matrix.inverse : registration.matrix,
                                     size: CGSize(width: width, height: height),
                                     flipY: registration.flipY)
    let alignedApple = perspective(apple,
                                   matrix: registration.inverse ? registration.matrix.inverse : registration.matrix,
                                   size: CGSize(width: width, height: height),
                                   flipY: registration.flipY)
    let targetPixels = frame(target, width: width, height: height)
    let alignedFixedPixels = frame(matrixTarget, width: width, height: height)
    let geometry = try geometryScore(candidate: alignedFixedPixels, target: targetPixels,
                                     nativeLongEdge: Int(max(raw.nativeSize.width,
                                                             raw.nativeSize.height)))
    let scores = try [
        "apple": colorScore(candidate: frame(alignedApple, width: width, height: height), target: targetPixels),
        "neutral": colorScore(candidate: frame(alignedNeutral, width: width, height: height), target: targetPixels),
        "fixedModel": colorScore(candidate: alignedFixedPixels, target: targetPixels),
    ]
    let pairDirectory = output.appendingPathComponent(pair.id)
    try FileManager.default.createDirectory(at: pairDirectory, withIntermediateDirectories: true)
    try writePNG(apple, to: pairDirectory.appendingPathComponent("apple.png"))
    try writePNG(neutral, to: pairDirectory.appendingPathComponent("neutral.png"))
    try writePNG(filtered, to: pairDirectory.appendingPathComponent("fixed-model.png"))
    try writePNG(target, to: pairDirectory.appendingPathComponent("camera.png"))
    let native = try writeNativeCorners(rawData: rawData, target: targetOriginal,
                                        decoder: decoder, model: model,
                                        directory: pairDirectory)
    let scoreData = try JSONEncoder().encode(scores)
    let scoreObject = try JSONSerialization.jsonObject(with: scoreData)
    let geometryObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(geometry))
    let nativeGeometryObject = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(native.geometry)
    )
    return [
        "id": pair.id, "session": pair.session, "role": pair.role.rawValue,
        "width": width, "height": height, "decoder": raw.decoderVersion.rawValue,
        "nativeWidth": native.width, "nativeHeight": native.height,
        "rawBytesRead": rawData.count, "targetBytesRead": targetData.count,
        "materialization": "alreadyLocal",
        "scores": scoreObject, "registrationMSE": registration.mse,
        "geometry": geometryObject,
        "nativeGeometry": nativeGeometryObject,
        "registrationInverse": registration.inverse,
        "registrationFlipY": registration.flipY,
    ]
}

func selfTest(_ path: String) throws {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    let lines = content.split(separator: "\n").filter { !$0.hasPrefix("#") }
    guard lines.count == 34 else { throw HarnessError.malformedReferenceData }
    for (index, line) in lines.enumerated() {
        let values = line.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard values.count == 7 else { throw HarnessError.malformedReferenceData }
        let first = Lab(l: values[0], a: values[1], b: values[2])
        let second = Lab(l: values[3], a: values[4], b: values[5])
        for (a, b) in [(first, second), (second, first)] {
            let error = ciede2000(a, b)
            guard abs(nativeResidualNorm(ciede2000Residual(a, b)) - error) < 1e-12,
                  abs(nativeResidualNorm(ciede2000CartesianResidual(a, b)) - error) < 1e-12
            else {
                throw HarnessError.malformedReferenceData
            }
            guard abs(error - values[6]) < 0.000051 else {
                throw NSError(domain: "CIEDE2000 reference row \(index + 1)",
                              code: 1, userInfo: ["actual": error, "expected": values[6]])
            }
        }
    }
    let gray = Lab.srgb(0.5, 0.5, 0.5)
    guard abs(gray.a) < 0.01, abs(gray.b) < 0.01 else { throw HarnessError.malformedReferenceData }
    let constant = RGBFrame(width: 32, height: 32,
                            rgba: Array(repeating: [Float(0.5), 0.5, 0.5, 1], count: 32 * 32).flatMap(\.self))
    let score = try colorScore(candidate: constant, target: constant)
    guard score.meanLowFrequencyDE00 == 0, score.validFraction == 1 else {
        throw HarnessError.malformedReferenceData
    }
    var pattern = [Float](repeating: 0, count: 128 * 96 * 4)
    var state: UInt32 = 0x6172_7738
    for i in 0 ..< 128 * 96 {
        state = 1_664_525 &* state &+ 1_013_904_223
        let value = Float(state & 0xFFFF) / 65535
        for channel in 0 ..< 3 {
            pattern[i * 4 + channel] = value
        }
        pattern[i * 4 + 3] = 1
    }
    let patterned = RGBFrame(width: 128, height: 96, rgba: pattern)
    let identicalGeometry = try geometryScore(candidate: patterned, target: patterned,
                                              nativeLongEdge: 128)
    let flat = RGBFrame(width: 128, height: 96,
                        rgba: Array(repeating: [Float(0.5), 0.5, 0.5, 1],
                                    count: 128 * 96).flatMap(\.self))
    let flatGeometry = try geometryScore(candidate: flat, target: flat,
                                         nativeLongEdge: 128)
    guard identicalGeometry.reliable > 20,
          (identicalGeometry.p95ResidualNativePixels ?? .infinity) < 0.05,
          flatGeometry.reliable == 0 else { throw HarnessError.malformedReferenceData }
    try nativeGeometrySelfTest()
    print("34 published CIEDE2000 pairs, scorecard and geometry fixtures: pass")
}

func validate(_ manifest: Manifest, output: URL) throws {
    guard !manifest.pairs.isEmpty, output.path.hasPrefix("/") else {
        throw HarnessError.invalidManifest
    }
    var ids = Set<String>()
    var sessionRoles = [String: PairRole]()
    let outputPath = output.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    for pair in manifest.pairs {
        guard !pair.id.isEmpty,
              pair.id.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
              }),
              ids.insert(pair.id).inserted,
              !pair.session.isEmpty,
              (sessionRoles[pair.session] ?? pair.role) == pair.role,
              pair.raw.lowercased().hasSuffix(".arw"),
              [".heif", ".hif", ".jpg", ".jpeg"].contains(where: {
                  pair.target.lowercased().hasSuffix($0)
              }),
              pair.raw != pair.target
        else { throw HarnessError.invalidManifest }
        sessionRoles[pair.session] = pair.role
        for path in [pair.raw, pair.target] {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard !outputPath.hasPrefix(directory) else { throw HarnessError.invalidManifest }
        }
    }
}

func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else { throw HarnessError.usage }
    if arguments[1] == "matching-residual-audit", arguments.count == 9 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[8])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[5]))
        try matchingResidualAudit(pair, candidateURL: URL(fileURLWithPath: arguments[4]), card: card,
                                  geometryReport: localData(arguments[6]), geometryBaseline: localData(arguments[7]), destination: output)
    } else if arguments[1] == "matching-calibration-look-audit", arguments.count == 7 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[6])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[4]))
        let profile = try ConditionalProfile(data: localData(arguments[5]))
        try auditNativeCalibrationSource(pair, card: card, profile: profile, destination: output)
    } else if arguments[1] == "matching-calibration-source-audit", arguments.count == 6 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[5])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[4]))
        try auditNativeCalibrationSource(pair, card: card, destination: output)
    } else if arguments[1] == "matching-native-region-palette", arguments.count == 8 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[7])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[4]))
        try exportNativeRegionPalette(pair, card: card, geometryReport: localData(arguments[5]), geometryBaseline: localData(arguments[6]), destination: output)
    } else if arguments[1] == "matching-native-input-range", arguments.count == 8 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[7])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[4]))
        try nativeInputRangeAudit(pair, card: card, geometryReport: localData(arguments[5]),
                                  geometryBaseline: localData(arguments[6]), destination: output)
    } else if arguments[1] == "training-native-profile-field", arguments.count == 10 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        guard manifest.pairs.allSatisfy({ $0.role == .training }),
              let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[5]))
        let initial = try JSONDecoder().decode([Double].self, from: localData(arguments[9]))
        try refineNativeProfileField(pair, baseData: localData(arguments[4]), card: card,
                                     geometryReport: localData(arguments[6]), geometryBaseline: localData(arguments[7]),
                                     curvature: .cartesian, objective: .regionMeanSquared, trainingInitial: initial,
                                     destination: URL(fileURLWithPath: arguments[8]))
    } else if arguments[1] == "matching-native-profile-field", (9 ... 11).contains(arguments.count) {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[8])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[5]))
        let curvature = arguments.count >= 10 ? NativeFieldCurvature(rawValue: arguments[9]) : .components
        let objective = arguments.count == 11 ? NativeFieldObjective(rawValue: arguments[10]) : .meanTail
        guard let curvature, let objective else { throw HarnessError.usage }
        try refineNativeProfileField(pair, baseData: localData(arguments[4]), card: card,
                                     geometryReport: localData(arguments[6]), geometryBaseline: localData(arguments[7]), curvature: curvature, objective: objective, destination: output)
    } else if arguments[1] == "matching-native-profile-refine", arguments.count == 9 || arguments.count == 10 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[8])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[5]))
        let controls = arguments.count == 10 ? NativeProfileRefinementControls(rawValue: arguments[9]) : .affine
        guard let controls else { throw HarnessError.usage }
        try refineNativeProfileOrder(pair, baseData: localData(arguments[4]), card: card,
                                     geometryReport: localData(arguments[6]), geometryBaseline: localData(arguments[7]), controls: controls, destination: output)
    } else if arguments[1] == "matching-native-profile-fit", arguments.count == 8 || arguments.count == 9 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[7])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[4]))
        let solve = arguments.count == 9 ? NativeProfileSolve(rawValue: arguments[8]) : .sequential
        guard let solve else { throw HarnessError.usage }
        try nativeProfileCapacity(pair, card: card, geometryReport: localData(arguments[5]), geometryBaseline: localData(arguments[6]), solve: solve, destination: output)
    } else if arguments[1] == "matching-native-order-refine", (8 ... 10).contains(arguments.count) {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[7])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let recipe = try AuthoredLook(json: localData(arguments[4]))
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[5]))
        let controls = arguments.count >= 9 ? NativeRefinementControls(rawValue: arguments[8]) : .toneOnly
        let objective = arguments.count == 10 ? NativeRefinementObjective(rawValue: arguments[9]) : .normalizedLab
        guard let controls, let objective else { throw HarnessError.usage }
        try refineNativeOrder(pair, base: recipe, card: card, geometryReport: localData(arguments[6]), controls: controls, objective: objective, destination: output)
    } else if arguments[1] == "matching-native-order-audit", arguments.count == 7 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[6])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        let recipe = try AuthoredLook(json: localData(arguments[4]))
        try nativeOrderDiagnostic(pair, recipe: recipe, candidateURL: URL(fileURLWithPath: arguments[5]), destination: output)
    } else if arguments[1] == "comparison-calibrate", arguments.count == 5 || arguments.count == 6 {
        guard arguments.count == 5 || arguments[5] == "native-crop" else { throw HarnessError.usage }
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[4])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else { throw HarnessError.invalidManifest }
        try comparisonCalibration(pair, destination: output, nativeCrop: arguments.count == 6)
    } else if arguments[1] == "authored-look-fit", arguments.count == 11 {
        let training = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let anchors = try JSONDecoder().decode(Manifest.self, from: localData(arguments[4]))
        let base = try AuthoredLook(json: localData(arguments[6]))
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[7]))
        guard let mixture = Double(arguments[8]), let objective = DisplayColourObjective(rawValue: arguments[9]) else { throw HarnessError.usage }
        try AuthoredCalibration.authorLook(anchors, samplesRoot: URL(fileURLWithPath: arguments[5]), base: base,
                                           card: card, training: training, trainingRoot: URL(fileURLWithPath: arguments[3]), mixture: mixture, objectiveSpace: objective,
                                           destination: URL(fileURLWithPath: arguments[10]))
    } else if arguments[1] == "self-test", arguments.count == 3 {
        try selfTest(arguments[2])
        try sensorRAWHEIFSelfTest()
        try authoredLookSelfTest()
        try displayColourRefinementSelfTest()
        try appearanceRegionSelfTest()
        try AuthoredCalibration.selfTest()
        try authoredCapacitySelfTest()
        try lookCalibrationSelfTest()
        try nativeProfileObservationSelfTest()
        try nativeProfileFieldSelfTest()
        try conditionalProfileSelfTest()
        try nativeInputRangeSelfTest()
        try nativeRegionPaletteSelfTest()
    } else if arguments[1] == "look-self-test", arguments.count == 4 {
        try lookModelSelfTest(modelPath: arguments[2], vectorsPath: arguments[3])
    } else if arguments[1] == "conditional-profile-fit", arguments.count == 8 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        guard let kind = ConditionalProfile.Kind(rawValue: arguments[6]) else { throw HarnessError.invalidManifest }
        try fitConditionalProfile(manifest, root: URL(fileURLWithPath: arguments[3]), metadata: localData(arguments[4]),
                                  baseData: localData(arguments[5]), kind: kind, destination: URL(fileURLWithPath: arguments[7]))
    } else if ["calibration-joint-fit", "calibration-joint-fit-domain"].contains(arguments[1]), arguments.count == 6 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        try fitJointLookCalibration(manifest, samplesRoot: URL(fileURLWithPath: arguments[3]),
                                    initialData: localData(arguments[4]), destination: URL(fileURLWithPath: arguments[5]),
                                    sampling: arguments[1].hasSuffix("-domain") ? .modelDomain : .interior)
    } else if ["calibration-export-one", "calibration-export-domain-one"].contains(arguments[1]), arguments.count == 5 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[4])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }) else {
            throw HarnessError.invalidManifest
        }
        try exportLookCalibrationPair(pair, output: output, sampling: arguments[1].contains("-domain-") ? .modelDomain : .interior)
    } else if arguments[1] == "authored-calibration-export-one", arguments.count == 7 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let output = URL(fileURLWithPath: arguments[4])
        try validate(manifest, output: output)
        guard let pair = manifest.pairs.first(where: { $0.id == arguments[3] }),
              let input = NativeRAWRecipe(rawValue: arguments[6]) else { throw HarnessError.invalidManifest }
        let registrationLook = try LookModel(json: localData(arguments[5]))
        try exportAuthoredCalibration(pair, input: input, registrationLook: registrationLook, output: output)
    } else if ["authored-colour-fit", "authored-colour-palette-fit", "authored-colour-palette-bound-fit"].contains(arguments[1]), arguments.count == (arguments[1].contains("bound") ? 8 : 7) {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let base = try AuthoredLook(json: localData(arguments[4]))
        guard let regularization = Double(arguments[5]) else { throw HarnessError.usage }
        let hasBound = arguments[1].contains("bound")
        guard let bound = hasBound ? Double(arguments[6]) : 0.5 else { throw HarnessError.usage }
        try AuthoredCalibration.fitColour(manifest, samplesRoot: URL(fileURLWithPath: arguments[3]), base: base,
                                          regularization: regularization, paletteBalanced: arguments[1].contains("palette"), coefficientBound: bound, destination: URL(fileURLWithPath: arguments[hasBound ? 7 : 6]))
    } else if arguments[1] == "authored-colour-display-fit", arguments.count == 8 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let initial = try AuthoredLook(json: localData(arguments[4]))
        guard let regularization = Double(arguments[5]), ["grid", "palette", "balanced-palette", "global-palette"].contains(arguments[6]) else { throw HarnessError.usage }
        try AuthoredCalibration.refineColour(manifest, samplesRoot: URL(fileURLWithPath: arguments[3]), initial: initial,
                                             regularization: regularization, paletteBalanced: arguments[6] != "grid",
                                             colourBalance: arguments[6] == "global-palette" ? 1 : arguments[6] == "balanced-palette" ? 0.5 : 0, destination: URL(fileURLWithPath: arguments[7]))
    } else if arguments[1] == "authored-colour-capacity-fit", arguments.count == 8 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let base = try AuthoredLook(json: localData(arguments[4]))
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[6]))
        guard let regularization = Double(arguments[7]) else { throw HarnessError.usage }
        try AuthoredCalibration.colourCapacity(manifest, samplesRoot: URL(fileURLWithPath: arguments[3]), base: base,
                                               card: card, regularization: regularization, destination: URL(fileURLWithPath: arguments[5]))
    } else if arguments[1] == "matching-colour-diagnostic-fit", arguments.count == 10 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        let base = try AuthoredLook(json: localData(arguments[4]))
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[6]))
        guard let regularization = Double(arguments[7]),
              let scope = AuthoredCalibration.DiagnosticScope(rawValue: arguments[8]),
              let objective = DisplayColourObjective(rawValue: arguments[9]) else { throw HarnessError.usage }
        try AuthoredCalibration.colourCapacity(manifest, samplesRoot: URL(fileURLWithPath: arguments[3]), base: base,
                                               card: card, regularization: regularization, scope: scope, objectiveSpace: objective,
                                               destination: URL(fileURLWithPath: arguments[5]))
    } else if arguments[1] == "matching-tone-diagnostic-fit", arguments.count == 9 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        guard let input = NativeRAWRecipe(rawValue: arguments[4]), let mode = AuthoredLook.ToneMode(rawValue: arguments[5]),
              let scope = AuthoredCalibration.DiagnosticScope(rawValue: arguments[8]) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[7]))
        try AuthoredCalibration.capacity(manifest, samplesRoot: URL(fileURLWithPath: arguments[3]), input: input, mode: mode,
                                         card: card, scope: scope, destination: URL(fileURLWithPath: arguments[6]))
    } else if arguments[1] == "authored-capacity-fit", arguments.count == 8 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        guard let input = NativeRAWRecipe(rawValue: arguments[4]), let mode = AuthoredLook.ToneMode(rawValue: arguments[5]) else { throw HarnessError.invalidManifest }
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[7]))
        try AuthoredCalibration.capacity(manifest, samplesRoot: URL(fileURLWithPath: arguments[3]), input: input, mode: mode,
                                         card: card, destination: URL(fileURLWithPath: arguments[6]))
    } else if arguments[1] == "authored-fit", arguments.count == 7 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        guard let input = NativeRAWRecipe(rawValue: arguments[4]), let mode = AuthoredLook.ToneMode(rawValue: arguments[5]) else { throw HarnessError.invalidManifest }
        try AuthoredCalibration.fit(manifest, samplesRoot: URL(fileURLWithPath: arguments[3]), input: input,
                                    mode: mode, destination: URL(fileURLWithPath: arguments[6]))
    } else if ["calibration-fit", "calibration-fit-domain"].contains(arguments[1]), arguments.count == 5 {
        let manifest = try JSONDecoder().decode(Manifest.self, from: localData(arguments[2]))
        try fitLookCalibration(manifest, samplesRoot: URL(fileURLWithPath: arguments[3]),
                               destination: URL(fileURLWithPath: arguments[4]), sampling: arguments[1].hasSuffix("-domain") ? .modelDomain : .interior)
    } else if arguments[1] == "score-regions", arguments.count == 7 {
        let card = try JSONDecoder().decode(AppearanceLookCard.self, from: localData(arguments[5]))
        try card.validate()
        let candidateData = try localData(arguments[2]), targetData = try localData(arguments[3]), geometryData = try localData(arguments[4])
        guard let regions = card.regions[arguments[6]],
              let candidate = CIImage(data: candidateData, options: [.applyOrientationProperty: true]),
              let target = CIImage(data: targetData, options: [.applyOrientationProperty: true]),
              let geometry = CIImage(data: geometryData, options: [.applyOrientationProperty: true]),
              geometry.extent.size == candidate.extent.size
        else { throw HarnessError.invalidManifest }
        let a = try encodedImage(scaled(candidate)), b = try encodedImage(scaled(target))
        let correspondence = geometryData == targetData ? regions.map { _ in RegionCorrespondence.identity } :
            try nativeRegionCorrespondence(source: zeroOrigin(geometry), target: zeroOrigin(target), regions: regions, evaluationWidth: Int(a.extent.width)) { crop in
                let encoded = try encodedImage(crop)
                return frame(encoded, width: Int(encoded.extent.width), height: Int(encoded.extent.height))
            }
        let scores = try appearanceRegionScores(
            candidate: frame(a, width: Int(a.extent.width), height: Int(a.extent.height)),
            target: frame(b, width: Int(b.extent.width), height: Int(b.extent.height)), regions: regions, card: card, correspondences: correspondence
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try print(String(data: encoder.encode(AppearanceRegionReport(geometryBaselineSHA256: SHA256.hash(data: geometryData).description, scores: scores)), encoding: .utf8)!)
    } else if arguments[1] == "score-images", arguments.count == 4 {
        guard let candidate = try CIImage(data: localData(arguments[2]),
                                          options: [.applyOrientationProperty: true]),
            let target = try CIImage(data: localData(arguments[3]),
                                     options: [.applyOrientationProperty: true])
        else { throw HarnessError.decodeFailed("score input") }
        let a = try encodedImage(scaled(candidate))
        let b = try encodedImage(scaled(target))
        guard a.extent.size == b.extent.size else { throw HarnessError.incompatibleDimensions }
        let width = Int(a.extent.width), height = Int(a.extent.height)
        let score = try colorScore(
            candidate: frame(a, width: width, height: height),
            target: frame(b, width: width, height: height)
        )
        try print(String(data: JSONEncoder().encode(score), encoding: .utf8)!)
    } else if arguments[1] == "sensor-raw-heif", arguments.count == 5 {
        let result = try CameraSensorRAWHEIFRenderer.render(
            rawURL: URL(fileURLWithPath: arguments[2]),
            destinationURL: URL(fileURLWithPath: arguments[3]),
            mediaRoots: [URL(fileURLWithPath: arguments[4])]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try print(String(data: encoder.encode(result), encoding: .utf8)!)
    } else if arguments[1] == "authored-heif", arguments.count == 6 {
        let look = try AuthoredLook(json: localData(arguments[5]))
        let result = try CameraSensorRAWHEIFRenderer.render(
            rawURL: URL(fileURLWithPath: arguments[2]), destinationURL: URL(fileURLWithPath: arguments[3]),
            mediaRoots: [URL(fileURLWithPath: arguments[4])], look: .authored(look)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try print(String(data: encoder.encode(result), encoding: .utf8)!)
    } else if ["sensor-model-heif", "sensor-conditional-heif"].contains(arguments[1]), arguments.count == 6 {
        let look: SensorRenderingLook = arguments[1] == "sensor-conditional-heif"
            ? try .conditional(ConditionalProfile(data: localData(arguments[5])))
            : try .saved(LookModel(json: localData(arguments[5])))
        let result = try CameraSensorRAWHEIFRenderer.render(
            rawURL: URL(fileURLWithPath: arguments[2]),
            destinationURL: URL(fileURLWithPath: arguments[3]),
            mediaRoots: [URL(fileURLWithPath: arguments[4])], look: look
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try print(String(data: encoder.encode(result), encoding: .utf8)!)
    } else if ["sensor-raw-evaluate", "sensor-model-evaluate", "sensor-conditional-evaluate", "authored-evaluate"].contains(
        arguments[1].replacingOccurrences(of: "-one", with: "")
    ), arguments.count == (arguments[1].contains("raw-evaluate") ? 4 : 5) +
        (arguments[1].hasSuffix("-one") ? 1 : 0)
    {
        let action = arguments[1].replacingOccurrences(of: "-one", with: "")
        let singlePair = arguments[1].hasSuffix("-one")
        let manifest = try JSONDecoder().decode(Manifest.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let look: SensorRenderingLook = switch action {
        case "sensor-raw-evaluate": .nativeDefault
        case "sensor-model-evaluate": try .saved(LookModel(json: localData(arguments[3])))
        case "sensor-conditional-evaluate": try .conditional(ConditionalProfile(data: localData(arguments[3])))
        default: try .authored(AuthoredLook(json: localData(arguments[3])))
        }
        let output = URL(fileURLWithPath: arguments[action == "sensor-raw-evaluate" ? 3 : 4])
        try validate(manifest, output: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if singlePair {
            guard let pair = manifest.pairs.first(where: { $0.id == arguments.last! }) else {
                throw HarnessError.invalidManifest
            }
            let record = try evaluateSensorRAWHEIF(
                pair, output: output, look: look
            )
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(pair.id + ".json"))
            print("evaluated \(pair.id) \(pair.role.rawValue) \(pair.session)")
        } else {
            // Each image gets a fresh process so Core Image, Metal and Image I/O
            // release their native allocations before the next large RAW.
            var failures = [[String: String]]()
            for pair in manifest.pairs {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: arguments[0])
                child.arguments = [action + "-one"] + Array(arguments[2...]) + [pair.id]
                do {
                    try child.run()
                    child.waitUntilExit()
                    if child.terminationStatus != 0 {
                        failures.append(["id": pair.id,
                                         "reason": "child exit \(child.terminationStatus)"])
                    }
                } catch {
                    failures.append(["id": pair.id, "reason": String(describing: error)])
                }
            }
            let summary = try JSONSerialization.data(withJSONObject: [
                "planned": manifest.pairs.count,
                "completed": manifest.pairs.count - failures.count,
                "failures": failures,
            ], options: [.prettyPrinted, .sortedKeys])
            try summary.write(to: output.appendingPathComponent("summary.json"))
            if !failures.isEmpty {
                throw HarnessError.partialEvaluation
            }
        }
    } else if arguments[1] == "lens-audit", arguments.count == 4 {
        let manifest = try JSONDecoder().decode(Manifest.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let output = URL(fileURLWithPath: arguments[3])
        try validate(manifest, output: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures = [[String: String]]()
        for pair in manifest.pairs {
            do {
                let record = try lensAudit(pair)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(record).write(to: output.appendingPathComponent(pair.id + ".json"))
                print("audited \(pair.id) \(pair.role.rawValue) \(pair.session)")
            } catch {
                failures.append(["id": pair.id, "reason": String(describing: error)])
                fputs("failed: \(pair.id)\n", stderr)
            }
        }
        let summary = try JSONSerialization.data(withJSONObject: [
            "planned": manifest.pairs.count,
            "completed": manifest.pairs.count - failures.count,
            "failures": failures,
        ], options: [.prettyPrinted, .sortedKeys])
        try summary.write(to: output.appendingPathComponent("summary.json"))
        if !failures.isEmpty {
            throw HarnessError.partialEvaluation
        }
    } else if arguments[1] == "evaluate", arguments.count == 5 {
        let manifest = try JSONDecoder().decode(Manifest.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let model = try LookModel(json: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        let output = URL(fileURLWithPath: arguments[4])
        try validate(manifest, output: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures = [[String: String]]()
        var completedIDs = [String]()
        for pair in manifest.pairs {
            do {
                let result = try evaluate(pair, model: model, output: output)
                let data = try JSONSerialization.data(withJSONObject: result,
                                                      options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent(pair.id + ".json"))
                completedIDs.append(pair.id)
                print("evaluated \(pair.id) \(pair.role.rawValue) \(pair.session)")
            } catch {
                let status = if let harnessError = error as? HarnessError,
                                case .unavailableOriginal = harnessError
                {
                    "unavailable"
                } else {
                    "failed"
                }
                failures.append(["id": pair.id, "status": status,
                                 "reason": String(describing: error)])
                fputs("\(status): \(pair.id)\n", stderr)
            }
        }
        let summary = try JSONSerialization.data(withJSONObject: [
            "planned": manifest.pairs.count,
            "completed": manifest.pairs.count - failures.count,
            "failures": failures,
        ], options: [.prettyPrinted, .sortedKeys])
        try summary.write(to: output.appendingPathComponent("summary.json"))
        try viewerHTML(ids: completedIDs).write(to: output.appendingPathComponent("index.html"),
                                                atomically: true, encoding: .utf8)
        if !failures.isEmpty {
            throw HarnessError.partialEvaluation
        }
    } else {
        throw HarnessError.usage
    }
}

do {
    try run()
} catch {
    fputs("Camera render harness: \(error)\n", stderr)
    exit(1)
}
