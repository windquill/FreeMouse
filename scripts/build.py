#!/usr/bin/python3
"""Build the app without Xcode, third-party dependencies or a developer account."""
from pathlib import Path
import os, plistlib, shutil, subprocess, sys, struct, tempfile
ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'.build'
BUILD=WORK/'release-1.1.31'
APP=BUILD/'OmniDesk.app'
def run(args):
    print('+', ' '.join(map(str,args)), flush=True)
    subprocess.run(list(map(str,args)), cwd=ROOT, check=True)
def copy_notices():
    resources=APP/'Contents/Resources'
    resources.mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT/'THIRD_PARTY_NOTICES.md',resources/'THIRD_PARTY_NOTICES.md')
    shutil.copy2(ROOT/'ThirdParty/Capso/LICENSE',resources/'Capso-LICENSE.txt')
    shutil.copy2(ROOT/'ThirdParty/Stats/LICENSE',resources/'Stats-LICENSE.txt')
def compile_app():
    sources=sorted((ROOT/'Sources/FreeMouse').rglob('*.swift'))
    run(['xcrun','swiftc','-O','-whole-module-optimization','-swift-version','5','-target','arm64-apple-macos15.0','-module-name','FreeMouse','-module-cache-path',WORK/'release-module-cache','-parse-as-library',*sources,'-o',APP/'Contents/MacOS/OmniDesk'])
if BUILD.exists():
    if sys.argv[1:] != ['--refresh-binary']:
        raise SystemExit(f'Refusing to overwrite {BUILD}; use --refresh-binary for this generated app only')
    info=plistlib.loads((APP/'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier']=='local.freemouse.toolbox'
    assert info['CFBundleShortVersionString']=='1.1.31' and info['CFBundleVersion']=='33'
    compile_app()
    copy_notices()
    run(['codesign','--force','--sign','-','--identifier','local.freemouse.toolbox',APP])
    run(['codesign','--verify','--deep','--strict','--verbose=2',APP])
    print('PASS: refreshed 1.1.31 build 33 executable and verified signature')
    raise SystemExit(0)
BUILD.mkdir(parents=True)
contents=APP/'Contents'
(contents/'MacOS').mkdir(parents=True,exist_ok=True)
(contents/'Resources').mkdir(exist_ok=True)
copy_notices()
compile_app()
plist={
 'CFBundleName':'OmniDesk','CFBundleDisplayName':'OmniDesk','CFBundleExecutable':'OmniDesk',
 'CFBundleIdentifier':'local.freemouse.toolbox','CFBundleShortVersionString':'1.1.31','CFBundleVersion':'33',
 'CFBundlePackageType':'APPL','CFBundleIconFile':'AppIcon','LSMinimumSystemVersion':'15.0',
 'NSLocationUsageDescription':'仅在您点击网络面板中的允许访问 Wi-Fi 详细信息时申请定位权限，用于读取当前 Wi-Fi 名称。',
 'NSLocationWhenInUseUsageDescription':'仅在您主动请求 Wi-Fi 详细信息时使用定位授权读取 Wi-Fi 名称。',
 'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','LSUIElement':True,
 'NSCameraUsageDescription':'仅在您开启录屏摄像头小窗时采集摄像头画面，并将其保存到您选择的本机视频文件。',
 'NSMicrophoneUsageDescription':'仅在您启用麦克风录屏时采集麦克风声音，并保存到您选择的本机文件。',
 'NSScreenCaptureUsageDescription':'在您主动使用截图、长截图或录屏时采集屏幕内容，所有处理均在本机完成。',
 'CFBundleURLTypes':[{'CFBundleURLName':'OmniDesk file actions','CFBundleURLSchemes':['freemouse']}],
 'CFBundleDocumentTypes':[{'CFBundleTypeName':'图片','CFBundleTypeRole':'Editor','LSHandlerRank':'Alternate','LSItemContentTypes':['public.png','public.jpeg','public.tiff','public.heic','com.compuserve.gif']}],
 'NSAppleEventsUsageDescription':'仅在您使用终端或云目录菜单时，获取 Finder 选区或在终端打开选定目录。',
 'NSServices':[
  {'NSMenuItem':{'default':'OmniDesk/文字转二维码'},'NSMessage':'textQRCode','NSPortName':'OmniDesk','NSSendTypes':['public.utf8-plain-text'],'NSRequiredContext':{}},
  {'NSMenuItem':{'default':'OmniDesk/Google 翻译'},'NSMessage':'translateGoogle','NSPortName':'OmniDesk','NSSendTypes':['public.utf8-plain-text'],'NSRequiredContext':{}},
  {'NSMenuItem':{'default':'OmniDesk/百度翻译'},'NSMessage':'translateBaidu','NSPortName':'OmniDesk','NSSendTypes':['public.utf8-plain-text'],'NSRequiredContext':{}},
  {'NSMenuItem':{'default':'OmniDesk/复制文件路径'},'NSMessage':'copyFilePaths','NSPortName':'OmniDesk','NSSendTypes':['public.file-url'],'NSReturnTypes':['public.utf8-plain-text'],'NSRequiredContext':{}},
  {'NSMenuItem':{'default':'OmniDesk/编辑图片与识字'},'NSMessage':'editSelectedImage','NSPortName':'OmniDesk','NSSendTypes':['public.file-url'],'NSRequiredContext':{}}
 ],
 'NSHumanReadableCopyright':'Copyright © 2026 FreeMouse contributors. Independent local utility.'
}
with (contents/'Info.plist').open('wb') as f: plistlib.dump(plist,f)
run(['xcrun','swift','-module-cache-path',BUILD/'icon-module-cache',ROOT/'scripts/make-icon.swift',BUILD/'AppIcon.png'])
iconset=BUILD/'AppIcon.iconset'; iconset.mkdir()
for size in [16,32,128,256,512]:
 for scale in [1,2]:
  name=f'icon_{size}x{size}'+('@2x' if scale==2 else '')+'.png'
  run(['sips','-z',size*scale,size*scale,BUILD/'AppIcon.png','--out',iconset/name])
# ICNS supports PNG payloads. Write standard chunks directly; avoids iconutil
# failures in Command Line Tools environments without the Xcode icon tooling.
chunks=[]
for kind,filename in [('icp4','icon_16x16.png'),('icp5','icon_32x32.png'),('icp6','icon_32x32@2x.png'),('ic07','icon_128x128.png'),('ic08','icon_256x256.png'),('ic09','icon_512x512.png'),('ic10','icon_512x512@2x.png')]:
 data=(iconset/filename).read_bytes()
 chunks.append(kind.encode()+struct.pack('>I',len(data)+8)+data)
payload=b''.join(chunks)
(contents/'Resources/AppIcon.icns').write_bytes(b'icns'+struct.pack('>I',len(payload)+8)+payload)
extension=contents/'PlugIns/FreeMouseFinder.appex'
(extension/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
# Swift 6.4 CLT can treat relative and canonical cache paths as duplicate
# Darwin modules. Use one fresh absolute cache for each extension build.
with tempfile.TemporaryDirectory(prefix='finder-build-',dir=BUILD) as finder_cache:
 run(['xcrun','swiftc','-O','-swift-version','5','-target','arm64-apple-macos15.0','-module-name','FreeMouseFinder','-module-cache-path',finder_cache,'-application-extension','-parse-as-library','-Xlinker','-e','-Xlinker','_NSExtensionMain',ROOT/'FinderExtension/FinderExtension.swift',ROOT/'Sources/FreeMouse/MenuCatalog.swift',ROOT/'Sources/FreeMouse/FinderMenuPreferences.swift',ROOT/'Sources/FreeMouse/FinderMenuBuilder.swift','-o',extension/'Contents/MacOS/FreeMouseFinder'])
extension_plist={'CFBundleName':'OmniDesk Finder','CFBundleDisplayName':'OmniDesk Finder','CFBundleIdentifier':'local.freemouse.toolbox.finder','CFBundleVersion':'33','CFBundleShortVersionString':'1.1.31','CFBundlePackageType':'XPC!','CFBundleExecutable':'FreeMouseFinder','LSMinimumSystemVersion':'15.0','NSExtension':{'NSExtensionPointIdentifier':'com.apple.FinderSync','NSExtensionPrincipalClass':'FinderExtension'}}
with (extension/'Contents/Info.plist').open('wb') as f: plistlib.dump(extension_plist,f)
entitlements=BUILD/'finder-entitlements.plist'
with entitlements.open('wb') as f: plistlib.dump({'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-only':True,'com.apple.security.temporary-exception.shared-preference.read-only':['local.freemouse.toolbox.finder-menu']},f)
run(['codesign','--force','--sign','-','--entitlements',entitlements,extension])
run(['codesign','--force','--sign','-','--identifier','local.freemouse.toolbox',APP])
run(['codesign','--verify','--deep','--strict','--verbose=2',APP])
for info_path in [contents/'Info.plist', extension/'Contents/Info.plist']:
 info=plistlib.loads(info_path.read_bytes())
 assert info['CFBundleShortVersionString']=='1.1.31' and info['CFBundleVersion']=='33'
actual=plistlib.loads((contents/'Info.plist').read_bytes())
assert actual['LSUIElement'] is True and actual['NSCameraUsageDescription']
print('PASS: 1.1.31 build 33, system translation and configurable menu shortcuts')
print(APP)

