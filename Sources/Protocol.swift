// DJI Mic Mini / Mini 2 USB status protocol (v2 firmware), read-only decoder.
// Wire format reference: https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md

import Foundation

// MARK: - State

enum VoiceTone: String {
    case standard = "Normal"
    case rich = "Rich"
    case bright = "Bright"
}

struct TXState: Equatable, Identifiable {
    var unit: Int                 // physical transmitter number, 1 or 2
    var battery: Int              // raw gauge: 1 = full … 7 = about to shut off, 0 = unknown
    var charging: Bool
    var ledsOn: Bool
    var autoOff: Bool
    var ncButton: Bool            // quick press of the TX button toggles noise cancel
    var lowCut: Bool
    var voiceTone: VoiceTone
    var level: Int?               // live input level, roughly 0x14–0x4f
    var firmware: String?
    var serial: String?
    var productName: String?

    var id: Int { unit }
}

struct DeviceState: Equatable {
    var receiverPresent = false
    var openError: String?
    var hasStatus = false
    var legacyFirmware = false    // v1 protocol detected — not decoded by this app

    var rxFirmware: String?
    var rxSerial: String?

    var ncEnabled = false
    var ncStrong = false
    var turnOnWithCamera = false
    var rxAutoOff = false
    var stereo = false
    var gainDB = 0
    var plugFreeSpeaker = false
    var clipLimiter = false
    var safetyTrack = false

    var tx: [TXState] = []
}

// MARK: - CRC-16 (reflected 0x8408), v2 seed

private let crcTable: [UInt16] = (0..<256).map { n -> UInt16 in
    var c = UInt16(n)
    for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
    return c
}

/// A valid v2 frame, checksummed in full from seed 0x3692, lands on residue 0.
func crcValidV2(_ frame: ArraySlice<UInt8>) -> Bool {
    var crc: UInt16 = 0x3692
    for b in frame { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt16(b)) & 0xff)] }
    return crc == 0
}

// MARK: - Decoder

struct Identity: Equatable {
    var firmware: String?
    var serial: String?
    var productName: String?
}

final class Decoder {
    private(set) var state = DeviceState(receiverPresent: true)
    private var buffer: [UInt8] = []
    private var identities: [Int: Identity] = [:]   // 0 = receiver, 1/2 = transmitters
    private var levels: [Int: Int] = [:]

    func feed(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        while let frame = takeFrame() { decode(frame) }
        if buffer.count > 4096 { buffer.removeFirst(buffer.count - 1024) }
    }

    /// Pull the next complete frame: 0x55, length, 0x04, …, CRC-16.
    private func takeFrame() -> [UInt8]? {
        var i = 0
        while i < buffer.count {
            guard buffer[i] == 0x55 else { i += 1; continue }
            guard i + 2 < buffer.count else { break }           // need more bytes
            let len = Int(buffer[i + 1])
            guard buffer[i + 2] == 0x04, len >= 13 else { i += 1; continue }
            guard i + len <= buffer.count else { break }        // frame still arriving
            let frame = buffer[i..<(i + len)]
            if isV1Heartbeat(frame) {
                state.legacyFirmware = true
            } else if crcValidV2(frame) {
                let out = Array(frame)
                buffer.removeFirst(i + len)
                return out
            }
            i += 1
        }
        buffer.removeFirst(min(i, buffer.count))
        return nil
    }

    private func isV1Heartbeat(_ f: ArraySlice<UInt8>) -> Bool {
        let s = f.startIndex
        return f.count >= 56 && f[s + 9] == 0x5b && f[s + 10] == 0x03 && f[s + 11] == 0x00
    }

    private func decode(_ f: [UInt8]) {
        // Status / identity / level pushes all carry `5b 03 03` at offset 9.
        guard f.count >= 16, f[9] == 0x5b, f[10] == 0x03, f[11] == 0x03 else { return }
        if decodeRecords(f) { rebuildTransmitters(nil); return }
        decodeStatus(f)
    }

    /// Identity and audio-level pushes: `[tag][unit][3 reserved][len][data]` records from offset 14.
    private func decodeRecords(_ f: [UInt8]) -> Bool {
        let end = f.count - 2
        var i = 14
        var parsed: [(tag: UInt8, unit: Int, data: ArraySlice<UInt8>)] = []
        while i < end {
            guard i + 6 <= end, [0x01, 0x04, 0x05, 0x06].contains(f[i]) else { return false }
            let dataEnd = i + 6 + Int(f[i + 5])
            guard dataEnd <= end else { return false }
            parsed.append((f[i], Int(f[i + 1]), f[(i + 6)..<dataEnd]))
            i = dataEnd
        }
        guard !parsed.isEmpty else { return false }

        for r in parsed where r.unit <= 2 {
            let d = Array(r.data)
            switch r.tag {
            case 0x01 where d.count > 4:
                var id = identities[r.unit] ?? Identity()
                id.firmware = String(format: "%02d.%02d.%02d.%02d", d[3], d[2], d[1], d[0])
                id.serial = ascii(d[4...])
                identities[r.unit] = id
            case 0x06:
                var id = identities[r.unit] ?? Identity()
                id.productName = ascii(d[...])
                identities[r.unit] = id
            case 0x05 where d.count == 1 && r.unit >= 1:
                levels[r.unit] = Int(d[0])
            default:
                break
            }
        }
        state.rxFirmware = identities[0]?.firmware
        state.rxSerial = identities[0]?.serial
        return true
    }

    /// Status push: 52-byte header, one 32-byte slot per connected transmitter, CRC.
    private func decodeStatus(_ f: [UInt8]) {
        let body = f.count - 54
        guard body >= 0, body % 32 == 0 else { return }
        let slots = min(body / 32, 2)

        state.hasStatus = true
        state.ncStrong = f[20] & 0x08 != 0
        state.ncEnabled = f[20] & 0x20 != 0
        state.turnOnWithCamera = f[20] & 0x80 != 0
        state.rxAutoOff = f[21] & 0x01 != 0
        state.stereo = f[21] & 0x04 != 0
        state.gainDB = Int(Int8(bitPattern: f[22]))
        state.plugFreeSpeaker = f[48] & 0x02 != 0
        state.clipLimiter = f[48] & 0x10 != 0
        state.safetyTrack = f[48] & 0x40 != 0

        var list: [TXState] = []
        for n in 0..<slots {
            let o = 52 + 32 * n
            let unit = Int(f[o + 1])
            guard f[o] == 0x02, unit == 1 || unit == 2 else { continue }
            let tone: VoiceTone = f[o + 9] & 0x80 != 0 ? .bright : (f[o + 9] & 0x40 != 0 ? .rich : .standard)
            list.append(TXState(
                unit: unit,
                battery: Int((f[o + 7] >> 2) & 0x07),
                charging: f[o + 7] & 0x02 != 0,
                ledsOn: f[o + 6] & 0x02 == 0,
                autoOff: f[o + 6] & 0x10 != 0,
                ncButton: f[o + 6] & 0x80 != 0,
                lowCut: f[o + 9] & 0x20 != 0,
                voiceTone: tone))
        }
        rebuildTransmitters(list.sorted { $0.unit < $1.unit })
    }

    /// Merge identity and level data (which arrive in their own pushes) into the TX list.
    private func rebuildTransmitters(_ fresh: [TXState]?) {
        var list = fresh ?? state.tx
        if fresh != nil {
            // Forget what we learned about a transmitter once it disconnects.
            let present = Set(list.map(\.unit))
            for unit in [1, 2] where !present.contains(unit) {
                identities[unit] = nil
                levels[unit] = nil
            }
        }
        for i in list.indices {
            let unit = list[i].unit
            list[i].level = levels[unit]
            list[i].firmware = identities[unit]?.firmware
            list[i].serial = identities[unit]?.serial
            list[i].productName = identities[unit]?.productName
        }
        state.tx = list
    }

    private func ascii(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Commands (v2 firmware)

/// A change to one setting. Transmitter settings are broadcast to both units,
/// except Voice Tone, which addresses a single transmitter.
enum SettingChange {
    case noiseCancelEnabled(Bool)
    case noiseCancelStrong(Bool)
    case noiseCancelButton(Bool)
    case lowCut(Bool)
    case micLEDs(Bool)
    case txAutoOff(Bool)
    case voiceTone(VoiceTone, unit: Int)
    case stereo(Bool)
    case safetyTrack(Bool)
    case clipLimiter(Bool)
    case rxAutoOff(Bool)
    case turnOnWithCamera(Bool)
    case plugFreeSpeaker(Bool)      // reboots the receiver
    case raw(target: UInt16, command: UInt16, value: UInt8)   // debugging only

    private static let receiver: UInt16 = 0x0000
    private static let allTransmitters: UInt16 = 0xffff

    var wire: (target: UInt16, command: UInt16, value: UInt8) {
        func bit(_ on: Bool) -> UInt8 { on ? 1 : 0 }
        switch self {
        case .noiseCancelEnabled(let on): return (Self.allTransmitters, 0x0038, bit(on))
        case .noiseCancelStrong(let on): return (Self.allTransmitters, 0x0037, bit(on))
        case .noiseCancelButton(let on): return (Self.allTransmitters, 0x000f, bit(on))
        case .lowCut(let on): return (Self.allTransmitters, 0x0003, bit(on))
        case .micLEDs(let on): return (Self.allTransmitters, 0x000a, on ? 0x00 : 0x02)   // inverted
        case .txAutoOff(let on): return (Self.allTransmitters, 0x0010, bit(on))
        case .voiceTone(let tone, let unit):
            let value: UInt8 = tone == .standard ? 0 : (tone == .rich ? 1 : 2)
            return (UInt16(unit), 0x0029, value)
        case .stereo(let on): return (Self.receiver, 0x0008, on ? 0x02 : 0x00)
        case .safetyTrack(let on): return (Self.receiver, 0x0021, bit(on))
        case .clipLimiter(let on): return (Self.receiver, 0x001e, bit(on))
        case .rxAutoOff(let on): return (Self.receiver, 0x0010, bit(on))
        case .turnOnWithCamera(let on): return (Self.receiver, 0x0020, bit(on))
        case .plugFreeSpeaker(let on): return (Self.receiver, 0x0023, bit(on))
        case .raw(let target, let command, let value): return (target, command, value)
        }
    }
}

/// 22-byte target-addressed command frame, CRC included.
func buildCommandV2(seq: UInt16, target: UInt16, command: UInt16, value: UInt8) -> [UInt8] {
    var p: [UInt8] = [
        0x55, 22, 0x04, 0xfc,                       // start, length, version, header CRC-8
        0x02, 0x5a,                                 // audio subsystem, attribute flags
        UInt8(seq & 0xff), UInt8(seq >> 8),
        0x40, 0x5b, 0x01, 0x02,                     // ACK requested, target-addressed sub-type
        UInt8(target & 0xff), UInt8(target >> 8), 0x00, 0x00,
        UInt8(command & 0xff), UInt8(command >> 8),
        0x01, value,
    ]
    // For this reflected CRC, appending the running value low byte first
    // makes the whole frame checksum to the v2 residue of zero.
    var crc: UInt16 = 0x3692
    for b in p { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt16(b)) & 0xff)] }
    p.append(UInt8(crc & 0xff))
    p.append(UInt8(crc >> 8))
    return p
}
