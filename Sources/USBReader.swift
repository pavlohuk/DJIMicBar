// Finds the DJI receiver, opens its vendor interface, streams status frames
// and sends setting changes.

import Foundation
import IOKit
import IOUSBHost

final class USBReader {
    static let vendorID = 0x2ca3
    static let productID = 0x4011
    static let interfaceNumber = 6
    static let bulkIn = 0x86
    static let bulkOut = 0x06

    private let onState: (DeviceState) -> Void
    private var last: DeviceState?

    // Command side: the OUT pipe of the currently open interface, if any.
    private let lock = NSLock()
    private var outPipe: IOUSBHostPipe?
    private var seq: UInt16 = 1
    private let sendQueue = DispatchQueue(label: "dji-usb-send")

    init(onState: @escaping (DeviceState) -> Void) {
        self.onState = onState
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "dji-usb-reader"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Queue a setting change. The result shows up in the status stream within a tick or two.
    func send(_ change: SettingChange) {
        sendQueue.async { [self] in
            lock.lock()
            let pipe = outPipe
            let number = seq
            seq &+= 1
            lock.unlock()
            guard let pipe else { return }
            let wire = change.wire
            let packet = buildCommandV2(seq: number, target: wire.target,
                                        command: wire.command, value: wire.value)
            if ProcessInfo.processInfo.environment["DJIMIC_DEBUG"] != nil {
                print("send:", packet.map { String(format: "%02x", $0) }.joined(separator: " "))
            }
            let data = NSMutableData(bytes: packet, length: packet.count)
            var sent = 0
            do {
                try pipe.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: 1.0)
            } catch {
                NSLog("DJIMicBar: command failed: \(error.localizedDescription)")
            }
        }
    }

    private func setOutPipe(_ pipe: IOUSBHostPipe?) {
        lock.lock()
        outPipe = pipe
        lock.unlock()
    }

    private func findInterface() -> io_service_t {
        let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        match["idVendor"] = Self.vendorID
        match["idProduct"] = Self.productID
        match["bInterfaceNumber"] = Self.interfaceNumber
        match["bConfigurationValue"] = 1
        return IOServiceGetMatchingService(kIOMainPortDefault, match)
    }

    private func isPresent() -> Bool {
        let service = findInterface()
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    private func publish(_ state: DeviceState) {
        guard state != last else { return }
        last = state
        DispatchQueue.main.async { [onState] in onState(state) }
    }

    private func run() {
        while true {
            let service = findInterface()
            guard service != 0 else {
                publish(DeviceState())
                Thread.sleep(forTimeInterval: 1.5)
                continue
            }
            defer { IOObjectRelease(service) }

            let iface: IOUSBHostInterface
            let pipe: IOUSBHostPipe
            do {
                iface = try IOUSBHostInterface(
                    __ioService: service, options: [], queue: nil, interestHandler: nil)
                pipe = try iface.copyPipe(withAddress: Self.bulkIn)
            } catch {
                publish(DeviceState(receiverPresent: true, openError: error.localizedDescription))
                Thread.sleep(forTimeInterval: 2)
                continue
            }

            publish(DeviceState(receiverPresent: true))
            setOutPipe(try? iface.copyPipe(withAddress: Self.bulkOut))
            let decoder = Decoder()
            var failures = 0
            while true {
                let data = NSMutableData(length: 512)!
                var got = 0
                do {
                    try pipe.__sendIORequest(with: data, bytesTransferred: &got, completionTimeout: 1.0)
                } catch {
                    failures += 1
                    if failures >= 3 || !isPresent() { break }
                    continue
                }
                failures = 0
                guard got > 0 else { continue }
                decoder.feed([UInt8](data as Data).prefix(got).map { $0 })
                publish(decoder.state)
            }
            setOutPipe(nil)
            iface.destroy()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
