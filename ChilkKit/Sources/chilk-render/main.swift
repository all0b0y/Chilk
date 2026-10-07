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
/// Slice 6e: `at` seconds into a 1.6 s leap into the screen.
func leapPose(at: Double) -> CharacterPose {
    let s = CharacterSim(metrics: metrics, rng: SeededRandom(seed: 42))
    s.standOut = .out                                      // in flight the window has left the edge: all of him shows
    for _ in 0..<90 { s.step(dt: 1.0 / 60, pointer: nil) }
    s.perform(.leap(seconds: 1.6, dir: -1))
    for _ in 0..<Int(at * 60) { s.step(dt: 1.0 / 60, pointer: nil) }
    return s.pose
}

@MainActor
func sim(_ setup: (CharacterSim) -> Void = { _ in }, seconds: Double, pointer: CGPoint? = nil) -> CharacterPose {
    let s = CharacterSim(metrics: metrics, rng: SeededRandom(seed: 42))
    setup(s)
    for _ in 0..<Int(seconds * 60) { s.step(dt: 1.0 / 60, pointer: pointer) }
    return s.pose
}

/// Petting (slice 6c): the cursor strokes across him; `wink` — then rests until the wink.
@MainActor
func petted(wink: Bool) -> CharacterPose {
    let s = CharacterSim(metrics: metrics, rng: SeededRandom(seed: 42))
    for _ in 0..<60 { s.step(dt: 1.0 / 60, pointer: nil) }
    for _ in 0..<72 { let c = s.bodyCenter; s.step(dt: 1.0 / 60, pointer: CGPoint(x: Double(c.x) + 20, y: Double(c.y))) }
    for stroke in 0..<8 {
        for i in 1...18 {
            let c = s.bodyCenter
            let d = (stroke % 2 == 0 ? -1.0 : 1.0) * (Double(i) / 18 - 0.5) * 40
            s.step(dt: 1.0 / 60, pointer: CGPoint(x: Double(c.x) + d, y: Double(c.y)))
        }
    }
    guard wink else { return s.pose }
    for _ in 0..<200 {
        let c = s.bodyCenter
        s.step(dt: 1.0 / 60, pointer: CGPoint(x: Double(c.x) + 20, y: Double(c.y)))
        if s.pose.mood.winking { for _ in 0..<12 { s.step(dt: 1.0 / 60, pointer: nil) }; break }
    }
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
        ("10-scratch-leaf", sim({ $0.startAntic(.scratchLeaf) }, seconds: 0.8, pointer: lookIn), false),
        ("11-stage1-buttons", sim({ $0.standOut = .peek; $0.say("Эй, ты давно не пил. Глоток воды?", buttons: ["Попил", "Через 10 мин", "Я занят"]); $0.hoveredButton = 0 }, seconds: 2), false),
        ("12-drink", sim({ $0.perform(.drink) }, seconds: 1.3), false),
        ("13-walk-out", sim({ $0.standOut = .out; $0.wear(.hat); $0.perform(.pack) }, seconds: 3), false),
        ("14-breathe-in", sim({ $0.standOut = .out; $0.perform(.breathe(seconds: 30)) }, seconds: 3.95), false),
        ("15-stage2-left", sim({ $0.standOut = .out; $0.fatigue = 0.8; $0.say("Я всё ещё тут. Разомнись, а? Спина скажет спасибо", buttons: ["Иду", "Я занят"]) }, seconds: 2.5), true),
        ("16-lookaway", sim({ $0.perform(.lookAway) }, seconds: 1.2), false),
        ("17-listening", sim({ $0.standOut = .out; $0.listening = true; $0.hearing = 0.5; $0.say("Напомни позвонить маме вечером", duration: .infinity) }, seconds: 2), false),
        ("18-thinking", sim({ $0.standOut = .out; $0.perform(.think(seconds: 30)); $0.say("···", duration: .infinity) }, seconds: 1.5), false),
        // Slice 6a
        ("19-eyes-strained", sim({ $0.eyeStrain = 1 }, seconds: 5, pointer: lookIn), false),
        ("20-tired-sag", sim({ $0.fatigue = 1; $0.standOut = .peek }, seconds: 3), false),
        ("21-hops-midair", sim({ $0.perform(.hops) }, seconds: 0.9), false),
        ("22-cheer-top", sim({ $0.standOut = .peek; $0.perform(.cheer) }, seconds: 1.36), false),
        ("23-cheer-confetti", sim({ $0.standOut = .peek; $0.perform(.cheer) }, seconds: 1.75), false),
        ("24-speck-watch", sim({ $0.startAntic(.catchSpeck) }, seconds: 0.9), false),
        ("25-speck-chew", sim({ $0.startAntic(.catchSpeck) }, seconds: 1.9), false),
        ("26-strain-left-edge", sim({ $0.eyeStrain = 1; $0.standOut = .peek }, seconds: 5), true),
        // Slice 6b
        ("27-lying", sim({ $0.slumped = true }, seconds: 2, pointer: lookIn), false),
        ("28-lying-help", sim({ $0.slumped = true; $0.say("Помоги мне… сделай хоть что-нибудь", buttons: ["Попил", "Встряхнуться"]) }, seconds: 2), false),
        ("29-lying-left-edge", sim({ $0.slumped = true; $0.say("Сделаешь — поговорим потом", duration: 30) }, seconds: 2), true),
        ("30-getting-up", { let s = CharacterSim(metrics: metrics, rng: SeededRandom(seed: 42)); s.slumped = true
            for _ in 0..<120 { s.step(dt: 1.0 / 60, pointer: nil) }; s.slumped = false
            for _ in 0..<45 { s.step(dt: 1.0 / 60, pointer: nil) }; return s.pose }(), false),
        // Slice 6c
        ("31-laugh", sim({ $0.standOut = .docked; $0.emote(.laugh, strong: false) }, seconds: 1.1), false),
        ("32-laugh-strong-back", sim({ $0.emote(.laugh, strong: true) }, seconds: 1.6), false),
        ("33-laugh-left-edge", sim({ $0.emote(.laugh, strong: false) }, seconds: 0.9), true),
        ("34-clown-nose", sim({ $0.emote(.clown, strong: false) }, seconds: 1.5), false),
        ("35-clown-stone", sim({ $0.emote(.clown, strong: false) }, seconds: 2.2), false),
        ("36-offended", sim({ $0.emote(.offended, strong: false) }, seconds: 1.4), false),
        ("37-sad", sim({ $0.emote(.sad, strong: false) }, seconds: 1.5), false),
        ("38-dizzy", sim({ $0.emote(.dizzy, strong: false) }, seconds: 1.0), false),
        ("39-petted", petted(wink: false), false),
        ("40-wink", petted(wink: true), false),
        // Slice 6d
        ("41-dive-puff", { let s = CharacterSim(metrics: metrics, rng: SeededRandom(seed: 42))
            for _ in 0..<60 { s.step(dt: 1.0 / 60, pointer: nil) }
            s.hidden = true
            for _ in 0..<240 { s.step(dt: 1.0 / 60, pointer: nil); if let a = s.pose.puffAge, a > 0.12 { break } }
            return s.pose }(), false),
        ("42-lurk", sim({ $0.hidden = true; $0.snapHidden(); $0.standOut = .lurk }, seconds: 1.5, pointer: CGPoint(x: 60, y: 120)), false),
        ("43-lurk-left-edge", sim({ $0.hidden = true; $0.snapHidden(); $0.standOut = .lurk }, seconds: 1.5, pointer: CGPoint(x: 60, y: 120)), true),
        ("44-diving", { let s = CharacterSim(metrics: metrics, rng: SeededRandom(seed: 42))
            for _ in 0..<60 { s.step(dt: 1.0 / 60, pointer: nil) }
            s.hidden = true
            for _ in 0..<27 { s.step(dt: 1.0 / 60, pointer: nil) }
            return s.pose }(), false),
        // Slice 6e: the leap to another monitor (1.6 s act: crouch, flight, landing).
        ("45-leap-crouch", leapPose(at: 0.08), false),
        ("46-leap-flight", leapPose(at: 0.7), false),
        ("47-leap-flight-left-edge", leapPose(at: 0.7), true),
        ("48-leap-landing", leapPose(at: 1.45), false),
        // Acceptance 2026-10-06: «измотан» (no flip) next to the most tired plain pose; emotions beside the words.
        ("64-hat", sim({ $0.wear(.hat) }, seconds: 2, pointer: lookIn), false),
        ("65-nightcap-awake", sim({ $0.wear(.nightcap) }, seconds: 2, pointer: lookIn), false),
        ("66-hat-backpack-left", sim({ $0.wear(.hat); $0.wear(.backpack) }, seconds: 2, pointer: lookIn), true),
        ("67-nightcap-asleep-left", sim({ $0.putOnNightcap() }, seconds: 5), true),
        ("68-shrug", sim({ $0.react(.shrug) }, seconds: 0.7, pointer: lookIn), false),
        ("69-shrug-left", sim({ $0.react(.shrug) }, seconds: 0.7, pointer: lookIn), true),
        ("70-game-think", sim({ $0.perform(.think(seconds: 1.2)) }, seconds: 0.6, pointer: lookIn), false),
        // Slice 7b: basketball — the ball over his head, the swing, the follow-through; claps; «пять!».
        ("71-shoot-hold", sim({ $0.perform(.shoot) }, seconds: 0.25, pointer: lookIn), false),
        ("72-shoot-swing", sim({ $0.perform(.shoot) }, seconds: 0.64, pointer: lookIn), false),
        ("73-shoot-follow", sim({ $0.perform(.shoot) }, seconds: 0.85, pointer: lookIn), true),
        ("74-clap", sim({ $0.finale(.fireworksAndClap) }, seconds: 0.5, pointer: lookIn), false),
        ("75-high-five", sim({ $0.say("Пять!", duration: 20); $0.finale(.highFive) }, seconds: 0.7, pointer: lookIn), false),
        ("76-high-five-left", sim({ $0.finale(.highFive) }, seconds: 0.7, pointer: lookIn), true),
        ("59-tired-max", sim({ $0.fatigue = 1 }, seconds: 3, pointer: lookIn), false),
        ("60-exhausted-sway", sim({ $0.slumped = true }, seconds: 4.5, pointer: lookIn), false),
        ("61-bubble-laugh", sim({ $0.say("Почему программисты путают Хэллоуин и Рождество? 31 OCT = 25 DEC", duration: 20)
                                  $0.emote(.laugh, strong: false) }, seconds: 1.6), false),
        ("62-bubble-laugh-strong", sim({ $0.say("Это лучшее, что я слышал за неделю!", duration: 20)
                                         $0.emote(.laugh, strong: true) }, seconds: 1.6), false),
        ("63-bubble-sulk-left", sim({ $0.say("Ну и ладно, сам такой", duration: 20); $0.emote(.offended, strong: false) },
                                    seconds: 1.2), true),
        // Slice 6f-1: the light around him.
        ("49-nightcap-yawn", sim({ $0.putOnNightcap() }, seconds: 0.8), false),
        ("50-nightcap-asleep", sim({ $0.putOnNightcap() }, seconds: 5), false),
        ("51-lamp", sim({ $0.wear(.lamp) }, seconds: 1.5), false),
        ("52-lamp-left-edge", sim({ $0.wear(.lamp) }, seconds: 1.5), true),
        ("53-sunglasses", sim({ $0.wear(.sunglasses) }, seconds: 1.5), false),
        ("54-sunglasses-peek", sim({ $0.wear(.sunglasses); $0.standOut = .peek }, seconds: 1.5), true),
        // Slice 6f-2: the dance (a beat with an arm up, mid-spin, the bow).
        ("55-dance-beat", sim({ $0.perform(.dance(seconds: 20)) }, seconds: 1.3), false),
        ("56-dance-spin", sim({ $0.perform(.dance(seconds: 20)) }, seconds: 3.25), false),
        ("57-dance-bow", sim({ $0.perform(.dance(seconds: 20)) }, seconds: 19.4), true),
    ]
    for (name, pose, mirrored) in states {
        let image = render(metrics.sceneSize) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.95, blue: 0.89, alpha: 1))   // stand-in wallpaper
            ctx.fill(CGRect(origin: .zero, size: metrics.sceneSize))
            ChilkRenderer.drawScene(in: ctx, pose: pose, metrics: metrics, palette: palette, mirrored: mirrored)
        }
        writePNG(image, to: dir.appendingPathComponent("\(name).png"))
    }
    // Slice 6f-2: the disco ball window above him, its thread from the top of the screen.
    let ball = render(CGSize(width: DiscoBall.width, height: 260)) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.95, blue: 0.89, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: DiscoBall.width, height: 260))
        DiscoBall.draw(in: ctx, width: DiscoBall.width, drop: 170, time: 2.3)
    }
    writePNG(ball, to: dir.appendingPathComponent("58-disco-ball.png"))
    // Slice 7b: the hoop (he is to the right of it), a ball in flight, a small firework over it.
    let court = render(CGSize(width: 300, height: 300)) { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.95, blue: 0.89, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        let outline = palette.outline.cgColor
        ctx.saveGState(); ctx.translateBy(x: 120, y: 170)
        CourtArt.hoop(ctx, facing: 1, swing: 0.3, outline: outline)
        ctx.restoreGState()
        ctx.saveGState(); ctx.translateBy(x: 236, y: 120)
        CourtArt.ball(ctx, spin: 0.6, outline: outline, lw: 1)
        ctx.restoreGState()
        var rng = SeededRandom(seed: 3)
        let show = Fireworks.small(at: CGPoint(x: 140, y: 230), rng: &rng)
        CourtArt.sparks(ctx, show, at: 0.35, origin: .zero, height: 300)
    }
    writePNG(court, to: dir.appendingPathComponent("77-court.png"))
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
case "portrait":
    // The main window's still portrait for the three sprout states (fresh / drooping / wilted), on light and dark.
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    for (name, fatigue) in [("fresh", 0.0), ("drooping", 0.55), ("wilted", 1.0)] {
        guard let image = Portrait.image(fatigue: fatigue, side: 160) else { continue }
        for (bg, gray) in [("light", 0.96), ("dark", 0.16)] {
            let out = render(CGSize(width: 160, height: 160), scale: 2) { ctx in
                ctx.setFillColor(CGColor(gray: gray, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
                ctx.saveGState()
                ctx.translateBy(x: 0, y: 160)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 160))
                ctx.restoreGState()
            }
            writePNG(out, to: target.appendingPathComponent("portrait-\(name)-\(bg).png"))
        }
    }
case "tray":
    // Tray icon states at 4× on white and black (how the template looks on a light and a dark menu bar).
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    for leaf in TrayLeaf.allCases {
        for dot in [false, true] {
            guard let glyph = TrayIconRenderer.image(TrayIconState(leaf: leaf, dot: dot), scale: 4) else { continue }
            for (name, background, tint) in [("light", 1.0, 0.0), ("dark", 0.15, 1.0)] {
                func context() -> CGContext {
                    CGContext(data: nil, width: glyph.width, height: glyph.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                }
                let rect = CGRect(x: 0, y: 0, width: glyph.width, height: glyph.height)
                let tinted = context()                  // the template's alpha in the menu-bar colour
                tinted.draw(glyph, in: rect)
                tinted.setBlendMode(.sourceIn)
                tinted.setFillColor(CGColor(gray: tint, alpha: 1))
                tinted.fill(rect)
                let ctx = context()
                ctx.setFillColor(CGColor(gray: background, alpha: 1))
                ctx.fill(rect)
                ctx.draw(tinted.makeImage()!, in: rect)
                writePNG(ctx.makeImage()!, to: target.appendingPathComponent("tray-\(leaf)\(dot ? "-dot" : "")-\(name).png"))
            }
        }
    }
default: print("unknown command \(args[1])"); exit(2)
}
