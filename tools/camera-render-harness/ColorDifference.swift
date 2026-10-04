import Foundation

/// Numerical D65 sRGB/CIELAB and CIEDE2000 reference for the plan-0105 scorecard.
/// Input RGB is encoded sRGB in [0, 1]. Clipping is counted by the caller, before
/// this conversion; it must not be hidden by this function.
struct Lab: Equatable {
    let l: Double
    let a: Double
    let b: Double

    static func srgb(_ red: Double, _ green: Double, _ blue: Double) -> Lab {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(red), g = linear(green), b = linear(blue)
        // IEC 61966-2-1 sRGB to CIE XYZ, D65/2-degree white.
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ value: Double) -> Double {
            value > 216.0 / 24389.0 ? cbrt(value) : (24389.0 / 27.0 * value + 16) / 116
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }
}

/// Sharma, Wu & Dalal, Color Research & Application 30(1), 2005, equations 2–22.
/// Parametric factors are all one. Hue is expressed in degrees until trig use.
private func ciede2000Terms(_ lhs: Lab, _ rhs: Lab) -> (light: Double, chroma: Double, hue: Double, rotation: Double) {
    let c1 = hypot(lhs.a, lhs.b), c2 = hypot(rhs.a, rhs.b)
    let meanC = (c1 + c2) / 2
    let seventh = pow(meanC, 7)
    let g = 0.5 * (1 - sqrt(seventh / (seventh + pow(25.0, 7))))
    let a1 = (1 + g) * lhs.a, a2 = (1 + g) * rhs.a
    let cp1 = hypot(a1, lhs.b), cp2 = hypot(a2, rhs.b)
    func hue(_ a: Double, _ b: Double) -> Double {
        if a == 0 && b == 0 {
            return 0
        }
        let angle = atan2(b, a) * 180 / .pi
        return angle < 0 ? angle + 360 : angle
    }
    let h1 = hue(a1, lhs.b), h2 = hue(a2, rhs.b)
    let dL = rhs.l - lhs.l, dC = cp2 - cp1
    var dh = h2 - h1
    if cp1 * cp2 == 0 {
        dh = 0
    } else if dh > 180 {
        dh -= 360
    } else if dh < -180 {
        dh += 360
    }
    let dH = 2 * sqrt(cp1 * cp2) * sin(dh * .pi / 360)
    let meanL = (lhs.l + rhs.l) / 2
    let meanCp = (cp1 + cp2) / 2
    let meanH: Double = if cp1 * cp2 == 0 {
        h1 + h2
    } else if abs(h1 - h2) <= 180 {
        (h1 + h2) / 2
    } else if h1 + h2 < 360 {
        (h1 + h2 + 360) / 2
    } else {
        (h1 + h2 - 360) / 2
    }
    func cosine(_ angle: Double) -> Double {
        cos(angle * .pi / 180)
    }
    let t = 1 - 0.17 * cosine(meanH - 30) + 0.24 * cosine(2 * meanH)
        + 0.32 * cosine(3 * meanH + 6) - 0.20 * cosine(4 * meanH - 63)
    let theta = 30 * exp(-pow((meanH - 275) / 25, 2))
    let meanSeventh = pow(meanCp, 7)
    let rc = 2 * sqrt(meanSeventh / (meanSeventh + pow(25.0, 7)))
    let sl = 1 + 0.015 * pow(meanL - 50, 2) / sqrt(20 + pow(meanL - 50, 2))
    let sc = 1 + 0.045 * meanCp
    let sh = 1 + 0.015 * meanCp * t
    let rt = -rc * sin(2 * theta * .pi / 180)
    let light = dL / sl, chroma = dC / sc, hueTerm = dH / sh
    return (light, chroma, hueTerm, rt)
}

func ciede2000(_ lhs: Lab, _ rhs: Lab) -> Double {
    let (light, chroma, hueTerm, rt) = ciede2000Terms(lhs, rhs)
    return sqrt(light * light + chroma * chroma + hueTerm * hueTerm + rt * chroma * hueTerm)
}

/// Factor the chroma/hue rotation cross-term into three signed residuals.
/// Their Euclidean norm equals DE00; preserving directions gives the nonlinear
/// solver colour curvature that a single distance Jacobian discards.
func ciede2000Residual(_ lhs: Lab, _ rhs: Lab) -> SIMD3<Double> {
    let (light, chroma, hue, rotation) = ciede2000Terms(lhs, rhs)
    return SIMD3(light, chroma + rotation * hue / 2, sqrt(max(0, 1 - rotation * rotation / 4)) * hue)
}

func nativeResidualNorm(_ value: SIMD3<Double>) -> Double {
    sqrt(nativeResidualDot(value, value))
}

func nativeResidualDot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    a.x * b.x + a.y * b.y + a.z * b.z
}

/// Keep DE00 length while expressing direction in Cartesian Lab. Polar hue
/// residuals have square-root sensitivity when source chroma approaches zero;
/// that artificial direction instability need not enter the fit's curvature.
func ciede2000CartesianResidual(_ lhs: Lab, _ rhs: Lab) -> SIMD3<Double> {
    let delta = SIMD3(rhs.l - lhs.l, rhs.a - lhs.a, rhs.b - lhs.b)
    let length = nativeResidualNorm(delta)
    guard length > 0 else { return .zero }
    return delta * (ciede2000(lhs, rhs) / length)
}
