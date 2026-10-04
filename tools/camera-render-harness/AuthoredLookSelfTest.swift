import Foundation
import simd

func authoredLookSelfTest() throws {
    func model(_ mode: String, _ extra: [String: Any] = [:]) throws -> AuthoredLook {
        var json: [String: Any] = ["formatVersion": 5, "gamutPolicy": "smoothRadial", "decoder": "9", "input": "unmapped",
                                   "exposureEV": 0, "whiteBalanceRGB": [1, 1, 1], "contrast": 1.15,
                                   "tonePivot": 0.65, "skew": 1, "toneMode": mode, "huePreservation": 0.5, "saturation": 1.08]
        json.merge(extra) { _, new in new }
        return try AuthoredLook(json: JSONSerialization.data(withJSONObject: json))
    }
    var maximumError = 0.0
    for mode in ["rgbRatio", "perChannel"] {
        let look = try model(mode)
        var previous = -1.0
        for i in 0 ... 1024 {
            let value = Double(i) * 16 / 1024
            let rgb = look.evaluate(SIMD3(repeating: value))
            guard abs(rgb.x - rgb.y) < 1e-10, abs(rgb.x - rgb.z) < 1e-10,
                  rgb.x >= previous, rgb.x >= 0, rgb.x <= 1 else { throw ReferenceError.invalidPixels }
            previous = rgb.x
        }
        let lifted = try model(mode, ["exposureEV": 1])
        let a = lifted.evaluate(SIMD3(repeating: 0.1)), b = look.evaluate(SIMD3(repeating: 0.2))
        guard simd_length(a - b) < 1e-12 else { throw ReferenceError.invalidPixels }
        var input = [Float]()
        let values: [Float] = [-0.1, -0.001, 0, 0.003, 0.18, 1, 4, 16]
        for red in values {
            for green in values {
                for blue in values {
                    input += [red, green, blue, 1]
                }
            }
        }
        let metal = try MetalAuthoredLook(look)
        let output = try metal.apply(input)
        for i in stride(from: 0, to: input.count, by: 4) {
            let cpu = look.evaluate(SIMD3(Double(input[i]), Double(input[i + 1]), Double(input[i + 2])))
            for channel in 0 ..< 3 {
                guard output[i + channel].isFinite, (0 ... 1).contains(output[i + channel]) else { throw ReferenceError.invalidPixels }
                maximumError = max(maximumError, abs(Double(output[i + channel]) - cpu[channel]))
            }
            guard output[i + 3] == 1 else { throw ReferenceError.invalidPixels }
        }
        for invalid in [[Float.nan, 0, 0, 1], [Float.infinity, 0, 0, 1], [0, 0, 0]] {
            do { _ = try metal.apply(invalid)
                throw ReferenceError.unsupportedModel
            } catch ReferenceError.invalidPixels {}
        }
        guard try metal.apply([]).isEmpty else { throw ReferenceError.invalidPixels }
        for stages in [AuthoredLook.Stages(normalization: false), .init(tone: false), .init(creative: false)] {
            let gpu = try MetalAuthoredLook(look, stages: stages).apply([0.12, 0.18, 0.25, 1])
            let cpu = look.evaluate(SIMD3(0.12, 0.18, 0.25), stages: stages)
            for c in 0 ..< 3 {
                maximumError = max(maximumError, abs(Double(gpu[c]) - cpu[c]))
            }
        }
    }
    // Exercise non-default coefficients too: matching defaults alone cannot
    // detect a missing fitted control in one of the implementations.
    for mode in ["rgbRatio", "perChannel"] {
        for skew in [0.3, 1.8, 3.0] {
            let look = try model(mode, ["skew": skew, "contrast": 0.7, "exposureEV": 1,
                                        "whiteBalanceRGB": [0.8, 1, 1.2], "saturation": 1.4])
            let input: [Float] = [0.02, 0.05, 0.1, 1, 0.2, 0.1, 0.05, 1, 4, 1, 0.01, 1, -0.03, 0.2, 0.8, 1]
            let gpu = try MetalAuthoredLook(look).apply(input)
            for i in stride(from: 0, to: input.count, by: 4) {
                let cpu = look.evaluate(SIMD3(Double(input[i]), Double(input[i + 1]), Double(input[i + 2])))
                for c in 0 ..< 3 {
                    maximumError = max(maximumError, abs(Double(gpu[i + c]) - cpu[c]))
                }
            }
        }
    }
    // A nearly zero weighted luminance with positive and negative channels must
    // not amplify dark noise. Endpoint interpolation is bounded before gamut,
    // continuous across luminance zero, and agrees on CPU and GPU.
    let bounded = try model("perChannel", ["saturation": 1, "huePreservation": 1])
    var cancellationInput = [Float]()
    var previousCancellation: SIMD3<Double>?
    for offset in [-1e-8, -1e-10, 0, 1e-10, 1e-8] {
        let red = -0.01, green = 0.0, blue = 0.01 * 0.2126 / 0.0722 + offset
        // Inverse of the display-primary conversion, preserving the adversarial
        // signed RGB rather than manufacturing a decoder failure.
        let wide = SIMD3(0.627403895934699 * red + 0.329283038377884 * green + 0.043313065687417 * blue,
                         0.069097289358232 * red + 0.919540395075459 * green + 0.011362315566309 * blue,
                         0.01639143887515 * red + 0.088013307877226 * green + 0.895595253247624 * blue)
        let linear = bounded.displayLinear(wide)
        guard linear.min() >= -1e-12, linear.max() < 0.05 else { throw ReferenceError.invalidPixels }
        if let previousCancellation {
            guard simd_length(linear - previousCancellation) < 1e-6 else { throw ReferenceError.invalidPixels }
        }
        previousCancellation = linear
        cancellationInput += [Float(wide.x), Float(wide.y), Float(wide.z), 1]
    }
    let cancellationOutput = try MetalAuthoredLook(bounded).apply(cancellationInput)
    for i in stride(from: 0, to: cancellationInput.count, by: 4) {
        let cpu = bounded.evaluate(SIMD3(Double(cancellationInput[i]), Double(cancellationInput[i + 1]), Double(cancellationInput[i + 2])))
        for c in 0 ..< 3 {
            maximumError = max(maximumError, abs(Double(cancellationOutput[i + c]) - cpu[c]))
        }
    }
    var colourCoefficients = [Double]()
    for b in 0 ... 4 {
        for g in 0 ... 4 {
            for r in 0 ... 4 {
                colourCoefficients += [0.02 * Double(r - g) / 4, 0.03 * Double(g - b) / 4, 0.015 * Double(b - r) / 4]
            }
        }
    }
    for mode in ["rgbRatio", "perChannel"] {
        let look = try model(mode, ["colourCorrection": ["dimension": 5, "coefficients": colourCoefficients]])
        let plain = try model(mode)
        let values: [Float] = [-0.1, 0, 0.003, 0.18, 1, 4]
        var input = [Float]()
        for r in values {
            for g in values {
                for b in values {
                    input += [r, g, b, 1]
                }
            }
        }
        let output = try MetalAuthoredLook(look).apply(input)
        for i in stride(from: 0, to: input.count, by: 4) {
            let rgb = SIMD3(Double(input[i]), Double(input[i + 1]), Double(input[i + 2]))
            let cpu = look.evaluate(rgb)
            for c in 0 ..< 3 {
                maximumError = max(maximumError, abs(Double(output[i + c]) - cpu[c]))
            }
        }
        for value in [0.001, 0.02, 0.18, 1, 5] {
            let neutral = SIMD3<Double>(repeating: value)
            guard simd_length(look.evaluate(neutral) - plain.evaluate(neutral)) < 1e-10 else { throw ReferenceError.invalidPixels }
        }
        let stages = AuthoredLook.Stages(colourResidual: false)
        let sample = SIMD3<Double>(0.1, 0.4, 0.8)
        guard simd_length(look.evaluate(sample, stages: stages) - plain.evaluate(sample)) < 1e-12 else { throw ReferenceError.invalidPixels }
        let disabled = try MetalAuthoredLook(look, stages: stages).apply([0.1, 0.4, 0.8, 1])
        let expected = look.evaluate(SIMD3(Double(Float(0.1)), Double(Float(0.4)), Double(Float(0.8))), stages: stages)
        for c in 0 ..< 3 {
            maximumError = max(maximumError, abs(Double(disabled[c]) - expected[c]))
        }
    }
    // This neutral-preserving SDR channel blend needs >0.5 coefficients;
    // the permitted amplitude must not clip a valid hue operation silently.
    var strong = [Double]()
    for b in 0 ... 4 {
        for g in 0 ... 4 {
            for _ in 0 ... 4 {
                func linear(_ v: Double) -> Double {
                    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
                strong += [0, 0.9 * (linear(Double(b) / 4) - linear(Double(g) / 4)), 0]
            }
        }
    }
    let strongLook = try model("perChannel", ["colourCorrection": ["dimension": 5, "coefficients": strong]])
    let strongPixels: [Float] = [0.01, 0.4, 0.9, 1, 0.4, 0.1, 0.01, 1, 0.18, 0.18, 0.18, 1]
    let strongOutput = try MetalAuthoredLook(strongLook).apply(strongPixels)
    for i in stride(from: 0, to: strongPixels.count, by: 4) {
        let cpu = strongLook.evaluate(SIMD3(Double(strongPixels[i]), Double(strongPixels[i + 1]), Double(strongPixels[i + 2])))
        for c in 0 ..< 3 {
            maximumError = max(maximumError, abs(Double(strongOutput[i + c]) - cpu[c]))
        }
    }
    for invalid in [["dimension": 9, "coefficients": colourCoefficients],
                    ["dimension": 5, "coefficients": [0.1]],
                    ["dimension": 5, "coefficients": [Double](repeating: 1.01, count: 375)]] as [[String: Any]]
    {
        do { _ = try model("rgbRatio", ["colourCorrection": invalid])
            throw ReferenceError.invalidPixels
        } catch ReferenceError.unsupportedModel {}
    }
    let projected = try model("perChannel", ["gamutPolicy": "radialProjection"])
    func encode(_ x: Double) -> Double {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
    for x in [SIMD3<Double>(0, 0.8, 1), SIMD3(0.8, 0.02, 0.3), SIMD3(0.2, 0.4, 0.6)] {
        guard simd_length(projected.prepareDisplay(x) - SIMD3(encode(x.x), encode(x.y), encode(x.z))) < 1e-12 else { throw ReferenceError.invalidPixels }
    }
    let projectionPixels: [Float] = (0 ..< 512).flatMap { i -> [Float] in
        let r = Float(i % 8) / Float(3) - Float(0.1)
        let g = Float(i / 8 % 8) / Float(3) - Float(0.1)
        let b = Float(i / 64) / Float(3) - Float(0.1)
        return [r, g, b, 1]
    }
    let projectionGPU = try MetalAuthoredLook(projected).apply(projectionPixels)
    for i in 0 ..< 512 {
        let cpu = projected.evaluate(SIMD3(Double(projectionPixels[i * 4]), Double(projectionPixels[i * 4 + 1]), Double(projectionPixels[i * 4 + 2])))
        for c in 0 ..< 3 {
            guard abs(cpu[c] - Double(projectionGPU[i * 4 + c])) < 2e-5 else { throw ReferenceError.invalidPixels }
        }
    }
    print("Display projection: in-gamut identity, saturated boundary and CPU/Metal extended-colour fixtures pass")
    for extra: [String: Any] in [["formatVersion": 4], ["formatVersion": 3], ["formatVersion": 1], ["formatVersion": 2], ["contrast": 0], ["tonePivot": -1], ["decoder": "8"], ["input": "appleDefault"], ["whiteBalanceRGB": [1]], ["saturation": 2], ["exposureEV": 20]] {
        do { _ = try model("rgbRatio", extra)
            throw ReferenceError.invalidPixels
        } catch ReferenceError.unsupportedModel {}
    }
    do { _ = try model("rgbRatio", ["gamutPolicy": "unknown"])
        throw ReferenceError.invalidPixels
    } catch DecodingError.dataCorrupted {}
    guard maximumError < 2e-5 else { throw ReferenceError.invalidPixels }
    print("Authored look: neutral/monotone/exposure/extended-range/stage-ablation/rejection fixtures pass; CPU/Metal vectors maxError=\(maximumError)")
}
