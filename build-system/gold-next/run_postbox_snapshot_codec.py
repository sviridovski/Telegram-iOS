#!/usr/bin/env python3
"""Execute the actual production record with the repository's Postbox codec.

macOS CI has Swift/Objective-C Foundation. No substituted encoder or model.
"""
from pathlib import Path
import os, resource, shutil, signal, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='goldgram-postbox-') as temp:
    work = Path(temp)
    module = work / 'MurMurHash32'
    module.mkdir()
    shutil.copy(root / 'submodules/MurMurHash32/PublicHeaders/MurMurHash32/MurMurHash32.h', module)
    (module / 'module.modulemap').write_text('module MurMurHash32 { header "MurMurHash32.h" export * }\n')
    obj = work / 'hash.o'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-c',
                    str(root / 'submodules/MurMurHash32/Sources/MurMurHash32.m'),
                    '-I', str(work), '-o', str(obj)], check=True)
    postbox = root / 'submodules/Postbox/Sources'
    sources = [postbox / 'Coding.swift', *sorted((postbox / 'Utils/Encoder').glob('*.swift')),
               *sorted((postbox / 'Utils/Decoder').glob('*.swift')),
               root / 'submodules/TelegramCore/Sources/State/GoldgramSnapshotRecord.swift',
               root / 'build-system/gold-next/test_snapshot_codec.swift']
    executable = work / 'snapshot-test'
    subprocess.run(['xcrun', 'swiftc', '-O', '-I', str(work), *map(str, sources),
                    str(obj), '-o', str(executable)], check=True)
    env = dict(os.environ, SWIFT_BACKTRACE='enable=no')
    def no_core():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    legacy = subprocess.run([str(executable), '--legacy-unsigned'], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=no_core)
    assert legacy.returncode in (-signal.SIGILL, -signal.SIGTRAP), \
        f'Expected Postbox UInt32 trap, got {legacy.returncode}'
    print('Confirmed #85 unsigned flag serialization traps in the actual Postbox adapter', flush=True)
    subprocess.run([str(executable)], check=True, env=env)
