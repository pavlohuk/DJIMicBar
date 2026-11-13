import AppKit
import Combine
import SwiftUI

// MARK: - Model

/// Live input levels arrive ~10 times a second, so they are kept apart from the
/// rest of the state and only published while the panel is open.
final class LevelModel: ObservableObject {
    @Published var levels: [Int: Int] = [:]
}

final class MicModel: ObservableObject {
    @Published var state = DeviceState()
    let levels = LevelModel()
    var panelVisible = false
    private var reader: USBReader?

    init() {
        let reader = USBReader { [weak self] in self?.apply($0) }
        self.reader = reader
        reader.start()
    }

    func send(_ changes: SettingChange...) {
        for change in changes { reader?.send(change) }
    }

    private func apply(_ incoming: DeviceState) {
        var settled = incoming
        var live: [Int: Int] = [:]
        for i in settled.tx.indices {
            live[settled.tx[i].unit] = settled.tx[i].level
            settled.tx[i].level = nil
        }
        if settled != state { state = settled }
        if panelVisible, live != levels.levels { levels.levels = live }
    }
}

// MARK: - Presentation helpers

enum Battery {
    /// Raw gauge is 1 (full) … 7 (about to shut off); 0 means not reported.
    static func symbol(_ gauge: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch gauge {
        case 1: return "battery.100percent"
        case 2: return "battery.75percent"
        case 3: return "battery.50percent"
        case 4, 5: return "battery.25percent"
        case 6, 7: return "battery.0percent"
        default: return "battery.0percent"
        }
    }

    static func label(_ gauge: Int) -> String {
        switch gauge {
        case 1: return "Full"
        case 2: return "High"
        case 3: return "Medium"
        case 4: return "Below medium"
        case 5: return "Low"
        case 6: return "Very low"
        case 7: return "Critical"
        default: return "Unknown"
        }
    }

    static func color(_ gauge: Int) -> Color {
        switch gauge {
        case 5: return .orange
        case 6, 7: return .red
        default: return .green
        }
    }
}

enum Artwork {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    /// Picture of the specific transmitter model that is connected.
    static func transmitter(_ productName: String?) -> NSImage? {
        image(productName == "DJI Mic Mini 2" ? "mic-mini-2-tx" : "mic-mini-tx")
    }

    static var receiver: NSImage? { image("mic-mini-usb-rx") }
}

/// Menu-bar icon: a microphone whose four signal dots double as a battery gauge —
/// the weakest connected transmitter decides how many dots are lit.
func statusBarImage(for state: DeviceState) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    let image: NSImage?
    if !state.receiverPresent || state.openError != nil {
        image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "DJI Mic unavailable")
    } else {
        // Raw gauge runs 1 (full) … 7 (about to shut off); no transmitter lights no dots.
        let worst = state.tx.filter { $0.battery > 0 }.map(\.battery).max()
        let dots: Double
        switch worst {
        case 1?: dots = 4
        case 2?: dots = 3
        case 3?: dots = 2
        case 4?, 5?: dots = 1
        default: dots = 0
        }
        image = NSImage(systemSymbolName: "microphone.and.signal.meter.fill",
                        variableValue: dots / 4, accessibilityDescription: "DJI Mic")
    }
    let result = image?.withSymbolConfiguration(config) ?? NSImage()
    result.isTemplate = true
    return result
}

// MARK: - Views
// Layout follows the Control Center "Display" module: a title block, a slim bar,
// then round toggles with a label and a state line under each.

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(subviews, width: bounds.width).origins
        for (view, origin) in zip(subviews, origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                       proposal: .unspecified)
        }
    }
}

/// The pill itself, coloured like Control Center's round toggles:
/// white with an accent glyph when on, translucent grey with a white glyph otherwise.
struct ChipLabel: View {
    let symbol: String
    var text: String?
    var on = false
    var interactive = true
    var fill = false               // stretch to the width offered by the row
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            if let text { Text(text).font(.system(size: 11, weight: .medium)) }
        }
        .foregroundStyle(on ? Color.accentColor : Color.white)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, fill ? 4 : 8)
        .frame(maxWidth: fill ? .infinity : nil)
        .frame(height: 24)
        .background(on ? Color.white.opacity(hovering ? 0.85 : 1)
                       : Color.white.opacity(hovering ? 0.26 : 0.16), in: Capsule())
        .contentShape(Capsule())
        .onHover { hovering = interactive && $0 }
    }
}

/// One setting as a pill. With an action it is a button that flips the setting.
struct Chip: View {
    let symbol: String
    var text: String?
    var on = false
    let help: String
    var fill = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { ChipLabel(symbol: symbol, text: text, on: on, fill: fill) }
                .buttonStyle(.plain)
                .help(help)
        } else {
            ChipLabel(symbol: symbol, text: text, on: on, interactive: false, fill: fill).help(help)
        }
    }
}

/// A pill that opens a menu of choices, for settings with more than two values.
struct MenuChip<Items: View>: View {
    let symbol: String
    var text: String?
    var on = false
    let help: String
    var fill = false
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: { ChipLabel(symbol: symbol, text: text, on: on, fill: fill) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: !fill, vertical: true)
            .help(help)
    }
}

/// A menu row with a checkmark on the current choice.
struct Choice: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

struct LevelMeter: View {
    /// Fixed green: the dark-appearance system green reads as lime on glass.
    private static let green = Color(red: 0.0, green: 0.84, blue: 0.27)
    @ObservedObject var model: LevelModel
    let unit: Int

    var body: some View {
        let level = model.levels[unit]
        // Levels sit roughly in 0x14–0x4f; 80 is treated as a full bar.
        let fraction = min(max(Double(level ?? 0) / 80, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(fraction > 0.85 ? Color.red : (fraction > 0.65 ? .yellow : Self.green))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 2)
        .animation(.linear(duration: 0.1), value: fraction)
        .help("Input level")
    }
}

struct SectionHeader<Subtitle: View>: View {
    let image: NSImage?
    let title: String
    @ViewBuilder var subtitle: Subtitle

    var body: some View {
        HStack(spacing: 9) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .bold))
                subtitle.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Firmware and serial number, shown only while Option is held.
struct DetailLines: View {
    let firmware: String?
    let serial: String?

    var body: some View {
        VStack(spacing: 2) {
            line("Firmware", firmware)
            line("Serial Number", serial)
        }
    }

    private func line(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—").monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

struct TransmitterSection: View {
    let tx: TXState
    let state: DeviceState
    let levels: LevelModel
    let showDetails: Bool
    let send: (SettingChange...) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(image: Artwork.transmitter(tx.productName),
                          title: tx.productName ?? "Transmitter \(tx.unit)") {
                HStack(spacing: 3) {
                    Image(systemName: Battery.symbol(tx.battery, charging: tx.charging))
                        .foregroundStyle(tx.battery >= 5 ? Battery.color(tx.battery) : Color.secondary)
                    Text(tx.charging ? "Charging" : Battery.label(tx.battery))
                    Text("· TX\(tx.unit)")
                }
            }
            if showDetails { DetailLines(firmware: tx.firmware, serial: tx.serial) }
            LevelMeter(model: levels, unit: tx.unit)
            // Three equal columns, so the row keeps its shape whatever the values are.
            HStack(spacing: 6) {
                // Display only: on Mic Mini 2 (firmware 02.03.17.00) the receiver ignores the
                // documented noise-cancel commands; the mode is switched on the hardware.
                Chip(symbol: state.ncEnabled ? "ear.badge.waveform" : "ear",
                     text: state.ncEnabled ? (state.ncStrong ? "Strong" : "Basic") : "Off",
                     on: state.ncEnabled,
                     help: "Noise Cancelling: " + (state.ncEnabled ? (state.ncStrong ? "Strong" : "Basic") : "off")
                         + " — switched on the device",
                     fill: true)
                MenuChip(symbol: "person.wave.2", text: tx.voiceTone.rawValue, help: "Voice Tone", fill: true) {
                    ForEach([VoiceTone.standard, .rich, .bright], id: \.self) { tone in
                        Choice(title: tone.rawValue, selected: tx.voiceTone == tone) {
                            send(.voiceTone(tone, unit: tx.unit))
                        }
                    }
                }
                Chip(symbol: "line.3.horizontal.decrease", text: "Low Cut", on: tx.lowCut,
                     help: "Low Cut: " + (tx.lowCut ? "on" : "off"), fill: true) { send(.lowCut(!tx.lowCut)) }
            }
            // Same three columns as the row above; the two icon chips share the first one.
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Chip(symbol: tx.ledsOn ? "lightbulb.fill" : "lightbulb.slash", on: tx.ledsOn,
                         help: "Mic LEDs: " + (tx.ledsOn ? "on" : "off"), fill: true) { send(.micLEDs(!tx.ledsOn)) }
                    Chip(symbol: "timer", on: tx.autoOff,
                         help: "Auto Off after 15 min: " + (tx.autoOff ? "on" : "off"), fill: true) {
                        send(.txAutoOff(!tx.autoOff))
                    }
                }
                .frame(maxWidth: .infinity)
                // Mic Mini 2 stores this flag but its button does not act on it, so it is
                // only offered for models where it is known to work.
                if let name = tx.productName, name != "DJI Mic Mini 2" {
                    Chip(symbol: "button.programmable", text: "NC Button", on: tx.ncButton,
                         help: "Button toggles Noise Cancelling: " + (tx.ncButton ? "yes" : "no"), fill: true) {
                        send(.noiseCancelButton(!tx.ncButton))
                    }
                } else {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 24)
                }
                Color.clear.frame(maxWidth: .infinity).frame(height: 24)
            }
        }
    }
}

struct ReceiverSection: View {
    let state: DeviceState
    let showDetails: Bool
    let send: (SettingChange...) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(image: Artwork.receiver, title: "Receiver") {
                Text("Connected via USB")
            }
            if showDetails { DetailLines(firmware: state.rxFirmware, serial: state.rxSerial) }
            // Gain, Safety Track, the plug-free speaker, camera power and auto-off are left out:
            // they belong to the camera receiver, and the protocol gives no way to tell receiver models apart.
            HStack(spacing: 6) {
                Chip(symbol: state.stereo ? "hifispeaker.2" : "hifispeaker",
                     text: state.stereo ? "Stereo" : "Mono",
                     help: "Recording mode: " + (state.stereo ? "stereo" : "mono"), fill: true) {
                    send(.stereo(!state.stereo))
                }
                Chip(symbol: "waveform.path", text: "Limiter", on: state.clipLimiter,
                     help: "Clip Limiter: " + (state.clipLimiter ? "on" : "off"), fill: true) {
                    send(.clipLimiter(!state.clipLimiter))
                }
                // Third column stays empty so the chips line up with the transmitter's.
                Color.clear.frame(maxWidth: .infinity).frame(height: 24)
            }
        }
    }
}

struct Placeholder: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

/// Forces the hosting panel itself into dark appearance, so the system glass
/// darkens too — `preferredColorScheme` does not reach a MenuBarExtra window.
struct DarkWindow: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.window?.appearance = NSAppearance(named: .darkAqua)
    }
}

/// Footer row with the same hover highlight as "… Settings…" rows in system menus.
struct MenuRow: View {
    let title: String
    var checked = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 0)
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.white.opacity(hovering ? 0.14 : 0),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Let the highlight extend past the text, towards the panel edges.
        .padding(.horizontal, -8)
    }
}

struct PanelView: View {
    @ObservedObject var model: MicModel
    var forceDetails = false
    @State private var optionDown = false
    private var showDetails: Bool { optionDown || forceDetails }
    private let optionPoll = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 10) {
            if !state.receiverPresent {
                Placeholder(symbol: "mic.slash", title: "Receiver not connected",
                            detail: "Plug the DJI Mic receiver into a USB port")
            } else if let error = state.openError {
                Placeholder(symbol: "exclamationmark.triangle", title: "Can't access the receiver",
                            detail: error)
            } else if !state.hasStatus {
                Placeholder(symbol: "hourglass",
                            title: state.legacyFirmware ? "Old firmware" : "Reading status…",
                            detail: state.legacyFirmware
                                ? "The receiver uses protocol v1 — update its firmware" : nil)
            } else {
                if state.tx.isEmpty {
                    Placeholder(symbol: "mic", title: "No transmitters connected",
                                detail: "Turn the mic on or take it out of the case")
                } else {
                    ForEach(state.tx) {
                        TransmitterSection(tx: $0, state: state, levels: model.levels, showDetails: showDetails, send: model.send)
                        Divider()
                    }
                }
                ReceiverSection(state: state, showDetails: showDetails, send: model.send)
            }
            Divider()
            MenuRow(title: "Quit DJI Mic Bar") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .padding(.vertical, -4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 290)
        // Dark appearance gives the system panel its Liquid Glass look with light text,
        // matching Control Center menus regardless of what is behind it.
        .environment(\.colorScheme, .dark)
        .background(DarkWindow())
        .onReceive(optionPoll) { _ in
            // Like the system Bluetooth menu: holding Option reveals firmware and serial numbers.
            guard model.panelVisible else { return }
            let down = NSEvent.modifierFlags.contains(.option)
            if down != optionDown { optionDown = down }
        }
        .onAppear { model.panelVisible = true }
        .onDisappear { model.panelVisible = false }
    }
}

// MARK: - Entry point

struct DJIMicBarApp: App {
    @StateObject private var model = MicModel()

    var body: some Scene {
        // No receiver, no menu bar icon: the app idles invisibly until one is plugged in.
        MenuBarExtra(isInserted: Binding(get: { model.state.receiverPresent }, set: { _ in })) {
            PanelView(model: model)
        } label: {
            Image(nsImage: statusBarImage(for: model.state))
        }
        .menuBarExtraStyle(.window)
    }
}

@main
enum Main {
    static func main() {
        // `--dump` prints decoded state to the terminal instead of starting the UI.
        if CommandLine.arguments.contains("--dump") {
            let reader = USBReader { state in
                dump(state)
                print("---")
            }
            reader.start()
            RunLoop.main.run(until: Date().addingTimeInterval(4))
            return
        }
        // `--icon <file.png>` renders the menu bar icon for the live state.
        if let i = CommandLine.arguments.firstIndex(of: "--icon"), i + 1 < CommandLine.arguments.count {
            var latest = DeviceState()
            let reader = USBReader { latest = $0 }
            reader.start()
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            // Optional third argument overrides the battery gauge (1–7) for previewing.
            if i + 2 < CommandLine.arguments.count, let gauge = Int(CommandLine.arguments[i + 2]),
               !latest.tx.isEmpty {
                latest.tx[0].battery = gauge
            }
            let icon = statusBarImage(for: latest)
            let scale: CGFloat = 4
            let size = NSSize(width: icon.size.width * scale + 16, height: icon.size.height * scale + 16)
            let canvas = NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                icon.draw(in: rect.insetBy(dx: 8, dy: 8))
                return true
            }
            if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
            return
        }
        // `--raw <target> <command> <value>` (hex) sends one command and prints the state around it.
        if let i = CommandLine.arguments.firstIndex(of: "--raw"), i + 3 < CommandLine.arguments.count {
            let args = CommandLine.arguments[(i + 1)...(i + 3)].map { UInt16($0, radix: 16) ?? 0 }
            var latest = DeviceState()
            let reader = USBReader { latest = $0 }
            reader.start()
            func summary() -> String {
                let tx = latest.tx.first
                return "nc=\(latest.ncEnabled) strong=\(latest.ncStrong) lowCut=\(tx?.lowCut ?? false) "
                    + "leds=\(tx?.ledsOn ?? false) tone=\(tx?.voiceTone.rawValue ?? "-") "
                    + "stereo=\(latest.stereo) safety=\(latest.safetyTrack) clip=\(latest.clipLimiter)"
            }
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            print("before:", summary())
            reader.send(.raw(target: args[0], command: args[1], value: UInt8(args[2] & 0xff)))
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            print("after: ", summary())
            return
        }
        // `--snapshot <file.png>` renders the panel with live data to an image.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
           i + 1 < CommandLine.arguments.count {
            let model = MicModel()
            model.panelVisible = true
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            let host = NSHostingView(rootView: PanelView(model: model, forceDetails: CommandLine.arguments.contains("--details")).background(CommandLine.arguments.contains("--dark-backdrop")
                    ? Color(white: 0.25) : Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
            return
        }
        DJIMicBarApp.main()
    }
}
