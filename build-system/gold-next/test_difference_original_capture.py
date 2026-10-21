#!/usr/bin/env python3
"""#106: the raw getChannelDifference new_messages body precedes edits and replay."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
state = (root / "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift").read_text()
core = (root / "submodules/TelegramCore/Sources/State/GoldgramNativeHistory.swift").read_text()

poll = state.split("private func pollChannel(", 1)[1]
normal = poll.split("case let .channelDifference(channelDifferenceData):", 1)[1].split(
    "case let .channelDifferenceEmpty(", 1)[0]
new = normal.split("for apiMessage in newMessages {", 1)[1].split("for update in otherUpdates {", 1)[0]
assert "goldgramCaptureServerOriginal(" in new, "missing raw catch-up original capture"
assert new.index("goldgramCaptureServerOriginal(") < new.index(
    "updatedState.addMessages([message], location: .UpperHistoryBlock)"
), "original must be recorded before deferred Postbox insertion"
assert "goldgramVerifiedPublicKind(" in new, "peer kind must be authenticated"
assert "goldgramNativeHistoryEnabled()" in new, "don't run legacy/new writer concurrently"
assert "goldgramCaptureServerOriginal(" not in normal.split("for update in otherUpdates {", 1)[1], (
    "edits cannot be relabelled as initial originals"
)
capture = core.split("func goldgramCaptureServerOriginal(", 1)[1].split(
    "// #103:", 1)[0]
assert "!message.attributes.contains(where: { $0 is EditedMessageAttribute })" in capture, (
    "a current edited server snapshot must never be called a genuine original"
)
assert '"baselineOnly": true' in capture, "no spurious edit events from original observation"
print("Goldgram #106: raw channel-difference original precedes edits; provenance guarded")
