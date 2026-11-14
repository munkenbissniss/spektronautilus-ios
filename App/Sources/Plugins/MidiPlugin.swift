import Foundation
import CoreMIDI

/// MIDI controllers (USB through the camera adapter, Bluetooth, network). Safari on iPhone has no Web MIDI, so the page gets a small
/// stand-in for navigator.requestMIDIAccess (web-shim/ios-bridge.js) that is fed by this plugin. The mixers do not know the difference.
final class MidiPlugin: Plugin {
    private weak var bridge: Bridge?
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var started = false
    private var connected = Set<MIDIUniqueID>()
    private let queue = DispatchQueue(label: "spk.midi")

    init(bridge: Bridge) { self.bridge = bridge }

    func call(_ method: String, _ args: [String: Any], done: @escaping (Any?) -> Void, fail: @escaping (String) -> Void) {
        switch method {
        case "start":
            if !started {
                started = true
                MIDIClientCreateWithBlock("Spektronautilus" as CFString, &client) { [weak self] _ in self?.refresh(emit: true) }
                MIDIInputPortCreateWithBlock(client, "Spektronautilus in" as CFString, &port) { [weak self] list, _ in self?.receive(list) }
            }
            done(refresh(emit: false))
        case "devices": done(devices())
        default: fail("Unknown method midi.\(method)")
        }
    }

    /// connect to every source that is not connected yet; returns the list of devices
    @discardableResult
    private func refresh(emit: Bool) -> [[String: Any]] {
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var uid: Int32 = 0; MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &uid)
            if !connected.contains(uid) { MIDIPortConnectSource(port, src, nil); connected.insert(uid) }
        }
        let list = devices()
        if emit { bridge?.emit("midi.devices", list) }
        return list
    }

    private func devices() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var uid: Int32 = 0; MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &uid)
            var name: Unmanaged<CFString>?; MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name)
            out.append(["id": Int(uid), "name": (name?.takeRetainedValue() as String?) ?? "MIDI device \(i + 1)"])
        }
        return out
    }

    /// raw MIDI bytes -> separate messages (a packet can hold several, and may use "running status")
    private func receive(_ list: UnsafePointer<MIDIPacketList>) {
        var messages: [[Int]] = []
        for packet in list.unsafeSequence() {
            var p = packet
            let bytes: [UInt8] = withUnsafeBytes(of: &p.data) { Array($0.prefix(Int(p.length))) }
            var i = 0, status: UInt8 = 0
            while i < bytes.count {
                let b = bytes[i]
                if b >= 0xF8 { i += 1; continue }                    // real-time bytes (clock): ignore
                if b >= 0x80 { status = b; i += 1; if b >= 0xF0 { while i < bytes.count && bytes[i] < 0x80 { i += 1 }; status = 0; continue } }
                guard status != 0 else { i += 1; continue }
                let need = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
                if i + need <= bytes.count, bytes[i..<(i + need)].allSatisfy({ $0 < 0x80 }) {
                    messages.append([Int(status)] + bytes[i..<(i + need)].map { Int($0) }); i += need
                } else { i += 1 }
            }
        }
        if !messages.isEmpty { bridge?.emit("midi.messages", messages) }
    }
}
