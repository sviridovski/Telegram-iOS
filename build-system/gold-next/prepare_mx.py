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
                // Telegram 12.9.2 stores .message as an associated-value tuple;
                // .group holds an array of tuples. Inspect the first message
                // without stringifying an entire chat bubble.
                for payload in Mirror(reflecting: unwrapOptional(child.value)).children {
                    if payload.label == "message",
                       let first = Mirror(reflecting: payload.value).children.first?.value,
                       let id = extractId(fromMessage: unwrapOptional(first)) {
                        return id
                    }
                    if payload.label == "group",
                       let firstTuple = Mirror(reflecting: payload.value).children.first?.value,
                       let first = Mirror(reflecting: firstTuple).children.first?.value,
                       let id = extractId(fromMessage: unwrapOptional(first)) {
                        return id
                    }
                }
                // Keep the previous generic fast path for other item shapes.
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

# Goldgram folder navigation (#62): adapt the pinned Mx UI before Theos builds.
# Keep every original setting key, toggle action and behaviour unchanged.
mx_ui_path = root / "Sources/tgapi/UI/Mx.m"
mx_ui_source = mx_ui_path.read_text()
mx_folder_patches = [
  [
    "@property(nonatomic, assign) BOOL isGhostModeExpanded;",
    "@property(nonatomic, assign) BOOL isGhostModeExpanded;\n// nil is Goldgram's folder index; a number shows one existing MX section.\n@property(nonatomic, strong) NSNumber *goldgramSection;"
  ],
  [
    "  self.title = @\"Mx\";",
    "  self.title = self.goldgramSection ? [self tableView:self.tableView titleForHeaderInSection:0] : @\"Goldgram\";"
  ],
  [
    "- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {\n  return 7;\n}",
    "- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {\n  // The root lists the seven folders; an opened folder shows one section.\n  return 1;\n}"
  ],
  [
    "    numberOfRowsInSection:(NSInteger)section {\n  switch (section) {",
    "    numberOfRowsInSection:(NSInteger)section {\n  if (!self.goldgramSection) return 7;\n  section = self.goldgramSection.integerValue;\n  switch (section) {"
  ],
  [
    "    titleForHeaderInSection:(NSInteger)section {\n\n  switch (section) {",
    "    titleForHeaderInSection:(NSInteger)section {\n  if (!self.goldgramSection) return nil;\n  section = self.goldgramSection.integerValue;\n\n  switch (section) {"
  ],
  [
    "    titleForFooterInSection:(NSInteger)section {\n",
    "    titleForFooterInSection:(NSInteger)section {\n  if (!self.goldgramSection) return nil;\n  section = self.goldgramSection.integerValue;\n"
  ],
  [
    "         cellForRowAtIndexPath:(NSIndexPath *)indexPath {\n  UITableViewCell *cell;",
    "         cellForRowAtIndexPath:(NSIndexPath *)indexPath {\n  UITableViewCell *cell;\n  if (!self.goldgramSection) {\n    // Folder index: original feature rows and setting keys remain untouched.\n    static NSArray<NSString *> *icons;\n    static dispatch_once_t onceToken;\n    dispatch_once(&onceToken, ^{\n      icons = @[@\"eye.slash\", @\"person.crop.circle.badge.checkmark\",\n                @\"slider.horizontal.3\", @\"folder\", @\"location\",\n                @\"globe\", @\"info.circle\"];\n    });\n    NSArray<NSString *> *titles = @[\n      TGLoc(@\"GHOST_MODE_SECTION_HEADER\"),\n      TGLoc(@\"GHOST_EXCEPTIONS_SECTION_HEADER\"),\n      TGLoc(@\"MISC_SECTION_HEADER\"),\n      TGLoc(@\"FILE_FIXER_SECTION_HEADER\"),\n      TGLoc(@\"FAKE_LOCATION_SECTION_HEADER\"),\n      TGLoc(@\"LANGUAGE_SECTION_HEADER\"),\n      TGLoc(@\"CREDITS_SECTION_HEADER\")\n    ];\n    cell = [self normalCellFromTableView:tableView];\n    if (indexPath.row >= (NSInteger)titles.count) return cell;\n    cell.textLabel.text = titles[indexPath.row];\n    cell.detailTextLabel.text = nil;\n    cell.accessoryView = nil;\n    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;\n    cell.imageView.image = [UIImage systemImageNamed:icons[indexPath.row]];\n    cell.imageView.tintColor = [self dynamicColorBW];\n    return cell;\n  }\n  // Reuse the existing MX cell factory and original index-based setting map.\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row\n                                inSection:self.goldgramSection.integerValue];"
  ],
  [
    "    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {\n  [tableView deselectRowAtIndexPath:indexPath animated:YES];",
    "    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {\n  [tableView deselectRowAtIndexPath:indexPath animated:YES];\n  if (!self.goldgramSection) {\n    Mx *folder = [Mx new];\n    folder.goldgramSection = @(indexPath.row);\n    [self.navigationController pushViewController:folder animated:YES];\n    return;\n  }\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row\n                                inSection:self.goldgramSection.integerValue];"
  ],
  [
    "    canEditRowAtIndexPath:(NSIndexPath *)indexPath {\n  return indexPath.section == GHOST_EXCEPTIONS &&",
    "    canEditRowAtIndexPath:(NSIndexPath *)indexPath {\n  if (!self.goldgramSection) return NO;\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:self.goldgramSection.integerValue];\n  return indexPath.section == GHOST_EXCEPTIONS &&"
  ],
  [
    "           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {\n  return indexPath.section == GHOST_EXCEPTIONS",
    "           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {\n  if (!self.goldgramSection) return UITableViewCellEditingStyleNone;\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:self.goldgramSection.integerValue];\n  return indexPath.section == GHOST_EXCEPTIONS"
  ],
  [
    "     forRowAtIndexPath:(NSIndexPath *)indexPath {\n  if (editingStyle != UITableViewCellEditingStyleDelete) return;",
    "     forRowAtIndexPath:(NSIndexPath *)indexPath {\n  if (!self.goldgramSection) return;\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:self.goldgramSection.integerValue];\n  if (editingStyle != UITableViewCellEditingStyleDelete) return;"
  ],
  [
    "    accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {\n  if (indexPath.section != GHOST_EXCEPTIONS) return;",
    "    accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {\n  if (!self.goldgramSection) return;\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:self.goldgramSection.integerValue];\n  if (indexPath.section != GHOST_EXCEPTIONS) return;"
  ],
  [
    "indexSetWithIndex:GHOST_MODE",
    "indexSetWithIndex:0"
  ],
  [
    "indexSetWithIndex:GHOST_EXCEPTIONS",
    "indexSetWithIndex:0"
  ],
  [
    "indexSetWithIndex:MISC",
    "indexSetWithIndex:0"
  ],
  [
    "indexSetWithIndex:FILE_FIXER",
    "indexSetWithIndex:0"
  ],
  [
    "indexSetWithIndex:FAKE_LOCATION",
    "indexSetWithIndex:0"
  ]
]
for old, new in mx_folder_patches:
    if old not in mx_ui_source:
        raise SystemExit("Unexpected pinned Mx UI source; refusing folder patch")
    mx_ui_source = mx_ui_source.replace(old, new)
mx_ui_path.write_text(mx_ui_source)
print("Goldgram UI: 7 navigable folders, native MX settings preserved")
