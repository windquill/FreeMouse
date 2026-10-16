#!/usr/bin/env python3
"""Validate production capture code against an opaque synthetic AppKit window.

Requires existing screen-recording permission. Does not request permission or
capture other windows. All generated files stay under this project's .build.
"""
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / 'Sources/FreeMouse'
HARNESS = Path(__file__).resolve().parent
WORK = ROOT / '.build/scroll-validation'
WORK.mkdir(parents=True, exist_ok=True)
CACHE = WORK / 'module-cache'
ENV = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(CACHE))


def compile_program(name, source_names):
    executable = WORK / name
    args = ['xcrun', 'swiftc', '-parse-as-library', '-O', '-swift-version', '5',
            '-target', 'arm64-apple-macos15.0', '-module-cache-path', str(CACHE)]
    if os.environ.get('SCROLL_VALIDATION_DIAGNOSTICS') == '1':
        args += ['-D', 'SCROLL_CAPTURE_DIAGNOSTICS']
    args += [str(SOURCES / item) for item in source_names]
    args += [str(HARNESS / (name + '.swift')), '-o', str(executable)]
    with (WORK / (name + '-build.log')).open('w') as log:
        subprocess.run(args, cwd=ROOT, env=ENV, stdout=log, stderr=subprocess.STDOUT, check=True)
    return executable


def validate(target, runner, result_name):
    directory = WORK / (runner.name + '-' + uuid.uuid4().hex[:8])
    directory.mkdir()
    with (directory / 'target.log').open('w') as target_log:
        process = subprocess.Popen([str(target), str(directory)], cwd=ROOT, env=ENV,
                                   stdout=target_log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while not (directory / 'state.json').is_file():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Synthetic window unavailable; see ' + str(directory / 'target.log'))
                time.sleep(0.05)
            with (directory / 'runner.log').open('w') as log:
                subprocess.run([str(runner), str(directory)], cwd=ROOT, env=ENV,
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
            result = (directory / result_name).read_text()
            print(result, flush=True)
            if 'RESULT_PASS' not in result or 'RESULT_FAIL' in result:
                raise RuntimeError('Live validation failed: ' + str(directory))
            print('Evidence: ' + str(directory), flush=True)
        finally:
            if process.poll() is None:
                (directory / 'command.json').write_text(json.dumps(
                    {'sequence': 2000000, 'offset': 0, 'quit': True}))
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    # This handle belongs only to the child started above.
                    process.terminate()
                    process.wait(timeout=5)


if __name__ == '__main__':
    target = compile_program('Target', [])
    sources = ['CaptureTypes.swift', 'ScrollCaptureFlow.swift', 'ScrollCaptureController.swift']
    sources += [str(p.relative_to(SOURCES)) for p in sorted((SOURCES / 'CapsoScrolling').glob('*.swift'))]
    controller = compile_program('ControllerRunner', sources)
    validate(target, controller, 'controller-result.log')
