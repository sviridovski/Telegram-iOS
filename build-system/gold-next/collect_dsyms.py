"""Package symbols whose LC_UUIDs match every slice of the distributed IPA."""
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


def uuids(path):
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", path], text=True)
    result = set(re.findall(r"^UUID: ([0-9a-fA-F-]{36}) \(([^)]+)\)", output, re.M))
    if not result:
        raise ValueError(f"No Mach-O UUIDs found in {path}")
    return result


def collect(app, bazel_out, output):
    bundles = [app] + [app / "Frameworks" / (name + ".framework")
                       for name in ("PostboxFramework", "TelegramCoreFramework")]
    wanted = {}
    for bundle in bundles:
        with (bundle / "Info.plist").open("rb") as stream:
            executable = bundle / plistlib.load(stream)["CFBundleExecutable"]
        wanted[executable.name] = uuids(executable)

    with tempfile.TemporaryDirectory() as temp:
        target = Path(temp) / "dSYMs"
        target.mkdir()
        manifest = []
        for root in bazel_out.glob("*/bin/Telegram"):
            for directory, dirs, _ in os.walk(root):
                for name in dirs.copy():
                    if not name.endswith(".dSYM"):
                        continue
                    dirs.remove(name)
                    dsym = Path(directory) / name
                    for dwarf in (dsym / "Contents/Resources/DWARF").glob("*"):
                        if dwarf.name not in wanted or uuids(dwarf) != wanted[dwarf.name]:
                            continue
                        shutil.copytree(dsym, target / name)
                        # Validate the copied payload, including symlink materialization.
                        copied = target / name / "Contents/Resources/DWARF" / dwarf.name
                        if uuids(copied) != wanted[dwarf.name]:
                            raise ValueError(f"Copied symbols differ for {dwarf.name}")
                        for uuid, arch in sorted(wanted.pop(dwarf.name)):
                            manifest.append(f"{dwarf.name} {arch} {uuid}")
        if wanted:
            raise SystemExit(f"Missing matching symbols: {wanted}")
        (target / "UUIDs.txt").write_text("\n".join(manifest) + "\n")
        subprocess.run(["ditto", "-c", "-k", "--keepParent", target, output], check=True)


if __name__ == "__main__":
    collect(*(Path(arg).resolve() for arg in sys.argv[1:]))
