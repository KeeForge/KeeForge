# YubiKey hardware checklist

Run this once per release that changes YubiKey code (`HardwareKey*`, `YubiKeyOTPHID`, `MacYubiKeyHID`, `ChallengeResponseKey`, the unlock and master-key screens). Automated tests cover everything else (`KeeForge/Services/Security/AGENTS.md`, Tests). This list covers only what needs a real key: Core NFC, IOKit and Input Monitoring, and a real touch.

Use a YubiKey 5 with HMAC-SHA1 challenge-response on slot 2, set to require touch (`ykman otp chalresp --touch --generate 2`), and slot 1 empty. You also need a KeePassXC database protected by that key (KDBX 4), and one created by KeePassXC 2.7 as KDBX 3.1.

## Mac (direct build, then App Store build)
- [ ] First unlock asks for Input Monitoring once. After you allow it, the picker shows "YubiKey via USB, Slot 1 (Not Set Up)" and "Slot 2 (Touch Required)".
- [ ] Unlock with slot 2: the key flashes, a touch unlocks, and Touch ID re-unlock asks for the key again.
- [ ] Cancel during the flash: the key stops flashing and the unlock page returns.
- [ ] Unplug the key during the flash: "YubiKey Disconnected", with retry available.
- [ ] Slot 1: "YubiKey Slot Not Set Up".
- [ ] Edit, save, quit, then reopen in KeePassXC with the same key.
- [ ] Mac AutoFill in Safari: unlocks with a touch, fills, and offers no save.
- [ ] The KDBX 3.1 database opens read-only.

## iPhone (NFC)
- [ ] Unlock by holding the key to the top of the phone, then edit and save; KeePassXC opens the saved file.
- [ ] Change Master Key to add the key to a password-only database, then remove it; KeePassXC opens both results.
