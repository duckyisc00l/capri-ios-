import SwiftUI
import UIKit

/// Cuts one of the APK's sprite strips into frames.
enum Sprites {
    private static var cache: [String: [UIImage]] = [:]
    static let widths: [String: Int] = [
        "idle": 240, "blink": 240, "blink_glitch": 240, "glitch": 240, "wake": 240, "mouth": 240,
        "click": 144, "kb_a": 384,
    ]

    static func frames(_ name: String) -> [UIImage] {
        if let f = cache[name] { return f }
        guard let img = UIImage(contentsOfFile: Res.url("sprites/\(name).png").path), let cg = img.cgImage else {
            Log.write("sprite missing: \(name)")
            cache[name] = []
            return []
        }
        let w = widths[name] ?? cg.height
        let n = max(1, cg.width / w)
        let out = (0..<n).compactMap { i -> UIImage? in
            guard let c = cg.cropping(to: CGRect(x: i * w, y: 0, width: w, height: cg.height)) else { return nil }
            return UIImage(cgImage: c)
        }
        cache[name] = out
        return out
    }
}

@MainActor
final class CapriAnimator: ObservableObject {
    enum Act { case wake, idle, blink, blinkGlitch, glitch }

    @Published private(set) var body: UIImage?
    @Published private(set) var mouth: UIImage?
    @Published var talking = false
    @Published var lying = false

    private var act: Act = .wake
    private var step = 0
    private var idleStep = 0
    private var tick = 0
    private var nextBlink = 40
    private var nextGlitch = 300
    private var timer: Timer?

    init() {
        body = Sprites.frames("wake").first
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func poke() {
        act = .glitch
        step = 0
    }

    private func play(_ a: Act) { act = a; step = 0 }

    private func advance() {
        tick += 1
        idleStep += 1
        if lying {
            let f = Sprites.frames("kb_a")
            body = f.isEmpty ? nil : f[(tick / 2) % f.count]
            mouth = nil
            return
        }
        switch act {
        case .wake:
            let f = Sprites.frames("wake")
            if step < f.count { body = f[step]; step += 1; mouth = nil; return }
            play(.idle)
        case .glitch:
            let f = Sprites.frames("glitch")
            if step < f.count { body = f[step]; step += 1; mouth = nil; return }
            play(.idle)
        case .blink, .blinkGlitch:
            let f = Sprites.frames(act == .blink ? "blink" : "blink_glitch")
            if step < f.count { body = f[step]; step += 1; mouth = nil; return }
            play(.idle)
        case .idle:
            break
        }
        nextBlink -= 1
        nextGlitch -= 1
        if nextBlink <= 0 {
            nextBlink = Int.random(in: 30...80)
            play(Int.random(in: 0..<8) == 0 ? .blinkGlitch : .blink)
            advanceAgain()
            return
        }
        if nextGlitch <= 0 {
            nextGlitch = Int.random(in: 250...600)
            play(.glitch)
            advanceAgain()
            return
        }
        let idle = Sprites.frames("idle")
        if !idle.isEmpty { body = idle[(idleStep / 2) % idle.count] }
        let m = Sprites.frames("mouth")
        if talking, !m.isEmpty {
            mouth = tick % 2 == 0 ? m[Int.random(in: 0..<m.count)] : mouth
        } else {
            mouth = nil
        }
    }

    private func advanceAgain() { idleStep -= 1; tick -= 1; advance() }
}

struct ClickBurst: View {
    let point: CGPoint
    @State private var frame = 0
    var body: some View {
        let f = Sprites.frames("click")
        Group {
            if frame < f.count {
                Image(uiImage: f[frame]).resizable().frame(width: 96, height: 96)
            }
        }
        .position(point)
        .allowsHitTesting(false)
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            if frame < f.count { frame += 1 }
        }
    }
}

struct CharacterView: View {
    @ObservedObject var anim: CapriAnimator
    var height: CGFloat
    var hue: Double
    var bubble: String?
    var onTap: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                if let b = anim.body {
                    Image(uiImage: b).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
                if let m = anim.mouth {
                    Image(uiImage: m).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
            }
            .hueRotation(.degrees(hue))
            .frame(height: height)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            if let bubble, !bubble.isEmpty {
                Text(bubble)
                    .font(Theme.font(13))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.pink.opacity(0.7), lineWidth: 1))
                    .frame(maxWidth: 220)
                    .offset(x: 110, y: -6)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .allowsHitTesting(false)
            }
        }
        .onAppear { anim.start() }
    }
}
