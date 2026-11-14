import CoreGraphics
import Foundation

/// The cursor pictures, drawn by the app itself (original art, no system or third-party images) into one
/// big texture of square cells. Each cell is a 32 × 32 point box, drawn at `Settings.cursorArtCellPixels`
/// per side so it stays sharp when the cursor is large or zoomed.
///
/// Each cell stores three masks rather than colours, so the shader can colour the cursor in any style:
/// red = the dark parts, green = the whole cursor (dark parts + light parts), blue = its soft shadow.
public enum CursorArt {
    /// Points per side of one cell (1 point = one screen point at cursor size 1).
    public static let cellPoints = 32.0
    static let columns = 4, rows = 3

    /// One picture in the texture.
    public enum Cell: Int, CaseIterable, Sendable {
        case arrow, iBeam, iBeamVertical, pointingHand, openHand, closedHand
        case crosshair, resizeLeftRight, resizeUpDown, notAllowed, dragCopy

        /// The point that is "where the cursor is" (the arrow's tip, the I-beam's middle…), in cell points.
        public var hotspot: CGPoint {
            switch self {
            case .arrow, .notAllowed, .dragCopy: return CGPoint(x: 9, y: 5)
            case .pointingHand: return CGPoint(x: 12.5, y: 3.5)
            default: return CGPoint(x: 16, y: 16)
            }
        }
    }

    /// Which picture draws each logged cursor shape (unknown shapes get the arrow).
    public static func cell(for shape: CursorShape) -> Cell {
        switch shape {
        case .arrow, .contextualMenu, .dragLink, .disappearingItem, .other: return .arrow
        case .iBeam: return .iBeam
        case .iBeamVertical: return .iBeamVertical
        case .pointingHand: return .pointingHand
        case .openHand: return .openHand
        case .closedHand: return .closedHand
        case .crosshair: return .crosshair
        case .resizeLeftRight, .resizeLeft, .resizeRight: return .resizeLeftRight
        case .resizeUpDown, .resizeUp, .resizeDown: return .resizeUpDown
        case .operationNotAllowed: return .notAllowed
        case .dragCopy: return .dragCopy
        }
    }

    /// Where a cell sits in the texture: x, y, width, height as fractions of the texture.
    public static func rect(of cell: Cell) -> CGRect {
        let w = 1 / Double(columns), h = 1 / Double(rows)
        return CGRect(x: Double(cell.rawValue % columns) * w, y: Double(cell.rawValue / columns) * h, width: w, height: h)
    }

    /// The whole texture as RGBA bytes (rows top to bottom).
    public static func atlas(cellPixels: Int = Settings.cursorArtCellPixels) -> (bytes: [UInt8], width: Int, height: Int) {
        let width = cellPixels * columns, height = cellPixels * rows
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for cell in Cell.allCases {
            let (dark, body, shadow) = masks(cell, size: cellPixels)
            let ox = (cell.rawValue % columns) * cellPixels, oy = (cell.rawValue / columns) * cellPixels
            for y in 0..<cellPixels {
                for x in 0..<cellPixels {
                    let i = y * cellPixels + x
                    let o = ((oy + y) * width + ox + x) * 4
                    bytes[o] = dark[i]; bytes[o + 1] = body[i]
                    bytes[o + 2] = UInt8(min(255, max(0, shadow[i] * 255)).rounded()); bytes[o + 3] = 255
                }
            }
        }
        return (bytes, width, height)
    }

    // MARK: Drawing

    /// Two gray bitmaps being drawn into (y goes down, in cell points).
    private final class Canvas {
        let dark: CGContext, body: CGContext
        let size: Int
        init(size: Int) {
            self.size = size
            func make() -> CGContext {
                let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                c.translateBy(x: 0, y: CGFloat(size))
                c.scaleBy(x: CGFloat(size) / cellPoints, y: -CGFloat(size) / cellPoints)
                c.setLineJoin(.round); c.setLineCap(.round)
                c.setShouldAntialias(true)
                return c
            }
            dark = make(); body = make()
        }

        private func fill(_ c: CGContext, _ paths: [CGPath], white: Bool, stroke: Double = 0) {
            c.setFillColor(gray: white ? 1 : 0, alpha: 1); c.setStrokeColor(gray: white ? 1 : 0, alpha: 1)
            for p in paths {
                c.addPath(p); c.fillPath()
                if stroke > 0 { c.addPath(p); c.setLineWidth(stroke); c.strokePath() }
            }
        }

        /// A dark shape with a light edge `halo` points wide (arrow, I-beam, crosshair, resize arrows).
        func darkShape(_ paths: [CGPath], halo: Double) {
            fill(body, paths, white: true, stroke: halo * 2)
            fill(dark, paths, white: true)
        }

        /// A light shape with a dark outline and a thin light edge outside it (hands, badges).
        /// `lines` are dark strokes inside it (the gaps between fingers).
        func lightShape(_ paths: [CGPath], outline: Double, halo: Double, lines: [CGPath] = [], lineWidth: Double = 0.9) {
            fill(body, paths, white: true, stroke: (outline + halo) * 2)
            fill(dark, paths, white: false, stroke: (outline + halo) * 2)   // clear what was under it
            fill(dark, paths, white: true, stroke: outline * 2)
            fill(dark, paths, white: false)
            dark.setStrokeColor(gray: 1, alpha: 1); dark.setLineWidth(lineWidth)
            for l in lines { dark.addPath(l); dark.strokePath() }
        }

        /// Dark strokes (badge symbols).
        func darkLines(_ paths: [CGPath], width: Double) {
            dark.setStrokeColor(gray: 1, alpha: 1); dark.setLineWidth(width)
            for p in paths { dark.addPath(p); dark.strokePath() }
        }

        func bytes(_ c: CGContext) -> [UInt8] {
            let p = c.data!.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: p, count: size * size))
        }
    }

    private static func masks(_ cell: Cell, size: Int) -> ([UInt8], [UInt8], [Double]) {
        let cv = Canvas(size: size)
        draw(cell, on: cv)
        let dark = cv.bytes(cv.dark), body = cv.bytes(cv.body)
        // Shadow: the whole cursor, blurred and moved a little down.
        let k = Double(size) / cellPoints
        let shadow = blur(body.map { Double($0) / 255 }, size: size, radius: Int(1.4 * k), shiftDown: Int(1.1 * k))
        return (dark, body, shadow)
    }

    // Shapes, in cell points (y down).
    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, r: Double) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
    }
    private static func polygon(_ pts: [(Double, Double)], dx: Double = 0, dy: Double = 0) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: pts.map { CGPoint(x: $0.0 + dx, y: $0.1 + dy) }); p.closeSubpath()
        return p
    }
    private static func line(_ a: (Double, Double), _ b: (Double, Double)) -> CGPath {
        let p = CGMutablePath(); p.move(to: CGPoint(x: a.0, y: a.1)); p.addLine(to: CGPoint(x: b.0, y: b.1)); return p
    }
    /// A rounded bar from a to b, `w` wide.
    private static func capsule(_ a: (Double, Double), _ b: (Double, Double), w: Double) -> CGPath {
        let dx = b.0 - a.0, dy = b.1 - a.1, len = (dx * dx + dy * dy).squareRoot()
        var t = CGAffineTransform(translationX: a.0, y: a.1).rotated(by: atan2(dy, dx))
        return CGPath(roundedRect: CGRect(x: 0, y: -w / 2, width: len, height: w), cornerWidth: w / 2, cornerHeight: w / 2, transform: &t)
    }
    private static func rotated(_ paths: [CGPath]) -> [CGPath] {
        var t = CGAffineTransform(translationX: 16, y: 16).rotated(by: .pi / 2).translatedBy(x: -16, y: -16)
        return paths.map { $0.copy(using: &t)! }
    }
    private static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
    }

    private static let arrowPath = polygon([(0, 0), (0, 16.6), (3.9, 12.9), (6.4, 18.7), (8.8, 17.7), (6.4, 12.1), (11.7, 12.1)], dx: 9, dy: 5)
    private static let iBeamPaths = [rect(15.25, 9.5, 1.5, 13, r: 0.3), rect(12.6, 8.4, 6.8, 1.5, r: 0.75), rect(12.6, 22.1, 6.8, 1.5, r: 0.75)]
    private static let resizePaths = [rect(11, 15.1, 10, 1.8, r: 0.2),
                                      polygon([(6.2, 16), (11.6, 11.2), (11.6, 20.8)]),
                                      polygon([(25.8, 16), (20.4, 11.2), (20.4, 20.8)])]

    private static func draw(_ cell: Cell, on cv: Canvas) {
        switch cell {
        case .arrow:
            cv.darkShape([arrowPath], halo: 1.3)
        case .iBeam:
            cv.darkShape(iBeamPaths, halo: 1.2)
        case .iBeamVertical:
            cv.darkShape(rotated(iBeamPaths), halo: 1.2)
        case .crosshair:
            cv.darkShape([rect(6.5, 15.35, 7.8, 1.3, r: 0.3), rect(17.7, 15.35, 7.8, 1.3, r: 0.3),
                          rect(15.35, 6.5, 1.3, 7.8, r: 0.3), rect(15.35, 17.7, 1.3, 7.8, r: 0.3)], halo: 1.1)
        case .resizeLeftRight:
            cv.darkShape(resizePaths, halo: 1.3)
        case .resizeUpDown:
            cv.darkShape(rotated(resizePaths), halo: 1.3)
        case .pointingHand:
            cv.lightShape([rect(10.6, 2.8, 3.9, 14, r: 1.95),          // pointing finger
                           rect(14.4, 10.4, 3.9, 8, r: 1.95),          // folded fingers
                           rect(18.2, 11.4, 3.8, 8, r: 1.9),
                           rect(21.9, 12.9, 3.4, 7.5, r: 1.7),
                           rect(10.6, 14, 14.7, 13.5, r: 4.6),         // palm
                           capsule((6.6, 16.6), (12, 22.6), w: 4.2)],  // thumb
                          outline: 1.1, halo: 0.8,
                          lines: [line((14.45, 13.6), (14.45, 17.6)), line((18.25, 15), (18.25, 18.6)), line((21.95, 16.2), (21.95, 19.6))])
        case .openHand:
            cv.lightShape([rect(9.6, 5.6, 3.6, 13, r: 1.8), rect(13.2, 4.0, 3.6, 14.5, r: 1.8),
                           rect(16.8, 5.0, 3.6, 13.5, r: 1.8), rect(20.4, 7.6, 3.2, 11.5, r: 1.6),
                           rect(9.6, 14, 14, 13, r: 4.5),
                           capsule((5.6, 13.2), (11.2, 21), w: 4)],
                          outline: 1.1, halo: 0.8,
                          lines: [line((13.2, 12.6), (13.2, 17)), line((16.8, 12.6), (16.8, 17)), line((20.4, 13.4), (20.4, 17.4))])
        case .closedHand:
            cv.lightShape([rect(9.6, 11, 3.6, 7, r: 1.8), rect(13.2, 10.4, 3.6, 7.5, r: 1.8),
                           rect(16.8, 10.6, 3.6, 7.3, r: 1.8), rect(20.4, 11.6, 3.2, 6.6, r: 1.6),
                           rect(9.6, 13.5, 14, 12.5, r: 4.5),
                           capsule((7.2, 15.6), (11.8, 19.2), w: 3.8)],
                          outline: 1.1, halo: 0.8,
                          lines: [line((13.2, 11.8), (13.2, 15.6)), line((16.8, 11.8), (16.8, 15.6)), line((20.4, 12.6), (20.4, 15.8))])
        case .notAllowed:
            cv.darkShape([arrowPath], halo: 1.3)
            cv.lightShape([circle(22.5, 21.5, 5.2)], outline: 1, halo: 0.7)
            cv.darkLines([circle(22.5, 21.5, 2.9), line((20.45, 23.55), (24.55, 19.45))], width: 1.3)
        case .dragCopy:
            cv.darkShape([arrowPath], halo: 1.3)
            cv.lightShape([circle(22.5, 21.5, 5.2)], outline: 1, halo: 0.7)
            cv.darkLines([line((22.5, 18.9), (22.5, 24.1)), line((19.9, 21.5), (25.1, 21.5))], width: 1.4)
        }
    }

    /// Soft blur (three box blurs) with the result moved down by `shiftDown` pixels.
    private static func blur(_ v: [Double], size: Int, radius: Int, shiftDown: Int) -> [Double] {
        var a = v, tmp = v
        let r = max(1, radius / 2)
        func pass(_ src: [Double], _ dst: inout [Double], horizontal: Bool) {
            var line = [Double](repeating: 0, count: size + 1)
            for j in 0..<size {
                for i in 0..<size { line[i + 1] = line[i] + (horizontal ? src[j * size + i] : src[i * size + j]) }
                for i in 0..<size {
                    let s = line[min(i + r, size - 1) + 1] - line[max(i - r, 0)]
                    let value = s / Double(2 * r + 1)
                    if horizontal { dst[j * size + i] = value } else { dst[i * size + j] = value }
                }
            }
        }
        for _ in 0..<3 { pass(a, &tmp, horizontal: true); pass(tmp, &a, horizontal: false) }
        var out = [Double](repeating: 0, count: size * size)
        for y in shiftDown..<size { for x in 0..<size { out[y * size + x] = a[(y - shiftDown) * size + x] } }
        return out
    }
}
