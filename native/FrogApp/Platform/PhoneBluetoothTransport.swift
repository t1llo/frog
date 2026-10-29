import CoreBluetooth
import FrogCore
import Foundation
import os

/// The byte stream with the one phone subscribed to tx.
@MainActor
final class PhoneBluetoothPipe: CompanionPipe {
    let transport = CompanionTransport.bluetooth
    let label = "bluetooth"
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?

    let central: CBCentral
    fileprivate weak var peripheral: PhoneBluetoothPeripheral?
    fileprivate var outgoing = CompanionByteQueue()
    fileprivate private(set) var closed = false

    fileprivate init(central: CBCentral, peripheral: PhoneBluetoothPeripheral) {
        self.central = central
        self.peripheral = peripheral
    }

    func start() {}

    func send(_ data: Data) {
        guard !closed else { return }
        outgoing.append(data)
        peripheral?.pump()
    }

    func close() {
        guard !closed else { return }
        closed = true
        outgoing.removeAll()
        peripheral?.pipeDidClose(self)
        let handler = onClose
        onClose = nil
        onReceive = nil
        handler?()
    }

    fileprivate func deliver(_ data: Data) {
        guard !closed else { return }
        onReceive?(data)
    }
}

/// The Mac as a Bluetooth LE peripheral with the Frog Companion service: the phone writes rx, the Mac
/// notifies tx. The manager, and with it the Bluetooth permission prompt, exists only while Phone is on.
@MainActor
final class PhoneBluetoothPeripheral: NSObject {
    enum Availability: Equatable { case unknown, on, off, unauthorized, unsupported }

    var onNewPipe: ((PhoneBluetoothPipe) -> Void)?
    var onAvailabilityChange: ((Availability) -> Void)?

    private(set) var availability = Availability.unknown
    private var manager: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?
    private var serviceAdded = false
    private var current: PhoneBluetoothPipe?
    private let log = Logger(subsystem: "frog", category: "phone")

    private let serviceUUID = CBUUID(string: CompanionProtocol.bleServiceUUID)
    private let rxUUID = CBUUID(string: CompanionProtocol.bleRxUUID)
    private let txUUID = CBUUID(string: CompanionProtocol.bleTxUUID)

    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func stop() {
        current?.close()
        current = nil
        if let manager {
            if manager.isAdvertising { manager.stopAdvertising() }
            manager.removeAllServices()
            manager.delegate = nil
        }
        manager = nil
        txCharacteristic = nil
        serviceAdded = false
        setAvailability(.unknown)
    }

    /// Sends as many chunks as the stack takes, and resumes when it is ready again.
    fileprivate func pump() {
        guard let manager, let tx = txCharacteristic, let pipe = current, !pipe.closed else { return }
        let chunkSize = min(CompanionProtocol.maxBluetoothChunk, max(20, pipe.central.maximumUpdateValueLength))
        while pipe.outgoing.count > 0 {
            var probe = pipe.outgoing
            guard let chunk = probe.read(min(chunkSize, pipe.outgoing.count)) else { return }
            guard manager.updateValue(chunk, for: tx, onSubscribedCentrals: [pipe.central]) else { return }
            pipe.outgoing = probe
        }
    }

    fileprivate func pipeDidClose(_ pipe: PhoneBluetoothPipe) {
        if current === pipe { current = nil }
    }

    private func setUpService() {
        guard let manager, !serviceAdded else { return }
        let rx = CBMutableCharacteristic(type: rxUUID, properties: [.write], value: nil, permissions: [.writeable])
        let tx = CBMutableCharacteristic(type: txUUID, properties: [.notify], value: nil, permissions: [.readable])
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [rx, tx]
        txCharacteristic = tx
        serviceAdded = true
        manager.add(service)
    }

    private func startAdvertising() {
        guard let manager, manager.state == .poweredOn, !manager.isAdvertising else { return }
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID], CBAdvertisementDataLocalNameKey: "Frog"])
    }

    private func setAvailability(_ value: Availability) {
        guard availability != value else { return }
        availability = value
        onAvailabilityChange?(value)
    }

    private func resetAfterPowerLoss() {
        current?.close()
        current = nil
        serviceAdded = false
        txCharacteristic = nil
    }
}

extension PhoneBluetoothPeripheral: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        switch peripheral.state {
        case .poweredOn: setAvailability(.on); setUpService()
        case .poweredOff: setAvailability(.off); resetAfterPowerLoss()
        case .unauthorized: setAvailability(.unauthorized); resetAfterPowerLoss()
        case .unsupported: setAvailability(.unsupported)
        default: setAvailability(.unknown)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            log.error("Phone Bluetooth service failed: \(error.localizedDescription, privacy: .public)")
            serviceAdded = false
            return
        }
        startAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == txUUID else { return }
        // A new subscription resets the stream; one phone at a time.
        current?.close()
        peripheral.setDesiredConnectionLatency(.low, for: central)
        let pipe = PhoneBluetoothPipe(central: central, peripheral: self)
        current = pipe
        onNewPipe?(pipe)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == txUUID, let pipe = current, pipe.central.identifier == central.identifier else { return }
        pipe.close()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // Only the subscribed phone may write, only to rx, and only from offset 0.
        let valid = requests.allSatisfy {
            $0.characteristic.uuid == rxUUID && $0.offset == 0 && $0.central.identifier == current?.central.identifier
        }
        guard valid, let pipe = current else {
            peripheral.respond(to: first, withResult: .writeNotPermitted)
            return
        }
        peripheral.respond(to: first, withResult: .success)
        for request in requests { if let value = request.value, !value.isEmpty { pipe.deliver(value) } }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        peripheral.respond(to: request, withResult: .readNotPermitted)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pump()
    }
}
