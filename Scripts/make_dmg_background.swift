// Рисует фон окна установочного DMG (600×400 pt): светлый нейтральный градиент,
// стрелка от иконки приложения к папке Applications и подпись на русском и английском.
// Запуск: swift scripts/make_dmg_background.swift <папка>
// Результат: <папка>/dmg-background.png (600×400) и <папка>/dmg-background@2x.png (1200×800).
import AppKit

let canvas = CGSize(width: 600, height: 400)
// Центры иконок в окне Finder (отсчёт сверху) — те же значения в make_dmg.sh.
let appIconCenter = CGPoint(x: 150, y: 190)
let applicationsIconCenter = CGPoint(x: 450, y: 190)

func draw(in context: CGContext) {
    // Фон: едва заметный вертикальный градиент.
    let colors = [CGColor(gray: 0.975, alpha: 1), CGColor(gray: 0.925, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: .zero, options: [])

    // Стрелка между иконками (координаты CoreGraphics — снизу вверх).
    let y = canvas.height - appIconCenter.y
    let start = appIconCenter.x + 88, end = applicationsIconCenter.x - 88
    context.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
    context.setLineWidth(5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: start, y: y))
    context.addLine(to: CGPoint(x: end, y: y))
    context.strokePath()
    context.move(to: CGPoint(x: end - 18, y: y + 18))
    context.addLine(to: CGPoint(x: end, y: y))
    context.addLine(to: CGPoint(x: end - 18, y: y - 18))
    context.strokePath()

    // Подпись внизу окна, по центру.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let lines: [(String, NSFont, NSColor, CGFloat)] = [
        ("Перетащите NaviDrive в папку Applications", .systemFont(ofSize: 15, weight: .medium),
         NSColor(white: 0.23, alpha: 1), 66),
        ("Drag NaviDrive to Applications", .systemFont(ofSize: 13, weight: .regular),
         NSColor(white: 0.45, alpha: 1), 44),
    ]
    for (text, font, color, baseline) in lines {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        NSAttributedString(string: text, attributes: attributes)
            .draw(in: CGRect(x: 0, y: baseline - 4, width: canvas.width, height: font.pointSize + 8))
    }
    NSGraphicsContext.restoreGraphicsState()
}

func render(scale: CGFloat, to url: URL) throws {
    let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.scaleBy(x: scale, y: scale)
    draw(in: context)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    rep.size = canvas // 72 DPI для 1x, 144 DPI для @2x
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
do {
    try render(scale: 1, to: outputDir.appendingPathComponent("dmg-background.png"))
    try render(scale: 2, to: outputDir.appendingPathComponent("dmg-background@2x.png"))
} catch {
    FileHandle.standardError.write(Data("Не удалось нарисовать фон DMG: \(error)\n".utf8))
    exit(1)
}
