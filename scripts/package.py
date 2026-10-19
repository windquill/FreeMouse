#!/usr/bin/python3
"""Package existing signed app. Uses makehybrid + convert without mounting."""
from pathlib import Path
import hashlib, shutil, subprocess, zipfile
ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'.build'
OUTPUT=ROOT/'outputs'
OUTPUT.mkdir(exist_ok=True)
STAGE=WORK/'dmg-stage-1.1.23'
APP=WORK/'release-1.1.23/自在工具箱.app'
raw=WORK/'FreeMouse-1.1.23.raw.dmg'
final=OUTPUT/'自在工具箱-1.1.23-AppleSilicon.dmg'
source=OUTPUT/'FreeMouse-1.1.23-Source.zip'
checks_path=OUTPUT/'SHA256SUMS-1.1.23.txt'
usage=OUTPUT/'自在工具箱-1.1.23-使用说明.txt'
for p in [STAGE,raw,final,source,checks_path,usage]:
 if p.exists(): raise SystemExit(f'Refusing to overwrite {p}')
for name in ['功能对照-1.1.23.txt','更新说明-1.1.23.txt','验证记录-1.1.23.txt']:
 if not (OUTPUT/name).is_file(): raise SystemExit(f'Missing release document: {name}')
STAGE.mkdir()
shutil.copytree(APP,STAGE/APP.name)
link=STAGE/'应用程序'
if not link.exists(): link.symlink_to('/Applications',target_is_directory=True)
shutil.copy2(ROOT/'README.md',STAGE/'安装与使用说明.txt')
shutil.copy2(ROOT/'LICENSE',STAGE/'LICENSE.txt')
shutil.copy2(ROOT/'THIRD_PARTY_NOTICES.md',STAGE/'THIRD_PARTY_NOTICES.md')
shutil.copy2(ROOT/'ThirdParty/Capso/LICENSE',STAGE/'Capso-LICENSE.txt')
shutil.copy2(ROOT/'README.md',usage)
shutil.copy2(OUTPUT/'验证记录-1.1.23.txt',STAGE/'验证记录.txt')
shutil.copy2(OUTPUT/'功能对照-1.1.23.txt',STAGE/'功能对照-1.1.23.txt')
shutil.copy2(OUTPUT/'更新说明-1.1.23.txt',STAGE/'更新说明-1.1.23.txt')
subprocess.run(['hdiutil','makehybrid','-hfs','-hfs-volume-name','自在工具箱','-o',str(raw),str(STAGE)],check=True)
subprocess.run(['hdiutil','convert',str(raw),'-format','UDZO','-o',str(final)],check=True)
# Source-only archive. Build caches, user state, reference DMG are never included.
with zipfile.ZipFile(source,'x',zipfile.ZIP_DEFLATED) as archive:
 for item in ['Package.swift','README.md','LICENSE','.gitignore','Sources','Tests','FinderExtension','scripts','docs','ThirdParty','THIRD_PARTY_NOTICES.md']:
  path=ROOT/item
  if path.is_dir():
   for f in sorted(path.rglob('*')):
    if f.is_file(): archive.write(f,'FreeMouse/'+str(f.relative_to(ROOT)))
  elif path.is_file(): archive.write(path,'FreeMouse/'+item)
checks=[]
for p in [final,source]: checks.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name)
with checks_path.open('x') as handle: handle.write('\n'.join(checks)+'\n')
print(final)

