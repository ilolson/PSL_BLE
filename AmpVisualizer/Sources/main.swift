import AppKit
import Metal
import QuartzCore
import ScreenCaptureKit
import CoreMedia
import Accelerate

let sampleCount = 8192
let scopeSampleCount = 2048
let spectrumBinCount = 512
final class AudioStore {
    private let lock = NSLock()
    private var left = [Float](repeating: 0, count: sampleCount)
    private var right = [Float](repeating: 0, count: sampleCount)
    private var head = 0
    private var received = 0
    private var lastAudio: Double = 0
    func append(_ l: [Float], _ r: [Float]) {
        lock.lock(); defer { lock.unlock() }
        for i in l.indices { left[head] = l[i]; right[head] = r[i]; head = (head + 1) % sampleCount }
        received += l.count; lastAudio = CACurrentMediaTime()
    }
    func snapshot() -> ([Float], [Float], Bool) {
        lock.lock(); defer { lock.unlock() }
        let l = Array(left[head...] + left[..<head])
        let r = Array(right[head...] + right[..<head])
        return (l, r, received > 0 && CACurrentMediaTime() - lastAudio < 1)
    }
}
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver {
    let audio: AudioStore
    var stream: SCStream?
    var status: ((String) -> Void)?
    let queue = DispatchQueue(label: "amp.audio", qos: .userInteractive)
    init(_ audio: AudioStore) { self.audio = audio }
    private var selection: CheckedContinuation<SCContentFilter, Error>?
    @MainActor func start() async throws {
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        var options = SCContentSharingPickerConfiguration()
        options.allowedPickerModes = [.singleDisplay, .singleApplication]
        picker.defaultConfiguration = options
        picker.isActive = true
        let filter: SCContentFilter
        do {
            filter = try await withCheckedThrowingContinuation { continuation in
                selection = continuation
                picker.present()
            }
        } catch {
            picker.remove(self); picker.isActive = false
            throw error
        }
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 2
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Drain the minimal screen output; no images are retained or written.
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        do {
            try await newStream.startCapture()
            stream = newStream
        } catch {
            picker.remove(self); picker.isActive = false
            throw error
        }
    }
    @MainActor func stop() async {
        if let s = stream { try? await s.stopCapture() }; stream = nil
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { [self] in
            let pending = selection; selection = nil
            pending?.resume(throwing: CancellationError())
        }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { [self] in
            if let pending = selection {
                selection = nil; pending.resume(returning: filter)
            } else if let stream = self.stream {
                Task { try? await stream.updateContentFilter(filter) }
            }
        }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { [self] in
            let pending = selection; selection = nil
            pending?.resume(throwing: error)
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        DispatchQueue.main.async { self.status?("Capture stopped: \(error.localizedDescription)") }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(buffer),
              let desc = CMSampleBufferGetFormatDescription(buffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        guard format.pointee.mFormatID == kAudioFormatLinearPCM,
              format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.pointee.mBitsPerChannel == 32 else { return }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: max(needed, MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
        guard result == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 0, let first = buffers.first, let data = first.mData else { return }
        var l = [Float](repeating: 0, count: count), r = l
        let channels = Int(format.pointee.mChannelsPerFrame)
        let nonInterleaved = format.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if nonInterleaved {
            guard Int(first.mDataByteSize) >= count * 4 else { return }
            let lp = data.assumingMemoryBound(to: Float.self)
            let rp = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : lp
            guard let rp, buffers.count < 2 || Int(buffers[1].mDataByteSize) >= count * 4 else { return }
            for i in 0..<count { l[i] = lp[i]; r[i] = rp[i] }
        } else {
            guard channels > 0, Int(first.mDataByteSize) >= count * channels * 4 else { return }
            let p = data.assumingMemoryBound(to: Float.self)
            for i in 0..<count { l[i] = p[i * channels]; r[i] = p[i * channels + min(1, channels - 1)] }
        }
        audio.append(l, r)
    }
}

let shader = """
#include <metal_stdlib>
using namespace metal;
struct Params { float2 size; float time; float dots; float width; uint independent; };
struct V { float4 position [[position]]; float2 local; float hue; };
vertex V lines(uint id [[vertex_id]], const device float2 *points [[buffer(0)]], constant Params &p [[buffer(1)]]) {
    uint segment = id / 6; uint corner = id % 6;
    uint point = p.independent ? segment*2 : segment;
    float2 a = points[point], b = points[point+1];
    float2 direction = (b-a)*p.size;
    float2 normal = float2(-direction.y, direction.x) / max(length(direction), 0.001);
    const float2 uv[6] = {float2(0,-1),float2(1,-1),float2(0,1),float2(0,1),float2(1,-1),float2(1,1)};
    float2 q = uv[corner];
    V out; out.position = float4(mix(a,b,q.x) + normal*q.y*p.width/p.size,0,1);
    out.local = float2(q.x,q.y); out.hue = p.independent ? clamp((a.x+0.9)/1.8,0.0,1.0) : float(segment)*0.003 + p.time*0.035;
    return out;
}
float3 hueColor(float hue) {
    float3 rgb=clamp(abs(fract(hue+float3(0,2.0/3.0,1.0/3.0))*6.0-3.0)-1.0,0.0,1.0);
    return mix(float3(1),rgb,0.88);
}
fragment float4 ink(V in [[stage_in]], constant Params &p [[buffer(1)]], constant float2 &palette [[buffer(2)]]) {
    float glow = exp(-4.0*in.local.y*in.local.y);
    float3 color = 0.55 + 0.45*cos(6.283185*(in.hue + float3(0,0.33,0.67)));
    if (p.independent) {
        // One shared palette: three anchors across the entire spectrum.
        float3 left=hueColor(palette.x);
        float3 middle=hueColor(palette.x+0.14);
        float3 right=hueColor(palette.x+0.28);
        float x=clamp(in.hue,0.0,1.0);
        color=x<0.5 ? mix(left,middle,x*2.0) : mix(middle,right,(x-0.5)*2.0);
        color *= 0.78; // Constant brightness; music only affects hue rotation.
    }
    float intensity = glow;
    if (p.dots > 0.5) {
        // Two columns by four rows, with spacing between Braille character cells.
        float2 cell = fmod(in.position.xy, float2(14,28));
        float dx = min(abs(cell.x-3),abs(cell.x-9));
        float dy = min(min(abs(cell.y-3),abs(cell.y-9)),min(abs(cell.y-15),abs(cell.y-21)));
        intensity *= 1.0-smoothstep(2.4,3.0,length(float2(dx,dy)));
    }
    return float4(color*intensity, intensity);
}
struct PanelVertex { float4 position [[position]]; };
vertex PanelVertex panelVertex(uint id [[vertex_id]]) {
    const float2 vertices[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    PanelVertex result; result.position=float4(vertices[id],0,1); return result;
}
fragment float4 panelInk(PanelVertex in [[stage_in]], texture2d<float> pixels [[texture(0)]], constant float4 &info [[buffer(0)]]) {
    float side=min(info.x,info.y);
    float2 uv=(in.position.xy-(info.xy-side)*0.5)/side;
    if (any(uv<0.0) || any(uv>=1.0)) return float4(0.012,0.018,0.032,1);
    float2 grid=uv*info.z;
    uint2 cell=uint2(floor(grid));
    float3 color=pixels.read(cell).rgb;
    // Solid square pixels, with linear-light HDR highlights on EDR displays.
    float3 linear = select(color/12.92,pow((color+0.055)/1.055,float3(2.4)),color>0.04045);
    return float4(linear*max(1.0,info.w),1);

}

"""
struct Params { var size: SIMD2<Float>; var time: Float; var dots: Float; var width: Float; var independent: UInt32 }
final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let panelPipeline: MTLRenderPipelineState
    var panelTexture: MTLTexture?
    var completed = 0
    let lock = NSLock()
    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw NSError(domain: "Metal", code: 1) }
        device = d; queue = q
        let library = try d.makeLibrary(source: shader, options: nil)
        let config = MTLRenderPipelineDescriptor()
        config.vertexFunction = library.makeFunction(name: "lines")
        config.fragmentFunction = library.makeFunction(name: "ink")
        config.colorAttachments[0].pixelFormat = .bgra8Unorm
        let a = config.colorAttachments[0]!
        a.isBlendingEnabled = true; a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .one
        a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .one
        pipeline = try d.makeRenderPipelineState(descriptor: config)
        let panelConfig = MTLRenderPipelineDescriptor()
        panelConfig.vertexFunction = library.makeFunction(name: "panelVertex")
        panelConfig.fragmentFunction = library.makeFunction(name: "panelInk")
        panelConfig.colorAttachments[0].pixelFormat = .rgba16Float
        panelPipeline = try d.makeRenderPipelineState(descriptor: panelConfig)
    }
    func render(points: [SIMD2<Float>], texture: MTLTexture, drawable: CAMetalDrawable? = nil, dots: Bool, independent: Bool = false, panelSize: Int = 0, hdrHeadroom: Float = 1, palette: SIMD2<Float> = SIMD2(0.55,0), finished: (() -> Void)? = nil) {
        guard points.count > 1, let command = queue.makeCommandBuffer() else { finished?(); return }
        var target = texture
        if panelSize > 0 {
            if panelTexture?.width != panelSize {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: panelSize, height: panelSize, mipmapped: false)
                descriptor.usage = [.renderTarget,.shaderRead]; descriptor.storageMode = .private
                panelTexture = device.makeTexture(descriptor: descriptor)
            }
            guard let panelTexture else { finished?(); return }
            target = panelTexture
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.012, green: 0.018, blue: 0.032, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { finished?(); return }
        var params = Params(size: SIMD2(Float(target.width), Float(target.height)), time: Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)), dots: dots && panelSize == 0 ? 1 : 0, width: panelSize > 0 ? 1.6 : (dots ? 11 : (independent ? 1.5 : 5)), independent: independent ? 1 : 0)
        encoder.setRenderPipelineState(pipeline)
        let pointBuffer = points.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        guard let pointBuffer else { encoder.endEncoding(); finished?(); return }
        encoder.setVertexBuffer(pointBuffer, offset: 0, index: 0)
        var colors = palette
        encoder.setFragmentBytes(&colors,length: MemoryLayout<SIMD2<Float>>.stride,index: 2)
        encoder.setVertexBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: (independent ? points.count/2 : points.count-1)*6)
        encoder.endEncoding()
        if panelSize > 0 {
            let preview = MTLRenderPassDescriptor()
            preview.colorAttachments[0].texture = texture
            preview.colorAttachments[0].loadAction = .clear; preview.colorAttachments[0].storeAction = .store
            guard let presenter = command.makeRenderCommandEncoder(descriptor: preview) else { finished?(); return }
            var info = SIMD4<Float>(Float(texture.width),Float(texture.height),Float(panelSize),hdrHeadroom)
            presenter.setRenderPipelineState(panelPipeline)
            presenter.setFragmentTexture(target,index: 0)
            presenter.setFragmentBytes(&info,length: MemoryLayout<SIMD4<Float>>.stride,index: 0)
            presenter.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
            presenter.endEncoding()
        }
        if let drawable { command.present(drawable) }
        command.addCompletedHandler { [self] _ in lock.lock(); completed += 1; lock.unlock(); finished?() }
        command.commit()
    }
    func frameCount() -> Int { lock.lock(); defer { lock.unlock() }; return completed }
}
final class MetalCanvas: NSView {
    let metal = CAMetalLayer()
    init(device: MTLDevice) {
        super.init(frame: .zero); wantsLayer = true
        metal.device = device; metal.pixelFormat = .rgba16Float
        metal.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metal.wantsExtendedDynamicRangeContent = true
        metal.framebufferOnly = true; metal.maximumDrawableCount = 3
        metal.displaySyncEnabled = false
        layer = metal
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: max(1,bounds.width*scale), height: max(1,bounds.height*scale))
    }
    override func viewDidChangeBackingProperties() { needsLayout = true }
}
final class SignalAnalysis {
    let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(sampleCount), .FORWARD)!
    var window = [Float](repeating: 0, count: sampleCount)
    var real = [Float](repeating: 0, count: sampleCount)
    var imag = [Float](repeating: 0, count: sampleCount)
    var outR = [Float](repeating: 0, count: sampleCount)
    var outI = [Float](repeating: 0, count: sampleCount)
    var smooth = [Float](repeating: 0, count: spectrumBinCount)
    var ranges = [(Float, Float)]()
    init() {
        vDSP_hann_window(&window, vDSP_Length(sampleCount), Int32(vDSP_HANN_NORM))
        for i in 0..<spectrumBinCount {
            let low = Float(20 * pow(1000, Double(i)/Double(spectrumBinCount))) / (48000 / Float(sampleCount))
            let high = Float(20 * pow(1000, Double(i+1)/Double(spectrumBinCount))) / (48000 / Float(sampleCount))
            ranges.append((low,high))
        }
    }
    deinit { vDSP_DFT_DestroySetup(setup) }
    func spectrum(_ input: [Float]) -> [Float] {
        vDSP_vmul(input, 1, window, 1, &real, 1, vDSP_Length(sampleCount))
        vDSP_DFT_Execute(setup, &real, &imag, &outR, &outI)
        for i in 0..<spectrumBinCount {
            let (lo,hi) = ranges[i]
            let low = max(1,Int(lo)), high = min(sampleCount/2-1,max(low,Int(hi)))
            var magnitude: Float = 0
            if hi-lo < 1 {
                let middle = (lo+hi)*0.5
                let k = min(sampleCount/2-2,max(1,Int(middle)))
                let fraction = middle-Float(k)
                magnitude = hypot(outR[k],outI[k])*(1-fraction) + hypot(outR[k+1],outI[k+1])*fraction
            } else {
                for k in low...high { magnitude = max(magnitude,hypot(outR[k],outI[k])) }
            }
            // Hann coherent gain is 0.5; scale the one-sided spectrum to amplitude.
            magnitude *= 4 / Float(sampleCount)
            let normalized = max(0,min(1,(20*log10(max(magnitude,0.00001))+80)/80))
            smooth[i] += (normalized-smooth[i]) * (normalized > smooth[i] ? 0.7 : 0.15)
        }
        return smooth
    }
}
final class BeatGradient {
    var hue: Float = 0.55
    var pulse: Float = 0
    private var baseline: Float = 0
    private var previous: Float = 0
    private var lastBeat: Double = -100
    func update(energy: Float,elapsed: Double,time: Double) {
        let dt = Float(max(0,min(0.1,elapsed)))
        pulse *= exp(-dt/0.18)
        if baseline == 0 { baseline = energy }
        // Bass onsets, with a short refractory period to avoid repeated flashes.
        if energy > 0.000001 && energy > baseline*1.5 && energy > previous*1.04 && time-lastBeat > 0.18 {
            pulse = 1; lastBeat = time
        }
        baseline += (energy-baseline)*(1-exp(-dt/0.8))
        previous = energy
        hue = (hue+dt*(0.012+0.018*pulse)).truncatingRemainder(dividingBy: 1)
    }
}
// Two centered box passes form a triangular display filter without phase shift.
// This filters only the waveform geometry; captured audio and FFT remain raw.
func smoothWaveform(_ samples: [Float], amount: Double) -> [Float] {
    guard amount > 0, !samples.isEmpty else { return samples }
    let radius = max(1,Int((amount/100)*(amount/100)*32))
    func box(_ input: [Float]) -> [Float] {
        var prefix = [Float](repeating: 0,count: input.count+1)
        for i in input.indices { prefix[i+1] = prefix[i]+input[i] }
        return input.indices.map { i in
            let low = max(0,i-radius), high = min(input.count,i+radius+1)
            return (prefix[high]-prefix[low])/Float(high-low)
        }
    }
    let filtered = box(box(samples))
    let blend = Float(min(1,amount/10))
    return zip(samples,filtered).map { $0+( $1-$0)*blend }
}
// Analytic-signal quadrature turns a tone into an orbit, without an arbitrary delay.
final class StereoOrbit {
    let forward = vDSP_DFT_zop_CreateSetup(nil,vDSP_Length(scopeSampleCount),.FORWARD)!
    let inverse = vDSP_DFT_zop_CreateSetup(nil,vDSP_Length(scopeSampleCount),.INVERSE)!
    var zero = [Float](repeating: 0,count: scopeSampleCount)
    var real = [Float](repeating: 0,count: scopeSampleCount)
    var imag = [Float](repeating: 0,count: scopeSampleCount)
    var outReal = [Float](repeating: 0,count: scopeSampleCount)
    var outImag = [Float](repeating: 0,count: scopeSampleCount)
    deinit { vDSP_DFT_DestroySetup(forward); vDSP_DFT_DestroySetup(inverse) }
    func points(left: [Float],right: [Float],amount: Float) -> [SIMD2<Float>] {
        if amount > 0 {
            vDSP_DFT_Execute(forward,left,zero,&real,&imag)
            for k in 1..<scopeSampleCount/2 { real[k] *= 2; imag[k] *= 2 }
            for k in (scopeSampleCount/2+1)..<scopeSampleCount { real[k] = 0; imag[k] = 0 }
            vDSP_DFT_Execute(inverse,real,imag,&outReal,&outImag)
        }
        return stride(from: 64,to: scopeSampleCount-64,by: 8).map { i in
            let orbitY = amount > 0 ? outImag[i]/Float(scopeSampleCount) : right[i]
            let y = right[i]*(1-amount)+orbitY*amount
            return SIMD2(left[i]*1.6,y*1.6)
        }
    }
}
final class App: NSObject, NSApplicationDelegate {
    let audio = AudioStore()
    lazy var capture = Capture(audio)
    let renderer: Renderer
    let analysis = SignalAnalysis()
    let orbit = StereoOrbit()
    var window: NSWindow!
    var canvas: MetalCanvas!
    let status = NSTextField(labelWithString: "Ready · Play audio, then click Capture system audio")
    let metrics = NSTextField(labelWithString: "")
    let start = NSButton(title: "Capture system audio", target: nil, action: nil)
    let mode = NSPopUpButton(), panel = NSPopUpButton()
    let smoothing = NSSlider(value: 0,minValue: 0,maxValue: 100,target: nil,action: nil)
    let smoothingValue = NSTextField(labelWithString: "0%")
    let circularity = NSSlider(value: 0,minValue: 0,maxValue: 100,target: nil,action: nil)
    let circularityValue = NSTextField(labelWithString: "0%")
    let demo = NSButton(checkboxWithTitle: "Demo", target: nil, action: nil)
    var timer: Timer?, telemetry: Timer?
    var busy = false, capturing = false
    var lastCount = 0, lastTime = CACurrentMediaTime()
    var spectrum = [Float](repeating: 0, count: spectrumBinCount), lastFFT: Double = 0
    let beatGradient = BeatGradient()
    let inFlight = DispatchSemaphore(value: 3)
    init(renderer: Renderer) { self.renderer = renderer }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(); let root = NSMenuItem(); menu.addItem(root)
        let sub = NSMenu(); sub.addItem(withTitle: "Quit Amp Visualizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); root.submenu = sub; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1100,height: 720), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Amp Visualizer"; window.minSize = NSSize(width: 820,height: 480)
        window.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 1)
        canvas = MetalCanvas(device: renderer.device)
        mode.addItems(withTitles: ["Waveform", "Stereo phase", "Spectrum"])
        mode.target = self; mode.action = #selector(changeMode)
        smoothing.doubleValue = UserDefaults.standard.double(forKey: "waveformSmoothing")
        smoothing.isContinuous = true
        smoothing.target = self; smoothing.action = #selector(changeSmoothing)
        smoothing.toolTip = "0% keeps the raw waveform; higher values soften fine detail. Only affects the displayed waveform."
        smoothing.setAccessibilityLabel("Waveform smoothing")
        smoothing.widthAnchor.constraint(equalToConstant: 180).isActive = true
        smoothingValue.widthAnchor.constraint(equalToConstant: 38).isActive = true
        changeSmoothing()
        circularity.doubleValue = UserDefaults.standard.double(forKey: "stereoCircularity")
        circularity.isContinuous = true
        circularity.target = self; circularity.action = #selector(changeCircularity)
        circularity.setAccessibilityLabel("Stereo circularity")
        circularity.toolTip = "0% shows stereo phase at 2× zoom. Higher values blend toward an audio-driven circular orbit; this is a visual effect."
        circularity.widthAnchor.constraint(equalToConstant: 150).isActive = true
        circularityValue.widthAnchor.constraint(equalToConstant: 38).isActive = true
        changeCircularity()
        changeMode()
        panel.addItems(withTitles: ["HUB75 · 32×32", "HUB75 · 64×64", "HUB75 · 128×128"])
        panel.selectItem(at: 1)
        panel.toolTip = "Square pixels · HDR adapts to your display"
        start.target = self; start.action = #selector(toggleCapture)
        let title = NSTextField(labelWithString: "AMP / SIGNAL LAB"); title.font = .monospacedSystemFont(ofSize: 18, weight: .bold)
        let controls = NSStackView(views: [title, start, mode, demo]); controls.spacing = 14
        let panelLabel = NSTextField(labelWithString: "Display preview")
        let panelHint = NSTextField(labelWithString: "Square pixels · HDR auto")
        panelHint.textColor = .secondaryLabelColor
        let panelControls = NSStackView(views: [panelLabel,panel,panelHint]); panelControls.spacing = 12
        let smoothingLabel = NSTextField(labelWithString: "Waveform smoothing")
        let smoothingControls = NSStackView(views: [smoothingLabel,smoothing,smoothingValue,NSTextField(labelWithString: "Circularity"),circularity,circularityValue]); smoothingControls.spacing = 12
        let footer = NSStackView(views: [status,metrics]); footer.distribution = .fill; footer.spacing = 16
        status.font = .monospacedSystemFont(ofSize: 11,weight: .regular); metrics.font = status.font
        status.lineBreakMode = .byTruncatingTail
        let content = NSView(); window.contentView = content
        for v in [controls,panelControls,smoothingControls,canvas!,footer] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor,constant: 16),controls.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 18),
            panelControls.topAnchor.constraint(equalTo: controls.bottomAnchor,constant: 10),panelControls.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 18),
            smoothingControls.topAnchor.constraint(equalTo: panelControls.bottomAnchor,constant: 10),smoothingControls.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 18),
            canvas.topAnchor.constraint(equalTo: smoothingControls.bottomAnchor,constant: 10),canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: canvas.bottomAnchor,constant: 12),footer.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 18),footer.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -18),footer.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant: -12)
        ])
        capture.status = { [weak self] message in self?.capturing = false; self?.start.title = "Capture system audio"; self?.status.stringValue = message }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        changeRate()
        telemetry = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateMetrics() }
        if CommandLine.arguments.contains("--demo") { demo.state = .on }
    }
    @objc func changeSmoothing() {
        smoothingValue.stringValue = "\(Int(smoothing.doubleValue.rounded()))%"
        UserDefaults.standard.set(smoothing.doubleValue,forKey: "waveformSmoothing")
    }
    @objc func changeCircularity() {
        circularityValue.stringValue = "\(Int(circularity.doubleValue.rounded()))%"
        UserDefaults.standard.set(circularity.doubleValue,forKey: "stereoCircularity")
    }
    @objc func changeMode() {
        lastFFT = 0
        circularity.isEnabled = mode.indexOfSelectedItem == 1
        circularityValue.textColor = circularity.isEnabled ? .labelColor : .disabledControlTextColor
        smoothing.isEnabled = mode.indexOfSelectedItem == 0
        smoothingValue.textColor = smoothing.isEnabled ? .labelColor : .disabledControlTextColor
    }
    @objc func toggleCapture() {
        guard !busy else { return }; busy = true; start.isEnabled = false
        Task { @MainActor in
            if capturing { await capture.stop(); capturing = false; start.title = "Capture system audio"; status.stringValue = "Capture stopped" }
            else {
                status.stringValue = "Select a display or audio app in the macOS sharing picker…"
                do { try await capture.start(); capturing = true; demo.state = .off; start.title = "Stop capture"; status.stringValue = "System audio · 48 kHz stereo" }
                catch is CancellationError { status.stringValue = "Selection cancelled · click Capture system audio to retry" }
                catch {
                    status.stringValue = "Capture unavailable · check Privacy & Security → Screen & System Audio Recording"
                    let alert = NSAlert(); alert.messageText = "System audio capture could not start"
                    alert.informativeText = "\(error.localizedDescription)\n\nAllow Amp Visualizer in System Settings → Privacy & Security → Screen & System Audio Recording. If macOS requests it, quit and reopen the app, then retry."
                    alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Open Settings")
                    if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
                }
            }
            busy = false; start.isEnabled = true
        }
    }
    @objc func changeRate() {
        timer?.invalidate()
        let fps = 400.0
        timer = Timer(timeInterval: 1/fps, repeats: true) { [weak self] _ in self?.draw() }
        timer!.tolerance = 0.0001; RunLoop.main.add(timer!, forMode: .common)
    }
    func samples() -> ([Float],[Float],Bool) {
        if demo.state == .on {
            let t = CACurrentMediaTime()
            let l = (0..<sampleCount).map { Float(sin(Double($0)*0.043 + t*3)*0.55 + sin(Double($0)*0.107-t)*0.18) }
            let r = (0..<sampleCount).map { Float(sin(Double($0)*0.043+t*3+0.8)*0.6) }
            return (l,r,true)
        }
        return audio.snapshot()
    }
    func draw() {
        guard window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible), inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = canvas.metal.nextDrawable() else { inFlight.signal(); return }
        let (historyL,historyR,_) = samples()
        let l = Array(historyL.suffix(scopeSampleCount)), r = Array(historyR.suffix(scopeSampleCount))
        let panelSize = [32,64,128][panel.indexOfSelectedItem]
        var points = [SIMD2<Float>](); points.reserveCapacity(1024)
        switch mode.indexOfSelectedItem {
        case 1:
            points = orbit.points(left: l,right: r,amount: Float(circularity.doubleValue/100))
        case 2:
            let now = CACurrentMediaTime()
            if now-lastFFT > 1/120 {
                let elapsed = lastFFT == 0 ? 0 : now-lastFFT
                spectrum = analysis.spectrum(historyL); lastFFT = now
                // Recover approximate power from the dB-scaled 20–180 Hz bins.
                let bass = spectrum.prefix(163).reduce(Float(0)) { sum,level in
                    sum+pow(10,(level*80-80)/10)
                }/163
                beatGradient.update(energy: bass,elapsed: elapsed,time: now)
            }
            let bars = panelSize > 0 ? panelSize-4 : spectrumBinCount
            for i in 0..<bars {
                let low = i*spectrumBinCount/bars, high = (i+1)*spectrumBinCount/bars
                let level = spectrum[low..<high].max() ?? 0
                let x: Float = panelSize > 0 ? (Float(i+2)+0.5)/Float(panelSize)*2-1 : Float(i)/Float(bars-1)*1.8-0.9
                points.append(SIMD2(x,-0.8)); points.append(SIMD2(x,level*1.6-0.8))
            }
        default:
            let waveform = smoothWaveform(l,amount: smoothing.doubleValue)
            // Trigger the scope near a rising zero crossing to reduce horizontal jitter.
            var offset = 0
            for i in 1..<1024 { if waveform[i-1] <= 0 && waveform[i] > 0 { offset = i; break } }
            for i in 0..<256 { points.append(SIMD2(Float(i)/255*1.85-0.925,waveform[min(scopeSampleCount-1,offset+i*4)]*0.8)) }
        }
        renderer.render(points: points, texture: drawable.texture, drawable: drawable, dots: false, independent: mode.indexOfSelectedItem == 2, panelSize: panelSize, hdrHeadroom: Float(window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1), palette: SIMD2(beatGradient.hue,beatGradient.pulse)) { [inFlight] in inFlight.signal() }
    }
    func updateMetrics() {
        let now = CACurrentMediaTime(), count = renderer.frameCount()
        let fps = Double(count-lastCount)/(now-lastTime); lastCount = count; lastTime = now
        let (l,_,live) = samples()
        let rms = sqrt(l.reduce(Float(0)) { $0+$1*$1 }/Float(sampleCount))
        metrics.stringValue = String(format: "%.0f FPS · %.1f dBFS",fps,20*log10(max(rms,0.000001)))
        if demo.state == .on { status.stringValue = "DEMO · synthetic stereo signal" }
        else if capturing { status.stringValue = live ? "System audio · 48 kHz stereo" : "Listening · play audio in another app" }
        else if status.stringValue.hasPrefix("DEMO") { status.stringValue = "Ready · click Capture system audio" }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

do {
    let renderer = try Renderer()
    let app = NSApplication.shared
    let delegate = App(renderer: renderer)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
} catch { fputs("Amp Visualizer: \(error)\n",stderr); exit(1) }
