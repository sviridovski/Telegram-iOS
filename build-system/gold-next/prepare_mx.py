"""Small, checked adaptations to the pinned Mx 1.0.0 source tree."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
path = root / "Sources/tgapi/UI/UIHooks.xm"
source = path.read_text()

def replace_once(before, after):
    global source
    if source.count(before) != 1:
        raise SystemExit(f"Unexpected Mx source: {before!r}")
    source = source.replace(before, after)

replace_once(
    "initWithTarget:_mxGestureTarget action:@selector(handleLongPress:)];",
    "initWithTarget:_mxGestureTarget action:@selector(handleLongPress:)];\n"
    "                    gr.minimumPressDuration = 3.0;",
)
replace_once(
    "action:@selector(__handleMxLongPress:)];",
    "action:@selector(__handleMxLongPress:)];\n"
    "        gr.minimumPressDuration = 3.0;",
)
replace_once(
    'if ([lower containsString:@"swiftgram"]) return YES;',
    '// Gold Next opens Mx from Support/Help rather than the Swiftgram settings row.\n'
    '    if ([lower isEqualToString:@"помощь"] || [lower isEqualToString:@"help"]) return YES;',
)
replace_once("@interface ASDisplayNode (TGExtra)", "@interface ASDisplayNode (Mx)")
# Export a stable, C-callable entry point. Swiftgram locates it in the injected
# Mx.dylib at runtime; existing Mx settings and gestures are unchanged.
replace_once(
    "void showUI() {",
    'extern "C" __attribute__((used, visibility("default"))) void goldgram_open_mx(void) {\n'
    '    dispatch_async(dispatch_get_main_queue(), ^{\n'
    '        showUI();\n'
    '    });\n'
    '}\n\n'
    'void showUI() {',
)
path.write_text(source)

# Confirm the parser being built targets the same schema as the new host.
compat = (root / "Sources/tgapi/api_sources/MxApiCompat.swift").read_text()
if "release-12.9.2" not in compat:
    raise SystemExit("Mx source does not declare Telegram 12.9.2 API compatibility")
print("Mx 1.0.0 prepared: 12.9.2 parser, Support/Help hold 3 seconds")
