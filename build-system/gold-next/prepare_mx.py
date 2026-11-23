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
# Goldgram #221: expose the verified SQLite revision count on the EXISTING
# Mx pencil badge beside a chat message. The chat layout only checks an
# in-memory cache; SQLite is read asynchronously on the Goldgram storage queue.
# Keep the original Mx tracker and its fallback menu fully intact.
def patch_chat_badge(before, after, name):
    global source
    if source.count(before) != 1:
        raise SystemExit("Goldgram #221 chat badge anchor mismatch: " + name)
    source = source.replace(before, after, 1)

patch_chat_badge(
    "#import <objc/message.h>",
    "#import <objc/message.h>\n#import <dlfcn.h>",
    "dlfcn")
patch_chat_badge(
    "static const NSInteger kMxEditBadgeTag = 8899;",
    """static int32_t goldgramVerifiedChatEditCount(NSNumber *msgId, NSNumber *peerKey) {
    if (!msgId || !peerKey) return -1;
    typedef int32_t (*CountFn)(int64_t, int32_t);
    static CountFn counter = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        counter = (CountFn)dlsym(RTLD_DEFAULT, "goldgram_chat_edit_count_v1");
    });
    return counter ? counter(peerKey.longLongValue, msgId.intValue) : -1;
}
static BOOL goldgramShowChatRevisions(NSNumber *msgId, NSNumber *peerKey) {
    if (!msgId || !peerKey) return NO;
    typedef int32_t (*ShowFn)(int64_t, int32_t);
    static ShowFn show = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        show = (ShowFn)dlsym(RTLD_DEFAULT, "goldgram_chat_show_revisions_v1");
    });
    return show && show(peerKey.longLongValue, msgId.intValue) == 1;
}

static const NSInteger kMxEditBadgeTag = 8899;""",
    "cache bridge")
patch_chat_badge(
    "    NSArray<NSString *> *versions = [TLParser editHistoryForId:msgId peer:peerKey];\n"
    "    if (versions.count < 2) return;",
    "    // Prefer the full account-scoped Goldgram history when present.\n"
    "    // The legacy Mx Anti-Edit dialog remains the fallback.\n"
    "    if (goldgramShowChatRevisions(msgId, peerKey)) return;\n"
    "    NSArray<NSString *> *versions = [TLParser editHistoryForId:msgId peer:peerKey];\n"
    "    if (versions.count < 2) return;",
    "tap fallback")
patch_chat_badge(
    """    NSUInteger versions = (msgId != nil)
        ? [TLParser editHistoryForId:msgId peer:peerKey].count
        : 0;
    BOOL hasHistory = (versions > 1);""",
    """    NSUInteger mxVersions = (msgId != nil)
        ? [TLParser editHistoryForId:msgId peer:peerKey].count
        : 0;
    int32_t verifiedEdits = goldgramVerifiedChatEditCount(msgId, peerKey);
    NSUInteger edits = mxVersions > 1 ? mxVersions - 1 : 0;
    if (verifiedEdits > 0) edits = MAX(edits, (NSUInteger)verifiedEdits);
    BOOL hasHistory = edits > 0;""",
    "badge counts")
patch_chat_badge(
    """    objc_setAssociatedObject(badge, &kMxEditMsgIdKey, msgId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);""",
    """    // Show the actual number of known edits without opening the archive.
    // Never place message text or peer identity in the visual badge.
    [badge setImage:nil forState:UIControlStateNormal];
    [badge setTitle:[NSString stringWithFormat:@"✎%lu", (unsigned long)edits]
          forState:UIControlStateNormal];
    badge.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
    badge.accessibilityLabel = [NSString stringWithFormat:@"Редакций: %lu",
                                (unsigned long)edits];
    objc_setAssociatedObject(badge, &kMxEditMsgIdKey, msgId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);""",
    "badge title")
patch_chat_badge(
    """        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessagesChanged:) name:@"MxMessageEditedRealtime" object:nil];""",
    """        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessagesChanged:) name:@"MxMessageEditedRealtime" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessagesChanged:) name:@"GoldgramChatHistoryBadgeChanged" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleGoldgramArchiveChanged:) name:@"GoldgramArchiveChanged" object:nil];""",
    "badge notifications")
patch_chat_badge(
    """}
@end

// ============================================================
// Edit history: a pencil badge""",
    """}
- (void)handleGoldgramArchiveChanged:(NSNotification *)note {
    // Bridge COMMIT finished. Drop stale counts; every visible message can
    // refresh without running SQLite queries on the UI/layout thread.
    typedef void (*ResetFn)(void);
    ResetFn reset = (ResetFn)dlsym(RTLD_DEFAULT,
                                  "goldgram_chat_edit_cache_reset_v1");
    if (reset) reset();
    NSHashTable *copy = nil;
    @synchronized(activeMessageNodes) { copy = [activeMessageNodes copy]; }
    for (ASDisplayNode *node in copy) {
        NSNumber *mid = [TLParser getMessageIdFromNode:node];
        if (!mid) continue;
        NSNumber *peer = [TLParser getMessagePeerKeyFromNode:node];
        dispatch_async(dispatch_get_main_queue(), ^{
            updateMxEditBadge(node, mid, peer);
        });
    }
}
@end

// ============================================================
// Edit history: a pencil badge""",
    "archive refresh")
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

# Goldgram history: personal/groups/channels plus an all-chat deleted folder.
# Keep all existing MX rows, hook symbols, toggles, and account-scoped DB untouched.
# Do not fabricate archive entries before account-safe SQLite readback is ready.
mx_history_patches = [
    ("@property(nonatomic, strong) NSNumber *goldgramMiscCategory;",
     "@property(nonatomic, strong) NSNumber *goldgramMiscCategory;\n// Goldgram #71: account-safe history navigation starts with category-only UI.\n@property(nonatomic, strong) NSNumber *goldgramHistoryCategory;"),
    ("  if (!self.goldgramSection) return 7;\n  if (self.goldgramSection.integerValue == MISC) {",
     "  if (self.goldgramHistoryCategory) return 1;\n  if (!self.goldgramSection) return 7;\n  if (self.goldgramSection.integerValue == MISC) {"),
    ("    return [groups[category] count];",
     "    return [groups[category] count] + (category == 0 ? 4 : 0);"),
    ("  if (!self.goldgramSection) return nil;\n  if (self.goldgramSection.integerValue == MISC && self.goldgramMiscCategory) {",
     "  if (self.goldgramHistoryCategory) {\n    NSInteger kind = self.goldgramHistoryCategory.integerValue;\n    BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@\"ru\"];\n    NSArray *titles = ru ? @[@\"Личные сообщения\", @\"Группы и чаты\", @\"Каналы\", @\"Удалённые сообщения\"] : @[@\"Personal messages\", @\"Groups & chats\", @\"Channels\", @\"Deleted messages\"];\n    return kind >= 0 && kind < (NSInteger)titles.count ? titles[kind] : nil;\n  }\n  if (!self.goldgramSection) return nil;\n  if (self.goldgramSection.integerValue == MISC && self.goldgramMiscCategory) {"),
    ("    titleForFooterInSection:(NSInteger)section {\n  if (!self.goldgramSection) return nil;",
     "    titleForFooterInSection:(NSInteger)section {\n  if (self.goldgramHistoryCategory) return nil;\n  if (!self.goldgramSection) return nil;"),
    ("  if (!self.goldgramSection) {\n    // Folder index: original feature rows and setting keys remain untouched.",
     "  if (self.goldgramHistoryCategory) {\n    cell = [self normalCellFromTableView:tableView];\n    BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@\"ru\"];\n    cell.textLabel.text = ru ? @\"Просмотр архива готовится\" : @\"Archive reader not connected yet\";\n    cell.detailTextLabel.text = ru ? @\"SQLite хранит данные отдельно; чтение добавим следующим атомом\" : @\"SQLite capture is separate; browsing comes in a later atom\";\n    cell.imageView.image = [UIImage systemImageNamed:@\"externaldrive\"];\n    cell.accessoryView = nil;\n    cell.accessoryType = UITableViewCellAccessoryNone;\n    cell.selectionStyle = UITableViewCellSelectionStyleNone;\n    return cell;\n  }\n  if (!self.goldgramSection) {\n    // Folder index: original feature rows and setting keys remain untouched."),
    ("    if (category < 0 || category >= (NSInteger)groups.count ||\n        indexPath.row < 0 || indexPath.row >= (NSInteger)groups[category].count) {\n      return [self normalCellFromTableView:tableView];\n    }\n    NSInteger originalRow = groups[category][indexPath.row].integerValue;",
     "    if (category == 0 && indexPath.row >= (NSInteger)groups[0].count &&\n        indexPath.row < (NSInteger)groups[0].count + 4) {\n      NSInteger kind = indexPath.row - (NSInteger)groups[0].count;\n      BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@\"ru\"];\n      NSArray *titles = ru ? @[@\"Личные сообщения\", @\"Группы и чаты\", @\"Каналы\", @\"Удалённые сообщения\"] : @[@\"Personal messages\", @\"Groups & chats\", @\"Channels\", @\"Deleted messages\"];\n      NSArray *icons = @[@\"person.crop.circle\", @\"person.3\", @\"megaphone\", @\"trash\"];\n      cell = [self normalCellFromTableView:tableView];\n      cell.textLabel.text = titles[kind];\n      cell.detailTextLabel.text = nil;\n      cell.imageView.image = [UIImage systemImageNamed:icons[kind]];\n      cell.imageView.tintColor = [self dynamicColorBW];\n      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;\n      cell.accessoryView = nil;\n      return cell;\n    }\n    if (category < 0 || category >= (NSInteger)groups.count ||\n        indexPath.row < 0 || indexPath.row >= (NSInteger)groups[category].count) {\n      return [self normalCellFromTableView:tableView];\n    }\n    NSInteger originalRow = groups[category][indexPath.row].integerValue;"),
    ("  [tableView deselectRowAtIndexPath:indexPath animated:YES];\n  if (!self.goldgramSection) {",
     "  [tableView deselectRowAtIndexPath:indexPath animated:YES];\n  if (self.goldgramHistoryCategory) return;\n  if (!self.goldgramSection) {"),
    ("    if (category < 0 || category >= (NSInteger)groups.count ||\n        indexPath.row < 0 || indexPath.row >= (NSInteger)groups[category].count) return;",
     "    if (category == 0 && indexPath.row >= (NSInteger)groups[0].count &&\n        indexPath.row < (NSInteger)groups[0].count + 4) {\n      Mx *folder = [Mx new];\n      folder.goldgramSection = @(MISC);\n      folder.goldgramMiscCategory = @(0);\n      folder.goldgramHistoryCategory = @(indexPath.row - (NSInteger)groups[0].count);\n      [self.navigationController pushViewController:folder animated:YES];\n      return;\n    }\n    if (category < 0 || category >= (NSInteger)groups.count ||\n        indexPath.row < 0 || indexPath.row >= (NSInteger)groups[category].count) return;"),
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

# #80: C/ObjC block bridge to the host's account-scoped metadata resolver.
metadata_source = pathlib.Path(__file__).with_name("GoldgramMetadataBridge.m")
metadata_dest = root / "Sources/tgapiC/GoldgramMetadataBridge.m"
metadata_header = root / "Sources/tgapiC/include/Tweak.h"
if metadata_dest.exists() or not metadata_source.is_file():
    raise SystemExit("Goldgram metadata bridge source mismatch")
metadata_dest.write_text(metadata_source.read_text())
header_source = metadata_header.read_text()
metadata_anchor = "NSData *decompressGzip(const void *input, size_t inputLen);"
if header_source.count(metadata_anchor) != 1:
    raise SystemExit("Goldgram metadata C header anchor mismatch")
metadata_header.write_text(header_source.replace(metadata_anchor, "NSData * _Null_unspecified decompressGzip(const void * _Null_unspecified input, size_t inputLen);\nvoid goldgramResolveNativeMetadata(NSDictionary * _Nonnull request, void (^ _Nonnull completion)(NSDictionary * _Nonnull response));"))
print("Goldgram #80: native Postbox metadata bridge ready")

grouping_source = pathlib.Path(__file__).with_name("GoldgramArchiveGrouping.swift")
grouping_dest = root / "Sources/tgapi/GoldgramArchiveGrouping.swift"
if grouping_dest.exists() or not grouping_source.is_file():
    raise SystemExit("Goldgram archive grouping source mismatch")
grouping_dest.write_text(grouping_source.read_text())

# #83: Native, authenticated Postbox handling must see the ORIGINAL deletion
# IDs. Disable both MX neutralizers only when the new host bridge is present
# AND the user enabled Goldgram capture. Legacy behavior remains otherwise.
parser_source = parser_path.read_text()
anchor = '        let defaults = UserDefaults.standard\n        let antiRevoke = defaults.bool(forKey: "MxAntiRevoke")'
if parser_source.count(anchor) != 1:
    raise SystemExit("Goldgram native deletion parser anchor mismatch")
parser_source = parser_source.replace(anchor, '        if UserDefaults.standard.bool(forKey: "GoldgramSQLiteCaptureEnabled") && goldgramNativeHostPresent() { return nil }\n' + anchor)
parser_path.write_text(parser_source)
hooks_path = root / "Sources/tgapi/Hooks.xm"
hooks_source = hooks_path.read_text()
anchor = '    BOOL antiSelfDestruct = [defaults boolForKey:kAntiSelfDestruct];'
if hooks_source.count(anchor) != 1:
    raise SystemExit("Goldgram raw deletion neutralizer anchor mismatch")
hooks_source = '#import <dlfcn.h>\n' + hooks_source.replace(anchor, anchor + '\n    if ([defaults boolForKey:@"GoldgramSQLiteCaptureEnabled"] && dlsym(RTLD_DEFAULT, "goldgram_native_history_host_v1")) { antiRevoke = NO; antiSelfDestruct = NO; }')
hooks_path.write_text(hooks_source)
header_source = metadata_header.read_text()
metadata_header.write_text(header_source + '\nBOOL goldgramNativeHostPresent(void);\n')

# Deleted history is the fourth archive row inside Deleted & edited. It uses
# the existing category-3 reader, which covers every cloud peer kind.
print("Goldgram: deleted archive nested inside Deleted & edited")

# #91: selected-account totals in Privacy & Functions; refresh when reopened.
summary_interface = '+ (void)presentClearHistoryFromController:(UIViewController *)controller;'
if mx_ui_source.count(summary_interface) != 1:
    raise SystemExit('Goldgram #91 summary interface mismatch')
mx_ui_source = mx_ui_source.replace(summary_interface, summary_interface + '\n+ (NSNumber *)activeAccountId;\n+ (void)query:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion;')
summary_methods = r'''
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:@"GoldgramArchiveChanged" object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(goldgramArchiveChanged:) name:@"GoldgramArchiveChanged" object:nil];
  [self goldgramRefreshArchiveTotals];
}

- (void)goldgramArchiveChanged:(NSNotification *)notification {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(goldgramRefreshArchiveTotals) object:nil];
  [self performSelector:@selector(goldgramRefreshArchiveTotals) withObject:nil afterDelay:0.5];
}

- (void)goldgramRefreshArchiveTotals {
  if (!self.goldgramSection || self.goldgramSection.integerValue != MISC || self.goldgramMiscCategory || !self.view.window) return;
  Class reader = NSClassFromString(@"GoldgramArchiveReader");
  if (![reader respondsToSelector:@selector(activeAccountId)] || ![reader respondsToSelector:@selector(query:completion:)]) return;
  NSNumber *account = [reader activeAccountId];
  if (!account) return;
  __weak Mx *weakSelf = self;
  [reader query:@{@"accountId": account, @"category": @3, @"mode": @"totals"} completion:^(NSDictionary *answer) {
    Mx *strongSelf = weakSelf;
    if (!strongSelf || ![account isEqual:[reader activeAccountId]]) return;
    NSString *status = answer[@"status"];
    if (![status isEqual:@"ok"] && ![status isEqual:@"no_archive"]) return;
    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = UIColor.secondaryLabelColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.text = [NSString stringWithFormat:@"Всего изменённых: %@\nВсего удалённых: %@", answer[@"edited"] ?: @0, answer[@"deleted"] ?: @0];
    CGFloat width = MAX(200.0, strongSelf.tableView.bounds.size.width - 32.0);
    CGSize size = [label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width + 32.0, size.height + 40.0)];
    label.frame = CGRectMake(16, 20, width, size.height);
    [footer addSubview:label];
    strongSelf.tableView.tableFooterView = footer;
  }];
}

'''
anchor = '- (void)viewDidLoad {'
if mx_ui_source.count(anchor) != 1:
    raise SystemExit('Goldgram #91 lifecycle anchor mismatch')
mx_ui_source = mx_ui_source.replace(anchor, summary_methods + anchor)
mx_ui_path.write_text(mx_ui_source)
print('Goldgram #91: selected-account total edited/deleted messages in Privacy & Functions')


# Telegram 13.2 request-ID reconciliation (Gold Next #163).
# Mx 1.0.0 is pinned to a 12.9.2 source snapshot. These three request
# constructor identifiers drifted. Verify the host schema and Mx's pinned
# expected values before updating them; never guess constructor IDs.
import re as _mx_re

_host_schema_path = pathlib.Path(__file__).resolve().parents[2] / "submodules/TelegramApi/swift_scheme.tl"
if not _host_schema_path.is_file():
    raise SystemExit("Mx compatibility: Telegram host TL schema missing")
_host_schema = _host_schema_path.read_text()
_mx_constants_path = root / "Sources/tgapi/Constants.h"
_mx_constants = _mx_constants_path.read_text()
_mx_method_updates = {
    "kMessagesReadMessageContents": ("messages.readMessageContents", 917472119),
    "kGetSponsoredMessages": ("messages.getSponsoredMessages", -1680673735),
    "kUploadGetCdnFile": ("upload.getCdnFile", -1691921240),
}
for _macro, (_method, _expected_old) in _mx_method_updates.items():
    _schema_match = _mx_re.search(
        rf"(?m)^{_mx_re.escape(_method)}#([0-9a-f]+)\b", _host_schema
    )
    if _schema_match is None:
        raise SystemExit(f"Mx compatibility: missing TL method {_method}")
    _host_id = int(_schema_match.group(1), 16)
    if _host_id >= (1 << 31):
        _host_id -= 1 << 32
    _matches = list(_mx_re.finditer(
        rf"(?m)^(#define[ \t]+{_mx_re.escape(_macro)}[ \t]+)(-?\d+)(?=[ \t]*(?:$|//))",
        _mx_constants
    ))
    if len(_matches) != 1 or int(_matches[0].group(2)) != _expected_old:
        raise SystemExit(f"Mx compatibility: unexpected pinned constant {_macro}")
    _m = _matches[0]
    _mx_constants = (
        _mx_constants[:_m.start(2)] + str(_host_id) + _mx_constants[_m.end(2):]
    )
# These synthetic responses must still be parseable by the 13.2 host.
for _response in ("messages.affectedMessages#84d19185",
                  "messages.sponsoredMessagesEmpty#1839490f"):
    if _response not in _host_schema:
        raise SystemExit("Mx compatibility: synthetic response changed: " + _response)
# Do not leave the stale CDN method identifier in the source comment.
_mx_constants = _mx_constants.replace(
    "upload.getCdnFile#2000bcc3", "upload.getCdnFile#395f69da"
)
_mx_constants_path.write_text(_mx_constants)
print("Mx 13.2: updated 3 verified request IDs; synthetic response TL constructors verified")


# Goldgram #237: native hybrid Mx dashboard, presentation-only.
# Only the root index changes. The original Mx sections and every original
# feature row, persisted key, switch tag and action remain reachable.
# The destructive clear-history action stays a native UITableView row.
dashboard_methods = r'''
// Dashboard is intentionally UIKit-only; no new database, controller hook,
// network call or Mx setting key is introduced.
- (UIButton *)goldgramDashboardTile:(NSString *)title
                           subtitle:(NSString *)subtitle
                             symbol:(NSString *)symbol
                               tint:(UIColor *)tint
                         identifier:(NSInteger)identifier
                            compact:(BOOL)compact {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  button.tag = identifier;
  button.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
  button.layer.cornerRadius = 18.0;
  button.layer.masksToBounds = YES;
  button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
  button.isAccessibilityElement = YES;
  button.accessibilityTraits = UIAccessibilityTraitButton;
  button.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", title, subtitle];
  [button addTarget:self action:@selector(goldgramDashboardTap:)
    forControlEvents:UIControlEventTouchUpInside];

  UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
  icon.translatesAutoresizingMaskIntoConstraints = NO;
  icon.contentMode = UIViewContentModeScaleAspectFit;
  icon.tintColor = tint;
  [NSLayoutConstraint activateConstraints:@[
    [icon.widthAnchor constraintEqualToConstant:26],
    [icon.heightAnchor constraintEqualToConstant:26]
  ]];

  UILabel *name = [UILabel new];
  name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
  name.adjustsFontForContentSizeCategory = YES;
  name.textColor = UIColor.labelColor;
  name.numberOfLines = 0;
  name.text = title;

  UILabel *detail = [UILabel new];
  detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
  detail.adjustsFontForContentSizeCategory = YES;
  detail.textColor = UIColor.secondaryLabelColor;
  detail.numberOfLines = 0;
  detail.text = subtitle;

  UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[icon, name, detail]];
  content.translatesAutoresizingMaskIntoConstraints = NO;
  content.axis = UILayoutConstraintAxisVertical;
  content.alignment = UIStackViewAlignmentLeading;
  content.spacing = compact ? 5 : 8;
  content.userInteractionEnabled = NO;
  [button addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:15],
    [content.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-12],
    [content.topAnchor constraintEqualToAnchor:button.topAnchor constant:14],
    [content.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-14],
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:(compact ? 106 : 118)]
  ]];
  return button;
}

- (UILabel *)goldgramDashboardHeading:(NSString *)title {
  UILabel *label = [UILabel new];
  label.text = title;
  label.textColor = UIColor.secondaryLabelColor;
  label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  label.adjustsFontForContentSizeCategory = YES;
  return label;
}

- (UIStackView *)goldgramDashboardPair:(UIView *)first second:(UIView *)second {
  UIStackView *pair = [[UIStackView alloc] initWithArrangedSubviews:@[first, second]];
  pair.axis = UILayoutConstraintAxisHorizontal;
  pair.distribution = UIStackViewDistributionFillEqually;
  pair.alignment = UIStackViewAlignmentFill;
  pair.spacing = 12;
  return pair;
}

- (void)goldgramBuildDashboard {
  BOOL russian = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"];
  UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 1)];
  UIStackView *stack = [UIStackView new];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  stack.axis = UILayoutConstraintAxisVertical;
  stack.alignment = UIStackViewAlignmentFill;
  stack.spacing = 12;
  [header addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
    [stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
    [stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:16],
    [stack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-18]
  ]];

  [stack addArrangedSubview:[self goldgramDashboardHeading:
    russian ? @"GOLDGRAM · MX" : @"GOLDGRAM · MX"]];
  [stack addArrangedSubview:[self goldgramDashboardTile:
    russian ? @"Режим невидимки" : @"Ghost mode"
    subtitle:russian ? @"Приватность и управление статусом" : @"Privacy and presence controls"
    symbol:@"eye.slash.fill" tint:UIColor.systemIndigoColor identifier:0 compact:NO]];

  [stack addArrangedSubview:[self goldgramDashboardHeading:
    russian ? @"АРХИВ СООБЩЕНИЙ" : @"MESSAGE ARCHIVE"]];
  [stack addArrangedSubview:[self goldgramDashboardPair:
    [self goldgramDashboardTile:russian ? @"Изменённые" : @"Edited"
      subtitle:russian ? @"История и разделы" : @"History and categories"
      symbol:@"pencil.line" tint:UIColor.systemBlueColor identifier:20 compact:YES]
    second:[self goldgramDashboardTile:russian ? @"Удалённые" : @"Deleted"
      subtitle:russian ? @"Архив удалений" : @"Deletion archive"
      symbol:@"trash" tint:UIColor.systemRedColor identifier:24 compact:YES]]];
  [stack addArrangedSubview:[self goldgramDashboardTile:
    russian ? @"Каналы и комментарии" : @"Channels and comments"
    subtitle:russian ? @"Открыть существующую историю каналов" : @"Open the existing channel archive"
    symbol:@"text.bubble" tint:UIColor.systemTealColor identifier:25 compact:YES]];

  [stack addArrangedSubview:[self goldgramDashboardHeading:
    russian ? @"ИНСТРУМЕНТЫ" : @"TOOLS"]];
  [stack addArrangedSubview:[self goldgramDashboardPair:
    [self goldgramDashboardTile:russian ? @"Приватность" : @"Privacy"
      subtitle:russian ? @"Доступ и функции" : @"Access and features"
      symbol:@"lock.shield" tint:UIColor.systemIndigoColor identifier:21 compact:YES]
    second:[self goldgramDashboardTile:russian ? @"Медиа" : @"Media"
      subtitle:russian ? @"Файлы и загрузки" : @"Files and downloads"
      symbol:@"square.and.arrow.down" tint:UIColor.systemOrangeColor identifier:22 compact:YES]]];
  [stack addArrangedSubview:[self goldgramDashboardPair:
    [self goldgramDashboardTile:russian ? @"Геопозиция" : @"Location"
      subtitle:russian ? @"Подмена позиции" : @"Location override"
      symbol:@"location" tint:UIColor.systemBlueColor identifier:4 compact:YES]
    second:[self goldgramDashboardTile:russian ? @"Другие функции" : @"Other features"
      subtitle:russian ? @"Дополнительные инструменты" : @"Additional tools"
      symbol:@"wand.and.stars" tint:UIColor.systemPurpleColor identifier:23 compact:YES]]];

  [stack addArrangedSubview:[self goldgramDashboardHeading:
    russian ? @"НАСТРОЙКИ" : @"SETTINGS"]];
  [stack addArrangedSubview:[self goldgramDashboardPair:
    [self goldgramDashboardTile:russian ? @"Исключения" : @"Exceptions"
      subtitle:russian ? @"Для невидимки" : @"Ghost-mode exceptions"
      symbol:@"person.crop.circle.badge.checkmark" tint:UIColor.systemTealColor identifier:1 compact:YES]
    second:[self goldgramDashboardTile:russian ? @"Файлы" : @"File fixer"
      subtitle:russian ? @"Исправление" : @"Repair tools"
      symbol:@"folder" tint:UIColor.systemOrangeColor identifier:3 compact:YES]]];
  [stack addArrangedSubview:[self goldgramDashboardPair:
    [self goldgramDashboardTile:russian ? @"Язык" : @"Language"
      subtitle:russian ? @"Локализация" : @"Localization"
      symbol:@"globe" tint:UIColor.systemBlueColor identifier:5 compact:YES]
    second:[self goldgramDashboardTile:russian ? @"О Mx" : @"About Mx"
      subtitle:russian ? @"Информация" : @"Information"
      symbol:@"info.circle" tint:UIColor.systemGrayColor identifier:6 compact:YES]]];
  [stack addArrangedSubview:[self goldgramDashboardTile:
    russian ? @"Все функции Mx" : @"All Mx features"
    subtitle:russian ? @"Исходные разделы и переключатели" : @"Original sections and switches"
    symbol:@"slider.horizontal.3" tint:UIColor.systemGrayColor identifier:2 compact:YES]];

  self.goldgramDashboardHeader = header;
  self.tableView.tableHeaderView = header;
}

- (void)goldgramFitDashboard {
  if (self.goldgramSection || !self.goldgramDashboardHeader) return;
  CGFloat width = CGRectGetWidth(self.tableView.bounds);
  if (width < 100) return;
  UIView *header = self.goldgramDashboardHeader;
  CGRect frame = header.frame;
  BOOL widthChanged = fabs(frame.size.width - width) > 0.5;
  frame.size.width = width;
  header.frame = frame;
  CGSize target = CGSizeMake(width, UILayoutFittingCompressedSize.height);
  CGFloat height = ceil([header systemLayoutSizeFittingSize:target
    withHorizontalFittingPriority:UILayoutPriorityRequired
          verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
  if (height <= 0) return;
  if (widthChanged || fabs(frame.size.height - height) > 0.5) {
    frame.size.height = height;
    header.frame = frame;
    self.tableView.tableHeaderView = header;
  }
}

- (void)goldgramDashboardTap:(UIButton *)button {
  NSInteger identifier = button.tag;
  if (identifier == 24 || identifier == 25) {
    // Existing native archive controller: 3 = deleted, 2 = channels/comments.
    Class browser = NSClassFromString(@"GoldgramArchiveScreen");
    if ([browser instancesRespondToSelector:@selector(initWithCategory:)]) {
      id controller = [[browser alloc] initWithCategory:identifier == 24 ? 3 : 2];
      if ([controller isKindOfClass:UIViewController.class]) {
        [self.navigationController pushViewController:controller animated:YES];
      }
    }
    return;
  }
  Mx *folder = [Mx new];
  if (identifier >= 20 && identifier <= 23) {
    folder.goldgramSection = @(MISC);
    folder.goldgramMiscCategory = @(identifier - 20);
  } else if (identifier >= 0 && identifier <= CREDITS) {
    folder.goldgramSection = @(identifier);
  } else {
    return;
  }
  [self.navigationController pushViewController:folder animated:YES];
}

'''
if mx_ui_source.count('- (void)viewDidLoad {') != 1:
    raise SystemExit('Goldgram #237: Mx dashboard lifecycle anchor mismatch')
mx_ui_source = mx_ui_source.replace('- (void)viewDidLoad {',
                                    dashboard_methods + '- (void)viewDidLoad {')

dashboard_property_anchor = '@property(nonatomic, strong) NSNumber *goldgramHistoryCategory;'
if mx_ui_source.count(dashboard_property_anchor) != 1:
    raise SystemExit('Goldgram #237: dashboard property anchor mismatch')
mx_ui_source = mx_ui_source.replace(dashboard_property_anchor,
    dashboard_property_anchor + '\n@property(nonatomic, strong) UIView *goldgramDashboardHeader;')

dashboard_patches = [
    ('  [self setupIconAsHeader];',
     '  if (self.goldgramSection) [self setupIconAsHeader];\n  else [self goldgramBuildDashboard];'),
    ('  [self fetchAnnouncement];',
     '  if (self.goldgramSection) [self fetchAnnouncement];'),
    ('- (void)viewDidLayoutSubviews {\n  [super viewDidLayoutSubviews];',
     '- (void)viewDidLayoutSubviews {\n  [super viewDidLayoutSubviews];\n  [self goldgramFitDashboard];'),
    ('  if (!self.goldgramSection) return 8;',
     '  if (!self.goldgramSection) return 1;'),
]
for before, after in dashboard_patches:
    if mx_ui_source.count(before) != 1:
        raise SystemExit('Goldgram #237: dashboard patch anchor mismatch: ' + before)
    mx_ui_source = mx_ui_source.replace(before, after)

# One native destructive row survives below the dashboard. Map only its visible
# index (0) to the original source index (7); preserve the original confirmation.
clear_row_anchor = '  if (!self.goldgramSection && indexPath.row == 7) {'
if mx_ui_source.count(clear_row_anchor) != 2:
    raise SystemExit('Goldgram #237: expected one clear-history cell and one action')
mx_ui_source = mx_ui_source.replace(clear_row_anchor,
    '  if (!self.goldgramSection && indexPath.row == 0) {\n'
    '    indexPath = [NSIndexPath indexPathForRow:7 inSection:0];\n'
    '  }\n' + clear_row_anchor)

# The implementation must still expose all seven original section IDs and the
# existing, account-scoped destructive confirmation.
for essential in ('goldgramMiscCategory', 'presentClearHistoryFromController:',
                  'goldgramDashboardTap:', 'GHOST_MODE', 'GHOST_EXCEPTIONS',
                  'FILE_FIXER', 'FAKE_LOCATION', 'LANGUAGE', 'CREDITS'):
    if essential not in mx_ui_source:
        raise SystemExit('Goldgram #237: missing preserved capability ' + essential)
mx_ui_path.write_text(mx_ui_source)
print('Goldgram #237: hybrid native dashboard, original switches and clear confirmation preserved')


# Goldgram #240: compact native settings screens, with true grouped Ghost rows.
# This runs AFTER #239's dashboard. Only UIKit layout and visible row grouping
# change. Original Mx switch tags/keys, actions, and profile exception IDs do not.
ghost_groups_240 = [[0,1],[2,3,19,20],[4,5,6,7,8,9,13,14],[10,11,12,15,16,17,18]]
assert sorted(v for group in ghost_groups_240 for v in group) == list(range(21))

inner_methods_240 = r'''
// A display-to-source row map: never change an original Mx switch tag/key.
+ (NSArray<NSArray<NSNumber *> *> *)goldgramGhostRows {
  static NSArray<NSArray<NSNumber *> *> *groups;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    groups = @[
      @[@0, @1],
      @[@2, @3, @19, @20],        // online, typing, read, stories
      @[@4, @5, @6, @7, @8, @9, @13, @14],  // media activity
      @[@10, @11, @12, @15, @16, @17, @18] // other activity
    ];
  });
  return groups;
}

- (NSIndexPath *)goldgramGhostSourceIndexPath:(NSIndexPath *)visible {
  NSArray<NSArray<NSNumber *> *> *groups = [Mx goldgramGhostRows];
  if (visible.section >= (NSInteger)groups.count ||
      visible.row >= (NSInteger)groups[visible.section].count) return nil;
  NSInteger original = groups[visible.section][visible.row].integerValue;
  return [NSIndexPath indexPathForRow:original inSection:GHOST_MODE];
}

- (UIColor *)goldgramInnerTint {
  if (!self.goldgramSection) return UIColor.systemGrayColor;
  switch (self.goldgramSection.integerValue) {
    case GHOST_MODE: return UIColor.systemIndigoColor;
    case GHOST_EXCEPTIONS: return UIColor.systemTealColor;
    case MISC: {
      NSInteger category = self.goldgramMiscCategory ?
          self.goldgramMiscCategory.integerValue : -1;
      if (category == 0) return UIColor.systemBlueColor;
      if (category == 1) return UIColor.systemIndigoColor;
      if (category == 2) return UIColor.systemOrangeColor;
      return UIColor.systemPurpleColor;
    }
    case FILE_FIXER: return UIColor.systemOrangeColor;
    case FAKE_LOCATION: return UIColor.systemBlueColor;
    case LANGUAGE: return UIColor.systemBlueColor;
    default: return UIColor.systemGrayColor;
  }
}

- (NSString *)goldgramInnerSymbol {
  switch (self.goldgramSection.integerValue) {
    case GHOST_MODE: return @"eye.slash.fill";
    case GHOST_EXCEPTIONS: return @"person.crop.circle.badge.checkmark";
    case MISC: {
      if (!self.goldgramMiscCategory) return @"slider.horizontal.3";
      NSArray *symbols = @[@"pencil.line", @"lock.shield", @"square.and.arrow.down", @"wand.and.stars"];
      NSInteger i = self.goldgramMiscCategory.integerValue;
      return (i >= 0 && i < (NSInteger)symbols.count) ? symbols[i] : @"slider.horizontal.3";
    }
    case FILE_FIXER: return @"folder";
    case FAKE_LOCATION: return @"location";
    case LANGUAGE: return @"globe";
    default: return @"info.circle";
  }
}

- (NSString *)goldgramInnerSummary {
  BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"];
  switch (self.goldgramSection.integerValue) {
    case GHOST_MODE: return ru ? @"Управление видимостью и действиями" : @"Presence and activity controls";
    case GHOST_EXCEPTIONS: return ru ? @"Люди, для которых действуют исключения" : @"People with individual exceptions";
    case MISC:
      if (!self.goldgramMiscCategory) return ru ? @"Все доступные настройки Mx" : @"All available Mx settings";
      switch (self.goldgramMiscCategory.integerValue) {
        case 0: return ru ? @"Редакции, удаления и сохранение истории" : @"Edits, deletion and history";
        case 1: return ru ? @"Защита контента и конфиденциальность" : @"Content protection and privacy";
        case 2: return ru ? @"Настройки загрузки и медиа" : @"Download and media controls";
        default: return ru ? @"Дополнительные возможности" : @"Additional tools";
      }
    case FILE_FIXER: return ru ? @"Исправление работы файлов и кэша" : @"File handling and cache tools";
    case FAKE_LOCATION: return ru ? @"Подмена местоположения" : @"Location override";
    case LANGUAGE: return ru ? @"Выбор языка интерфейса" : @"Choose interface language";
    default: return ru ? @"Информация и сведения о Mx" : @"About Mx";
  }
}

// Compact context header, replacing the old large Mx logo inside folders.
// Layout follows system Dynamic Type and dark/light mode.
- (void)goldgramBuildInnerHeader {
  if (!self.goldgramSection) return;
  UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 1)];

  UIImageView *symbol = [[UIImageView alloc] initWithImage:
      [UIImage systemImageNamed:[self goldgramInnerSymbol]]];
  symbol.translatesAutoresizingMaskIntoConstraints = NO;
  symbol.tintColor = [self goldgramInnerTint];
  symbol.contentMode = UIViewContentModeScaleAspectFit;

  UILabel *name = [UILabel new];
  name.text = [self tableView:self.tableView titleForHeaderInSection:0] ?: @"Mx";
  name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
  name.adjustsFontForContentSizeCategory = YES;
  name.textColor = UIColor.labelColor;
  name.numberOfLines = 0;

  UILabel *subtitle = [UILabel new];
  subtitle.text = [self goldgramInnerSummary];
  subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
  subtitle.adjustsFontForContentSizeCategory = YES;
  subtitle.textColor = UIColor.secondaryLabelColor;
  subtitle.numberOfLines = 0;

  UIStackView *labels = [[UIStackView alloc]
      initWithArrangedSubviews:@[name, subtitle]];
  labels.translatesAutoresizingMaskIntoConstraints = NO;
  labels.axis = UILayoutConstraintAxisVertical;
  labels.alignment = UIStackViewAlignmentFill;
  labels.spacing = 4;

  [header addSubview:symbol];
  [header addSubview:labels];
  [NSLayoutConstraint activateConstraints:@[
    [symbol.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:28],
    [symbol.topAnchor constraintGreaterThanOrEqualToAnchor:header.topAnchor constant:14],
    [symbol.centerYAnchor constraintEqualToAnchor:labels.centerYAnchor],
    [symbol.widthAnchor constraintEqualToConstant:26],
    [symbol.heightAnchor constraintEqualToConstant:26],
    [labels.leadingAnchor constraintEqualToAnchor:symbol.trailingAnchor constant:14],
    [labels.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-28],
    [labels.topAnchor constraintEqualToAnchor:header.topAnchor constant:14],
    [labels.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-14]
  ]];

  self.goldgramInnerHeader = header;
  self.tableView.tableHeaderView = header;
}

- (void)goldgramFitInnerHeader {
  if (!self.goldgramSection || !self.goldgramInnerHeader) return;
  CGFloat width = CGRectGetWidth(self.tableView.bounds);
  if (width < 100) return;
  UIView *header = self.goldgramInnerHeader;
  CGRect f = header.frame;
  BOOL changedWidth = fabs(f.size.width - width) > 0.5;
  f.size.width = width;
  header.frame = f;
  CGFloat height = ceil([header systemLayoutSizeFittingSize:
      CGSizeMake(width, UILayoutFittingCompressedSize.height)
      withHorizontalFittingPriority:UILayoutPriorityRequired
      verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
  if (height > 0 && (changedWidth || fabs(f.size.height - height) > 0.5)) {
    f.size.height = height;
    header.frame = f;
    self.tableView.tableHeaderView = header;
  }
}

// Appearance only. UISwitch targets, gestures, source index paths and storage
// remain the original Mx implementations.
- (void)tableView:(UITableView *)tableView
    willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (!self.goldgramSection) return;
  cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
  cell.textLabel.textColor = UIColor.labelColor;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  cell.textLabel.adjustsFontForContentSizeCategory = YES;
  cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
  if (cell.imageView.image) cell.imageView.tintColor = [self goldgramInnerTint];
}
'''
if mx_ui_source.count('- (void)viewDidLoad {') != 1:
    raise SystemExit('Goldgram #240: Mx lifecycle anchor changed')
mx_ui_source = mx_ui_source.replace('- (void)viewDidLoad {',
                                    inner_methods_240 + '- (void)viewDidLoad {')

inner_prop_240 = '@property(nonatomic, strong) UIView *goldgramDashboardHeader;'
if mx_ui_source.count(inner_prop_240) != 1:
    raise SystemExit('Goldgram #240: dashboard property anchor changed')
mx_ui_source = mx_ui_source.replace(inner_prop_240,
    inner_prop_240 + '\n@property(nonatomic, strong) UIView *goldgramInnerHeader;')

# Group the existing Ghost rows without changing source row IDs or switch tags.
inner_patches_240 = [
    ('  // The root lists the seven folders; an opened folder shows one section.\n  return 1;',
     '  if (self.goldgramSection && self.goldgramSection.integerValue == GHOST_MODE)\n    return self.isGhostModeExpanded ? 4 : 1;\n  return 1;'),
    ('  if (self.goldgramHistoryCategory) return 1;\n  if (!self.goldgramSection) return 1;',
     '  if (self.goldgramSection && self.goldgramSection.integerValue == GHOST_MODE) {\n    if (!self.isGhostModeExpanded) return section == 0 ? 2 : 0;\n    NSArray *groups = [Mx goldgramGhostRows];\n    return section >= 0 && section < (NSInteger)groups.count ? [groups[section] count] : 0;\n  }\n  if (self.goldgramHistoryCategory) return 1;\n  if (!self.goldgramSection) return 1;'),
    ('    titleForHeaderInSection:(NSInteger)section {\n  if (self.goldgramHistoryCategory)',
     '    titleForHeaderInSection:(NSInteger)section {\n  if (self.goldgramSection && self.goldgramSection.integerValue == GHOST_MODE && section > 0) {\n    BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"];\n    NSArray *names = ru ? @[@"", @"ПРИСУТСТВИЕ", @"МЕДИА И ЗАПИСЬ", @"ДРУГИЕ ДЕЙСТВИЯ"] : @[@"", @"PRESENCE", @"MEDIA AND RECORDING", @"OTHER ACTIVITY"];\n    return section < (NSInteger)names.count ? names[section] : nil;\n  }\n  if (self.goldgramHistoryCategory)'),
    ('  // Reuse original MX row mapping; UISwitch tags still encode source row IDs.\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row\n                                inSection:self.goldgramSection.integerValue];',
     '  // Match the visible grouped Ghost row to the original switch-key row.\n  if (self.goldgramSection.integerValue == GHOST_MODE) {\n    indexPath = [self goldgramGhostSourceIndexPath:indexPath];\n    if (!indexPath) return [self normalCellFromTableView:tableView];\n  }\n  // Reuse original MX row mapping; UISwitch tags still encode source row IDs.\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row\n                                inSection:self.goldgramSection.integerValue];'),
    ('  indexPath = [NSIndexPath indexPathForRow:indexPath.row\n                                inSection:self.goldgramSection.integerValue];\n\n  if (indexPath.section == GHOST_MODE && indexPath.row == 1)',
     '  if (self.goldgramSection.integerValue == GHOST_MODE) {\n    indexPath = [self goldgramGhostSourceIndexPath:indexPath];\n    if (!indexPath) return;\n  }\n  indexPath = [NSIndexPath indexPathForRow:indexPath.row\n                                inSection:self.goldgramSection.integerValue];\n\n  if (indexPath.section == GHOST_MODE && indexPath.row == 1)'),
    ('  [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]\n                  withRowAnimation:UITableViewRowAnimationAutomatic];',
     '  [self.tableView reloadData];'),
    ('  if (self.goldgramSection) [self setupIconAsHeader];\n  else [self goldgramBuildDashboard];',
     '  if (self.goldgramSection) [self goldgramBuildInnerHeader];\n  else [self goldgramBuildDashboard];'),
    ('  [self setupFooterView];',
     '  if (!self.goldgramSection || self.goldgramSection.integerValue == CREDITS)\n    [self setupFooterView];\n  else\n    self.tableView.tableFooterView = [UIView new];'),
    ('- (void)viewDidLayoutSubviews {\n  [super viewDidLayoutSubviews];\n  [self goldgramFitDashboard];',
     '- (void)viewDidLayoutSubviews {\n  [super viewDidLayoutSubviews];\n  [self goldgramFitDashboard];\n  [self goldgramFitInnerHeader];'),
]
for before, after in inner_patches_240:
    if mx_ui_source.count(before) != 1:
        raise SystemExit('Goldgram #240: patch anchor mismatch: ' + before[:80])
    mx_ui_source = mx_ui_source.replace(before, after)

# The scoped @selector(switchChanged:) still uses original 0..20 Ghost row IDs.
for needed in ('goldgramGhostSourceIndexPath:', 'goldgramBuildInnerHeader',
               'goldgramFitInnerHeader', 'willDisplayCell:',
               'goldgramDashboardTap:', 'goldgramMiscRows',
               'presentClearHistoryFromController:',
               "indexPath = [self goldgramGhostSourceIndexPath:indexPath];"):
    if needed not in mx_ui_source:
        raise SystemExit('Goldgram #240: expected feature disappeared: ' + needed)
mx_ui_path.write_text(mx_ui_source)
print('Goldgram #240: native compact inner menus and 4 safe Ghost groups, original switch keys preserved')


# Goldgram #241: visual polish of native Mx settings.
# Keep existing archive, collectors, Mx switch keys and actions untouched.
# Section 0 still has original two controls; groups 1-3 reuse exact indices
# established by #240, and collapse persists only a NEW UI preference.
polish_methods_241 = r'''
- (BOOL)goldgramGhostGroupExpanded:(NSInteger)section {
  if (section < 1 || section > 3) return YES;
  NSString *key = [NSString stringWithFormat:@"GoldgramMxGroup%ldExpanded", (long)section];
  id saved = [[NSUserDefaults standardUserDefaults] objectForKey:key];
  // First run is concise: presence visible, media and other groups folded.
  return saved ? [saved boolValue] : (section == 1);
}

- (NSString *)goldgramGhostGroupTitle:(NSInteger)section {
  BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"];
  NSArray *titles = ru
      ? @[@"", @"ПРИСУТСТВИЕ", @"МЕДИА И ЗАПИСЬ", @"ДРУГИЕ ДЕЙСТВИЯ"]
      : @[@"", @"PRESENCE", @"MEDIA AND RECORDING", @"OTHER ACTIVITY"];
  if (section < 1 || section >= (NSInteger)titles.count) return @"";
  NSArray<NSArray<NSNumber *> *> *groups = [Mx goldgramGhostRows];
  NSArray<NSString *> *keys = [Mx ghostSubFeatureKeys];
  NSArray<NSNumber *> *rows = groups[section];
  NSInteger enabled = 0;
  for (NSNumber *rowNumber in rows) {
    NSInteger index = rowNumber.integerValue - 2;
    if (index >= 0 && index < (NSInteger)keys.count &&
        [[NSUserDefaults standardUserDefaults] boolForKey:keys[index]]) {
      enabled++;
    }
  }
  return [NSString stringWithFormat:@"%@  ·  %ld/%ld",
          titles[section], (long)enabled, (long)rows.count];
}

- (void)goldgramSetGhostGroupButton:(UIButton *)button section:(NSInteger)section {
  BOOL expanded = [self goldgramGhostGroupExpanded:section];
  NSString *title = [self goldgramGhostGroupTitle:section];
  [button setTitle:title forState:UIControlStateNormal];
  UIImage *chevron = [UIImage systemImageNamed:
                      expanded ? @"chevron.down" : @"chevron.right"];
  [button setImage:chevron forState:UIControlStateNormal];
  button.accessibilityLabel = title;
  button.accessibilityHint = expanded ? @"Свернуть группу" : @"Раскрыть группу";
}

- (void)goldgramGhostGroupTapped:(UIButton *)button {
  NSInteger section = button.tag;
  if (!self.goldgramSection ||
      self.goldgramSection.integerValue != GHOST_MODE ||
      section < 1 || section > 3 || !self.isGhostModeExpanded) return;
  BOOL next = ![self goldgramGhostGroupExpanded:section];
  NSString *key = [NSString stringWithFormat:@"GoldgramMxGroup%ldExpanded", (long)section];
  [[NSUserDefaults standardUserDefaults] setBool:next forKey:key];
  [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section]
                withRowAnimation:UITableViewRowAnimationFade];
}

- (void)goldgramRefreshGhostGroupTitles {
  if (!self.goldgramSection ||
      self.goldgramSection.integerValue != GHOST_MODE ||
      !self.isGhostModeExpanded) return;
  for (NSInteger section = 1; section < 4; section++) {
    UITableViewHeaderFooterView *header = [self.tableView headerViewForSection:section];
    UIButton *button = (UIButton *)header.contentView.subviews.firstObject;
    if ([button isKindOfClass:UIButton.class])
      [self goldgramSetGhostGroupButton:button section:section];
  }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  if (!self.goldgramSection ||
      self.goldgramSection.integerValue != GHOST_MODE ||
      !self.isGhostModeExpanded || section < 1 || section > 3)
    return nil;

  NSString *reuse = @"GoldgramGhostGroupHeader";
  UITableViewHeaderFooterView *header =
      [tableView dequeueReusableHeaderFooterViewWithIdentifier:reuse];
  if (!header) {
    header = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:reuse];
    header.contentView.backgroundColor = UIColor.clearColor;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    button.layer.cornerRadius = 15.0;
    button.layer.masksToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
    button.tintColor = UIColor.secondaryLabelColor;
    [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.numberOfLines = 1;
    button.isAccessibilityElement = YES;
    button.accessibilityTraits = UIAccessibilityTraitButton;
    button.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 8);
    [button addTarget:self action:@selector(goldgramGhostGroupTapped:)
      forControlEvents:UIControlEventTouchUpInside];
    [header.contentView addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
      [button.leadingAnchor constraintEqualToAnchor:header.contentView.leadingAnchor constant:16],
      [button.trailingAnchor constraintEqualToAnchor:header.contentView.trailingAnchor constant:-16],
      [button.topAnchor constraintEqualToAnchor:header.contentView.topAnchor constant:4],
      [button.bottomAnchor constraintEqualToAnchor:header.contentView.bottomAnchor constant:-4]
    ]];
  }
  UIButton *button = (UIButton *)header.contentView.subviews.firstObject;
  button.tag = section;
  [self goldgramSetGhostGroupButton:button section:section];
  return header;
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForHeaderInSection:(NSInteger)section {
  if (!self.goldgramSection) return UITableViewAutomaticDimension;
  if (self.goldgramSection.integerValue == GHOST_MODE &&
      self.isGhostModeExpanded && section > 0 && section < 4) return 56.0;
  return CGFLOAT_MIN;  // no duplicate title immediately below the navigation bar
}
'''
if mx_ui_source.count('- (void)viewDidLoad {') != 1:
    raise SystemExit('Goldgram #241: expected a single Mx viewDidLoad')
mx_ui_source = mx_ui_source.replace('- (void)viewDidLoad {',
                                    polish_methods_241 + '- (void)viewDidLoad {')

# The #240 header displayed the navigation title a second/third time and
# occupied 120+ points. Replace with a single contextual line under the navbar.
polish_header_start = '- (void)goldgramBuildInnerHeader {'
polish_header_end = '- (void)goldgramFitInnerHeader {'
if mx_ui_source.count(polish_header_start) != 1 or mx_ui_source.count(polish_header_end) != 1:
    raise SystemExit('Goldgram #241: inner header boundaries changed')
start = mx_ui_source.index(polish_header_start)
end = mx_ui_source.index(polish_header_end, start)
compact_header_241 = r'''- (void)goldgramBuildInnerHeader {
  if (!self.goldgramSection) return;
  UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 1)];
  UIImageView *symbol = [[UIImageView alloc] initWithImage:
      [UIImage systemImageNamed:[self goldgramInnerSymbol]]];
  symbol.translatesAutoresizingMaskIntoConstraints = NO;
  symbol.tintColor = [self goldgramInnerTint];
  symbol.contentMode = UIViewContentModeScaleAspectFit;
  UILabel *summary = [UILabel new];
  summary.translatesAutoresizingMaskIntoConstraints = NO;
  summary.text = [self goldgramInnerSummary];
  summary.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  summary.adjustsFontForContentSizeCategory = YES;
  summary.textColor = UIColor.secondaryLabelColor;
  summary.numberOfLines = 0;
  [header addSubview:symbol];
  [header addSubview:summary];
  [NSLayoutConstraint activateConstraints:@[
    [symbol.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:30],
    [symbol.centerYAnchor constraintEqualToAnchor:summary.centerYAnchor],
    [symbol.heightAnchor constraintEqualToConstant:20],
    [symbol.widthAnchor constraintEqualToConstant:20],
    [summary.leadingAnchor constraintEqualToAnchor:symbol.trailingAnchor constant:11],
    [summary.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-30],
    [summary.topAnchor constraintEqualToAnchor:header.topAnchor constant:11],
    [summary.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-11]
  ]];
  self.goldgramInnerHeader = header;
  self.tableView.tableHeaderView = header;
}

'''
mx_ui_source = mx_ui_source[:start] + compact_header_241 + mx_ui_source[end:]

# Hide legacy section-title headers; the navigation title and contextual subtitle
# identify the section. Ghost headers 1..3 become real collapsible buttons.
old_title_241 = '    titleForHeaderInSection:(NSInteger)section {\n  if (self.goldgramSection && self.goldgramSection.integerValue == GHOST_MODE && section > 0) {'
new_title_241 = '    titleForHeaderInSection:(NSInteger)section {\n  if (self.goldgramSection) return nil;\n  if (self.goldgramSection && self.goldgramSection.integerValue == GHOST_MODE && section > 0) {'
if mx_ui_source.count(old_title_241) != 1:
    raise SystemExit('Goldgram #241: section title anchor changed')
mx_ui_source = mx_ui_source.replace(old_title_241, new_title_241)

old_rows_241 = '    return section >= 0 && section < (NSInteger)groups.count ? [groups[section] count] : 0;'
new_rows_241 = ('    if (section < 0 || section >= (NSInteger)groups.count) return 0;\n'
                '    if (section > 0 && ![self goldgramGhostGroupExpanded:section]) return 0;\n'
                '    return [groups[section] count];')
if mx_ui_source.count(old_rows_241) != 1:
    raise SystemExit('Goldgram #241: Ghost group row anchor changed')
mx_ui_source = mx_ui_source.replace(old_rows_241, new_rows_241)

# Only the two original hardcoded English Ghost rows; other labels still use
# MxLocalization and their original per-feature keys.
polish_text_241 = [
  ('      cell.textLabel.text = @"Advanced Settings";',
   '      cell.textLabel.text = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"] ? @"Дополнительные настройки" : @"Advanced Settings";'),
  ('      cell.detailTextLabel.text = self.isGhostModeExpanded ? @"Hide detail settings" : @"Show detail settings";',
   '      BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"];\n'
   '      cell.detailTextLabel.text = self.isGhostModeExpanded\n'
   '          ? (ru ? @"Скрыть группы настроек" : @"Hide settings groups")\n'
   '          : (ru ? @"Показать группы настроек" : @"Show settings groups");'),
  ('      cell.textLabel.text = @"Ghost Mode";',
   '      cell.textLabel.text = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"] ? @"Режим призрака" : @"Ghost Mode";'),
  ('      cell.detailTextLabel.text = @"Main toggle for all ghost features";',
   '      cell.detailTextLabel.text = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"] ? @"Общий переключатель невидимки" : @"Main toggle for ghost features";'),
  ('  cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];',
   '  cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];'),
  ('  cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];',
   '  cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];'),
]
for before, after in polish_text_241:
    if mx_ui_source.count(before) != 1:
        raise SystemExit('Goldgram #241: Polish anchor mismatch: ' + before[:80])
    mx_ui_source = mx_ui_source.replace(before, after)

# Set fonts before the self-sizing cell is measured, not only willDisplayCell.
polish_cells_241 = [
  ('  return switchCell;\n}', '''
  if (self.goldgramSection) {
    switchCell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
    switchCell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    switchCell.textLabel.adjustsFontForContentSizeCategory = YES;
    switchCell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
  }
  return switchCell;
}'''),
  ('  return normalCell;\n}', '''
  if (self.goldgramSection) {
    normalCell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
    normalCell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    normalCell.textLabel.adjustsFontForContentSizeCategory = YES;
    normalCell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
  }
  return normalCell;
}''')
]
for before, after in polish_cells_241:
    if mx_ui_source.count(before) != 1:
        raise SystemExit('Goldgram #241: cell factory anchor mismatch')
    mx_ui_source = mx_ui_source.replace(before, after)

# Preserve original switchChanged: write path and its account/ghost validation;
# only refresh labels from user defaults once the existing write finishes.
post_switch_241 = '    mxDiag("switch section=%ld row=%ld has NO KEY", (long)section, (long)row);\n  }\n}'
if mx_ui_source.count(post_switch_241) != 1:
    raise SystemExit('Goldgram #241: switch handler anchor mismatch')
mx_ui_source = mx_ui_source.replace(post_switch_241,
    post_switch_241[:-1] + '  [self goldgramRefreshGhostGroupTitles];\n}')

for needed in ('goldgramGhostGroupExpanded:', 'goldgramGhostGroupTapped:',
               'goldgramGhostGroupTitle:', 'goldgramRefreshGhostGroupTitles',
               'goldgramDashboardTap:', 'presentClearHistoryFromController:',
               'kGhostModeEnabled', 'switchKeyForIndexPath:',
               'goldgramGhostSourceIndexPath:'):
    if needed not in mx_ui_source:
        raise SystemExit('Goldgram #241: required preserved capability absent: ' + needed)
mx_ui_path.write_text(mx_ui_source)
print('Goldgram #241: compact inner Mx UI, collapsible Ghost groups with real switch counts; original archive & keys intact')


# Goldgram #242: a single, scoped dashboard; reused SQLite totals; no
# changes to any persisted Mx setting, archive table, collector, or bridge.
dashboard_cleanup_242 = r'''
// UI-only links; every original Mx action remains in its previous section.
- (UIButton *)goldgramDashboardLink:(NSString *)name
                             symbol:(NSString *)symbol
                         identifier:(NSInteger)identifier {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  button.tag = identifier;
  button.backgroundColor = UIColor.clearColor;
  button.accessibilityLabel = name;
  button.accessibilityTraits = UIAccessibilityTraitButton;
  [button addTarget:self action:@selector(goldgramDashboardTap:)
     forControlEvents:UIControlEventTouchUpInside];

  UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
  icon.translatesAutoresizingMaskIntoConstraints = NO;
  icon.tintColor = UIColor.secondaryLabelColor;
  UILabel *label = [UILabel new];
  label.text = name;
  label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  label.adjustsFontForContentSizeCategory = YES;
  label.textColor = UIColor.labelColor;
  UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
  chevron.translatesAutoresizingMaskIntoConstraints = NO;
  chevron.tintColor = UIColor.tertiaryLabelColor;
  UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, label, chevron]];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  row.axis = UILayoutConstraintAxisHorizontal;
  row.alignment = UIStackViewAlignmentCenter;
  row.spacing = 14;
  row.userInteractionEnabled = NO;
  [button addSubview:row];
  [NSLayoutConstraint activateConstraints:@[
    [icon.widthAnchor constraintEqualToConstant:22],
    [icon.heightAnchor constraintEqualToConstant:22],
    [chevron.widthAnchor constraintEqualToConstant:12],
    [chevron.heightAnchor constraintEqualToConstant:14],
    [row.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:16],
    [row.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-16],
    [row.topAnchor constraintEqualToAnchor:button.topAnchor constant:12],
    [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-12],
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:50]
  ]];
  return button;
}

- (UIStackView *)goldgramDashboardSettingsList:(BOOL)russian {
  UIStackView *list = [UIStackView new];
  list.axis = UILayoutConstraintAxisVertical;
  list.alignment = UIStackViewAlignmentFill;
  list.spacing = 0;
  list.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
  list.layer.cornerRadius = 18;
  list.clipsToBounds = YES;
  NSArray<NSString *> *titles = russian
      ? @[@"Сохранение истории", @"Исправление файлов", @"Язык", @"О Mx"]
      : @[@"History settings", @"File repair", @"Language", @"About Mx"];
  NSArray<NSString *> *symbols = @[@"archivebox", @"folder", @"globe", @"info.circle"];
  NSArray<NSNumber *> *ids = @[@26, @3, @5, @6];
  for (NSInteger i = 0; i < (NSInteger)titles.count; ++i) {
    [list addArrangedSubview:[self goldgramDashboardLink:titles[i]
                                                  symbol:symbols[i]
                                              identifier:ids[i].integerValue]];
    if (i + 1 < (NSInteger)titles.count) {
      UIView *line = [UIView new];
      line.backgroundColor = UIColor.separatorColor;
      [line.heightAnchor constraintEqualToConstant:0.5].active = YES;
      [list addArrangedSubview:line];
    }
  }
  return list;
}

- (UIView *)goldgramDashboardTotalsCard:(BOOL)russian {
  UIView *card = [UIView new];
  card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
  card.layer.cornerRadius = 18.0;
  card.clipsToBounds = YES;
  UILabel *heading = [UILabel new];
  heading.text = russian ? @"Сумма по категориям" : @"Category totals";
  heading.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
  heading.textColor = UIColor.secondaryLabelColor;
  UILabel *count = [UILabel new];
  count.text = @"—";
  count.tag = 3099;
  count.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
  count.adjustsFontForContentSizeCategory = YES;
  count.textColor = UIColor.labelColor;
  UILabel *caption = [UILabel new];
  caption.text = russian ? @"Изменённые + удалённые · возможны пересечения"
                         : @"Edited + deleted · may overlap";
  caption.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
  caption.adjustsFontForContentSizeCategory = YES;
  caption.textColor = UIColor.secondaryLabelColor;
  caption.numberOfLines = 0;
  UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[heading, count, caption]];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  stack.axis = UILayoutConstraintAxisVertical;
  stack.alignment = UIStackViewAlignmentLeading;
  stack.spacing = 4;
  [card addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
    [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
    [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
    [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]
  ]];
  return card;
}

// Uses GoldgramArchiveReader.query(mode:totals) on its existing read-only WAL
// path. Never creates a database and never caches a previous account's counts.
- (void)goldgramDashboardLoadCounts {
  if (self.goldgramSection || !self.goldgramDashboardHeader) return;
  Class reader = NSClassFromString(@"GoldgramArchiveReader");
  if (![reader respondsToSelector:@selector(activeAccountId)] ||
      ![reader respondsToSelector:@selector(query:completion:)]) return;
  NSNumber *account = [reader activeAccountId];
  if (!account || account.longLongValue <= 0) {
    [self goldgramDashboardSetTotal:@"—" edited:@"—" deleted:@"—"];
    return;
  }
  __weak typeof(self) weakSelf = self;
  NSDictionary *request = @{@"accountId":account, @"category":@3,
                            @"mode":@"totals", @"offset":@0, @"limit":@1};
  [reader query:request completion:^(NSDictionary *answer) {
    __strong typeof(weakSelf) owner = weakSelf;
    if (!owner || owner.goldgramSection) return;
    Class currentReader = NSClassFromString(@"GoldgramArchiveReader");
    NSNumber *current = [currentReader activeAccountId];
    if (!current || current.longLongValue != account.longLongValue) {
      [owner goldgramDashboardSetTotal:@"—" edited:@"—" deleted:@"—"];
      return;
    }
    if (![answer[@"status"] isEqual:@"ok"]) {
      [owner goldgramDashboardSetTotal:@"—" edited:@"—" deleted:@"—"];
      return;
    }
    NSNumber *edited = answer[@"edited"];
    NSNumber *deleted = answer[@"deleted"];
    if (![edited isKindOfClass:NSNumber.class] || ![deleted isKindOfClass:NSNumber.class]) return;
    long long e = MAX(0LL, edited.longLongValue);
    long long d = MAX(0LL, deleted.longLongValue);
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    [owner goldgramDashboardSetTotal:[formatter stringFromNumber:@(e + d)]
                            edited:[formatter stringFromNumber:@(e)]
                           deleted:[formatter stringFromNumber:@(d)]];
  }];
}

- (void)goldgramDashboardSetTotal:(NSString *)total
                           edited:(NSString *)edited
                          deleted:(NSString *)deleted {
  UIView *root = self.goldgramDashboardHeader;
  UILabel *combined = (UILabel *)[root viewWithTag:3099];
  UILabel *editedLabel = (UILabel *)[root viewWithTag:3020];
  UILabel *deletedLabel = (UILabel *)[root viewWithTag:3024];
  if ([combined isKindOfClass:UILabel.class]) combined.text = total;
  if ([editedLabel isKindOfClass:UILabel.class]) editedLabel.text = edited;
  if ([deletedLabel isKindOfClass:UILabel.class]) deletedLabel.text = deleted;
}

- (void)goldgramDashboardArchiveChanged:(NSNotification *)notification {
  if (self.goldgramSection || !self.isViewLoaded || !self.view.window) return;
  Class reader = NSClassFromString(@"GoldgramArchiveReader");
  NSNumber *account = [reader respondsToSelector:@selector(activeAccountId)]
      ? [reader activeAccountId] : nil;
  if ([notification.object isKindOfClass:NSNumber.class] && account &&
      [notification.object longLongValue] != account.longLongValue) return;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(goldgramDashboardLoadCounts)
                                             object:nil];
  [self performSelector:@selector(goldgramDashboardLoadCounts)
             withObject:nil afterDelay:0.35];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  if (!self.goldgramSection) [self goldgramDashboardLoadCounts];
}

// Exception controls keep their existing section and all original handlers.
- (void)goldgramOpenGhostExceptions {
  Mx *controller = [Mx new];
  controller.goldgramSection = @(GHOST_EXCEPTIONS);
  [self.navigationController pushViewController:controller animated:YES];
}
'''
if mx_ui_source.count('- (void)goldgramBuildDashboard {') != 1:
    raise SystemExit('Goldgram #242: dashboard anchor changed')
mx_ui_source = mx_ui_source.replace('- (void)goldgramBuildDashboard {',
    dashboard_cleanup_242 + '- (void)goldgramBuildDashboard {')

api_anchor_242 = '@interface NSObject (GoldgramBrowserFactory)'
if mx_ui_source.count(api_anchor_242) != 1:
    raise SystemExit('Goldgram #242: runtime browser API anchor changed')
mx_ui_source = mx_ui_source.replace(api_anchor_242,
    '''@interface NSObject (GoldgramArchiveTotalsAPI)
+ (NSNumber *)activeAccountId;
+ (void)query:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion;
@end
''' + api_anchor_242)

# The root has only one remaining table row (the existing confirmed clear).
# Every other destination is a visible tile or compact navigation row.
tile_counts_anchor = '  content.userInteractionEnabled = NO;'
if mx_ui_source.count(tile_counts_anchor) != 1:
    raise SystemExit('Goldgram #242: tile content anchor changed')
mx_ui_source = mx_ui_source.replace(tile_counts_anchor, tile_counts_anchor + '''
  if (identifier == 20 || identifier == 24) {
    UILabel *count = [UILabel new];
    count.tag = 3000 + identifier;
    count.text = @"—";
    count.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    count.adjustsFontForContentSizeCategory = YES;
    count.textColor = UIColor.labelColor;
    [content insertArrangedSubview:count atIndex:1];
  }''')

old_heading_242 = '''  [stack addArrangedSubview:[self goldgramDashboardHeading:
    russian ? @"АРХИВ СООБЩЕНИЙ" : @"MESSAGE ARCHIVE"]];'''
if mx_ui_source.count(old_heading_242) != 1:
    raise SystemExit('Goldgram #242: archive heading changed')
mx_ui_source = mx_ui_source.replace(old_heading_242, '''
  [stack addArrangedSubview:[self goldgramDashboardHeading:
    russian ? @"АРХИВ GOLDGRAM" : @"GOLDGRAM ARCHIVE"]];
  [stack addArrangedSubview:[self goldgramDashboardTotalsCard:russian]];''')

dashboard_rewords_242 = [
  ('subtitle:russian ? @"Приватность и управление статусом" : @"Privacy and presence controls"',
   'subtitle:russian ? @"Статус, активность и исключения" : @"Presence, activity and exceptions"'),
  ('subtitle:russian ? @"История и разделы" : @"History and categories"',
   'subtitle:russian ? @"История редакций" : @"Edit history"'),
  ('subtitle:russian ? @"Открыть существующую историю каналов" : @"Open the existing channel archive"',
   'subtitle:russian ? @"Публикации и обсуждения" : @"Posts and discussions"'),
]
for before, after in dashboard_rewords_242:
    if mx_ui_source.count(before) != 1:
        raise SystemExit('Goldgram #242: dashboard label anchor changed')
    mx_ui_source = mx_ui_source.replace(before, after)
settings_start_242 = '''  [stack addArrangedSubview:[self goldgramDashboardHeading:
    russian ? @"НАСТРОЙКИ" : @"SETTINGS"]];'''
settings_end_242 = '  self.goldgramDashboardHeader = header;'
if mx_ui_source.count(settings_start_242) != 1 or mx_ui_source.count(settings_end_242) != 1:
    raise SystemExit('Goldgram #242: settings boundaries changed')
ix = mx_ui_source.index(settings_start_242)
jx = mx_ui_source.index(settings_end_242, ix)
mx_ui_source = mx_ui_source[:ix] + '''
  [stack addArrangedSubview:[self goldgramDashboardHeading:
    russian ? @"НАСТРОЙКИ" : @"SETTINGS"]];
  [stack addArrangedSubview:[self goldgramDashboardSettingsList:russian]];

''' + mx_ui_source[jx:]

old_route_242 = '''  if (identifier == 24 || identifier == 25) {
    // Existing native archive controller: 3 = deleted, 2 = channels/comments.'''
new_route_242 = '''  if (identifier == 20 || identifier == 24 || identifier == 25) {
    // Existing Swift archive: 4 = all edits, 3 = all deletions, 2 = channels.
    // This view never alters the underlying archive or its capture path.'''
if mx_ui_source.count(old_route_242) != 1:
    raise SystemExit('Goldgram #242: archive route anchor changed')
mx_ui_source = mx_ui_source.replace(old_route_242, new_route_242)
old_dest_242 = 'id controller = [[browser alloc] initWithCategory:identifier == 24 ? 3 : 2];'
if mx_ui_source.count(old_dest_242) != 1:
    raise SystemExit('Goldgram #242: archive route category changed')
mx_ui_source = mx_ui_source.replace(old_dest_242,
    'id controller = [[browser alloc] initWithCategory:identifier == 20 ? 4 : (identifier == 24 ? 3 : 2)];')
old_folder_242 = '''  Mx *folder = [Mx new];
  if (identifier >= 20 && identifier <= 23) {'''
new_folder_242 = '''  Mx *folder = [Mx new];
  if (identifier == 26) {
    // Former "Edited" settings remain accessible as "History settings".
    folder.goldgramSection = @(MISC);
    folder.goldgramMiscCategory = @0;
  } else if (identifier >= 21 && identifier <= 23) {'''
if mx_ui_source.count(old_folder_242) != 1:
    raise SystemExit('Goldgram #242: settings route anchor changed')
mx_ui_source = mx_ui_source.replace(old_folder_242, new_folder_242)

# Group names change only in the UI; the original source row groups remain.
old_group_title_242 = '@[@"Удалённые и изменённые", @"Приватность и доступ",'
if mx_ui_source.count(old_group_title_242) != 1:
    raise SystemExit('Goldgram #242: history section title changed')
mx_ui_source = mx_ui_source.replace(old_group_title_242,
    '@[@"Сохранение истории", @"Приватность и доступ",')

# Add a compact link *inside* Ghost instead of a duplicate root tile.
# This replaces only the #241 compact header, not its setting table.
ghost_header_start = '- (void)goldgramBuildInnerHeader {'
ghost_header_end = '- (void)goldgramFitInnerHeader {'
if mx_ui_source.count(ghost_header_start) != 1 or mx_ui_source.count(ghost_header_end) != 1:
    raise SystemExit('Goldgram #242: inner header boundaries changed')
start = mx_ui_source.index(ghost_header_start)
end = mx_ui_source.index(ghost_header_end, start)
inner_header_242 = r'''- (void)goldgramBuildInnerHeader {
  if (!self.goldgramSection) return;
  UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 1)];
  UIStackView *column = [UIStackView new];
  column.translatesAutoresizingMaskIntoConstraints = NO;
  column.axis = UILayoutConstraintAxisVertical;
  column.alignment = UIStackViewAlignmentFill;
  column.spacing = 8;
  UIImageView *symbol = [[UIImageView alloc] initWithImage:
      [UIImage systemImageNamed:[self goldgramInnerSymbol]]];
  symbol.tintColor = [self goldgramInnerTint];
  [symbol.widthAnchor constraintEqualToConstant:20].active = YES;
  [symbol.heightAnchor constraintEqualToConstant:20].active = YES;
  UILabel *summary = [UILabel new];
  summary.text = [self goldgramInnerSummary];
  summary.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  summary.adjustsFontForContentSizeCategory = YES;
  summary.textColor = UIColor.secondaryLabelColor;
  summary.numberOfLines = 0;
  UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:@[symbol, summary]];
  line.axis = UILayoutConstraintAxisHorizontal;
  line.alignment = UIStackViewAlignmentCenter;
  line.spacing = 11;
  [column addArrangedSubview:line];
  if (self.goldgramSection.integerValue == GHOST_MODE) {
    BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"];
    UIButton *exceptions = [UIButton buttonWithType:UIButtonTypeSystem];
    [exceptions setTitle:ru ? @"Исключения для невидимки  ›" : @"Ghost exceptions  ›"
                forState:UIControlStateNormal];
    exceptions.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    exceptions.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    [exceptions setTitleColor:UIColor.systemTealColor forState:UIControlStateNormal];
    [exceptions addTarget:self action:@selector(goldgramOpenGhostExceptions)
         forControlEvents:UIControlEventTouchUpInside];
    [exceptions.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [column addArrangedSubview:exceptions];
  }
  [header addSubview:column];
  [NSLayoutConstraint activateConstraints:@[
    [column.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:30],
    [column.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-30],
    [column.topAnchor constraintEqualToAnchor:header.topAnchor constant:11],
    [column.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-11]
  ]];
  self.goldgramInnerHeader = header;
  self.tableView.tableHeaderView = header;
}

'''
mx_ui_source = mx_ui_source[:start] + inner_header_242 + mx_ui_source[end:]

observer_anchor_242 = '  else [self goldgramBuildDashboard];'
if mx_ui_source.count(observer_anchor_242) != 1:
    raise SystemExit('Goldgram #242: root lifecycle changed')
mx_ui_source = mx_ui_source.replace(observer_anchor_242, '''  else {
    [self goldgramBuildDashboard];
    [[NSNotificationCenter defaultCenter] addObserver:self
       selector:@selector(goldgramDashboardArchiveChanged:)
           name:@"GoldgramArchiveChanged" object:nil];
  }''')

# Counts are per archived message in two categories, not numbers of edit events.
# Do not relabel them as "unique messages". User-facing sum can double-count
# a message which was both edited and deleted.
for must in ('goldgramDashboardArchiveChanged:', 'goldgramDashboardLoadCounts',
             'goldgramDashboardTotalsCard:', 'goldgramOpenGhostExceptions',
             'identifier == 20 ? 4', 'goldgramDashboardSettingsList:russian',
             'presentClearHistoryFromController:', 'goldgramGhostGroupExpanded:',
             'kGhostModeEnabled'):
    if must not in mx_ui_source:
        raise SystemExit('Goldgram #242: required capability absent ' + must)
if 'Все функции Mx' in mx_ui_source or 'All Mx features' in mx_ui_source:
    raise SystemExit('Goldgram #242: duplicate root tile was not removed')
mx_ui_path.write_text(mx_ui_source)
print('Goldgram #242: scoped totals, direct edit/deletion archives, one home for each Mx setting')


# Goldgram #244: UI-only folder de-duplication, root archive shortcuts, safe areas.
# Keep legacy Mx switch keys, SQLite counters, navigation and archival actions.
def patch_244(a, b, label):
    global mx_ui_source
    if mx_ui_source.count(a) != 1:
        raise SystemExit('Goldgram #244: anchor ' + label + ' missing/ambiguous')
    mx_ui_source = mx_ui_source.replace(a, b, 1)

patch_244('''  [stack addArrangedSubview:[self goldgramDashboardTile:
    russian ? @"Каналы и комментарии" : @"Channels and comments"''',
'''  [stack addArrangedSubview:[self goldgramDashboardPair:
    [self goldgramDashboardTile:russian ? @"Личные сообщения" : @"Personal messages"
      subtitle:russian ? @"История личных чатов" : @"Private chat history"
      symbol:@"person.crop.circle" tint:UIColor.systemTealColor identifier:27 compact:YES]
    second:[self goldgramDashboardTile:russian ? @"Группы и чаты" : @"Groups and chats"
      subtitle:russian ? @"История групп" : @"Group history"
      symbol:@"person.3" tint:UIColor.systemPurpleColor identifier:28 compact:YES]]];
  [stack addArrangedSubview:[self goldgramDashboardTile:
    russian ? @"Каналы и комментарии" : @"Channels and comments"''',
    'home personal/group tiles')
patch_244(
    'if (identifier == 20 || identifier == 24 || identifier == 25) {',
    'if (identifier == 20 || identifier == 24 || identifier == 25 || identifier == 27 || identifier == 28) {',
    'archive IDs')
patch_244(
    'id controller = [[browser alloc] initWithCategory:identifier == 20 ? 4 : (identifier == 24 ? 3 : 2)];',
    '''NSInteger category = identifier == 20 ? 4 : identifier == 24 ? 3 :
                        identifier == 27 ? 0 : identifier == 28 ? 1 : 2;
      id controller = [[browser alloc] initWithCategory:category];''',
    'existing archive categories')
# Hide only redundant archive links in the five-row history settings view;
# preserve the handlers and all five original Mx toggles.
patch_244(
    'return [groups[category] count] + (category == 0 ? 4 : 0);',
    'return [groups[category] count];',
    'duplicated history rows')

# Internal table must not begin underneath the translucent custom navbar.
# Root dashboard remains unchanged, while nested menus use safe-area layout.
patch_244(
    '[self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor]',
    '[self.tableView.topAnchor constraintEqualToAnchor:(self.goldgramSection ? self.view.safeAreaLayoutGuide.topAnchor : self.view.topAnchor)]',
    'inner safe-area anchor')
patch_244(
    '  self.tableView.translatesAutoresizingMaskIntoConstraints = NO;',
    '''  self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
  if (self.goldgramSection) {
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.tableView.sectionHeaderTopPadding = 0;
    self.tableView.estimatedSectionFooterHeight = 0;
  }''',
    'disable double top inset')

# Reuse all original Ghost group keys/counters, but separate count from title
# and move the navigation chevron to the right.
start_name = '- (void)goldgramSetGhostGroupButton:(UIButton *)button section:(NSInteger)section {'
end_name = '- (void)goldgramGhostGroupTapped:(UIButton *)button {'
if mx_ui_source.count(start_name) != 1 or mx_ui_source.count(end_name) != 1:
    raise SystemExit('Goldgram #244: Ghost setter source moved')
start, end = mx_ui_source.index(start_name), mx_ui_source.index(end_name)
mx_ui_source = mx_ui_source[:start] + r'''- (void)goldgramSetGhostGroupButton:(UIButton *)button section:(NSInteger)section {
  NSString *title = [self goldgramGhostGroupTitle:section];
  NSArray<NSString *> *parts = [title componentsSeparatedByString:@"  ·  "];
  UILabel *name = (UILabel *)[button viewWithTag:4441];
  UILabel *count = (UILabel *)[button viewWithTag:4442];
  UIImageView *arrow = (UIImageView *)[button viewWithTag:4443];
  name.text = parts.firstObject;
  count.text = parts.count > 1 ? parts.lastObject : @"";
  arrow.image = [UIImage systemImageNamed:
                [self goldgramGhostGroupExpanded:section] ? @"chevron.down" : @"chevron.right"];
  button.accessibilityLabel = title;
  BOOL ru = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"];
  button.accessibilityHint = [self goldgramGhostGroupExpanded:section]
      ? (ru ? @"Свернуть группу" : @"Collapse group")
      : (ru ? @"Раскрыть группу" : @"Expand group");
}

''' + mx_ui_source[end:]

start_head = '- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {'
end_head = '- (CGFloat)tableView:(UITableView *)tableView\n    heightForHeaderInSection:(NSInteger)section {'
if mx_ui_source.count(start_head) != 1 or mx_ui_source.count(end_head) != 1:
    raise SystemExit('Goldgram #244: Ghost header source moved')
start, end = mx_ui_source.index(start_head), mx_ui_source.index(end_head)
mx_ui_source = mx_ui_source[:start] + r'''- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  if (!self.goldgramSection || self.goldgramSection.integerValue != GHOST_MODE ||
      !self.isGhostModeExpanded || section < 1 || section > 3) return nil;
  NSString *reuse = @"GoldgramGhostGroupHeader";
  UITableViewHeaderFooterView *header =
      [tableView dequeueReusableHeaderFooterViewWithIdentifier:reuse];
  if (!header) {
    header = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:reuse];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    button.layer.cornerRadius = 15;
    button.layer.masksToBounds = YES;
    button.accessibilityTraits = UIAccessibilityTraitButton;
    UILabel *name = [UILabel new];
    name.tag = 4441;
    name.textColor = UIColor.labelColor;
    name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    name.adjustsFontForContentSizeCategory = YES;
    name.numberOfLines = 1;
    [name setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                          forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *count = [UILabel new];
    count.tag = 4442;
    count.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    count.adjustsFontForContentSizeCategory = YES;
    count.textColor = UIColor.secondaryLabelColor;
    [count setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    UIImageView *arrow = [UIImageView new];
    arrow.tag = 4443;
    arrow.tintColor = UIColor.tertiaryLabelColor;
    arrow.contentMode = UIViewContentModeScaleAspectFit;
    [arrow.widthAnchor constraintEqualToConstant:14].active = YES;
    [arrow.heightAnchor constraintEqualToConstant:14].active = YES;
    UIStackView *items = [[UIStackView alloc] initWithArrangedSubviews:@[name, count, arrow]];
    items.axis = UILayoutConstraintAxisHorizontal;
    items.alignment = UIStackViewAlignmentCenter;
    items.spacing = 10;
    items.translatesAutoresizingMaskIntoConstraints = NO;
    items.userInteractionEnabled = NO;
    [button addSubview:items];
    [NSLayoutConstraint activateConstraints:@[
      [items.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:16],
      [items.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-16],
      [items.topAnchor constraintEqualToAnchor:button.topAnchor constant:8],
      [items.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-8]
    ]];
    [button addTarget:self action:@selector(goldgramGhostGroupTapped:)
       forControlEvents:UIControlEventTouchUpInside];
    [header.contentView addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
      [button.leadingAnchor constraintEqualToAnchor:header.contentView.leadingAnchor constant:16],
      [button.trailingAnchor constraintEqualToAnchor:header.contentView.trailingAnchor constant:-16],
      [button.topAnchor constraintEqualToAnchor:header.contentView.topAnchor constant:2],
      [button.bottomAnchor constraintEqualToAnchor:header.contentView.bottomAnchor constant:-2]
    ]];
  }
  UIButton *button = (UIButton *)header.contentView.subviews.firstObject;
  button.tag = section;
  [self goldgramSetGhostGroupButton:button section:section];
  return header;
}

''' + mx_ui_source[end:]
patch_244('self.isGhostModeExpanded && section > 0 && section < 4) return 56.0;',
          'self.isGhostModeExpanded && section > 0 && section < 4) return 48.0;',
          'compact Ghost headers')
patch_244(end_head, r'''- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  if (!self.goldgramSection) return UITableViewAutomaticDimension;
  return self.goldgramSection.integerValue == GHOST_MODE ? 8.0 : CGFLOAT_MIN;
}

''' + end_head, 'compact section footers')

for preserved in ('goldgramMiscRows', 'goldgramDashboardLoadCounts',
                  'goldgramGhostGroupTapped:', 'presentClearHistoryFromController:',
                  'goldgramOpenGhostExceptions', 'goldgramDashboardArchiveChanged',
                  'identifier == 27 ? 0', 'identifier == 28 ? 1'):
    if preserved not in mx_ui_source:
        raise SystemExit('Goldgram #244: preserved capability missing: ' + preserved)
mx_ui_path.write_text(mx_ui_source)
print('Goldgram #244: direct personal/group archives; deduplicated history; compact Ghost; safe-area inner menus')


# Goldgram #245: one new dashboard tile without reusing old Mx IDs.
# Preserve #244 archives, all ghost toggles, and the existing SQLite reader.
author_anchor_245 = '''  [stack addArrangedSubview:[self goldgramDashboardTile:
    russian ? @"Режим невидимки" : @"Ghost mode"'''
if mx_ui_source.count(author_anchor_245) != 1:
    raise SystemExit('Goldgram #245: dashboard author entry anchor mismatch')
mx_ui_source = mx_ui_source.replace(author_anchor_245, '''  [stack addArrangedSubview:[self goldgramDashboardTile:
    russian ? @"Поиск по автору" : @"Search by author"
    subtitle:russian ? @"Сообщения человека в разных чатах" : @"Messages by sender across chats"
    symbol:@"person.crop.circle.badge.magnifyingglass"
    tint:UIColor.systemBlueColor identifier:29 compact:NO]];
''' + author_anchor_245)
author_route_245 = '''  Mx *folder = [Mx new];
  if (identifier == 26) {'''
if mx_ui_source.count(author_route_245) != 1:
    raise SystemExit('Goldgram #245: dashboard route anchor mismatch')
mx_ui_source = mx_ui_source.replace(author_route_245, '''  if (identifier == 29) {
    Class search = NSClassFromString(@"GoldgramAuthorSearchBridge");
    SEL action = @selector(presentFromController:);
    if ([search respondsToSelector:action]) {
      typedef void (*OpenSearch)(id, SEL, UIViewController *);
      ((OpenSearch)[search methodForSelector:action])(search, action, self);
    }
    return;
  }
''' + author_route_245)
mx_ui_path.write_text(mx_ui_source)
print('Goldgram #245: author search on Mx dashboard')
