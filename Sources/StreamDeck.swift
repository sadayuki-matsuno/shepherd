// StreamDeck — a tiny IOKit-HID driver for the 15-key "Gen2" Elgato Stream Decks
// (Stream Deck MK.2 and Original V2). No external dependencies; talks to the device
// directly over USB HID, the same protocol python-elgato-streamdeck implements.
//
// Only what Shepherd needs: enumerate/open one device, reset, set brightness, push a
// per-key JPEG, and report key presses. Rendering lives in the app (main.swift) so the
// deck reuses the same status colours / ordering as the HUD.
import AppKit
import IOKit
import IOKit.hid

final class StreamDeck {
    // MARK: Protocol constants (Stream Deck MK.2 / Original V2)
    static let vendorElgato = 0x0fd9
    static let productIDs = [0x0080, 0x006d, 0x00a5, 0x00b9]  // MK.2, Original V2, MK.2 scissor, MK.2 module/V2

    static let keyCount = deckKeyCount   // defined in Models.swift (15) — shared with the layout logic
    static let keyPixels = 72
    private static let imageReportLength = 1024
    private static let imageHeaderLength = 8
    private static let imagePayloadLength = imageReportLength - imageHeaderLength

    private let device: IOHIDDevice
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var keyStates = [Bool](repeating: false, count: keyCount)
    var onKey: ((_ key: Int, _ pressed: Bool) -> Void)?

    private init(device: IOHIDDevice) {
        self.device = device
    }

    // MARK: Open

    /// Is any supported Stream Deck attached? Enumerates without opening (cheap, and
    /// won't seize the device), so it's safe to poll when building the menu.
    static func isPresent() -> Bool {
        for pid in productIDs {
            guard let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary? else { continue }
            matching[kIOHIDVendorIDKey] = vendorElgato
            matching[kIOHIDProductIDKey] = pid
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { continue }
            var present = false
            var service = IOIteratorNext(iter)
            while service != 0 { present = true; IOObjectRelease(service); service = IOIteratorNext(iter) }
            IOObjectRelease(iter)
            if present { return true }
        }
        return false
    }

    /// Open the first matching Stream Deck (or the one whose serial matches `serial`).
    /// Returns nil if no matching device is present or it can't be opened.
    static func open(serial: String?) -> StreamDeck? {
        var candidates: [IOHIDDevice] = []
        for pid in productIDs {
            guard let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary? else { continue }
            matching[kIOHIDVendorIDKey] = vendorElgato
            matching[kIOHIDProductIDKey] = pid
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { continue }
            var service = IOIteratorNext(iter)
            while service != 0 {
                if let dev = IOHIDDeviceCreate(kCFAllocatorDefault, service) { candidates.append(dev) }
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }
        guard !candidates.isEmpty else { return nil }

        // Probe each candidate: seize it and send a reset. A device that's wedged (e.g.
        // left in a bad USB state) fails the reset — skip it and try the next one, so a
        // healthy deck is chosen even when another is stuck.
        let ordered: [IOHIDDevice]
        if let serial = serial, !serial.isEmpty {
            ordered = candidates.filter { (IOHIDDeviceGetProperty($0, kIOHIDSerialNumberKey as CFString) as? String) == serial }
        } else {
            ordered = candidates
        }
        for dev in ordered {
            // Seize (exclusive) — matches hidapi's default; a non-seize open leaves the
            // kernel HID driver holding the device and every SetReport fails.
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess else { continue }
            let deck = StreamDeck(device: dev)
            if deck.reset() {
                deck.setBrightness(70)
                return deck
            }
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))   // wedged — try the next
        }
        return nil
    }

    func serialNumber() -> String? {
        IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
    }

    /// Begin delivering key presses. Must be called on the main thread (schedules on the
    /// main run loop); the blocking open() can run on a background queue beforehand.
    func startInput() {
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, { context, _, _, _, _, report, length in
            guard let context = context else { return }
            Unmanaged<StreamDeck>.fromOpaque(context).takeUnretainedValue().handleInput(report, length)
        }, ctx)
    }

    /// Stop input delivery. Must be called on the main thread (unschedules the main run loop).
    func stopInput() {
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// Reset and close the device. Blocking (HID writes) — run off the main thread.
    func close() {
        reset()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit { inputBuffer.deallocate() }

    // MARK: Input (key presses)

    private func handleInput(_ report: UnsafeMutablePointer<UInt8>?, _ length: CFIndex) {
        // Report layout (matches hidapi): [reportID, 0x00, count, 0x00, state0, state1, ...].
        guard let report = report, length >= 4 + Self.keyCount else { return }
        for i in 0..<Self.keyCount {
            let pressed = report[4 + i] != 0
            if pressed != keyStates[i] {
                keyStates[i] = pressed
                onKey?(i, pressed)
            }
        }
    }

    // MARK: Output

    @discardableResult
    private func setReport(_ type: IOHIDReportType, _ bytes: [UInt8]) -> Bool {
        guard let reportID = bytes.first else { return false }
        return bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, type, CFIndex(reportID), $0.baseAddress!, bytes.count) == kIOReturnSuccess
        }
    }

    @discardableResult
    func reset() -> Bool {
        var payload = [UInt8](repeating: 0, count: 32)
        payload[0] = 0x03; payload[1] = 0x02
        return setReport(kIOHIDReportTypeFeature, payload)
    }

    func setBrightness(_ percent: Int) {
        var payload = [UInt8](repeating: 0, count: 32)
        payload[0] = 0x03; payload[1] = 0x08; payload[2] = UInt8(min(max(percent, 0), 100))
        setReport(kIOHIDReportTypeFeature, payload)
    }

    /// Push a JPEG image (72×72, already oriented for the device) to one key.
    @discardableResult
    func setKeyImage(_ key: Int, jpeg: Data) -> Bool {
        guard key >= 0, key < Self.keyCount, !jpeg.isEmpty else { return false }
        var ok = true
        jpeg.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            let total = jpeg.count
            var offset = 0, page = 0
            while offset < total {
                let thisLen = min(total - offset, Self.imagePayloadLength)
                let isLast: UInt8 = (offset + thisLen >= total) ? 1 : 0
                var packet = [UInt8](repeating: 0, count: Self.imageReportLength)
                packet[0] = 0x02
                packet[1] = 0x07
                packet[2] = UInt8(key)
                packet[3] = isLast
                packet[4] = UInt8(thisLen & 0xff)
                packet[5] = UInt8((thisLen >> 8) & 0xff)
                packet[6] = UInt8(page & 0xff)
                packet[7] = UInt8((page >> 8) & 0xff)
                packet.withUnsafeMutableBufferPointer { pkt in
                    _ = memcpy(pkt.baseAddress! + Self.imageHeaderLength, base + offset, thisLen)
                }
                if !setReport(kIOHIDReportTypeOutput, packet) { ok = false }
                offset += thisLen
                page += 1
            }
        }
        return ok
    }

    // MARK: Rendering helper

    /// Draw a key image upright; the result is pre-rotated 180° so the device (which
    /// flips both axes) displays it the right way up. `draw` runs with the AppKit
    /// graphics context set, in a `px`-sized, y-up coordinate space.
    static func encodeKeyImage(_ draw: (_ px: CGFloat) -> Void) -> Data? {
        let px = keyPixels
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        let cg = gctx.cgContext
        cg.translateBy(x: CGFloat(px), y: CGFloat(px))
        cg.rotate(by: .pi)
        draw(CGFloat(px))
        gctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
