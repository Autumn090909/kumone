import Foundation
import AVFoundation

// ---------------------------------------------------------------- config
struct Cfg {
    var name        = "baseline"
    var glideTarget : Float = 0.9859     // final rate of the glide
    var glideSteps  = 40
    var glideMs     = 90.0               // ms per step
    var preRollSec  = 1.2                // play at 1.0 before glide
    var stopDelayMs = 7.0                // stop() -> rate=1.0 gap (negative = rate first)
    var snapWhileStopped = true          // false => set rate=1.0 before stop()
    var idleSec     = 3.0
    var extraStops  = 2                  // extra stop()/rate=1.0 during idle
    var tinyFirst   = 31                 // frames of first chunk after idle (0 = none)
    var usePlayAt   = true               // play(at: future) vs play()
    var restartSec  = 5.5                // measurement window after restart
    var enginePauseDuringIdle = false
    var fixReset    = false              // timePitch.reset() after stop
    var fixAUReset  = false              // timePitch.auAudioUnit.reset() after stop
    var fixBypass   = false              // bypass at unity rate
}

func arg(_ k: String) -> String? {
    for a in CommandLine.arguments.dropFirst() where a.hasPrefix("--\(k)=") {
        return String(a.dropFirst(k.count + 3))
    }
    return CommandLine.arguments.contains("--\(k)") ? "1" : nil
}

var cfg = Cfg()
let plainMode = arg("plain") != nil
let minimalMode = arg("minimal") != nil
let dump = arg("dump") != nil
if let v = arg("name") { cfg.name = v }
if let v = arg("rate") { cfg.glideTarget = Float(v)! }
if let v = arg("stopDelayMs") { cfg.stopDelayMs = Double(v)! }
if let v = arg("rec") { cfg.restartSec = Double(v)! }
if let v = arg("idle") { cfg.idleSec = Double(v)! }
if let v = arg("tiny") { cfg.tinyFirst = Int(v)! }
if let v = arg("glideSteps") { cfg.glideSteps = Int(v)! }
if let v = arg("glideMs") { cfg.glideMs = Double(v)! }
if let v = arg("extraStops") { cfg.extraStops = Int(v)! }
if arg("snapWhilePlaying") != nil { cfg.snapWhileStopped = false }
if arg("noPlayAt") != nil { cfg.usePlayAt = false }
if arg("enginePause") != nil { cfg.enginePauseDuringIdle = true }
if arg("fixReset") != nil { cfg.fixReset = true }
if arg("fixAUReset") != nil { cfg.fixAUReset = true }
if arg("fixBypass") != nil { cfg.fixBypass = true }

// ---------------------------------------------------------------- signal
let SR = 44100.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: SR, channels: 2)!
let sigLen = Int(SR * 4)
var sig = [Float](repeating: 0, count: sigLen)
do {
    var rng: UInt64 = 0x12345678ABCDEF01
    func rnd() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: Int(rng >> 33))) / Float(Int32.max) }
    for n in 0..<sigLen {
        let t = Double(n) / SR
        var s = 0.0
        for (k, f) in [110.0, 220.0, 331.0, 523.0, 784.0, 1319.0].enumerated() {
            let am = 0.6 + 0.4 * sin(2 * .pi * (0.7 + 0.31 * Double(k)) * t)
            s += am * sin(2 * .pi * f * t + Double(k)) / Double(k + 2)
        }
        // noise bursts every 0.5 s
        if (t.truncatingRemainder(dividingBy: 0.5)) < 0.02 { s += 0.5 * Double(rnd()) }
        sig[n] = Float(s * 0.25)
    }
}

// ---------------------------------------------------------------- graph
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let tp = AVAudioUnitTimePitch()
tp.overlap = 8
let eq = AVAudioUnitEQ(numberOfBands: 3)
let dly = AVAudioUnitDelay()
for n in [player, tp, eq, dly] { engine.attach(n) }
engine.connect(player, to: tp, format: fmt)
engine.connect(tp, to: eq, format: fmt)
engine.connect(eq, to: dly, format: fmt)
engine.connect(dly, to: engine.mainMixerNode, format: fmt)
engine.mainMixerNode.outputVolume = 0.05
for b in eq.bands { b.bypass = false; b.filterType = .parametric; b.frequency = 1000; b.bandwidth = 1; b.gain = 0 }
dly.wetDryMix = 0
_ = engine.mainMixerNode.outputFormat(forBus: 0)

// ---------------------------------------------------------------- taps
final class Rec {
    var buf = [Float](); var on = false
    let lock = NSLock()
    func add(_ b: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard on, let d = b.floatChannelData else { return }
        let n = Int(b.frameLength)
        buf.reserveCapacity(buf.count + n)
        for i in 0..<n { buf.append(d[0][i]) }
    }
    func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return buf }
    func start() { lock.lock(); buf.removeAll(); on = true; lock.unlock() }
    func stop()  { lock.lock(); on = false; lock.unlock() }
}
let recP = Rec(), recT = Rec()
player.installTap(onBus: 0, bufferSize: 4096, format: fmt) { b, _ in recP.add(b) }
tp.installTap(onBus: 0, bufferSize: 4096, format: fmt) { b, _ in recT.add(b) }

// ---------------------------------------------------------------- feeder
final class Feeder {
    let player: AVAudioPlayerNode
    var idx = 0
    var running = false
    let q = DispatchQueue(label: "feeder")
    init(_ p: AVAudioPlayerNode) { player = p }
    func makeBuf(_ frames: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        let d = b.floatChannelData!
        for i in 0..<frames { let v = sig[(idx + i) % sigLen]; d[0][i] = v; d[1][i] = v }
        idx = (idx + frames) % sigLen
        return b
    }
    func push(_ frames: Int = 4096) {
        let b = makeBuf(frames)
        player.scheduleBuffer(b, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let s = self else { return }
            s.q.async { if s.running { s.push() } }
        }
    }
    func begin(prime: Int = 4, tiny: Int = 0) {
        running = true; idx = 0
        if tiny > 0 { push(tiny) }
        for _ in 0..<prime { push() }
    }
    func halt() { running = false }
}
let feeder = Feeder(player)

func nsToHost(_ ns: UInt64) -> UInt64 {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    return ns * UInt64(tb.denom) / UInt64(tb.numer)
}
func startPlayer(_ usePlayAt: Bool) {
    if usePlayAt { player.play(at: AVAudioTime(hostTime: mach_absolute_time() + nsToHost(60_000_000))) }
    else { player.play() }
}
func sleepMs(_ ms: Double) { Thread.sleep(forTimeInterval: ms / 1000.0) }

// ---------------------------------------------------------------- run
try! engine.start()

// phase A: play at 1.0
tp.rate = 1.0
feeder.begin(prime: 6)
startPlayer(cfg.usePlayAt)
Thread.sleep(forTimeInterval: cfg.preRollSec)

if plainMode {
    recP.start(); recT.start()
    Thread.sleep(forTimeInterval: cfg.restartSec)
    feeder.halt(); recP.stop(); recT.stop(); player.stop(); engine.stop()
    analyse(); exit(0)
}

// phase B: glide down
let r0: Float = 1.0
for s in 1...max(1, cfg.glideSteps) {
    tp.rate = r0 + (cfg.glideTarget - r0) * Float(s) / Float(cfg.glideSteps)
    sleepMs(cfg.glideMs)
}

if minimalMode {
    dumpParams("afterGlide")
    tp.rate = 1.0
    if cfg.fixReset { tp.reset() }
    if cfg.fixAUReset { tp.auAudioUnit.reset() }
    if cfg.fixBypass { tp.bypass = true }
    if arg("fixToggleBypass") != nil { tp.bypass = true; sleepMs(150); tp.bypass = false }
    if arg("fixDouble") != nil { sleepMs(120); tp.rate = 1.0 }
    if arg("fixNudge") != nil { sleepMs(120); tp.rate = 1.0001; sleepMs(20); tp.rate = 1.0 }
    dumpParams("afterSnap")
    recP.start(); recT.start()
    Thread.sleep(forTimeInterval: cfg.restartSec)
    dumpParams("atEnd")
    feeder.halt(); recP.stop(); recT.stop(); player.stop(); engine.stop()
    analyse(); exit(0)
}

// phase C: stop + snap
if cfg.snapWhileStopped {
    feeder.halt(); player.stop()
    if cfg.stopDelayMs > 0 { sleepMs(cfg.stopDelayMs) }
    tp.rate = 1.0
} else {
    tp.rate = 1.0
    if cfg.stopDelayMs > 0 { sleepMs(cfg.stopDelayMs) }
    feeder.halt(); player.stop()
}
for b in eq.bands { b.gain = 0 }
dly.wetDryMix = 0
if cfg.fixReset { tp.reset() }
if cfg.fixAUReset { tp.auAudioUnit.reset() }
if cfg.fixBypass { tp.bypass = true }

// phase D: idle
let idleStart = Date()
if cfg.enginePauseDuringIdle {
    Thread.sleep(forTimeInterval: cfg.idleSec / 2); engine.pause()
    Thread.sleep(forTimeInterval: 0.3); try! engine.start()
}
for _ in 0..<cfg.extraStops {
    Thread.sleep(forTimeInterval: max(0.1, cfg.idleSec / Double(cfg.extraStops + 2)))
    player.stop(); tp.rate = 1.0
}
let rem = cfg.idleSec - Date().timeIntervalSince(idleStart)
if rem > 0 { Thread.sleep(forTimeInterval: rem) }

// phase E: restart
if cfg.fixBypass { tp.bypass = false }
recP.start(); recT.start()
feeder.begin(prime: 6, tiny: cfg.tinyFirst)
startPlayer(cfg.usePlayAt)
Thread.sleep(forTimeInterval: cfg.restartSec)
feeder.halt()
recP.stop(); recT.stop()
player.stop()
engine.stop()

// ---------------------------------------------------------------- analyse
func dumpParams(_ tag: String) {
    var ps: [String] = []
    if let tree = tp.auAudioUnit.parameterTree {
        for prm in tree.allParameters { ps.append("\(prm.identifier)=\(prm.value)") }
    }
    print("  params[\(tag)] rate=\(tp.rate) pitch=\(tp.pitch) bypass=\(tp.bypass) au: " + ps.joined(separator: " "))
}
func analyse() {
let P = recP.snapshot(), T = recT.snapshot()
func rms(_ a: ArraySlice<Float>) -> Double {
    var s = 0.0; for v in a { s += Double(v) * Double(v) }; return (s / Double(max(1, a.count))).squareRoot()
}
let N = min(P.count, T.count)
let M = min(88200, N - 90000)
guard M > 20000 else {
    print("[\(cfg.name)] INSUFFICIENT DATA P=\(P.count) T=\(T.count)"); return
}
let start = N - M - 42000
let maxLag = 40000
var y = [Double](repeating: 0, count: M)
for i in 0..<M { y[i] = Double(T[start + i]) }
let ym = y.reduce(0, +) / Double(M)
for i in 0..<M { y[i] -= ym }
let yn = (y.reduce(0) { $0 + $1 * $1 }).squareRoot()

var bestC = 0.0, bestL = 0; var valid = false

func corrAt(_ l: Int, _ m: Int, _ stride: Int) -> Double? {
    let o = start + l
    if o < 0 || o + m > P.count { return nil }
    var dot = 0.0, xx = 0.0
    var i = 0
    while i < m { let v = Double(P[o + i]); dot += v * y[i]; xx += v * v; i += stride }
    if xx <= 1e-12 { return nil }
    var yy = 0.0; i = 0
    while i < m { yy += y[i] * y[i]; i += stride }
    if yy <= 1e-12 { return nil }
    return dot / (xx.squareRoot() * yy.squareRoot())
}

if yn > 1e-9 {
    // coarse: step 4 over the full lag range, decimated dot products
    let cm = min(M, 44100)
    var cBest = 0.0, cL = 0; var cValid = false
    var l = -maxLag
    while l <= maxLag {
        if let c = corrAt(l, cm, 3) {
            if !cValid || abs(c) > abs(cBest) { cBest = c; cL = l; cValid = true }
        }
        l += 4
    }
    if cValid {
        for l in (cL - 12)...(cL + 12) {
            if let c = corrAt(l, M, 1) {
                if !valid || abs(c) > abs(bestC) { bestC = c; bestL = l; valid = true }
            }
        }
    }
}

// per-window analysis: is it garbage, or a drifting lag?
if yn > 1e-9 && arg("win") != nil {
    let W = 2205  // 50 ms
    let nw = M / W
    var lags = [Int](); var cs = [Double]()
    for w in 0..<nw {
        let base = start + w * W
        var bC = 0.0, bL = 0; var ok = false
        for l in -8000...8000 {
            let o = base + l
            if o < 0 || o + W > P.count { continue }
            var dot = 0.0, xx = 0.0, yy = 0.0
            for i in 0..<W { let v = Double(P[o+i]); let u = y[w*W + i]; dot += v*u; xx += v*v; yy += u*u }
            if xx < 1e-12 || yy < 1e-12 { continue }
            let c = dot / (xx*yy).squareRoot()
            if !ok || abs(c) > abs(bC) { bC = c; bL = l; ok = true }
        }
        if ok { lags.append(bL); cs.append(bC) }
    }
    let sorted = cs.map { abs($0) }.sorted()
    let med = sorted.isEmpty ? 0 : sorted[sorted.count/2]
    print(String(format: "  windows n=%d medCorr=%.3f lagFirst=%d lagLast=%d lagSpread=%d",
        lags.count, med, lags.first ?? 0, lags.last ?? 0, (lags.max() ?? 0) - (lags.min() ?? 0)))
    print("  lags: " + lags.map(String.init).joined(separator: " "))
    var diffs = [Double]()
    for i in 1..<max(1, lags.count) where abs(cs[i]) > 0.8 && abs(cs[i-1]) > 0.8 {
        let d = Double(lags[i] - lags[i-1]); if abs(d) < 400 { diffs.append(d) }
    }
    let sd = diffs.sorted(); let mdiff = sd.isEmpty ? 0 : sd[sd.count/2]
    print(String(format: "  medLagDiff=%.1f per %d frames -> implied effective rate = %.5f", mdiff, W, 1.0 - mdiff/Double(W)))
    print("  corr: " + cs.map { String(format: "%.2f", $0) }.joined(separator: " "))
}

// comb fit y[i] = g0*P[start+i+L] + g1*P[start+i+L-d]
var bestD = 0, bestG0 = 0.0, bestG1 = 0.0, bestR = Double.infinity
if yn > 1e-9 {
    for d in 1...60 {
        let o = start + bestL
        if o - d < 0 || o + M > P.count { continue }
        var a00 = 0.0, a01 = 0.0, a11 = 0.0, b0 = 0.0, b1 = 0.0
        for i in 0..<M {
            let x0 = Double(P[o + i]), x1 = Double(P[o + i - d])
            a00 += x0 * x0; a01 += x0 * x1; a11 += x1 * x1
            b0 += x0 * y[i]; b1 += x1 * y[i]
        }
        let det = a00 * a11 - a01 * a01
        if abs(det) < 1e-9 { continue }
        let g0 = (b0 * a11 - b1 * a01) / det
        let g1 = (a00 * b1 - a01 * b0) / det
        let resid = 1.0 - (g0 * b0 + g1 * b1) / (yn * yn)
        if resid < bestR { bestR = resid; bestD = d; bestG0 = g0; bestG1 = g1 }
    }
}

if dump {
    func wav(_ a: [Float], _ f: String) {
        var d = Data()
        let n = a.count, br = 44100 * 4
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n*4)); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(3); u16(1); u32(44100); u32(UInt32(br)); u16(4); u16(32)
        d.append("data".data(using: .ascii)!); u32(UInt32(n*4))
        a.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        try? d.write(to: URL(fileURLWithPath: f))
    }
    wav(P, "dump_\(cfg.name)_player.wav"); wav(T, "dump_\(cfg.name)_tp.wav")
}
let rP = rms(P[max(0,P.count-M)...]), rT = rms(T[max(0,T.count-M)...])
let verdict: String
if rT < 1e-5 { verdict = "SILENT" }
else if !valid { verdict = "NOLAG" }
else if abs(bestC) > 0.9 { verdict = "CLEAN" }
else if abs(bestC) < 0.5 { verdict = "CORRUPT" }
else { verdict = "SUSPECT" }
print(String(format: "[%@] %@ corr=%.3f lag=%d rmsP=%.4f rmsT=%.4f comb d=%d g0=%.2f g1=%.2f resid=%.3f",
             cfg.name, verdict, bestC, bestL, rP, rT, bestD, bestG0, bestG1, bestR))
}

analyse()
exit(0)
