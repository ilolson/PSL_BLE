import Foundation
import CoreBluetooth

private let serviceUUID = CBUUID(string: "21436587-A9CB-ED0F-1032-547698BADCFE")
private let commandCharacteristicUUID = CBUUID(string: "0C1D2E3F-4051-6273-8495-A6B7C8D9EAFB")
private let maxLights = 300
private let frameCommandId: UInt8 = 0xA0
private let rainbowCommandId: UInt8 = 0xA1
private let bleDeviceName = "PSL"
private let bleShortName = "PSL"

final class BLEManager: NSObject {
    var status: String = "scanning" { didSet { if status != oldValue { print("BLE: \(status)") } } }
    var onReady: (() -> Void)?
    private var pending: Data?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var serviceDiscoveryAttempts = 0

    init(start: Bool = true) {
        super.init()
        if start { central = CBCentralManager(delegate: self, queue: nil) }
    }

    func sendPacket(_ data: Data) {
        guard peripheral != nil, commandCharacteristic != nil else {
            status = "waiting for Peripheral"
            return
        }
        pending = data
        flush()
    }

    private func flush() {
        guard let data = pending, let peripheral, let characteristic = commandCharacteristic else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        guard data.count <= peripheral.maximumWriteValueLength(for: type) else {
            pending = nil
            status = "frame exceeds BLE write limit (\(data.count) bytes); reduce segment width or use solid mode"
            return
        }
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
        if type == .withResponse && writing { return }
        pending = nil
        writing = type == .withResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }
    private var writing = false
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { flush() }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        if let error { status = "write failed: \(error.localizedDescription)" }
        flush()
    }

    func sendCommand(_ text: String) {
        sendPacket(Data(text.utf8))
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = "scanning..."
            central.scanForPeripherals(withServices: nil)
        default:
            status = "Bluetooth unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let displayName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "device"
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard displayName == bleDeviceName || displayName == bleShortName || serviceUUIDs.contains(serviceUUID) else {
            return
        }

        status = "connecting to \(displayName)"
        self.peripheral = peripheral
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "discovering services"
        serviceDiscoveryAttempts = 0
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "connection failed"
        self.peripheral = nil
        commandCharacteristic = nil
        writing = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            central.scanForPeripherals(withServices: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        status = "disconnected"
        self.peripheral = nil
        commandCharacteristic = nil
        writing = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            central.scanForPeripherals(withServices: nil)
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = "service discovery error: \(error.localizedDescription)"
            scheduleServiceDiscovery(peripheral)
            return
        }
        guard let services = peripheral.services else {
            status = "service discovery returned empty list"
            scheduleServiceDiscovery(peripheral)
            return
        }
        status = "services: \(services.map(\.uuid.uuidString).joined(separator: ","))"
        if let service = services.first(where: { $0.uuid == serviceUUID }) {
            peripheral.discoverCharacteristics([commandCharacteristicUUID], for: service)
            return
        }
        scheduleServiceDiscovery(peripheral)
    }

    private func scheduleServiceDiscovery(_ peripheral: CBPeripheral) {
        serviceDiscoveryAttempts += 1
        guard serviceDiscoveryAttempts <= 5 else {
            status = "service not found"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            peripheral.discoverServices(nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == commandCharacteristicUUID {
            commandCharacteristic = characteristic
            status = "connected"
            writing = false
            onReady?()
            return
        }
    }
}

final class LightController {
    let bleManager: BLEManager
    var hue: Double = 25
    var brightness: Double = 15
    var segmentWidth = maxLights
    var segmentCenter = maxLights / 2 + 1
    var segmentStart = 1
    var segmentEnd = maxLights
    var rainbowEnabled = false
    var rainbowPhase: Double = 0
    var rainbowTimer: Timer?
    var lastRainbowTimestamp: TimeInterval = 0
    let rainbowLength: Double = 300
    let rainbowCycleRate: Double = 0.1
    init(_ ble: BLEManager) { bleManager = ble; ble.onReady = { [weak self] in self?.sendFrame() } }
    static let help = """
    hue <0–360>          Set solid hue in degrees
    brightness <0–100>   Set brightness percent
    center <1–300>       Move segment (clamped to fit its width)
    width <1–300>        Set segment width
    rainbow on|off       Animate at 30 Hz, one cycle per 10 seconds
    send                Send all current settings
    off                 Set brightness to zero
    status              Show connection and settings
    help                Show commands
    quit                Exit (lights keep their last frame)
    """
    func summary() {
        print("\(bleManager.status) · Hue \(hue)° · Brightness \(brightness)% · Segment \(segmentStart)…\(segmentEnd) · Center \(segmentCenter) · Width \(segmentWidth) · Rainbow \(rainbowEnabled ? "on" : "off")")
    }
    func command(_ line: String) {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let name = parts.first?.lowercased() else { return }
        switch name {
        case "quit", "exit": stopRainbowTimer(); exit(0)
        case "help" where parts.count == 1: print(Self.help)
        case "status" where parts.count == 1: summary()
        case "send" where parts.count == 1: sendFrame()
        case "off" where parts.count == 1: brightness = 0; sendFrame(); summary()
        case "rainbow" where parts.count == 2 && ["on", "off"].contains(parts[1].lowercased()):
            rainbowEnabled = parts[1].lowercased() == "on"
            if rainbowEnabled { startRainbowTimer() } else { stopRainbowTimer() }
            sendFrame(); summary()
        case "hue", "brightness", "center", "width":
            guard parts.count == 2, let value = Double(parts[1]), value.isFinite else { print("Expected a finite numeric value. Type help."); return }
            let range: ClosedRange<Double> = name == "hue" ? 0...360 : (name == "brightness" ? 0...100 : 1...300)
            guard range.contains(value), (name != "center" && name != "width") || value.rounded() == value else { print("Value must be in \(range); center and width require integers."); return }
            switch name {
            case "hue": hue = value; sendFrame()
            case "brightness": brightness = value; sendFrame()
            case "center": updateSegmentCenter(Int(value))
            default: updateSegmentWidth(Int(value))
            }
            summary()
        default: print("Unknown command or arguments. Type help.")
        }
    }
    private func sendFrame() {
        if rainbowEnabled {
            sendRainbowFrame()
            return
        }
        guard let payload = currentFramePayload() else { return }
        bleManager.sendPacket(payload)
    }

    private func updateSegmentCenter(_ value: Int) {
        segmentCenter = clampCenter(value, forWidth: segmentWidth)
        applySegmentBounds()
    }

    private func updateSegmentWidth(_ value: Int) {
        let clampedWidth = max(1, min(value, maxLights))
        segmentWidth = clampedWidth
        segmentCenter = clampCenter(segmentCenter, forWidth: clampedWidth)
        applySegmentBounds()
    }

    private func clampCenter(_ center: Int, forWidth width: Int) -> Int {
        let halfWidth = width / 2
        let minCenter = halfWidth + 1
        let tailWidth = width - halfWidth - 1
        let maxCenter = maxLights - tailWidth
        return min(max(center, minCenter), maxCenter)
    }

    private func applySegmentBounds(sendFrameUpdate: Bool = true) {
        let halfWidth = segmentWidth / 2
        let newStart = max(1, segmentCenter - halfWidth)
        let newEnd = min(maxLights, newStart + segmentWidth - 1)
        var updated = false

        if newStart != segmentStart {
            segmentStart = newStart
            updated = true
        }

        if newEnd != segmentEnd {
            segmentEnd = newEnd
            updated = true
        }

        if sendFrameUpdate && updated {
            sendFrame()
        }
    }

    private func currentFramePayload() -> Data? {
        let runs = buildCurrentRuns()
        guard !runs.isEmpty else { return nil }
        return LEDFrame(runs: runs).dataPayload()
    }

    private func sendRainbowFrame() {
        guard let payload = rainbowPayload() else { return }
        bleManager.sendPacket(payload)
    }

    private func rainbowPayload() -> Data? {
        let runs = buildRainbowRuns()
        guard !runs.isEmpty else { return nil }
        return LEDFrame(runs: runs).dataPayload()
    }

    private func buildCurrentRuns() -> [LEDFrameRun] {
        guard maxLights > 0 else { return [] }
        let clampedStart = max(1, min(segmentStart, maxLights))
        let clampedEnd = max(clampedStart, min(segmentEnd, maxLights))
        var runs: [LEDFrameRun] = []

        var cursor = UInt16(0)
        if clampedStart > 1 {
            let leadingLength = UInt16(clampedStart - 1)
            runs.append(LEDFrameRun(start: cursor, length: leadingLength, color: .off))
            cursor &+= leadingLength
        }

        let length = UInt16(clampedEnd - clampedStart + 1)
        runs.append(LEDFrameRun(start: cursor, length: length, color: currentActiveColor()))
        cursor &+= length

        if clampedEnd < maxLights {
            let trailingLength = UInt16(maxLights - clampedEnd)
            runs.append(LEDFrameRun(start: cursor, length: trailingLength, color: .off))
        }

        return runs
    }

    private func buildRainbowRuns() -> [LEDFrameRun] {
        guard maxLights > 0 else { return [] }
        let clampedStart = max(1, min(segmentStart, maxLights))
        let clampedEnd = max(clampedStart, min(segmentEnd, maxLights))
        var runs: [LEDFrameRun] = []
        var cursor = UInt16(0)

        if clampedStart > 1 {
            let leadingLength = UInt16(clampedStart - 1)
            runs.append(LEDFrameRun(start: cursor, length: leadingLength, color: .off))
            cursor &+= leadingLength
        }

        let activeLength = UInt16(clampedEnd - clampedStart + 1)
        if activeLength > 0 {
            let gradientRuns = rainbowGradientRuns(length: activeLength, offset: cursor)
            runs.append(contentsOf: gradientRuns)
            cursor &+= activeLength
        }

        if clampedEnd < maxLights {
            let trailingLength = UInt16(maxLights - clampedEnd)
            runs.append(LEDFrameRun(start: cursor, length: trailingLength, color: .off))
        }

        return runs
    }

    private func rainbowGradientRuns(length: UInt16, offset: UInt16) -> [LEDFrameRun] {
        let activeLength = Int(length)
        guard activeLength > 0 else { return [] }
        let maxRainbowRuns = 50
        let runCount = max(1, min(activeLength, maxRainbowRuns))
        var remaining = activeLength
        var consumed = 0
        var gradientRuns: [LEDFrameRun] = []

        for index in 0..<runCount {
            let bucketsLeft = runCount - index
            var chunkLength = max(1, remaining / bucketsLeft)
            if index == runCount - 1 {
                chunkLength = remaining
            }
            let chunkStart = consumed
            consumed += chunkLength
            remaining -= chunkLength

            let midpoint = Double(chunkStart) + Double(chunkLength) / 2.0
            let cyclePosition = (midpoint / max(1.0, rainbowLength)) + rainbowPhase
            let hue = (cyclePosition.truncatingRemainder(dividingBy: 1.0) + 1.0)
                .truncatingRemainder(dividingBy: 1.0) * 360.0
            let color = hsvToRGB(
                hue: hue,
                saturation: 1.0,
                value: max(0.0, min(1.0, brightness / 100.0))
            )
            gradientRuns.append(
                LEDFrameRun(
                    start: offset &+ UInt16(chunkStart),
                    length: UInt16(chunkLength),
                    color: color
                )
            )
        }

        return gradientRuns
    }

    private func startRainbowTimer() {
        stopRainbowTimer()
        lastRainbowTimestamp = ProcessInfo.processInfo.systemUptime
        rainbowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let delta = max(0, now - self.lastRainbowTimestamp)
            self.lastRainbowTimestamp = now
            self.rainbowPhase = (self.rainbowPhase + delta * self.rainbowCycleRate).truncatingRemainder(dividingBy: 1)
            self.sendRainbowFrame()
        }
    }
    private func stopRainbowTimer() { rainbowTimer?.invalidate(); rainbowTimer = nil }

    private func currentActiveColor() -> LEDColor {
        let normalizedBrightness = max(0.0, min(1.0, brightness / 100.0))
        return hsvToRGB(hue: hue, saturation: 1.0, value: normalizedBrightness)
    }

    private func hsvToRGB(hue: Double, saturation: Double, value: Double) -> LEDColor {
        let normalizedHue = (hue.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)
        let s = max(0.0, min(1.0, saturation))
        let v = max(0.0, min(1.0, value))
        let c = v * s
        let huePrime = normalizedHue / 60.0
        let x = c * (1.0 - abs(huePrime.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = v - c

        let rgbPrime: (Double, Double, Double)
        switch huePrime {
        case 0..<1:
            rgbPrime = (c, x, 0)
        case 1..<2:
            rgbPrime = (x, c, 0)
        case 2..<3:
            rgbPrime = (0, c, x)
        case 3..<4:
            rgbPrime = (0, x, c)
        case 4..<5:
            rgbPrime = (x, 0, c)
        default:
            rgbPrime = (c, 0, x)
        }

        func byte(_ value: Double) -> UInt8 {
            UInt8(clamping: Int(((value + m) * 255.0).rounded()))
        }

        return LEDColor(red: byte(rgbPrime.0), green: byte(rgbPrime.1), blue: byte(rgbPrime.2))
    }
}

private struct LEDColor {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let off = LEDColor(red: 0, green: 0, blue: 0)
}

private struct LEDFrameRun {
    let start: UInt16
    let length: UInt16
    let color: LEDColor
}

private struct LEDFrame {
    let runs: [LEDFrameRun]

    func dataPayload() -> Data? {
        guard !runs.isEmpty, runs.count <= Int(UInt8.max) else { return nil }
        var payload = Data()
        payload.append(frameCommandId)
        payload.append(1)
        payload.append(UInt8(runs.count))

        for run in runs {
            payload.append(contentsOf: run.start.littleEndianBytes)
            payload.append(contentsOf: run.length.littleEndianBytes)
            payload.append(run.color.red)
            payload.append(run.color.green)
            payload.append(run.color.blue)
        }

        return payload
    }
}

private extension UInt16 {
    var littleEndianBytes: [UInt8] {
        let value = self.littleEndian
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }
}

extension LightController {
    static func verify() {
        let controller = LightController(BLEManager(start: false))
        let full = controller.currentFramePayload()!
        precondition(full == Data([0xA0, 1, 1, 0, 0, 44, 1, 38, 16, 0]))
        controller.updateSegmentWidth(10)
        controller.updateSegmentCenter(1)
        precondition(controller.segmentStart == 1 && controller.segmentEnd == 10)
        controller.updateSegmentCenter(300)
        precondition(controller.segmentStart == 291 && controller.segmentEnd == 300)
        let runs = controller.buildRainbowRuns()
        precondition(runs.reduce(0) { $0 + Int($1.length) } == 300)
        precondition(runs.count == 11 && runs.first!.color.red == 0)
        controller.updateSegmentWidth(300)
        precondition(controller.buildRainbowRuns().count == 50)
        precondition(controller.rainbowPayload()!.count == 353)
        controller.brightness = 0
        precondition(controller.buildRainbowRuns().allSatisfy { $0.color.red == 0 && $0.color.green == 0 && $0.color.blue == 0 })
        print("Passed: Xcode default packet, segment clamping, rainbow coverage/encoding, and off brightness.")
    }
}
if CommandLine.arguments.contains("--self-test") {
    LightController.verify()
    exit(0)
}
if CommandLine.arguments.contains("--help") {
    print("Amp Visualizer terminal light controller\n" + LightController.help)
    exit(0)
}
print("Amp Visualizer · PSL terminal light controller\n" + LightController.help)
let ble = BLEManager()
let controller = LightController(ble)
DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine() {
        DispatchQueue.main.async { controller.command(line) }
    }
    DispatchQueue.main.async { exit(0) }
}
RunLoop.main.run()
