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
# Disable one hot-path debug write, without changing the UI hook behavior.
# Accessibility labels may include message contents; never persist unmatched
# labels or synchronously write a log file during chat rendering.
replace_once(
    '        customLog2(@"[Mx] unmatched label: %@", label);',
    '        // Ordinary accessibility labels are intentionally not logged.',
)
path.write_text(source)

# The message-bubble layout hook asks for an ID on every layout pass.
# Extract it through the stored message fields first; avoid allocating a
# description and compiling regexes when the ordinary structure is available.
# The original ID extraction paths remain as a fallback for other item shapes.
parser_path = root / "Sources/tgapi/TLParser.swift"
parser_source = parser_path.read_text()
parser_anchor = '    @objc static func getMessageId(from item: Any) -> NSNumber? {\n'
if parser_source.count(parser_anchor) != 1:
    raise SystemExit("Unexpected Mx TLParser ID extraction entry point")
parser_fast_path = """        // Prefer the stored message id over expensive descriptions and regex.
        // Message items are often Optional<ChatMessageItemImpl>; unwrap them first.
        // Keep the existing description/dump extraction as an untouched fallback.
        let fastItem = unwrapOptional(item)
        for child in Mirror(reflecting: fastItem).children {
            switch child.label {
            case "content":
                for nested in Mirror(reflecting: unwrapOptional(child.value)).children
                where nested.label == "firstMessage" || nested.label == "message" {
                    if let id = extractId(fromMessage: unwrapOptional(nested.value)) {
                        return id
                    }
                }
            case "firstMessage", "message":
                if let id = extractId(fromMessage: unwrapOptional(child.value)) {
                    return id
                }
            default:
                break
            }
        }

"""
parser_source = parser_source.replace(parser_anchor, parser_anchor + parser_fast_path)
parser_path.write_text(parser_source)

# Confirm the parser being built targets the same schema as the new host.
compat = (root / "Sources/tgapi/api_sources/MxApiCompat.swift").read_text()
if "release-12.9.2" not in compat:
    raise SystemExit("Mx source does not declare Telegram 12.9.2 API compatibility")
print("Mx 1.0.0 prepared: 12.9.2 parser, Support/Help hold 3 seconds")
