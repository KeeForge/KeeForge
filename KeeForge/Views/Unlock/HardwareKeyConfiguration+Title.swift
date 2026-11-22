extension HardwareKeyConfiguration {
    /// The unlock pickers' name for this key choice.
    var title: String {
        switch (transport, slot) {
        case (.nfc, .one): String(localized: "YubiKey via NFC, Slot 1")
        case (.nfc, .two): String(localized: "YubiKey via NFC, Slot 2")
        case (.usb, .one): String(localized: "YubiKey via USB, Slot 1")
        case (.usb, .two): String(localized: "YubiKey via USB, Slot 2")
        }
    }

    /// Every slot on each transport offered, plus `current` even when this
    /// device lacks its transport, so a picker can show it.
    static func pickerOptions(
        transports: [Transport],
        current: HardwareKeyConfiguration?
    ) -> [HardwareKeyConfiguration] {
        var options = transports.flatMap { transport in
            Slot.allCases.map { HardwareKeyConfiguration(transport: transport, slot: $0) }
        }
        if let current, options.contains(current) == false {
            options.append(current)
        }
        return options
    }
}
