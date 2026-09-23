#!/usr/bin/env python3
"""Retarget the app and bundled extensions before the user's KSign signing pass."""

import pathlib
import plistlib
import sys
import tempfile
import zipfile


IDENTIFIER_KEYS = {
    "CFBundleIdentifier",
    "CFBundleURLName",
    "WKAppBundleIdentifier",
    "WKCompanionAppBundleIdentifier",
}


def replace_identifiers(value, old_id, new_id):
    if isinstance(value, dict):
        return {
            key: (
                new_id + item[len(old_id):]
                if key in IDENTIFIER_KEYS
                and isinstance(item, str)
                and (item == old_id or item.startswith(old_id + "."))
                else replace_identifiers(item, old_id, new_id)
            )
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [replace_identifiers(item, old_id, new_id) for item in value]
    return value


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: retarget_ipa.py <ipa> <original bundle id> <new bundle id>")
    ipa_path = pathlib.Path(sys.argv[1])
    old_id, new_id = sys.argv[2:]
    if old_id == new_id:
        raise SystemExit("the new bundle id must differ from the original")
    changed = []
    with tempfile.NamedTemporaryFile(dir=ipa_path.parent, suffix=".ipa", delete=False) as tmp:
        tmp_path = pathlib.Path(tmp.name)
    try:
        with zipfile.ZipFile(ipa_path, "r") as source, zipfile.ZipFile(
            tmp_path, "w", allowZip64=True
        ) as target:
            for item in source.infolist():
                data = source.read(item.filename)
                if item.filename.startswith("Payload/") and item.filename.endswith("/Info.plist"):
                    try:
                        info = plistlib.loads(data)
                    except (ValueError, TypeError):
                        info = None
                    if isinstance(info, dict):
                        updated = replace_identifiers(info, old_id, new_id)
                        if updated != info:
                            fmt = (
                                plistlib.FMT_BINARY
                                if data.startswith(b"bplist00")
                                else plistlib.FMT_XML
                            )
                            data = plistlib.dumps(updated, fmt=fmt, sort_keys=False)
                            changed.append((item.filename, updated.get("CFBundleIdentifier")))
                target.writestr(item, data)
        with zipfile.ZipFile(tmp_path) as verified:
            app_infos = [
                name for name in verified.namelist()
                if name.startswith("Payload/")
                and name.count("/") == 2
                and name.endswith(".app/Info.plist")
            ]
            if len(app_infos) != 1:
                raise RuntimeError(f"expected one app Info.plist, found {app_infos}")
            app_id = plistlib.loads(verified.read(app_infos[0]))["CFBundleIdentifier"]
            if app_id != new_id:
                raise RuntimeError(f"main bundle id is still {app_id!r}")
            extension_infos = [
                name for name in verified.namelist()
                if "/PlugIns/" in name and name.endswith(".appex/Info.plist")
            ]
            if len(extension_infos) < 6:
                raise RuntimeError(f"expected at least six extensions, found {len(extension_infos)}")
            for name in extension_infos:
                identifier = plistlib.loads(verified.read(name))["CFBundleIdentifier"]
                if not identifier.startswith(new_id + "."):
                    raise RuntimeError(f"extension has mismatched id: {name}: {identifier}")
        tmp_path.replace(ipa_path)
    finally:
        tmp_path.unlink(missing_ok=True)
    for name, identifier in changed:
        print(f"Updated {name}: {identifier}")


if __name__ == "__main__":
    main()
