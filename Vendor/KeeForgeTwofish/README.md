# KeeForgeTwofish

`KeeForgeTwofish` is KeeForge's narrow Swift wrapper around Niels Ferguson's
Twofish C implementation, version 0.3. The public KDBX-facing API supports only
Twofish-256-CBC with a 16-byte IV and strict PKCS#7 padding.

## Provenance

- Authoritative project page: <https://www.schneier.com/academic/twofish/download/>
- Stable upstream mirror: <https://deb.debian.org/debian/pool/main/t/twofish/twofish_0.3.orig.tar.gz>
- Retrieved: 2026-07-12
- Archive SHA-256: `9d061a335eecc6885b2d3b8ce2123f6c2674ba366842379ce2f613f3c1e97db8`
- Pristine `twofish.c` SHA-256: `4f6564e4952fc4e0857818154caf8120c83704077999bd930a38c6a88fc4a85c`
- Pristine `twofish.h` SHA-256: `a6c85899e3e8bd31bd2b8bb2a3f05a93c53e4a3783be34184bfb9f5f3369c02b`
- Vendored patched `twofish.c` SHA-256: `a0ef5314351ca22e3af89b23ac9869edb9a1475ef9a55f22934bda09efbe9d88`
- Vendored pristine `twofish.h` SHA-256: `a6c85899e3e8bd31bd2b8bb2a3f05a93c53e4a3783be34184bfb9f5f3369c02b`

The complete upstream licensing terms are retained in `LICENSE` and at the top
of both vendored source files.

## Local integration changes

The vendored `twofish.h` is byte-for-byte pristine. The vendored `twofish.c`
has exactly two integration changes, both marked `KEEFORGE INTEGRATION`:

1. The upstream infinite-loop fatal macro calls a private `_Noreturn` adapter
   hook instead. Every upstream entry point runs inside a thread-local
   `setjmp`/`longjmp` failure boundary, translating failures into status codes
   without returning into failed cipher code, terminating, or hanging the app.
   The once-only Swift initializer maps self-test failure to
   `TwofishError.initializationFailed`.
2. The upstream key-schedule scratch array is cleared by the adapter's volatile
   byte-wise zeroizer instead of plain `memset`, which a compiler could remove.

The C adapter keeps the upstream key structure private, allocates one expanded
key per operation, securely clears it before release, and never logs inputs.
Swift's thread-safe static initialization runs the upstream table generation and
self-tests exactly once. CBC state and all plaintext/key-schedule work buffers
are operation-local and cleared on success and failure paths where ownership
allows. Returned plaintext necessarily remains owned by the caller.

The `TwofishBlock` SPI exists only for official known-answer-vector tests. App
code should use `TwofishCBC`.
