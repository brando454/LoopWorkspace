@preconcurrency import CoreBluetooth

// GATT service UUIDs for Tandem pumps.
// TIP_SERVICE is present on both t:slim X2 and Mobi.
// TDU_SERVICE is Mobi-only (firmware updates only; not used for pump management).
enum TandemServiceUUID {
    static let tip = CBUUID(string: "0000FDFB-0000-1000-8000-00805F9B34FB")
    static let tdu = CBUUID(string: "0000FDFA-0000-1000-8000-00805F9B34FB")
    static let deviceInformation = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")
    static let genericAttribute = CBUUID(string: "00001801-0000-1000-8000-00805F9B34FB")
}

// Characteristic UUIDs within TIP_SERVICE.
// All share the Tandem vendor prefix 7B83xxxx-9F77-4E5C-8064-AAE2C24838B9.
enum TandemCharacteristicUUID {
    // Read/Notify — status query responses
    static let currentStatus    = CBUUID(string: "7B83FFF6-9F77-4E5C-8064-AAE2C24838B9")
    // Notify only — unsolicited pump event bitmasks; write {0,0,0,0} to clear
    static let qualifyingEvents = CBUUID(string: "7B83FFF7-9F77-4E5C-8064-AAE2C24838B9")
    // Notify — history log stream
    static let historyLog       = CBUUID(string: "7B83FFF8-9F77-4E5C-8064-AAE2C24838B9")
    // Auth handshake (challenge-response, J-PAKE)
    static let authorization    = CBUUID(string: "7B83FFF9-9F77-4E5C-8064-AAE2C24838B9")
    // Signed commands (all bolus/TBR/suspend/resume)
    static let control          = CBUUID(string: "7B83FFFC-9F77-4E5C-8064-AAE2C24838B9")
    // Streaming control messages
    static let controlStream    = CBUUID(string: "7B83FFFD-9F77-4E5C-8064-AAE2C24838B9")

    // Generic Attribute
    static let serviceChanged   = CBUUID(string: "00002A05-0000-1000-8000-00805F9B34FB")

    // Device Information Service
    static let modelNumber      = CBUUID(string: "00002A24-0000-1000-8000-00805F9B34FB")
    static let serialNumber     = CBUUID(string: "00002A25-0000-1000-8000-00805F9B34FB")
    static let manufacturerName = CBUUID(string: "00002A29-0000-1000-8000-00805F9B34FB")

    // Characteristics we subscribe to on connect, best-effort. A given pump
    // model may not expose every one (e.g. the Tandem Mobi does not offer the
    // GATT Service Changed characteristic on its FDFB service), so this list is
    // NOT a gate — see TandemPeripheralManager's auth-start gate, which keys on
    // the AUTHORIZATION characteristic alone. serviceChanged was removed from
    // this set: it belongs to the Generic Attribute service (1801), which the
    // pump does not expose under FDFB, so it could never be found here.
    static let allNotifiable: [CBUUID] = [
        currentStatus, qualifyingEvents, historyLog,
        authorization, control, controlStream
    ]
}

// Maximum chunk sizes per characteristic.
// CONTROL uses 40-byte chunks; everything else uses 18-byte chunks.
enum TandemMTU {
    static let requested = 185
    static let controlChunk = 40
    static let defaultChunk = 18
}

// Pump advertisement names (DIS model number still says "tslim X2" even on Mobi)
enum TandemAdvertisedName {
    static let mobi   = "Tandem Mobi"
    static let tslimX2 = "tslim X2"
}

// Mobi advertisement manufacturer data last byte encodes connection readiness
enum MobiConnectionState: UInt8 {
    case normal             = 0x10
    case chargingOrPickedUp = 0x11
    case pickedUpWithTap    = 0x12
}
