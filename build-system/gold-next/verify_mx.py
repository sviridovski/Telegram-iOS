"""Check the packaged Mx and its non-system loader dependencies on macOS."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
mx = app / "Frameworks/Mx.dylib"
bundle = app / "Mx.bundle"
if not mx.is_file() or not (bundle / "langs.json").is_file():
    raise SystemExit("Mx runtime or localization bundle missing")
if not (bundle / "ru.lproj/Localizable.strings").is_file():
    raise SystemExit("Mx Russian localization missing")
with (app / "Info.plist").open("rb") as stream:
    executable = app / plistlib.load(stream)["CFBundleExecutable"]

def dependencies(binary):
    output = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    return [line.strip().split(" (compatibility version", 1)[0]
            for line in output.splitlines()[1:] if line.strip()]

host_deps = dependencies(executable)
if "@rpath/Mx.dylib" not in host_deps:
    raise SystemExit("Host has no Mx load command")
if b"Gold Next startup diagnostic" in executable.read_bytes():
    raise SystemExit("Startup diagnostic still present")
for path in app.rglob("*"):
    if "tgextra" in path.name.lower():
        raise SystemExit(f"TGExtra artifact remains: {path}")
for binary in [executable, mx]:
    for dependency in dependencies(binary):
        if "tgextra" in dependency.lower():
            raise SystemExit(f"TGExtra load command remains: {binary}")
        if dependency.startswith("/System/Library/") or dependency.startswith("/usr/lib/"):
            continue
        if dependency.startswith("@rpath/"):
            target = app / "Frameworks" / dependency[len("@rpath/"):]
        elif dependency.startswith("@loader_path/"):
            target = binary.parent / dependency[len("@loader_path/"):]
        elif dependency.startswith("@executable_path/"):
            target = app / dependency[len("@executable_path/"):]
        else:
            raise SystemExit(f"Unresolved jailbreak dependency: {dependency}")
        if not target.is_file():
            raise SystemExit(f"Missing dependency of {binary.name}: {dependency}")

print("OK Mx runtime, host loader, localization, dependencies and TGExtra cleanup")
