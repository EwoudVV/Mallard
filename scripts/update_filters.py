#!/usr/bin/env python3
"""Refresh the bundled blocking data from its upstream maintainers."""
from pathlib import Path
import concurrent.futures
import hashlib
import json
import os
import re
import urllib.request
from datetime import datetime, timezone

ROOT=Path(__file__).resolve().parents[1]
DEST=ROOT/'Resources/blocking'
SOURCES={
    'resources.json':'https://raw.githubusercontent.com/brave/adblock-rust/master/data/brave/brave-resources.json',
    'resources-brave.json':'https://raw.githubusercontent.com/brave/adblock-resources/master/dist/resources.json',
}
for name in ['filters','filters-general','filters-2020','filters-2021','filters-2022','filters-2023','filters-2024','filters-2025','filters-2026','quick-fixes','unbreak']:
    SOURCES['ublock-'+name+'.txt']='https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/'+name+'.txt'

def download(item):
    name,url=item
    with urllib.request.urlopen(url,timeout=60) as response:
        data=response.read(12_000_001)
    if len(data)>12_000_000 or data.lstrip().startswith(b'<'):
        raise ValueError('Unexpected filter payload: '+name)
    if name.endswith('.json'):
        if not isinstance(json.loads(data),list): raise ValueError('Invalid resource collection')
    else:
        data.decode('utf-8')
    return name,url,data

if __name__=='__main__':
    for template in ['easylist.template','easyprivacy.template']:
        with urllib.request.urlopen('https://raw.githubusercontent.com/easylist/easylist/master/'+template) as response:
            content=response.read().decode()
        for path in re.findall(r'%include easylist:([a-zA-Z0-9_/-]+\.txt)%',content):
            if '/' in path:
                SOURCES[path.replace('/','_')]='https://raw.githubusercontent.com/easylist/easylist/master/'+path
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        downloads=list(pool.map(download,SOURCES.items()))
    DEST.mkdir(parents=True,exist_ok=True)
    manifest={'updated':datetime.now(timezone.utc).isoformat(),'sources':[]}
    for name,url,data in downloads:
        target=DEST/name
        temporary=target.with_suffix(target.suffix+'.pending')
        temporary.write_bytes(data); os.replace(temporary,target)
        manifest['sources'].append({'file':name,'url':url,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)})
        print(name,len(data),'bytes')
    (DEST/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
