import Foundation
import simd

/// A smooth body-wide style residual in display-linear sRGB. Lookup coordinates
/// use bounded encoded sRGB; extended image values are retained until gamut prep.
/// Subtracting the neutral lookup protects the tone curve on every neutral value.
struct CreativeColour: Codable {
    let dimension: Int
    let coefficients: [Double]

    func validate() throws {
        guard dimension == 5, coefficients.count == 375,
              coefficients.allSatisfy({ $0.isFinite && abs($0) <= 1 })
        else { throw ReferenceError.unsupportedModel }
    }

    static func basis(_ rgb: SIMD3<Double>) -> [(index: Int, weight: Double)] {
        let grey = min(1, max(0, simd_dot(rgb, SIMD3(0.2126, 0.7152, 0.0722))))
        var weights = [Double](repeating: 0, count: 125)
        func accumulate(_ value: SIMD3<Double>, sign: Double) {
            let q = (0 ..< 3).map { c -> Double in
                let v = min(1, max(0, value[c]))
                return 4 * (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
            }
            let lower = q.map { min(3, Int($0)) }, f = (0 ..< 3).map { q[$0] - Double(lower[$0]) }
            for blue in 0 ... 1 {
                for green in 0 ... 1 {
                    for red in 0 ... 1 {
                        let w = (red == 0 ? 1 - f[0] : f[0]) * (green == 0 ? 1 - f[1] : f[1]) * (blue == 0 ? 1 - f[2] : f[2])
                        weights[lower[0] + red + 5 * (lower[1] + green) + 25 * (lower[2] + blue)] += sign * w
                    }
                }
            }
        }
        accumulate(rgb, sign: 1)
        accumulate(SIMD3(repeating: grey), sign: -1)
        return weights.enumerated().filter { abs($0.element) > 1e-14 }.map { ($0.offset, $0.element) }
    }

    func residual(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        Self.basis(rgb).reduce(.zero) { value, node in
            value + SIMD3(coefficients[node.index * 3], coefficients[node.index * 3 + 1], coefficients[node.index * 3 + 2]) * node.weight
        }
    }

    static let metalSource = """
    float3 colourLookup(float3 x,device const float *table) {
        float3 q=float3(encode(x.r),encode(x.g),encode(x.b))*4;
        uint3 lo=min(uint3(q),uint3(3));float3 f=q-float3(lo);float3 value=0;
        for(uint b=0;b<2;b++)for(uint g=0;g<2;g++)for(uint r=0;r<2;r++) {
            uint n=lo.r+r+5*(lo.g+g)+25*(lo.b+b);
            float w=(r ? f.r : 1-f.r)*(g ? f.g : 1-f.g)*(b ? f.b : 1-f.b);
            value+=float3(table[3*n],table[3*n+1],table[3*n+2])*w;
        }
        return value;
    }
    """
}
