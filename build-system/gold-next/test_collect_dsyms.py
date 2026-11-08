"""Exercise symbol selection on a staged IPA with two Bazel configurations."""
from pathlib import Path
import plistlib
import tempfile
from unittest.mock import patch
from zipfile import ZipFile

from collect_dsyms import collect


def check_output(args, text):
    return args[-1].read_text()


def run(args, check):
    with ZipFile(args[-1], "w") as archive:
        for path in args[-2].rglob("*"):
            if path.is_file():
                archive.write(path, path.relative_to(args[-2]))


with tempfile.TemporaryDirectory() as temp, patch("collect_dsyms.subprocess.check_output", check_output), patch("collect_dsyms.subprocess.run", run):
    root = Path(temp)
    app = root / "Swiftgram.app"
    out = root / "bazel-out"
    archive = root / "symbols.zip"
    for index, name in enumerate(("Swiftgram", "PostboxFramework", "TelegramCoreFramework")):
        bundle = app if index == 0 else app / "Frameworks" / (name + ".framework")
        bundle.mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": name}))
        uuid = f"UUID: 00000000-0000-0000-0000-{index:012x} (arm64)"
        (bundle / name).write_text(uuid)
        for config in ("wrong", "matching"):
            dwarf = out / config / "bin/Telegram" / (bundle.name + ".dSYM") / "Contents/Resources/DWARF" / name
            dwarf.parent.mkdir(parents=True)
            dwarf.write_text(uuid if config == "matching" else uuid.replace("arm64", "x86_64"))
    collect(app, out, archive)
    with ZipFile(archive) as zipped:
        assert len(zipped.read("UUIDs.txt").splitlines()) == 3
    dwarf.unlink()
    try:
        collect(app, out, archive)
    except SystemExit as error:
        assert "TelegramCoreFramework" in str(error)
    else:
        raise AssertionError("missing matching framework symbols accepted")
