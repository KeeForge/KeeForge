"""Small, disjoint databases for the physical-device AutoFill store smoke suite."""

from pathlib import Path
from uuid import UUID

from ._common import Generator, fixture_path, new_database, pykeepass, verify_keepassxc_lists_group

PASSWORD = "testpassword123"
OTP = "otpauth://totp/Store:fixture-user?secret=JBSWY3DPEHPK3PXP&issuer=Store"
ENTRIES = {
    "alpha": [("Alpha Login", "alpha-user", "alpha-store-fixture.net", "11111111-1111-4111-8111-111111111111", True)],
    "bravo": [
        ("Bravo Login", "bravo-user", "bravo-store-fixture.org", "22222222-2222-4222-8222-222222222222", True),
        ("Bravo Password", "bravo-password-user", "bravo-password-fixture.com", "33333333-3333-4333-8333-333333333333", False),
    ],
}


def build(path: Path, name: str) -> None:
    kp = new_database(path, PASSWORD)
    group = kp.add_group(kp.root_group, "Store")
    for title, user, domain, identifier, has_code in ENTRIES[name]:
        entry = kp.add_entry(group, title, user, "fixture-password", url=f"https://{domain}")
        entry.uuid = UUID(identifier)
        if has_code:
            entry.otp = OTP
    kp.save()


def verify(path: Path, name: str, keepassxc_cli: str | None) -> None:
    kp = pykeepass.PyKeePass(str(path), password=PASSWORD)
    assert len(kp.entries) == len(ENTRIES[name])
    for entry, (title, user, domain, identifier, has_code) in zip(kp.entries, ENTRIES[name]):
        assert (entry.title, entry.username, entry.url, str(entry.uuid)) == (title, user, f"https://{domain}", identifier)
        assert entry.password == "fixture-password"
        assert not entry.expires
        assert entry.otp == (OTP if has_code else None)
    if keepassxc_cli:
        verify_keepassxc_lists_group(path, keepassxc_cli, PASSWORD, "Store")


def build_alpha(path: Path) -> None:
    build(path, "alpha")


def build_bravo(path: Path) -> None:
    build(path, "bravo")


def verify_alpha(path: Path, keepassxc_cli: str | None) -> None:
    verify(path, "alpha", keepassxc_cli)


def verify_bravo(path: Path, keepassxc_cli: str | None) -> None:
    verify(path, "bravo", keepassxc_cli)


GENERATORS = (
    Generator("autofill-store-alpha", fixture_path("autofill-store-alpha.kdbx"), build_alpha, verify_alpha),
    Generator("autofill-store-bravo", fixture_path("autofill-store-bravo.kdbx"), build_bravo, verify_bravo),
)
