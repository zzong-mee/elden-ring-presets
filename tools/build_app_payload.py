#!/usr/bin/env python3
"""Build our own entry-point payload; does not contain the user's EXE/runtime."""
import base64
import hashlib
import json
import marshal
from pathlib import Path
import sys
import textwrap
import zlib


def prepare(root, output):
    if sys.version_info[:2]!=(3,13):
        raise RuntimeError('Python 3.13 is required for the user-supplied runtime')
    modules={}
    for name,path in [('app.model','app/model.py'),('tools.diagnose_1171','tools/diagnose_1171.py'),
                      ('app.windows','app/windows.py'),('app.main','app/main.py')]:
        modules[name]=(path,(root/path).read_text(encoding='utf-8'))
    source='''import marshal, sys, types, traceback, pathlib
for package in ('app', 'tools'):
    module = types.ModuleType(package)
    module.__path__ = []
    module.__package__ = package
    sys.modules[package] = module
try:
    modules = MODULE_BYTES
    for name, (filename, source) in modules.items():
        module = types.ModuleType(name)
        module.__package__ = name.rpartition('.')[0]
        module.__file__ = filename
        sys.modules[name] = module
        exec(compile(source, filename, 'exec'), module.__dict__)
    sys.modules['app.main'].main()
except Exception:
    error = traceback.format_exc()
    try:
        import os
        target = pathlib.Path(os.environ.get('LOCALAPPDATA',str(pathlib.Path.home()))) / 'EldenRingPresets'
        target.mkdir(parents=True,exist_ok=True)
        (target / 'startup-error.txt').write_text(error,encoding='utf-8')
        from tkinter import messagebox
        messagebox.showerror('Elden Ring Presets', 'Startup failed. Log: ' + str(target / 'startup-error.txt'))
    finally:
        raise
'''.replace('MODULE_BYTES',repr(modules))
    raw=marshal.dumps(compile(source,'eldenring_presets_entry.py','exec'))
    packed=zlib.compress(raw,9)
    result=dict(schema=1,python_version=313,raw_size=len(raw),
                compressed_sha256=hashlib.sha256(packed).hexdigest(),
                original_sha256='31a132aceee81a1e2b71fc4ba1d149e074844b36a7c9d029fd1f1d10813727f1',
                payload=base64.b64encode(packed).decode('ascii'),
                source_sha256={path:hashlib.sha256((root/path).read_bytes()).hexdigest() for path in
                               ['app/model.py','app/windows.py','app/main.py','tools/diagnose_1171.py']})
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    template=(root/'tools/install-from-original.ps1').read_text(encoding='utf-8')
    start=template.index('if (-not $PayloadFile) {')
    end=template.index('if ($payload.schema',start)
    metadata=dict(result); metadata['payload']=''
    rows='\n'.join("        '"+result['payload'][i:i+120]+"'" for i in range(0,len(result['payload']),120))
    embedded=("if ($PayloadFile) {\n    $payload = Get-Content -LiteralPath $PayloadFile -Raw | ConvertFrom-Json\n} else {\n    $payload = ConvertFrom-Json -InputObject '"+
              json.dumps(metadata,separators=(',',':'))+"'\n    $payload.payload = @(\n"+rows+"\n    ) -join ''\n}\n")
    standalone='& {\n'+template[:start]+embedded+template[end:]+'\n}\n'
    (output.parent/'Install-EldenRingPresets.ps1').write_text(standalone,encoding='utf-8')
    print('Own-code payload:',len(packed),'bytes; no original EXE or runtime included')
    return source

if __name__=='__main__':
    root=Path(__file__).resolve().parents[1]
    source=prepare(root,root/'release/app-payload.json')
    (root/'build/app-entry.py').write_text(source,encoding='utf-8')
