// Векторная иконка NaviDrive: SVG + PNG всех размеров AppIcon, каждый размер рисуется с нуля из вектора.
// Только системные фреймворки (AppKit, CoreGraphics, CoreText).
//
// Запуск из корня проекта:
//   swift Scripts/make_app_icon.swift Resources Resources/Assets.xcassets/AppIcon.appiconset <папка превью>
//
// Геометрия облака и раскладка цифр сняты с образца Resources/Design/NaviDrive_icon.jpeg (одноразовый численный подбор:
// облако — объединение 4 окружностей и прямоугольника с плоским низом, несовпадение силуэта 0,17%).
// Пространство иконки: 1024×1024, ось y направлена вниз (как в SVG).
import AppKit
import CoreText

let args = CommandLine.arguments
let resourcesDir = args[1], iconsetDir = args[2], previewDir = args[3]
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

let inkHex = "#1E1C1A"
let ink = CGColor(srgbRed: 0x1E / 255.0, green: 0x1C / 255.0, blue: 0x1A / 255.0, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

// MARK: - Геометрия

/// Форма иконки macOS: 824×824 по центру, поля 100, радиус 185, «непрерывные» углы (сглаживание 60%).
let shapeRect = CGRect(x: 100, y: 100, width: 824, height: 824)

struct Circle { let cx: CGFloat, cy: CGFloat, r: CGFloat }
/// Облако: доли L, TL, T, R + прямоугольник. Низ плоский (y = 448), боковые доли касаются его.
let cloudBottom: CGFloat = 448
let cloudCircles = [
    Circle(cx: 350.16, cy: 373.05, r: cloudBottom - 373.05),   // L  — левая нижняя доля
    Circle(cx: 417.28, cy: 299.70, r: 75.00),                  // TL — левая верхняя доля
    Circle(cx: 556.12, cy: 291.08, r: 125.00),                 // T  — большая верхняя доля
    Circle(cx: 664.47, cy: 362.80, r: cloudBottom - 362.80),   // R  — правая доля
]
let cloudRect = CGRect(x: 350.16, y: 316.20, width: 664.47 - 350.16, height: cloudBottom - 316.20)

/// Цифры: символ и рамка (x0, y0, x1, y1) в пространстве иконки — раскладка образца.
let digitLayout: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    ("0", 402.4, 468.6, 438.5, 514.8), ("0", 643.1, 468.6, 685.3, 522.8), ("1", 333.7, 469.1, 363.3, 534.3),
    ("1", 490.7, 469.1, 521.3, 534.3), ("1", 580.5, 469.1, 598.0, 506.2), ("0", 545.9, 519.3, 582.0, 565.9),
    ("1", 611.6, 524.3, 631.1, 565.9), ("1", 445.0, 526.8, 467.1, 575.4), ("0", 374.3, 548.4, 410.4, 595.0),
    ("0", 653.7, 548.4, 684.3, 588.0), ("0", 481.7, 568.9, 533.8, 635.6), ("0", 593.0, 586.5, 636.1, 641.6),
    ("1", 341.7, 596.5, 361.3, 639.1), ("0", 424.5, 602.0, 458.1, 645.2), ("1", 653.2, 632.1, 669.2, 666.2),
    ("0", 538.3, 636.1, 566.9, 672.7), ("1", 388.9, 644.2, 406.9, 682.3), ("0", 587.0, 668.2, 614.6, 703.3),
    ("1", 498.2, 677.8, 520.8, 726.4),
]

// MARK: - Контуры

func squirclePath(in rect: CGRect, radius r: CGFloat, smoothing: CGFloat = 0.6) -> CGPath {
    let p = (1 + smoothing) * r
    let arcMeasure = (CGFloat.pi / 2) * (1 - smoothing)
    let arcSection = sin(arcMeasure / 2) * r * sqrt(2)
    let alpha = (CGFloat.pi / 2 - arcMeasure) / 2
    let p3p4 = r * tan(alpha / 2)
    let beta = (CGFloat.pi / 4) * smoothing
    let c = p3p4 * cos(beta), d = c * tan(beta)
    let b = (p - arcSection - c - d) / 3, a = 2 * b
    let w = rect.width, center = CGPoint(x: rect.midX, y: rect.midY)
    // Угол строится как правый верхний (y вниз) и поворачивается на 90° для остальных углов.
    func map(_ x: CGFloat, _ y: CGFloat, _ k: Int) -> CGPoint {
        let lx = x - w / 2, ly = y - w / 2, t = CGFloat(k) * .pi / 2
        return CGPoint(x: center.x + lx * cos(t) - ly * sin(t), y: center.y + lx * sin(t) + ly * cos(t))
    }
    let path = CGMutablePath()
    for k in 0..<4 {
        let s = (w - p, CGFloat(0))
        if k == 0 { path.move(to: map(s.0, s.1, k)) } else { path.addLine(to: map(s.0, s.1, k)) }
        let e1 = (s.0 + a + b + c, d)
        path.addCurve(to: map(e1.0, e1.1, k), control1: map(s.0 + a, 0, k), control2: map(s.0 + a + b, 0, k))
        // Дуга окружности (центр (w - r, r)) — двумя кубическими Безье.
        let cx = w - r, cy = r
        let a0 = atan2(e1.1 - cy, e1.0 - cx), e2 = (e1.0 + arcSection, e1.1 + arcSection), a1 = atan2(e2.1 - cy, e2.0 - cx)
        for i in 0..<2 {
            let t0 = a0 + (a1 - a0) * CGFloat(i) / 2, t1 = a0 + (a1 - a0) * CGFloat(i + 1) / 2
            let kk = 4 / 3 * tan((t1 - t0) / 4) * r
            let p0 = (cx + r * cos(t0), cy + r * sin(t0)), p3 = (cx + r * cos(t1), cy + r * sin(t1))
            path.addCurve(to: map(p3.0, p3.1, k),
                          control1: map(p0.0 - kk * sin(t0), p0.1 + kk * cos(t0), k),
                          control2: map(p3.0 + kk * sin(t1), p3.1 - kk * cos(t1), k))
        }
        let e3 = (e2.0 + d, e2.1 + a + b + c)
        path.addCurve(to: map(e3.0, e3.1, k), control1: map(e2.0 + d, e2.1 + c, k), control2: map(e2.0 + d, e2.1 + b + c, k))
        path.addLine(to: map(w, w - p, k))
    }
    path.closeSubpath()
    return path
}

/// Окружность четырьмя кубическими Безье, по часовой стрелке (y вниз) — как и прямоугольник,
/// чтобы при правиле nonzero подконтуры облака объединялись, а не вычитались.
func addCircle(_ c: Circle, to path: CGMutablePath, transform t: CGAffineTransform = .identity) {
    let k = 0.5522847498 * c.r
    let pts: [(CGFloat, CGFloat)] = [(c.cx + c.r, c.cy), (c.cx, c.cy + c.r), (c.cx - c.r, c.cy), (c.cx, c.cy - c.r)]
    let tan: [(CGFloat, CGFloat)] = [(0, 1), (-1, 0), (0, -1), (1, 0)]   // направление обхода в каждой точке
    path.move(to: CGPoint(x: pts[0].0, y: pts[0].1), transform: t)
    for i in 0..<4 {
        let p0 = pts[i], p1 = pts[(i + 1) % 4], d0 = tan[i], d1 = tan[(i + 1) % 4]
        path.addCurve(to: CGPoint(x: p1.0, y: p1.1),
                      control1: CGPoint(x: p0.0 + d0.0 * k, y: p0.1 + d0.1 * k),
                      control2: CGPoint(x: p1.0 - d1.0 * k, y: p1.1 - d1.1 * k), transform: t)
    }
    path.closeSubpath()
}

func cloudPath(transform t: CGAffineTransform = .identity) -> CGPath {
    let path = CGMutablePath()
    for c in cloudCircles { addCircle(c, to: path, transform: t) }
    let r = cloudRect
    path.move(to: CGPoint(x: r.minX, y: r.minY), transform: t)
    path.addLine(to: CGPoint(x: r.maxX, y: r.minY), transform: t)
    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY), transform: t)
    path.addLine(to: CGPoint(x: r.minX, y: r.maxY), transform: t)
    path.closeSubpath()
    return path
}

/// Рамка облака в пространстве иконки.
let cloudBounds: CGRect = {
    let xs = cloudCircles.flatMap { [$0.cx - $0.r, $0.cx + $0.r] } + [cloudRect.minX, cloudRect.maxX]
    let ys = cloudCircles.map { $0.cy - $0.r } + [cloudRect.minY]
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: cloudBottom - ys.min()!)
}()

/// Шрифт цифр: SF Pro Rounded Semibold (системный полужирный, если скруглённого нет).
let digitFont: CTFont = {
    let base = NSFont.systemFont(ofSize: 100, weight: .semibold)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return (NSFont(descriptor: descriptor, size: 100) ?? base) as CTFont
}()
print("шрифт цифр: \(CTFontCopyFullName(digitFont) as String)")

/// Контур символа (y вверх, базовая линия 0) — цифры переводятся в кривые, SVG не зависит от шрифтов.
func glyphOutline(_ ch: String) -> CGPath {
    var unichar = UniChar(ch.utf16.first!), glyph = CGGlyph()
    CTFontGetGlyphsForCharacters(digitFont, &unichar, &glyph, 1)
    return CTFontCreatePathForGlyph(digitFont, glyph, nil)!
}
let outlines = ["0": glyphOutline("0"), "1": glyphOutline("1")]

/// Цифра, вписанная по высоте в рамку и отцентрованная по горизонтали (равномерный масштаб).
/// `snapWidth` — для мелких размеров: ширина подгоняется точно под рамку (выравнивание по пикселям).
func addDigit(_ ch: String, in box: CGRect, to path: CGMutablePath, fitWidth: Bool = false) {
    let outline = outlines[ch]!, bb = outline.boundingBoxOfPath
    let sy = box.height / bb.height
    let sx = fitWidth ? box.width / bb.width : sy
    // y вниз: низ рамки — низ глифа, переворот по вертикали.
    var t = CGAffineTransform(translationX: box.midX, y: box.maxY)
        .scaledBy(x: sx, y: -sy)
        .translatedBy(x: -bb.midX, y: -bb.minY)
    if let transformed = outline.copy(using: &t) { path.addPath(transformed) }
}

func fullDigitsPath() -> CGPath {
    let path = CGMutablePath()
    for (ch, x0, y0, x1, y1) in digitLayout { addDigit(ch, in: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), to: path) }
    return path
}

// MARK: - Упрощённый вариант для 16 и 32 px (выравнивание по пиксельной сетке)

struct Design { let shape: CGPath; let cloud: CGPath; let digits: CGPath }

let fullDesign = Design(shape: squirclePath(in: shapeRect, radius: 185), cloud: cloudPath(), digits: fullDigitsPath())

/// Раскладка в пикселях целевого размера: все прямые края облака и цифр попадают на границы пикселей.
func smallDesign(pixels n: Int) -> Design {
    let u = 1024 / CGFloat(n)                       // единиц иконки в одном пикселе
    func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: CGFloat(x) * u, y: CGFloat(y) * u, width: CGFloat(w) * u, height: CGFloat(h) * u)
    }
    // n = 32: облако 20×12 px, цифры «1 0 1» высотой 8 px; n = 16: облако 10×6 px, цифры высотой 4 px.
    let (cloudBox, digitH, digitTop, digitW, gap): (CGRect, Int, Int, (one: Int, zero: Int), Int) = n >= 32
        ? (rect(6, 5, 20, 12), 8, 19, (3, 5), 2)
        : (rect(3, 3, 10, 6), 4, 10, (2, 3), 1)
    // Облако масштабируется в целую пиксельную рамку (плоский низ — ровно по границе пикселя).
    let t = CGAffineTransform(translationX: cloudBox.minX, y: cloudBox.minY)
        .scaledBy(x: cloudBox.width / cloudBounds.width, y: cloudBox.height / cloudBounds.height)
        .translatedBy(x: -cloudBounds.minX, y: -cloudBounds.minY)
    let cloud = cloudPath(transform: t)
    // Три крупные цифры «1 0 1» по центру, каждая — в целой пиксельной рамке.
    let widths = [digitW.one, digitW.zero, digitW.one]
    let total = widths.reduce(0, +) + gap * 2
    var x = (n - total) / 2
    let digits = CGMutablePath()
    for (ch, w) in zip(["1", "0", "1"], widths) {
        addDigit(ch, in: rect(x, digitTop, w, digitH), to: digits, fitWidth: true)
        x += w + gap
    }
    return Design(shape: squirclePath(in: shapeRect, radius: 185), cloud: cloud, digits: digits)
}

// MARK: - Отрисовка (каждый размер — с нуля из вектора)

func render(_ design: Design, pixels n: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.clear(CGRect(x: 0, y: 0, width: n, height: n))
    ctx.translateBy(x: 0, y: CGFloat(n))
    ctx.scaleBy(x: CGFloat(n) / 1024, y: -CGFloat(n) / 1024)   // пространство иконки (y вниз) → пиксели
    ctx.addPath(design.shape); ctx.setFillColor(white); ctx.fillPath(using: .winding)
    ctx.addPath(design.cloud); ctx.setFillColor(ink); ctx.fillPath(using: .winding)
    ctx.addPath(design.digits); ctx.fillPath(using: .winding)
    return ctx.makeImage()!
}

func savePNG(_ image: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("не удалось сохранить \(path)") }
}

// MARK: - SVG

func svgPathData(_ path: CGPath) -> String {
    var d: [String] = []
    func f(_ v: CGFloat) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
    path.applyWithBlock { el in
        let p = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d.append("M\(f(p[0].x)) \(f(p[0].y))")
        case .addLineToPoint: d.append("L\(f(p[0].x)) \(f(p[0].y))")
        case .addQuadCurveToPoint: d.append("Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))")
        case .addCurveToPoint: d.append("C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))")
        case .closeSubpath: d.append("Z")
        @unknown default: break
        }
    }
    return d.joined()
}

func svg(_ design: Design) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- NaviDrive app icon. Холст 1024×1024, форма macOS 824×824 (поля 100, радиус 185). Цифры — в контурах. -->
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <path fill="#FFFFFF" d="\(svgPathData(design.shape))"/>
      <path fill="\(inkHex)" d="\(svgPathData(design.cloud))"/>
      <path fill="\(inkHex)" d="\(svgPathData(design.digits))"/>
    </svg>

    """
}

// MARK: - Вывод

try! svg(fullDesign).write(toFile: "\(resourcesDir)/AppIcon.svg", atomically: true, encoding: .utf8)
print("сохранено: \(resourcesDir)/AppIcon.svg")

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (file, n) in entries {
    let design = n <= 32 ? smallDesign(pixels: n) : fullDesign
    savePNG(render(design, pixels: n), "\(iconsetDir)/\(file)")
    print("  \(file): \(n) px — \(n <= 32 ? "упрощённый вариант, по пиксельной сетке" : "полный вариант") (вектор)")
}

savePNG(render(fullDesign, pixels: 1024), "\(previewDir)/preview-1024.png")
savePNG(render(smallDesign(pixels: 32), pixels: 32), "\(previewDir)/preview-32.png")
savePNG(render(smallDesign(pixels: 16), pixels: 16), "\(previewDir)/preview-16.png")
print("превью: \(previewDir)/preview-1024.png, \(previewDir)/preview-32.png, \(previewDir)/preview-16.png")
