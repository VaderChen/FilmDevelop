#!/usr/bin/env python3
"""對照縮減前後的真實 Mac 引擎，驗證全配方、Vulkan 與深度模型。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--before', required=True, type=Path)
parser.add_argument('--after', required=True, type=Path)
args = parser.parse_args()
out = Path(tempfile.mkdtemp(prefix='macos-resource-smoke-', dir=root/'build'))
baseline = json.loads((root/'build/engine-smoke-latest.json').read_text())
source = Path(baseline['report']).parent/'來源照片.bmp'
styles = json.loads((root/'desktop/internal/recipes/catalog.json').read_text())['styles']
cases = [(s['id']+'-'+backend, s, backend) for s in styles for backend in ('system', 'vulkan')]
depth = json.loads(json.dumps(next(s for s in styles if s['id']=='original')))
depth['adjustment']['backgroundBlur'] = 40
cases.append(('depth-model', depth, 'system'))
results = []

def render(engine, request):
    reply = subprocess.run([str(engine.resolve())], input=json.dumps(request)+'\n',
                           capture_output=True, text=True, timeout=90, check=True)
    messages = [json.loads(line) for line in reply.stdout.splitlines()]
    assert messages[-1]['kind']=='result', messages[-1]
    return messages[-1]['payload']

for name, style, backend in cases:
    outputs = []
    for label, engine in [('before', args.before), ('after', args.after)]:
        image = out/(name+'-'+label+'.png')
        job = {'input': {'path': str(source), 'rawDecoder': 'system', 'lensCorrection': True},
               'output': {'path': str(image), 'format': 'png', 'bitDepth': 16, 'colorSpace': 'sRGB',
                          'quality': .95, 'maxPixel': 0, 'webPLossless': False, 'tiffCompression': 1},
               'recipe': {'version': 1, 'style': style['id'], 'adjustment': style['adjustment'],
                          'repairPatches': [], 'detectSubject': False},
               'computeBackend': backend, 'preview': False, 'previewMaxPixel': 1024}
        render(engine, {'version': 1, 'id': name, 'method': 'render', 'payload': job})
        assert image.is_file()
        outputs.append(image)
    compared = json.loads(subprocess.check_output([str(root/'build/engine-compare-images'), *map(str, outputs)]))
    assert compared['maxError'] <= 2/65535, (name, compared)
    results.append({'case': name, 'passed': True, 'comparison': compared})

def resources(engine):
    return engine.resolve().parents[1]/'Resources'

def inventory(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.rglob('*') if p.is_file()}

before, after = resources(args.before), resources(args.after)
for folder in ('RAWMapping', 'RAWLicenses'):
    assert inventory(before/folder)==inventory(after/folder), folder
assert not (after/'PhotoCompute/film-data/digital-looks').exists()
assert not (after/'PhotoCompute/film-data/editor').exists()
assert not list((after/'Models').glob('*.mlpackage'))
assert list((after/'Models').glob('*.mlmodelc'))
report = {'passed': True, 'checks': results, 'rawResourcesUnchanged': True,
          'windowsTablesOmitted': True, 'modelSourceOmitted': True}
(out/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({'passed': True, 'checks': len(results), 'report': str(out/'report.json')}, ensure_ascii=False))
