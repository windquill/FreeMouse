#!/usr/bin/python3
"""Render documentation illustrations from production views with fixture data.
Requires a successful scripts/build.py run for the archive codec objects.
No screenshot includes the desktop; no system control action is invoked.
"""
from pathlib import Path
import re, subprocess

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.build/readme-screenshots'
WORK.mkdir(parents=True, exist_ok=True)
SOURCES = ROOT / 'Sources/FreeMouse'

# Copies live only in .build: exposing setters permits fixture injection without
# adding test hooks or changing behavior in the shipping application.
copies = {
 'StartupManager.swift': [('private struct StartupManagerView:', 'struct StartupManagerView:')],
 'ApplicationRuntime.swift': [('@Published private(set) var processes:', '@Published var processes:')],
 'InputSourceSwitcher.swift': [('@Published private(set)', '@Published'), ('private struct AppInputSwitcherView:', 'struct AppInputSwitcherView:')],
 'FanControl.swift': [('@Published private(set)', '@Published'), ('private struct FanControlView:', 'struct FanControlView:')]
}
for name, replacements in copies.items():
 text = (SOURCES / name).read_text()
 for old, new in replacements:
  if old not in text: raise SystemExit(f'Production view changed: {name}: {old}')
  text = text.replace(old, new)
 (WORK / name).write_text(text)
translation = (SOURCES / 'SystemTranslation.swift').read_text()
start = translation.index('@MainActor final class SystemTranslationState:')
translation = 'import AppKit\nimport SwiftUI\nimport Translation\nimport NaturalLanguage\nimport AVFoundation\n' + translation[start:]
translation, count = re.subn(r'\n            \.translationTask\(state.configuration\).*?\.id\(requestID\)', '', translation, flags=re.S)
if count != 1: raise SystemExit('Translation view changed: cannot disable live session task')
(WORK / 'SystemTranslation.swift').write_text(translation)
objects = sorted((ROOT / '.build/archive-codecs').glob('*.o'))
if not objects: raise SystemExit('Run scripts/build.py before generating documentation images')
inputs = [WORK / name for name in copies] + [WORK / 'SystemTranslation.swift']
inputs += [SOURCES / name for name in ['StartupSystemServices.swift','NetworkProcessKiller.swift','ArchiveFormats.swift','MenuCatalog.swift','FinderMenuPreferences.swift','FinderMenuBuilder.swift']]
command = ['/usr/bin/arch','-arm64','/usr/bin/xcrun','swiftc','-parse-as-library',
 '-target','arm64-apple-macos15.0','-module-cache-path', str(ROOT / '.build/release-module-cache'),
 '-I',str(ROOT / 'Sources/CArchiveBridge/include'), *map(str,inputs),
 str(Path(__file__).with_name('Renderer.swift')), *map(str,objects), '-larchive.2', '-o',str(WORK / 'Renderer')]
subprocess.run(command,cwd=ROOT,check=True)
subprocess.run([str(WORK / 'Renderer')],cwd=ROOT,check=True)
