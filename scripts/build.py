#!/usr/bin/env python3
"""Build and package the local Apple-silicon development app."""
from pathlib import Path
import os
import plistlib
import re
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
running=subprocess.run(['pgrep','-f','^'+re.escape(str(ROOT/'build/Mallard.app/Contents/MacOS/Mallard'))+'( |$)'],capture_output=True,text=True)
if running.returncode==0:
    raise SystemExit('Quit Mallard before rebuilding. Its open tabs will be restored when you launch it again.')
def run(*args):
    subprocess.run(args,cwd=ROOT,check=True)
run(sys.executable,'scripts/fetch_cef.py')
if not (ROOT/'Resources/blocking/manifest.json').exists():
    run(sys.executable,'scripts/update_filters.py')
run('cargo','build','--release','--locked','--manifest-path','Blocker/Cargo.toml')
run('cmake','-S','.','-B','build/native','-G','Unix Makefiles','-DCMAKE_BUILD_TYPE=Release')
run('cmake','--build','build/native','--parallel','8')
app=ROOT/'build/Mallard.app'
native=ROOT/'build/native/Mallard.app'
app.mkdir(parents=True,exist_ok=True)
shutil.copytree(native,app,dirs_exist_ok=True)
frameworks=app/'Contents/Frameworks'
frameworks.mkdir(exist_ok=True)
framework=frameworks/'Chromium Embedded Framework.framework'
if not framework.exists():
    shutil.copytree(ROOT/'.deps/cef/Release/Chromium Embedded Framework.framework',framework,symlinks=True)
for suffix in ['', ' (Alerts)', ' (GPU)', ' (Plugin)', ' (Renderer)']:
    name='Mallard Helper'+suffix
    helper=frameworks/(name+'.app')/'Contents'
    (helper/'MacOS').mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT/'build/native/MallardHelper',helper/'MacOS'/name)
    identifier='com.ewoudvv.Mallard.helper'+('' if not suffix else '.'+suffix.strip(' ()').lower())
    plist={'CFBundleExecutable':name,'CFBundleIdentifier':identifier,'CFBundleName':name,'CFBundlePackageType':'APPL','LSUIElement':True,'LSBackgroundOnly':True,'NSHighResolutionCapable':True}
    with (helper/'Info.plist').open('wb') as f: plistlib.dump(plist,f)
resources=app/'Contents/Resources'
resources.mkdir(exist_ok=True)
icon_source=ROOT/'Resources/Artwork/Mallard.png'
if icon_source.exists():
    iconset=ROOT/'build/Mallard.iconset'
    iconset.mkdir(exist_ok=True)
    for size in [16,32,128,256,512]:
        for scale in [1,2]:
            name=f'icon_{size}x{size}'+('@2x' if scale==2 else '')+'.png'
            subprocess.run(['sips','-z',str(size*scale),str(size*scale),str(icon_source),'--out',str(iconset/name)],check=True,stdout=subprocess.DEVNULL)
    run('iconutil','-c','icns',str(iconset),'-o',str(ROOT/'Resources/Mallard.icns'))
    shutil.copy2(ROOT/'Resources/Mallard.icns',resources/'Mallard.icns')
shutil.copy2(ROOT/'Resources/autofill.js',resources/'autofill.js')
for name in ['blocking','fonts','ThirdParty']:
    source=ROOT/'Resources'/name
    if source.exists(): shutil.copytree(source,resources/name,dirs_exist_ok=True)
run('codesign','--force','--deep','--sign','-',str(app))
run('codesign','--verify','--deep','--strict',str(app))
print('\nBuilt '+str(app))
