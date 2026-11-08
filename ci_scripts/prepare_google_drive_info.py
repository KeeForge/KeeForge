#!/usr/bin/env python3
"""Generate an app Info.plist with only a real platform Google OAuth callback."""
import argparse
import copy
import os
from pathlib import Path
import plistlib
import re
import sys


class ConfigurationError(ValueError):
    pass


def configured_info(template, platform, environment):
    info = copy.deepcopy(template)
    prefix, setting = ("GoogleDriveIOS", "IOS") if platform == "ios" else ("GoogleDriveMac", "MAC")
    client = environment.get(f"GOOGLE_DRIVE_{setting}_CLIENT_ID", "")
    redirect = environment.get(f"GOOGLE_DRIVE_{setting}_REDIRECT_URI", "")
    info.pop(prefix + "ClientID", None)
    info.pop(prefix + "RedirectURI", None)
    url_types = [entry for entry in info.get("CFBundleURLTypes", []) if entry.get("CFBundleURLName") != "Google Drive OAuth"]
    info["CFBundleURLTypes"] = url_types
    if not client:
        if redirect:
            raise ConfigurationError(f"GOOGLE_DRIVE_{setting}_REDIRECT_URI requires its platform client ID")
        return info
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+-]*\.apps\.googleusercontent\.com", client):
        raise ConfigurationError(f"GOOGLE_DRIVE_{setting}_CLIENT_ID is not a valid native-client configuration")
    stem = client.removesuffix(".apps.googleusercontent.com")
    scheme = "com.googleusercontent.apps." + stem
    expected_redirect = scheme + ":/oauthredirect"
    if redirect and redirect != expected_redirect:
        raise ConfigurationError(f"GOOGLE_DRIVE_{setting}_REDIRECT_URI does not match its native client callback")
    info[prefix + "ClientID"] = client
    info[prefix + "RedirectURI"] = expected_redirect
    if not any(scheme in entry.get("CFBundleURLSchemes", []) for entry in url_types):
        url_types.append({"CFBundleTypeRole": "Editor", "CFBundleURLName": "Google Drive OAuth", "CFBundleURLSchemes": [scheme]})
    return info


def self_test():
    template = {"CFBundleURLTypes": [{"CFBundleURLName": "OTP", "CFBundleURLSchemes": ["otpauth"]}],
                "GoogleDriveIOSClientID": "$(GOOGLE_DRIVE_IOS_CLIENT_ID)",
                "GoogleDriveIOSRedirectURI": "$(GOOGLE_DRIVE_IOS_REDIRECT_URI)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)"}
    original = copy.deepcopy(template)
    absent = configured_info(template, "ios", {})
    assert "GoogleDriveIOSClientID" not in absent
    assert absent["CFBundleURLTypes"] == template["CFBundleURLTypes"]
    ios = {"GOOGLE_DRIVE_IOS_CLIENT_ID": "fixture-ios.apps.googleusercontent.com"}
    enabled = configured_info(template, "ios", ios)
    assert enabled["GoogleDriveIOSRedirectURI"] == "com.googleusercontent.apps.fixture-ios:/oauthredirect"
    assert enabled["CFBundleURLTypes"][0] == template["CFBundleURLTypes"][0]
    assert enabled["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)"
    assert "GoogleDriveMacClientID" not in configured_info({}, "macos", ios)
    mac = {"GOOGLE_DRIVE_MAC_CLIENT_ID": "fixture-mac.apps.googleusercontent.com"}
    assert configured_info({}, "macos", mac)["GoogleDriveMacRedirectURI"] == "com.googleusercontent.apps.fixture-mac:/oauthredirect"
    for invalid in ["$(CLIENT)", "invalid", " fixture.apps.googleusercontent.com", "bad_scheme.apps.googleusercontent.com"]:
        try:
            configured_info(template, "ios", {"GOOGLE_DRIVE_IOS_CLIENT_ID": invalid})
        except ConfigurationError:
            pass
        else:
            raise AssertionError("Invalid native-client value accepted")
    for invalid in [{"GOOGLE_DRIVE_IOS_REDIRECT_URI": "unexpected:/oauthredirect"},
                    dict(ios, GOOGLE_DRIVE_IOS_REDIRECT_URI="unexpected:/oauthredirect")]:
        try:
            configured_info(template, "ios", invalid)
        except ConfigurationError:
            pass
        else:
            raise AssertionError("Mismatched or partial callback accepted")
    assert template == original
    assert configured_info(enabled, "ios", {}) == absent
    assert plistlib.dumps(configured_info(enabled, "ios", ios)) == plistlib.dumps(enabled)
    print("Google OAuth plist configuration self-test passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["ios", "macos"])
    parser.add_argument("--template", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.platform is None or args.template is None or args.output is None:
        parser.error("--platform, --template and --output are required")
    try:
        with args.template.open("rb") as source:
            template = plistlib.load(source)
        data = plistlib.dumps(configured_info(template, args.platform, os.environ), sort_keys=False)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(data)
    except (ConfigurationError, OSError, plistlib.InvalidFileException) as error:
        print(f"error: Google Drive Info.plist generation failed: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
