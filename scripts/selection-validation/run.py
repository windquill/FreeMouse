from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[2]
work=root/'.build/selection-validation'
work.mkdir(parents=True,exist_ok=True)
source=root/'Sources/FreeMouse'
args=['xcrun','swiftc','-parse-as-library','-swift-version','5','-module-cache-path',str(work/'module-cache')]
args += [str(source/name) for name in ['RegionSelector.swift','SelectionGeometry.swift','CaptureTypes.swift','ScrollCaptureFlow.swift']]
args += [str(Path(__file__).with_name('Runner.swift')),'-o',str(work/'Runner')]
subprocess.run(args,cwd=root,check=True)
subprocess.run([str(work/'Runner')],cwd=root,check=True,timeout=30)
