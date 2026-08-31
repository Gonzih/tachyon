import SwiftUI

/// Official provider marks, embedded as SVG path data and rendered grayscale
/// (tinted by the caller — the app never uses brand colors). Geometry sources:
/// Claude starburst & Cursor cube via simple-icons (CC0 path data), OpenAI knot
/// via Wikimedia Commons, Grok comet via lobehub icons (MIT). The app still ships with
/// zero assets: paths are parsed at render time and cached.
enum ProviderGlyph: String, Sendable, CaseIterable {
    case claude
    case codex
    case grok
    case cursor
    case omp
    case openrouter
    case ollama

    /// Native coordinate space of `pathData`.
    var viewBox: CGRect {
        switch self {
        case .claude, .cursor, .grok, .omp, .openrouter, .ollama: return CGRect(x: 0, y: 0, width: 24, height: 24)
        case .codex: return CGRect(x: 0, y: 0, width: 320, height: 320)
        }
    }

    var pathData: String {
        switch self {
        case .claude:
            return "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
        case .codex:
            return "m297.06 130.97c7.26-21.79 4.76-45.66-6.85-65.48-17.46-30.4-52.56-46.04-86.84-38.68-15.25-17.18-37.16-26.95-60.13-26.81-35.04-.08-66.13 22.48-76.91 55.82-22.51 4.61-41.94 18.7-53.31 38.67-17.59 30.32-13.58 68.54 9.92 94.54-7.26 21.79-4.76 45.66 6.85 65.48 17.46 30.4 52.56 46.04 86.84 38.68 15.24 17.18 37.16 26.95 60.13 26.8 35.06.09 66.16-22.49 76.94-55.86 22.51-4.61 41.94-18.7 53.31-38.67 17.57-30.32 13.55-68.51-9.94-94.51zm-120.28 168.11c-14.03.02-27.62-4.89-38.39-13.88.49-.26 1.34-.73 1.89-1.07l63.72-36.8c3.26-1.85 5.26-5.32 5.24-9.07v-89.83l26.93 15.55c.29.14.48.42.52.74v74.39c-.04 33.08-26.83 59.9-59.91 59.97zm-128.84-55.03c-7.03-12.14-9.56-26.37-7.15-40.18.47.28 1.3.79 1.89 1.13l63.72 36.8c3.23 1.89 7.23 1.89 10.47 0l77.79-44.92v31.1c.02.32-.13.63-.38.83l-64.41 37.19c-28.69 16.52-65.33 6.7-81.92-21.95zm-16.77-139.09c7-12.16 18.05-21.46 31.21-26.29 0 .55-.03 1.52-.03 2.2v73.61c-.02 3.74 1.98 7.21 5.23 9.06l77.79 44.91-26.93 15.55c-.27.18-.61.21-.91.08l-64.42-37.22c-28.63-16.58-38.45-53.21-21.95-81.89zm221.26 51.49-77.79-44.92 26.93-15.54c.27-.18.61-.21.91-.08l64.42 37.19c28.68 16.57 38.51 53.26 21.94 81.94-7.01 12.14-18.05 21.44-31.2 26.28v-75.81c.03-3.74-1.96-7.2-5.2-9.06zm26.8-40.34c-.47-.29-1.3-.79-1.89-1.13l-63.72-36.8c-3.23-1.89-7.23-1.89-10.47 0l-77.79 44.92v-31.1c-.02-.32.13-.63.38-.83l64.41-37.16c28.69-16.55 65.37-6.7 81.91 22 6.99 12.12 9.52 26.31 7.15 40.1zm-168.51 55.43-26.94-15.55c-.29-.14-.48-.42-.52-.74v-74.39c.02-33.12 26.89-59.96 60.01-59.94 14.01 0 27.57 4.92 38.34 13.88-.49.26-1.33.73-1.89 1.07l-63.72 36.8c-3.26 1.85-5.26 5.31-5.24 9.06l-.04 89.79zm14.63-31.54 34.65-20.01 34.65 20v40.01l-34.65 20-34.65-20z"
        case .grok:
            // Current Grok comet mark (lobehub icons, MIT).
            return "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"
        case .omp:
            // Oh My Pi's geometric pi: full-width bar, short left leg,
            // long right stem. Traced from the official mark.
            return "M5.2 5.8L18.6 5.8L18.6 9.1L15.2 9.1L15.2 21.2L11.9 21.2L11.9 9.1L9.3 9.1L9.3 17.3L6.7 17.3L6.7 9.1L5.2 9.1Z"
        case .openrouter:
            // OpenRouter mark (lobehub icons, MIT).
            return "M18.654 3.87a5.087 5.087 0 110 10.174L23.7 19.09c.64.641.187 1.737-.72 1.737H8.48a8.479 8.479 0 010-16.958h10.175zM8.479 7.26a5.087 5.087 0 100 10.176 5.087 5.087 0 000-10.175z"
        case .ollama:
            // Ollama llama mark (lobehub icons, MIT).
            return "M7.905 1.09c.216.085.411.225.588.41.295.306.544.744.734 1.263.191.522.315 1.1.362 1.68a5.054 5.054 0 012.049-.636l.051-.004c.87-.07 1.73.087 2.48.474.101.053.2.11.297.17.05-.569.172-1.134.36-1.644.19-.52.439-.957.733-1.264a1.67 1.67 0 01.589-.41c.257-.1.53-.118.796-.042.401.114.745.368 1.016.737.248.337.434.769.561 1.287.23.934.27 2.163.115 3.645l.053.04.026.019c.757.576 1.284 1.397 1.563 2.35.435 1.487.216 3.155-.534 4.088l-.018.021.002.003c.417.762.67 1.567.724 2.4l.002.03c.064 1.065-.2 2.137-.814 3.19l-.007.01.01.024c.472 1.157.62 2.322.438 3.486l-.006.039a.651.651 0 01-.747.536.648.648 0 01-.54-.742c.167-1.033.01-2.069-.48-3.123a.643.643 0 01.04-.617l.004-.006c.604-.924.854-1.83.8-2.72-.046-.779-.325-1.544-.8-2.273a.644.644 0 01.18-.886l.009-.006c.243-.159.467-.565.58-1.12a4.229 4.229 0 00-.095-1.974c-.205-.7-.58-1.284-1.105-1.683-.595-.454-1.383-.673-2.38-.61a.653.653 0 01-.632-.371c-.314-.665-.772-1.141-1.343-1.436a3.288 3.288 0 00-1.772-.332c-1.245.099-2.343.801-2.67 1.686a.652.652 0 01-.61.425c-1.067.002-1.893.252-2.497.703-.522.39-.878.935-1.066 1.588a4.07 4.07 0 00-.068 1.886c.112.558.331 1.02.582 1.269l.008.007c.212.207.257.53.109.785-.36.622-.629 1.549-.673 2.44-.05 1.018.186 1.902.719 2.536l.016.019a.643.643 0 01.095.69c-.576 1.236-.753 2.252-.562 3.052a.652.652 0 01-1.269.298c-.243-1.018-.078-2.184.473-3.498l.014-.035-.008-.012a4.339 4.339 0 01-.598-1.309l-.005-.019a5.764 5.764 0 01-.177-1.785c.044-.91.278-1.842.622-2.59l.012-.026-.002-.002c-.293-.418-.51-.953-.63-1.545l-.005-.024a5.352 5.352 0 01.093-2.49c.262-.915.777-1.701 1.536-2.269.06-.045.123-.09.186-.132-.159-1.493-.119-2.73.112-3.67.127-.518.314-.95.562-1.287.27-.368.614-.622 1.015-.737.266-.076.54-.059.797.042zm4.116 9.09c.936 0 1.8.313 2.446.855.63.527 1.005 1.235 1.005 1.94 0 .888-.406 1.58-1.133 2.022-.62.375-1.451.557-2.403.557-1.009 0-1.871-.259-2.493-.734-.617-.47-.963-1.13-.963-1.845 0-.707.398-1.417 1.056-1.946.668-.537 1.55-.849 2.485-.849zm0 .896a3.07 3.07 0 00-1.916.65c-.461.37-.722.835-.722 1.25 0 .428.21.829.61 1.134.455.347 1.124.548 1.943.548.799 0 1.473-.147 1.932-.426.463-.28.7-.686.7-1.257 0-.423-.246-.89-.683-1.256-.484-.405-1.14-.643-1.864-.643zm.662 1.21l.004.004c.12.151.095.37-.056.49l-.292.23v.446a.375.375 0 01-.376.373.375.375 0 01-.376-.373v-.46l-.271-.218a.347.347 0 01-.052-.49.353.353 0 01.494-.051l.215.172.22-.174a.353.353 0 01.49.051zm-5.04-1.919c.478 0 .867.39.867.871a.87.87 0 01-.868.871.87.87 0 01-.867-.87.87.87 0 01.867-.872zm8.706 0c.48 0 .868.39.868.871a.87.87 0 01-.868.871.87.87 0 01-.867-.87.87.87 0 01.867-.872zM7.44 2.3l-.003.002a.659.659 0 00-.285.238l-.005.006c-.138.189-.258.467-.348.832-.17.692-.216 1.631-.124 2.782.43-.128.899-.208 1.404-.237l.01-.001.019-.034c.046-.082.095-.161.148-.239.123-.771.022-1.692-.253-2.444-.134-.364-.297-.65-.453-.813a.628.628 0 00-.107-.09L7.44 2.3zm9.174.04l-.002.001a.628.628 0 00-.107.09c-.156.163-.32.45-.453.814-.29.794-.387 1.776-.23 2.572l.058.097.008.014h.03a5.184 5.184 0 011.466.212c.086-1.124.038-2.043-.128-2.722-.09-.365-.21-.643-.349-.832l-.004-.006a.659.659 0 00-.285-.239h-.004z"
        case .cursor:
            return "M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"
        }
    }
}

// MARK: - SVG path parsing

/// Minimal SVG path-data parser covering M/L/H/V/C/S/Q/T/A/Z (absolute and
/// relative, with implicit command repetition). Enough for the embedded marks;
/// contributors adding a provider glyph get it for free.
enum SVGPath {
    private struct ParserState {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?

        mutating func resetControls() {
            lastControl = nil
            lastQuadControl = nil
        }
    }

    static func parse(_ data: String) -> Path {
        var scanner = Tokenizer(data)
        var command: Character = " "
        var state = ParserState()

        while let next = scanner.nextCommandOrNumberStart() {
            command = resolvedCommand(next, previous: command, scanner: &scanner)
            guard apply(command, scanner: &scanner, state: &state) else {
                return state.path
            }
        }
        return state.path
    }

    private static func resolvedCommand(
        _ next: Character,
        previous: Character,
        scanner: inout Tokenizer
    ) -> Character {
        if next.isLetter {
            scanner.advance()
            return next
        }
        if previous == "M" { return "L" } // implicit repeat after moveto
        if previous == "m" { return "l" }
        return previous
    }

    private static func apply(
        _ command: Character,
        scanner: inout Tokenizer,
        state: inout ParserState
    ) -> Bool {
        let normalized = Character(command.uppercased())
        let origin = command.isLowercase ? state.current : .zero
        switch normalized {
        case "M", "L", "H", "V", "Z":
            return applyStraightCommand(
                normalized, origin: origin, scanner: &scanner, state: &state)
        case "C", "S", "Q", "T":
            return applyCurveCommand(
                normalized, origin: origin, scanner: &scanner, state: &state)
        case "A":
            return applyArcCommand(origin: origin, scanner: &scanner, state: &state)
        default:
            return false
        }
    }

    private static func applyStraightCommand(
        _ command: Character,
        origin: CGPoint,
        scanner: inout Tokenizer,
        state: inout ParserState
    ) -> Bool {
        switch command {
        case "M":
            guard let point = scanner.point() else { return false }
            state.current = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
            state.subpathStart = state.current
            state.path.move(to: state.current)
        case "L":
            guard let point = scanner.point() else { return false }
            state.current = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
            state.path.addLine(to: state.current)
        case "H":
            guard let x = scanner.number() else { return false }
            state.current = CGPoint(x: origin.x + x, y: state.current.y)
            state.path.addLine(to: state.current)
        case "V":
            guard let y = scanner.number() else { return false }
            state.current = CGPoint(x: state.current.x, y: origin.y + y)
            state.path.addLine(to: state.current)
        case "Z":
            state.path.closeSubpath()
            state.current = state.subpathStart
        default:
            return false
        }
        state.resetControls()
        return true
    }

    private static func applyCurveCommand(
        _ command: Character,
        origin: CGPoint,
        scanner: inout Tokenizer,
        state: inout ParserState
    ) -> Bool {
        switch command {
        case "C":
            guard let control1 = scanner.point(),
                  let control2 = scanner.point(),
                  let end = scanner.point() else { return false }
            let point1 = CGPoint(x: origin.x + control1.x, y: origin.y + control1.y)
            let point2 = CGPoint(x: origin.x + control2.x, y: origin.y + control2.y)
            state.current = CGPoint(x: origin.x + end.x, y: origin.y + end.y)
            state.path.addCurve(to: state.current, control1: point1, control2: point2)
            state.lastControl = point2
            state.lastQuadControl = nil
        case "S":
            guard let control2 = scanner.point(), let end = scanner.point() else {
                return false
            }
            let point1 = state.lastControl.map {
                CGPoint(x: 2 * state.current.x - $0.x, y: 2 * state.current.y - $0.y)
            } ?? state.current
            let point2 = CGPoint(x: origin.x + control2.x, y: origin.y + control2.y)
            state.current = CGPoint(x: origin.x + end.x, y: origin.y + end.y)
            state.path.addCurve(to: state.current, control1: point1, control2: point2)
            state.lastControl = point2
            state.lastQuadControl = nil
        case "Q":
            guard let first = scanner.point(), let end = scanner.point() else { return false }
            let control = CGPoint(x: origin.x + first.x, y: origin.y + first.y)
            state.current = CGPoint(x: origin.x + end.x, y: origin.y + end.y)
            state.path.addQuadCurve(to: state.current, control: control)
            state.lastQuadControl = control
            state.lastControl = nil
        case "T":
            guard let end = scanner.point() else { return false }
            let control = state.lastQuadControl.map {
                CGPoint(x: 2 * state.current.x - $0.x, y: 2 * state.current.y - $0.y)
            } ?? state.current
            state.current = CGPoint(x: origin.x + end.x, y: origin.y + end.y)
            state.path.addQuadCurve(to: state.current, control: control)
            state.lastQuadControl = control
            state.lastControl = nil
        default:
            return false
        }
        return true
    }

    private static func applyArcCommand(
        origin: CGPoint,
        scanner: inout Tokenizer,
        state: inout ParserState
    ) -> Bool {
        guard let radiusX = scanner.number(), let radiusY = scanner.number(),
              let rotation = scanner.number(),
              let largeArc = scanner.flag(), let sweep = scanner.flag(),
              let end = scanner.point() else { return false }
        let target = CGPoint(x: origin.x + end.x, y: origin.y + end.y)
        addArc(
            to: &state.path,
            from: state.current,
            to: target,
            rx: radiusX,
            ry: radiusY,
            rotationDegrees: rotation,
            largeArc: largeArc,
            sweep: sweep
        )
        state.current = target
        state.resetControls()
        return true
    }

    private struct ArcGeometry {
        let center: CGPoint
        let radiusX: CGFloat
        let radiusY: CGFloat
        let cosRotation: CGFloat
        let sinRotation: CGFloat

        func point(cosine: CGFloat, sine: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + radiusX * cosRotation * cosine
                    - radiusY * sinRotation * sine,
                y: center.y + radiusX * sinRotation * cosine
                    + radiusY * cosRotation * sine
            )
        }

        func derivative(cosine: CGFloat, sine: CGFloat) -> CGPoint {
            CGPoint(
                x: -radiusX * cosRotation * sine - radiusY * sinRotation * cosine,
                y: -radiusX * sinRotation * sine + radiusY * cosRotation * cosine
            )
        }
    }

    private static func signedAngle(
        _ ux: CGFloat,
        _ uy: CGFloat,
        _ vx: CGFloat,
        _ vy: CGFloat
    ) -> CGFloat {
        let dot = ux * vx + uy * vy
        let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
        var result = acos(min(1, max(-1, dot / length)))
        if ux * vy - uy * vx < 0 { result = -result }
        return result
    }

    private static func appendArcSegments(
        to path: inout Path,
        geometry: ArcGeometry,
        startAngle: CGFloat,
        delta: CGFloat
    ) {
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let alpha = 4 / 3 * tan(step / 4)
        var theta = startAngle
        for _ in 0..<segments {
            let cosine1 = cos(theta)
            let sine1 = sin(theta)
            let theta2 = theta + step
            let cosine2 = cos(theta2)
            let sine2 = sin(theta2)
            let point1 = geometry.point(cosine: cosine1, sine: sine1)
            let point2 = geometry.point(cosine: cosine2, sine: sine2)
            let derivative1 = geometry.derivative(cosine: cosine1, sine: sine1)
            let derivative2 = geometry.derivative(cosine: cosine2, sine: sine2)
            let control1 = CGPoint(
                x: point1.x + alpha * derivative1.x,
                y: point1.y + alpha * derivative1.y
            )
            let control2 = CGPoint(
                x: point2.x - alpha * derivative2.x,
                y: point2.y - alpha * derivative2.y
            )
            path.addCurve(to: point2, control1: control1, control2: control2)
            theta = theta2
        }
    }

    /// Endpoint-parameterized elliptical arc → cubic Bézier segments
    /// (SVG implementation notes, F.6).
    private static func addArc(
        to path: inout Path, from start: CGPoint, to end: CGPoint,
        rx: CGFloat, ry: CGFloat, rotationDegrees: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        guard rx != 0, ry != 0, start != end else {
            path.addLine(to: end)
            return
        }
        var rx = abs(rx), ry = abs(ry)
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx2 = (start.x - end.x) / 2, dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Scale radii up if the endpoints cannot be joined at this size.
        let x1pSquared = x1p * x1p
        let y1pSquared = y1p * y1p
        var rxSquared = rx * rx
        var rySquared = ry * ry
        let lambda = x1pSquared / rxSquared + y1pSquared / rySquared
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale; ry *= scale
            rxSquared = rx * rx
            rySquared = ry * ry
        }

        let sign: CGFloat = largeArc != sweep ? 1 : -1
        let xTerm = rxSquared * y1pSquared
        let yTerm = rySquared * x1pSquared
        let num = rxSquared * rySquared - xTerm - yTerm
        let den = xTerm + yTerm
        let coefficient = sign * sqrt(max(0, num / den))
        let cxp = coefficient * (rx * y1p / ry)
        let cyp = coefficient * (-ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        let startUnitX = (x1p - cxp) / rx
        let startUnitY = (y1p - cyp) / ry
        let endUnitX = (-x1p - cxp) / rx
        let endUnitY = (-y1p - cyp) / ry
        let startAngle = signedAngle(1, 0, startUnitX, startUnitY)
        var delta = signedAngle(startUnitX, startUnitY, endUnitX, endUnitY)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        // Split into ≤90° cubic segments.
        appendArcSegments(
            to: &path,
            geometry: ArcGeometry(
                center: CGPoint(x: cx, y: cy),
                radiusX: rx,
                radiusY: ry,
                cosRotation: cosPhi,
                sinRotation: sinPhi
            ),
            startAngle: startAngle,
            delta: delta
        )
    }

    /// Character-level tokenizer. Arc flags need special handling (they may be
    /// glued to the following number, e.g. "0 0-.42"), hence `flag()`.
    private struct Tokenizer {
        private struct NumberLexeme {
            var text = ""
            private var seenDot = false
            private var seenExponent = false

            mutating func consume(_ character: Character) -> Bool {
                if character.isNumber {
                    text.append(character)
                    return true
                }
                if character == "." {
                    guard !seenDot else { return false } // "1.5.5" is two numbers
                    seenDot = true
                    text.append(character)
                    return true
                }
                if character == "-" || character == "+" {
                    guard text.isEmpty || text.last == "e" || text.last == "E" else {
                        return false
                    }
                    text.append(character)
                    return true
                }
                if character == "e" || character == "E" {
                    guard !seenExponent, !text.isEmpty else { return false }
                    seenExponent = true
                    seenDot = true // decimal point not allowed after exponent
                    text.append(character)
                    return true
                }
                return false
            }
        }

        private let chars: [Character]
        private var index = 0

        init(_ s: String) { chars = Array(s) }

        mutating func advance() { index += 1 }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" || chars[index] == "\t" || chars[index] == "\r" {
                index += 1
            }
        }

        mutating func nextCommandOrNumberStart() -> Character? {
            skipSeparators()
            guard index < chars.count else { return nil }
            return chars[index]
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var lexeme = NumberLexeme()
            while index < chars.count, lexeme.consume(chars[index]) {
                index += 1
            }
            return lexeme.text.isEmpty ? nil : Double(lexeme.text).map { CGFloat($0) }
        }

        /// Arc flag: exactly one '0' or '1' character.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return nil }
            defer { index += 1 }
            return chars[index] == "1"
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }
    }
}

/// `Shape` that renders a glyph's official path fitted into the given rect,
/// preserving aspect ratio. Parsed paths are cached per glyph.
struct GlyphShape: Shape {
    let glyph: ProviderGlyph

    private static let cache: [ProviderGlyph: Path] = Dictionary(
        uniqueKeysWithValues: ProviderGlyph.allCases.map { ($0, SVGPath.parse($0.pathData)) }
    )

    func path(in rect: CGRect) -> Path {
        let source = Self.cache[glyph] ?? Path()
        let box = glyph.viewBox
        guard box.width > 0, box.height > 0 else { return source }
        let scale = min(rect.width / box.width, rect.height / box.height)
        let offsetX = rect.minX + (rect.width - box.width * scale) / 2
        let offsetY = rect.minY + (rect.height - box.height * scale) / 2
        return source.applying(
            CGAffineTransform(translationX: -box.minX, y: -box.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
        )
    }
}

// MARK: - Rendering

/// Draws any `ProviderGlyph` at the given size, filled in a single grayscale
/// tint. Brand colors are deliberately not used.
struct GlyphView: View {
    let glyph: ProviderGlyph
    var size: CGFloat = 16
    var color: Color = .white

    var body: some View {
        GlyphShape(glyph: glyph)
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
