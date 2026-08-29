import AppKit
// Builds menubar@2x.png: the flipped Superwhisper glyph as a black-on-clear template.
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: "flipped-256.png")))!
let w = src.pixelsWide, h = src.pixelsHigh
let sp = src.samplesPerPixel, sbpr = src.bytesPerRow
let sdata = src.bitmapData!
func lum(_ x: Int, _ y: Int) -> Double {
    let p = sdata + y * sbpr + x * sp
    let a = Double(p[3]) / 255
    return Double(p[0]) / 255 * a
}
let m = Int(Double(w) * 0.18)          // drop the outer shadow margin
let cw = w - 2*m, ch = h - 2*m
let N = 36
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: N, pixelsHigh: N, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bitmapFormat: [], bytesPerRow: N*4, bitsPerPixel: 32)!
let od = out.bitmapData!
var maxA = 0
for y in 0..<N { for x in 0..<N {
    var acc = 0.0
    for sy in 0..<4 { for sx in 0..<4 {
        acc += lum(m + (x*4+sx) * cw / (N*4), m + (y*4+sy) * ch / (N*4))
    }}
    let l = acc / 16
    let a = Int(255 * min(1, max(0, (l - 0.22) / 0.5)))
    maxA = max(maxA, a)
    let p = od + y * N*4 + x * 4
    p[0] = 0; p[1] = 0; p[2] = 0; p[3] = UInt8(a)
}}
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "menubar@2x.png"))
print("wrote menubar@2x.png, max alpha", maxA)
