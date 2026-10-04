import ChilkCore
import ChilkRender
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// chilk-render icon <AppIcon.appiconset>   — writes the static AppIcon PNGs + Contents.json
// chilk-render previews <dir>              — renders key states as PNGs for visual review

let palette = Palette.peach
let metrics = Metrics.standard

/// A y-down bitmap context of `size` points at `scale` pixels per point.
func render(_ size: CGSize, scale: Double = 2, _ draw: (CGContext) -> Void) -> CGImage {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: scale, y: -scale)
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

@MainActor
func sim(_ setup: (CharacterSim) -> Void = { _ in }, seconds: Double, pointer: CGPoint? = nil) -> CharacterPose {
    let s = CharacterSim(metrics: metrics, rng: SeededRandom(seed: 42))
    setup(s)
    for _ in 0..<Int(seconds * 60) { s.step(dt: 1.0 / 60, pointer: pointer) }
    return s.pose
}

@MainActor
func icon(into dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var pose = sim(seconds: 0.5, pointer: CGPoint(x: 120, y: 200))
    pose.eyeOpen = 1; pose.scaleX = 1; pose.scaleY = 1
    var images: [[String: String]] = []
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
            // macOS icon grid: the tile is 824/1024 of the canvas, centred.
            let image = render(CGSize(width: px, height: px), scale: 1) { ctx in
                let inset = Double(px) * 100 / 1024
                ChilkRenderer.drawIcon(in: ctx, rect: CGRect(x: inset, y: inset, width: Double(px) - inset * 2, height: Double(px) - inset * 2),
                                       pose: pose, metrics: metrics, palette: palette)
            }
            writePNG(image, to: dir.appendingPathComponent(name))
            images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "chilk-render", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: dir.appendingPathComponent("Contents.json"))
    print("wrote \(images.count) icons to \(dir.path)")
}

@MainActor
func previews(into dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lookIn = CGPoint(x: 60, y: 200)
    let states: [(String, CharacterPose, Bool)] = [
        ("01-idle-right", sim(seconds: 2, pointer: lookIn), false),
        ("02-hover-peek", { let s = CharacterSim(metrics: metrics, rng: SeededRandom(seed: 42)); for _ in 0..<90 { s.step(dt: 1.0 / 60, pointer: s.bodyCenter) }; return s.pose }(), false),
        ("03-called-bubble", sim({ $0.call(line: "Звал? 👀") }, seconds: 1.3), false),
        ("04-annoyed", sim({ $0.poke() }, seconds: 0.12), false),
        ("05-dizzy", sim({ $0.poke(); $0.poke(); $0.poke() }, seconds: 0.4), false),
        ("06-tired", sim({ $0.fatigue = 1 }, seconds: 3, pointer: lookIn), false),
        ("07-asleep-left-edge", sim({ $0.fallAsleep() }, seconds: 4.2), true),
        ("08-greeting-left-edge", sim({ $0.say("Доброе утро! Как спалось? Начнём со стакана воды?") }, seconds: 1.6), true),
        ("09-carried", sim({ $0.isCarried = true }, seconds: 0.5, pointer: lookIn), false),
        ("10-stretch", { let s = CharacterSim(metrics: metrics, rng: SeededRandom(seed: 3)); var best = s.pose
            for _ in 0..<(60 * 120) { s.step(dt: 1.0 / 60, pointer: lookIn); if s.currentAntic == .stretch, s.pose.scaleY > best.scaleY { best = s.pose } }
            return best }(), false),
        ("11-stage1-buttons", sim({ $0.standOut = .peek; $0.say("Эй, ты давно не пил. Глоток воды?", buttons: ["Попил", "Через 10 мин", "Я занят"]); $0.hoveredButton = 0 }, seconds: 2), false),
        ("12-drink", sim({ $0.perform(.drink) }, seconds: 1.3), false),
        ("13-walk-out", sim({ $0.standOut = .out; $0.wear(.hat); $0.perform(.pack) }, seconds: 3), false),
        ("14-breathe-in", sim({ $0.standOut = .out; $0.perform(.breathe(seconds: 30)) }, seconds: 3.95), false),
        ("15-stage2-left", sim({ $0.standOut = .out; $0.fatigue = 0.8; $0.say("Я всё ещё тут. Разомнись, а? Спина скажет спасибо", buttons: ["Иду", "Я занят"]) }, seconds: 2.5), true),
        ("16-lookaway", sim({ $0.perform(.lookAway) }, seconds: 1.2), false),
        ("17-listening", sim({ $0.standOut = .out; $0.listening = true; $0.hearing = 0.5; $0.say("Напомни позвонить маме вечером", duration: .infinity) }, seconds: 2), false),
        ("18-thinking", sim({ $0.standOut = .out; $0.perform(.think(seconds: 30)); $0.say("···", duration: .infinity) }, seconds: 1.5), false),
    ]
    for (name, pose, mirrored) in states {
        let image = render(metrics.sceneSize) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.95, blue: 0.89, alpha: 1))   // stand-in wallpaper
            ctx.fill(CGRect(origin: .zero, size: metrics.sceneSize))
            ChilkRenderer.drawScene(in: ctx, pose: pose, metrics: metrics, palette: palette, mirrored: mirrored)
        }
        writePNG(image, to: dir.appendingPathComponent("\(name).png"))
    }
    let dock = render(CGSize(width: 200, height: 70)) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.21, blue: 0.25, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 70))
        let pose = sim(seconds: 1, pointer: lookIn)
        for (size, x) in [(56.0, 8.0), (32.0, 80.0), (18.0, 130.0)] {
            ChilkRenderer.drawIcon(in: ctx, rect: CGRect(x: x, y: (70 - size) / 2, width: size, height: size), pose: pose, metrics: metrics, palette: palette)
        }
    }
    writePNG(dock, to: dir.appendingPathComponent("99-dock-icons.png"))
    print("wrote \(states.count + 1) previews to \(dir.path)")
}

/// Per-frame CPU on this process (tight loop, so P-cores: in-app numbers are several × higher).
/// `vector` = full CoreGraphics frame (old app path); `rig` = what the app does now per frame:
/// simulation + placements + CALayer property updates (rasterising happens only on first use).
@MainActor
func bench() {
    let scale = 2.0
    let ctx = CGContext(data: nil, width: Int(metrics.width * scale), height: Int(metrics.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.translateBy(x: 0, y: metrics.height * scale)
    ctx.scaleBy(x: scale, y: -scale)
    let rig = LayerRig(metrics: metrics, palette: palette, rasterScale: 3)

    func measure(_ label: String, frames: Int, prepare: (CharacterSim) -> Void = { _ in }, each frame: (CharacterSim) -> Void) {
        let s = CharacterSim(metrics: metrics, rng: SeededRandom(seed: 7))
        prepare(s)
        for _ in 0..<60 { s.step(dt: 1.0 / 60, pointer: CGPoint(x: 80, y: 180)); frame(s) }   // warm caches
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<frames {
            s.step(dt: 1.0 / 60, pointer: CGPoint(x: 80, y: 180))
            frame(s)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(frames)
        print(String(format: "%@: %.3f ms/frame → %.2f%% of one core at 60 fps", label, ms, ms * 60 / 10))
    }
    let vector: (CharacterSim) -> Void = { s in
        ctx.clear(CGRect(origin: .zero, size: metrics.sceneSize))
        ChilkRenderer.drawScene(in: ctx, pose: s.pose, metrics: metrics, palette: palette)
    }
    let layers: (CharacterSim) -> Void = { s in
        rig.apply(ChilkRenderer.placements(pose: s.pose, metrics: metrics, mirrored: false))
    }
    measure("vector, idle      ", frames: 600, each: vector)
    measure("rig,    idle      ", frames: 3000, each: layers)
    measure("rig,    asleep    ", frames: 3000, prepare: { $0.fallAsleep() }, each: layers)
    measure("rig,    talking   ", frames: 3000, prepare: { $0.call(line: "Звал? 👀 Я тут, слушаю") }, each: layers)
    print("rig bitmaps rasterised: \(rig.rasterisedCount), layers: \(rig.layerCount)")
}

let args = CommandLine.arguments
if args.count == 2, args[1] == "bench" {
    bench()
    exit(0)
}
guard args.count >= 3 else {
    print("usage: chilk-render icon <AppIcon.appiconset> | previews <dir> | bench")
    exit(2)
}
let target = URL(fileURLWithPath: args[2])
switch args[1] {
case "icon": try icon(into: target)
case "previews": try previews(into: target)
default: print("unknown command \(args[1])"); exit(2)
}
