//
//  ContentView.swift
//  WS2812
//
//  Created by isaac on 12/15/25.
//

import SwiftUI
import Combine
import CoreBluetooth

private let serviceUUID = CBUUID(string: "21436587-A9CB-ED0F-1032-547698BADCFE")
private let commandCharacteristicUUID = CBUUID(string: "0C1D2E3F-4051-6273-8495-A6B7C8D9EAFB")
private let maxLights = 300
private let frameCommandId: UInt8 = 0xA0
private let rainbowCommandId: UInt8 = 0xA1
private let bleDeviceName = "PSL"
private let bleShortName = "PSL"

final class BLEManager: NSObject, ObservableObject {
    @Published var status: String = "scanning"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var serviceDiscoveryAttempts = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func sendPacket(_ data: Data) {
        guard let peripheral = peripheral,
              let characteristic = commandCharacteristic else {
            status = "waiting for Peripheral"
            return
        }
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            central.scanForPeripherals(withServices: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        status = "disconnected"
        self.peripheral = nil
        commandCharacteristic = nil
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
            return
        }
    }
}

struct ContentView: View {
    @StateObject private var bleManager = BLEManager()
    @State private var hue: Double = 25
    @State private var brightness: Double = 15
    @State private var segmentWidth = maxLights
    @State private var segmentCenter = (maxLights / 2) + 1
    @State private var segmentStart = 1
    @State private var segmentEnd = maxLights
    @State private var rainbowEnabled = false
    @State private var rainbowPhase: Double = 0
    @State private var rainbowTimer: AnyCancellable?
    @State private var lastRainbowTimestamp: TimeInterval = 0
    private let rainbowLength: Double = 300
    private let rainbowCycleRate: Double = 0.1

    var body: some View {
        VStack(spacing: 24) {
            Text(bleManager.status)
                .font(.headline)

            VStack(spacing: 8) {
                Text(String(format: "Hue: %.0f°", hue))
                Text(String(format: "Brightness: %.0f%%", brightness))
                Text("Segment: \(segmentStart) … \(segmentEnd)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Toggle("Rainbow Mode", isOn: $rainbowEnabled)
                .onChange(of: rainbowEnabled) { _, newValue in
                    if newValue {
                        startRainbowTimer()
                        sendRainbowFrame()
                    } else {
                        stopRainbowTimer()
                        sendFrame()
                    }
                }
                .padding(.horizontal)

            if !rainbowEnabled {
                sliderView(
                    title: "Hue",
                    value: $hue,
                    range: 0...360,
                    format: "%.0f°",
                    onChange: { _ in sendFrame() }
                )
            }

            sliderView(
                title: "Brightness",
                value: $brightness,
                range: 0...100,
                format: "%.0f%%",
                onChange: { _ in sendFrame() }
            )

            sliderView(
                title: "Segment Center",
                value: Binding(
                    get: { Double(segmentCenter) },
                    set: { updateSegmentCenter(Int($0.rounded())) }
                ),
                range: 1...Double(maxLights),
                format: "%.0f",
                onChange: { _ in }
            )

            sliderView(
                title: "Segment Width",
                value: Binding(
                    get: { Double(segmentWidth) },
                    set: { updateSegmentWidth(Int($0.rounded())) }
                ),
                range: 1...Double(maxLights),
                format: "%.0f",
                onChange: { _ in }
            )

            Button("Send All Settings", action: sendFrame)
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding()
        .onAppear(perform: startRainbowTimerIfNeeded)
        .onDisappear(perform: stopRainbowTimer)
    }

    private func sliderView(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title): \(String(format: format, value.wrappedValue))")
                .fontWeight(.semibold)
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _, newValue in
                    onChange(newValue)
                }
        }
        .padding(.horizontal)
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

    private func startRainbowTimerIfNeeded() {
        if rainbowEnabled {
            startRainbowTimer()
        }
    }

    private func startRainbowTimer() {
        stopRainbowTimer()
        resetRainbowTimestamp()
        rainbowTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                tickRainbowPhase()
            }
    }

    private func stopRainbowTimer() {
        rainbowTimer?.cancel()
        rainbowTimer = nil
    }

    private func resetRainbowTimestamp() {
        lastRainbowTimestamp = ProcessInfo.processInfo.systemUptime
    }

    private func tickRainbowPhase() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = max(0, now - lastRainbowTimestamp)
        lastRainbowTimestamp = now
        guard delta > 0 else {
            sendRainbowFrame()
            return
        }
        let nextPhase = rainbowPhase + delta * rainbowCycleRate
        rainbowPhase = nextPhase - floor(nextPhase)
        sendRainbowFrame()
    }

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

#Preview {
    ContentView()
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
