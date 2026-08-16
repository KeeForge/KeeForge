# WebDAV Manual E2E Checklist

Manual pass used on 2026-07-04 to verify WebDAV sync against real servers (not part
of the release process). Automated coverage (unit tests with stubbed transport +
mock-provider UI tests) does not touch a real server, so this pass verified
real-world behavior. Servers tested:

1. **Nextcloud** — base URL `https://<host>/remote.php/dav/files/<user>/`, using
   an app password (Settings → Security → Devices & sessions).
2. **One non-Nextcloud server** — e.g. Synology WebDAV Server or Apache mod_dav.

## Checklist

- [ ] Connect with a bad password → clean inline error in the connect form.
- [ ] Connect with a wrong path (non-DAV endpoint) → "does not look like a
      WebDAV server" / not-found message.
- [ ] Add an existing `.kdbx` via the folder browser, including a folder and a
      filename with spaces/umlauts → opens; row shows correct display path.
- [ ] Create a new database into a chosen folder; re-create with the same name
      → conflict ("already exists") message.
- [ ] Edit an entry + save → server file updated (ETag changed), local backup
      written.
- [ ] Modify the file server-side, then save in the app → conflict alert with
      reload path.
- [ ] Airplane-mode open → cached-copy banner; save offline → error surfaced;
      recovery once back online.
- [ ] AutoFill save on the WebDAV database → pending upload queued; open main
      app → drain succeeds.
- [ ] Sign out in Settings → database row shows "Disconnected"; cached copy
      still opens.
- [ ] Two accounts on the same server with different users → both listed and
      isolated.

## Known v1 limitations

- HTTPS with a trusted certificate only (no self-signed / untrusted-cert
  toggle yet; the `WebDAVCredential` payload accepts extra fields without
  migration when that lands).
- Reconnect-after-sign-out shows guidance text instead of re-presenting the
  connect form; re-add the server via Add Database → WebDAV.
- Servers without ETags fall back to `Last-Modified` revisions (1-second
  granularity).
