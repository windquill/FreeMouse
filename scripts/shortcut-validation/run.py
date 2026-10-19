from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[2]
work=root/'.build/shortcut-validation'
work.mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-module-cache-path',str(work/'module-cache'),str(root/'Sources/FreeMouse/KeyboardShortcuts.swift'),str(Path(__file__).with_name('Runner.swift')),'-o',str(work/'Runner')],cwd=root,check=True)
subprocess.run([str(work/'Runner'),str(work/'settings.png')],cwd=root,check=True,timeout=30)
