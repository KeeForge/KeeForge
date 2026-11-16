# Browser native-messaging host

The sandboxed tool relays complete length-prefixed frames and handles only browser-to-host control messages from protocol sections 1–2. It has no app, vault, network, or package dependencies. Never log payloads. Its embedded Info.plist supplies the signing prefix; only the browser group is entitled.

`BrowserBridgeIdentifiers.swift` also compiles into the Mac app. Relay and control sources compile directly into `KeeForgeMacTests`; `BrowserHostRelayTests` uses isolated pipes and Unix sockets, with launch injected. Keep the entry point out of both app and test sources. Both distribution specs inherit the same target and code-sign-on-copy phase.
