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

# Goldgram nested MX tool folders (#63). Apply only after the tested #62 UI.
# Each of the original twelve MISC controls is mapped to exactly one category;
# its original row ID and persisted NSUserDefaults key must remain unchanged.
mx_misc_groups = [[2,3,5,7,8],[1,4,6],[9,10],[0,11]]
assert sorted(index for group in mx_misc_groups for index in group) == list(range(12))
mx_misc_patches = [
  [
    "+ (NSArray<NSString *> *)ghostSubFeatureKeys;\n@end",
    "+ (NSArray<NSString *> *)ghostSubFeatureKeys;\n// Goldgram #63: MISC section is grouped into nested semantic categories.\n+ (NSArray<NSArray<NSNumber *> *> *)goldgramMiscRows;\n+ (NSArray<NSString *> *)goldgramMiscTitles;\n@end"
  ],
  [
    "@property(nonatomic, strong) NSNumber *goldgramSection;",
    "@property(nonatomic, strong) NSNumber *goldgramSection;\n@property(nonatomic, strong) NSNumber *goldgramMiscCategory;"
  ],
  [
    "@implementation Mx\n\n- (void)viewDidLoad {",
    "@implementation Mx\n\n// Original indices 0..11 are preserved: UI navigation does not change switch\n// keys, action tags, persisted settings, or injected hooks.\n+ (NSArray<NSArray<NSNumber *> *> *)goldgramMiscRows {\n  static NSArray<NSArray<NSNumber *> *> *groups;\n  static dispatch_once_t onceToken;\n  dispatch_once(&onceToken, ^{\n    groups = @[\n      @[@2, @3, @5, @7, @8], // removed / edited / ephemeral\n      @[@1, @4, @6],         // privacy / content access\n      @[@9, @10],            // media / downloads\n      @[@0, @11]             // ads / cosmetic tools\n    ];\n  });\n  return groups;\n}\n\n+ (NSArray<NSString *> *)goldgramMiscTitles {\n  NSString *language = [NSLocale preferredLanguages].firstObject ?: @\"\";\n  if ([language hasPrefix:@\"ru\"]) {\n    return @[@\"Удалённые и изменённые\", @\"Приватность и доступ\",\n             @\"Медиа и загрузки\", @\"Другие инструменты\"];\n  }\n  return @[@\"Deleted & edited\", @\"Privacy & access\",\n           @\"Media & downloads\", @\"Other tools\"];\n}\n\n- (void)viewDidLoad {"
  ],
  [
    "  if (!self.goldgramSection) return 7;\n  section = self.goldgramSection.integerValue;",
    "  if (!self.goldgramSection) return 7;\n  if (self.goldgramSection.integerValue == MISC) {\n    if (!self.goldgramMiscCategory) return 4;\n    NSInteger category = self.goldgramMiscCategory.integerValue;\n    NSArray *groups = [Mx goldgramMiscRows];\n    if (category < 0 || category >= (NSInteger)groups.count) return 0;\n    return [groups[category] count];\n  }\n  section = self.goldgramSection.integerValue;"
  ],
  [
    "  if (!self.goldgramSection) return nil;\n  section = self.goldgramSection.integerValue;\n\n  switch (section) {",
    "  if (!self.goldgramSection) return nil;\n  if (self.goldgramSection.integerValue == MISC && self.goldgramMiscCategory) {\n    NSInteger category = self.goldgramMiscCategory.integerValue;\n    NSArray *titles = [Mx goldgramMiscTitles];\n    if (category >= 0 && category < (NSInteger)titles.count) return titles[category];\n  }\n  section = self.goldgramSection.integerValue;\n\n  switch (section) {"
  ],
  [
    "  // Reuse the existing MX cell factory and original index-based setting map.\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row\n                                inSection:self.goldgramSection.integerValue];",
    "  if (self.goldgramSection.integerValue == MISC) {\n    if (!self.goldgramMiscCategory) {\n      static NSArray<NSString *> *icons;\n      static dispatch_once_t onceToken;\n      dispatch_once(&onceToken, ^{\n        icons = @[@\"text.badge.checkmark\", @\"lock.shield\", @\"square.and.arrow.down\",\n                  @\"wand.and.stars\"];\n      });\n      NSArray<NSString *> *titles = [Mx goldgramMiscTitles];\n      cell = [self normalCellFromTableView:tableView];\n      if (indexPath.row < 0 || indexPath.row >= (NSInteger)titles.count) return cell;\n      cell.textLabel.text = titles[indexPath.row];\n      cell.detailTextLabel.text = nil;\n      cell.accessoryView = nil;\n      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;\n      cell.imageView.image = [UIImage systemImageNamed:icons[indexPath.row]];\n      cell.imageView.tintColor = [self dynamicColorBW];\n      return cell;\n    }\n    NSInteger category = self.goldgramMiscCategory.integerValue;\n    NSArray<NSArray<NSNumber *> *> *groups = [Mx goldgramMiscRows];\n    if (category < 0 || category >= (NSInteger)groups.count ||\n        indexPath.row < 0 || indexPath.row >= (NSInteger)groups[category].count) {\n      return [self normalCellFromTableView:tableView];\n    }\n    NSInteger originalRow = groups[category][indexPath.row].integerValue;\n    indexPath = [NSIndexPath indexPathForRow:originalRow inSection:MISC];\n  }\n  // Reuse original MX row mapping; UISwitch tags still encode source row IDs.\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row\n                                inSection:self.goldgramSection.integerValue];"
  ],
  [
    "  indexPath = [NSIndexPath indexPathForRow:indexPath.row\n                                inSection:self.goldgramSection.integerValue];\n\n  if (indexPath.section == GHOST_MODE && indexPath.row == 1)",
    "  if (self.goldgramSection.integerValue == MISC) {\n    if (!self.goldgramMiscCategory) {\n      if (indexPath.row < 0 || indexPath.row >= (NSInteger)[Mx goldgramMiscRows].count) return;\n      Mx *folder = [Mx new];\n      folder.goldgramSection = @(MISC);\n      folder.goldgramMiscCategory = @(indexPath.row);\n      [self.navigationController pushViewController:folder animated:YES];\n      return;\n    }\n    NSInteger category = self.goldgramMiscCategory.integerValue;\n    NSArray<NSArray<NSNumber *> *> *groups = [Mx goldgramMiscRows];\n    if (category < 0 || category >= (NSInteger)groups.count ||\n        indexPath.row < 0 || indexPath.row >= (NSInteger)groups[category].count) return;\n    indexPath = [NSIndexPath indexPathForRow:groups[category][indexPath.row].integerValue\n                                  inSection:MISC];\n  }\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row\n                                inSection:self.goldgramSection.integerValue];\n\n  if (indexPath.section == GHOST_MODE && indexPath.row == 1)"
  ]
]
for before, after in mx_misc_patches:
    if mx_ui_source.count(before) != 1:
        raise SystemExit("Unexpected Goldgram UI: #63 MISC patch anchor mismatch")
    mx_ui_source = mx_ui_source.replace(before, after)
mx_ui_path.write_text(mx_ui_source)
print("Goldgram #63: four MISC subfolders, all 12 original controls retained")


# Goldgram #64: compile the local SQLite store but do not activate capture.
# Leave the upstream Mx 1.0.0 pin and all message hooks unchanged.
sqlite_source = pathlib.Path(__file__).with_name("GoldgramHistoryStore.swift")
if not sqlite_source.is_file():
    raise SystemExit("Goldgram SQLite source is missing")
sqlite_destination = root / "Sources/tgapi/GoldgramHistoryStore.swift"
if sqlite_destination.exists():
    raise SystemExit("Unexpected upstream Goldgram SQLite module")
sqlite_destination.write_text(sqlite_source.read_text())

# Theos discovers *.swift automatically; link the iOS system SQLite library.
makefile_path = root / "Makefile"
makefile_source = makefile_path.read_text()
link_anchor = "$(TWEAK_NAME)_LIBRARIES = z\n"
if makefile_source.count(link_anchor) != 1:
    raise SystemExit("Unexpected pinned Mx Makefile SQLite linker anchor")
makefile_path.write_text(
    makefile_source.replace(link_anchor, "$(TWEAK_NAME)_LIBRARIES = z sqlite3\n")
)
print("Goldgram #64: isolated SQLite schema ready, capture remains disabled")


# Goldgram #65 — compile migration adapter; never invoke it automatically.
importer_src = pathlib.Path(__file__).with_name("GoldgramLegacyImporter.swift")
if not importer_src.is_file():
    raise SystemExit("Missing Goldgram legacy importer")
importer_dst = root / "Sources/tgapi/GoldgramLegacyImporter.swift"
if importer_dst.exists():
    raise SystemExit("Unexpected upstream legacy importer")
importer_dst.write_text(importer_src.read_text())
print("Goldgram #65: account-gated importer available, not running")


# Goldgram #66: one explicitly opt-in control in Deleted/Edited MISC.
# The legacy feature row IDs 0...11 must remain exactly unchanged.
goldgram_capture_patches = [
    ('groups = @[\n      @[@2, @3, @5, @7, @8],',
     'groups = @[\n      @[@2, @3, @5, @7, @8, @12],'),
    ('  case MISC:\n    return 12;',
     '  case MISC:\n    return 13;'),
    ('      cell.detailTextLabel.text = TGLoc(@"VIDEO_TO_VOICE_SUBTITLE");\n    }\n\n    UISwitch *toggle',
     '      cell.detailTextLabel.text = TGLoc(@"VIDEO_TO_VOICE_SUBTITLE");\n    }\n    if (indexPath.row == 12) {\n      BOOL russian = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"];\n      cell.imageView.image = [UIImage systemImageNamed:@"externaldrive.badge.plus"];\n      cell.imageView.tintColor = [self dynamicColorBW];\n      cell.textLabel.text = russian ? @"Оригиналы в SQLite" : @"SQLite originals archive";\n      cell.detailTextLabel.text = russian ? @"Сохранять входящие личные сообщения локально" : @"Save incoming private-chat originals locally";\n    }\n\n    UISwitch *toggle'),
    ('    case 10:\n      return kVideoToVoice;\n    default:',
     '    case 10:\n      return kVideoToVoice;\n    case 12:\n      return @"GoldgramSQLiteCaptureEnabled";\n    default:')
]
for before, after in goldgram_capture_patches:
    if mx_ui_source.count(before) != 1:
        raise SystemExit("Unexpected pinned Goldgram Mx UI for #66 capture setting")
    mx_ui_source = mx_ui_source.replace(before, after)
mx_ui_path.write_text(mx_ui_source)
print("Goldgram #66: personal-chat SQLite archiving toggle is default OFF")

# Goldgram #71: three read-only history folder entry points (UI atom only).
# Keep all existing MX rows, hook symbols, toggles, and account-scoped DB untouched.
# Do not fabricate archive entries before account-safe SQLite readback is ready.
mx_history_patches = [
    ("@property(nonatomic, strong) NSNumber *goldgramMiscCategory;",
     "@property(nonatomic, strong) NSNumber *goldgramMiscCategory;\n// Goldgram #71: account-safe history navigation starts with category-only UI.\n@property(nonatomic, strong) NSNumber *goldgramHistoryCategory;"),
    ("  if (!self.goldgramSection) return 7;\n  if (self.goldgramSection.integerValue == MISC) {",
     "  if (self.goldgramHistoryCategory) return 1;\n  if (!self.goldgramSection) return 7;\n  if (self.goldgramSection.integerValue == MISC) {"),
    ("    return [groups[category] count];",
     "    return [groups[category] count] + (category == 0 ? 3 : 0);"),
    ("  if (!self.goldgramSection) return nil;\n  if (self.goldgramSection.integerValue == MISC && self.goldgramMiscCategory) {",
     "  if (self.goldgramHistoryCategory) {\n    NSInteger kind = self.goldgramHistoryCategory.integerValue;\n    BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@\"ru\"];\n    NSArray *titles = ru ? @[@\"Личные сообщения\", @\"Группы и чаты\", @\"Каналы\"] : @[@\"Personal messages\", @\"Groups & chats\", @\"Channels\"];\n    return kind >= 0 && kind < (NSInteger)titles.count ? titles[kind] : nil;\n  }\n  if (!self.goldgramSection) return nil;\n  if (self.goldgramSection.integerValue == MISC && self.goldgramMiscCategory) {"),
    ("    titleForFooterInSection:(NSInteger)section {\n  if (!self.goldgramSection) return nil;",
     "    titleForFooterInSection:(NSInteger)section {\n  if (self.goldgramHistoryCategory) return nil;\n  if (!self.goldgramSection) return nil;"),
    ("  if (!self.goldgramSection) {\n    // Folder index: original feature rows and setting keys remain untouched.",
     "  if (self.goldgramHistoryCategory) {\n    cell = [self normalCellFromTableView:tableView];\n    BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@\"ru\"];\n    cell.textLabel.text = ru ? @\"Просмотр архива готовится\" : @\"Archive reader not connected yet\";\n    cell.detailTextLabel.text = ru ? @\"SQLite хранит данные отдельно; чтение добавим следующим атомом\" : @\"SQLite capture is separate; browsing comes in a later atom\";\n    cell.imageView.image = [UIImage systemImageNamed:@\"externaldrive\"];\n    cell.accessoryView = nil;\n    cell.accessoryType = UITableViewCellAccessoryNone;\n    cell.selectionStyle = UITableViewCellSelectionStyleNone;\n    return cell;\n  }\n  if (!self.goldgramSection) {\n    // Folder index: original feature rows and setting keys remain untouched."),
    ("    if (category < 0 || category >= (NSInteger)groups.count ||\n        indexPath.row < 0 || indexPath.row >= (NSInteger)groups[category].count) {\n      return [self normalCellFromTableView:tableView];\n    }\n    NSInteger originalRow = groups[category][indexPath.row].integerValue;",
     "    if (category == 0 && indexPath.row >= (NSInteger)groups[0].count &&\n        indexPath.row < (NSInteger)groups[0].count + 3) {\n      NSInteger kind = indexPath.row - (NSInteger)groups[0].count;\n      BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@\"ru\"];\n      NSArray *titles = ru ? @[@\"Личные сообщения\", @\"Группы и чаты\", @\"Каналы\"] : @[@\"Personal messages\", @\"Groups & chats\", @\"Channels\"];\n      NSArray *icons = @[@\"person.crop.circle\", @\"person.3\", @\"megaphone\"];\n      cell = [self normalCellFromTableView:tableView];\n      cell.textLabel.text = titles[kind];\n      cell.detailTextLabel.text = nil;\n      cell.imageView.image = [UIImage systemImageNamed:icons[kind]];\n      cell.imageView.tintColor = [self dynamicColorBW];\n      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;\n      cell.accessoryView = nil;\n      return cell;\n    }\n    if (category < 0 || category >= (NSInteger)groups.count ||\n        indexPath.row < 0 || indexPath.row >= (NSInteger)groups[category].count) {\n      return [self normalCellFromTableView:tableView];\n    }\n    NSInteger originalRow = groups[category][indexPath.row].integerValue;"),
    ("  [tableView deselectRowAtIndexPath:indexPath animated:YES];\n  if (!self.goldgramSection) {",
     "  [tableView deselectRowAtIndexPath:indexPath animated:YES];\n  if (self.goldgramHistoryCategory) return;\n  if (!self.goldgramSection) {"),
    ("    if (category < 0 || category >= (NSInteger)groups.count ||\n        indexPath.row < 0 || indexPath.row >= (NSInteger)groups[category].count) return;",
     "    if (category == 0 && indexPath.row >= (NSInteger)groups[0].count &&\n        indexPath.row < (NSInteger)groups[0].count + 3) {\n      Mx *folder = [Mx new];\n      folder.goldgramSection = @(MISC);\n      folder.goldgramMiscCategory = @(0);\n      folder.goldgramHistoryCategory = @(indexPath.row - (NSInteger)groups[0].count);\n      [self.navigationController pushViewController:folder animated:YES];\n      return;\n    }\n    if (category < 0 || category >= (NSInteger)groups.count ||\n        indexPath.row < 0 || indexPath.row >= (NSInteger)groups[category].count) return;"),
]
for before, after in mx_history_patches:
    if mx_ui_source.count(before) != 1:
        raise SystemExit("Unexpected pinned Goldgram UI: #71 history folder patch mismatch")
    mx_ui_source = mx_ui_source.replace(before, after)
mx_ui_path.write_text(mx_ui_source)
print("Goldgram #71: personal/groups/channels entry points; SQLite reader pending")

# Goldgram #74: compile a native archive browser without modifying legacy MX.
goldgram_browser = pathlib.Path(__file__).with_name("GoldgramArchiveScreen.swift")
goldgram_browser_dest = root / "Sources/tgapi/GoldgramArchiveScreen.swift"
if not goldgram_browser.is_file() or goldgram_browser_dest.exists():
    raise SystemExit("Goldgram browser source missing or unexpected upstream file")
goldgram_browser_dest.write_text(goldgram_browser.read_text())
browser_header = "#import <UIKit/UIKit.h>"
if mx_ui_source.count(browser_header) != 1:
    raise SystemExit("Goldgram #74 browser header mismatch")
mx_ui_source = mx_ui_source.replace(browser_header, "#import <UIKit/UIKit.h>\n\n// Runtime-only interface: does not link the Mx menu against a Swift class.\n@interface NSObject (GoldgramBrowserFactory)\n- (instancetype)initWithCategory:(NSInteger)category;\n@end")
browser_entry = "      Mx *folder = [Mx new];\n      folder.goldgramSection = @(MISC);\n      folder.goldgramMiscCategory = @(0);\n      folder.goldgramHistoryCategory = @(indexPath.row - (NSInteger)groups[0].count);\n      [self.navigationController pushViewController:folder animated:YES];\n      return;"
if mx_ui_source.count(browser_entry) != 1:
    raise SystemExit("Goldgram #74 history entry mismatch")
mx_ui_source = mx_ui_source.replace(browser_entry, "      NSInteger kind = indexPath.row - (NSInteger)groups[0].count;\n      Class browser = NSClassFromString(@\"GoldgramArchiveScreen\");\n      if (!browser || ![browser instancesRespondToSelector:@selector(initWithCategory:)]) return;\n      id controller = [[browser alloc] initWithCategory:kind];\n      if ([controller isKindOfClass:UIViewController.class]) {\n        [self.navigationController pushViewController:controller animated:YES];\n      }\n      return;")
mx_ui_path.write_text(mx_ui_source)
print("Goldgram #74: native SQLite browser wired to history folders")

# Goldgram #79: root action, outside every original MX setting/folder index.
clear_patches = [
    ("- (instancetype)initWithCategory:(NSInteger)category;\n@end",
     "- (instancetype)initWithCategory:(NSInteger)category;\n+ (void)presentClearHistoryFromController:(UIViewController *)controller;\n@end"),
    ("  if (!self.goldgramSection) return 7;",
     "  if (!self.goldgramSection) return 8;"),
    ("  if (!self.goldgramSection) {\n    // Folder index:",
     """  if (!self.goldgramSection && indexPath.row == 7) {
    cell = [self normalCellFromTableView:tableView];
    cell.textLabel.text = @"Очистить логи";
    cell.textLabel.textColor = UIColor.systemRedColor;
    cell.detailTextLabel.text = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = [UIImage systemImageNamed:@"trash"];
    cell.imageView.tintColor = UIColor.systemRedColor;
    return cell;
  }
  if (!self.goldgramSection) {
    // Folder index:"""),
    ("  if (self.goldgramHistoryCategory) return;\n  if (!self.goldgramSection) {",
     """  if (self.goldgramHistoryCategory) return;
  if (!self.goldgramSection && indexPath.row == 7) {
    Class browser = NSClassFromString(@"GoldgramArchiveScreen");
    if ([browser respondsToSelector:@selector(presentClearHistoryFromController:)]) {
      [browser presentClearHistoryFromController:self];
    }
    return;
  }
  if (!self.goldgramSection) {"""),
]
for before, after in clear_patches:
    if mx_ui_source.count(before) != 1:
        raise SystemExit("Goldgram #79 clear-history menu anchor mismatch")
    mx_ui_source = mx_ui_source.replace(before, after)
mx_ui_path.write_text(mx_ui_source)
print("Goldgram #79: confirmed account-scoped clear history on root menu")
