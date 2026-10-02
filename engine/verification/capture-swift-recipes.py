#!/usr/bin/env python3
"""從移植前保留的 Swift 引擎擷取配方金樣本；不可用 Go 產物更新參考答案。"""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('reference_engine', type=Path, help='仍提供 catalog/editRecipe/projectRecipes/normalizeRecipe 的舊引擎')
args = parser.parse_args()
worker = args.reference_engine.resolve()

def call(method, payload):
    request = {'version': 1, 'id': 'fixture', 'method': method, 'payload': payload}
    result = subprocess.run([str(worker)], input=json.dumps(request), text=True, capture_output=True, timeout=15)
    lines = [json.loads(line) for line in result.stdout.splitlines()]
    assert lines and lines[-1]['kind'] in ('result', 'error'), result.stderr
    reply = lines[-1]
    assert (result.returncode == 0) == (reply['kind'] == 'result')
    return {'valid': reply['kind'] == 'result', 'value': reply['payload']}

catalog = call('catalog', None)['value']
recipes = {entry['id']: {'version': 1, 'style': entry['id'], 'adjustment': entry['adjustment'], 'repairPatches': [], 'detectSubject': False} for entry in catalog['styles']}
cases = []
def record(name, method, payload):
    expected = call(method, payload)
    cases.append({'name': name, 'method': method, 'input': payload, **expected})
    return expected

for style, recipe in recipes.items():
    record('預設/'+style, 'normalizeRecipe', recipe)
    record('投影/'+style, 'projectRecipes', {style: recipe})

editor = json.loads((root/'desktop/internal/recipes/editor.json').read_text())
base = recipes['filmPortra400']
for key, rule in editor['properties'].items():
    if rule['type'] == 'number':
        low, high = rule['minimum'], rule['maximum']
        values = [low, high, low+(high-low)*.375, low-1, high+1, '1', True, None]
    elif rule['type'] == 'boolean': values = [False, True, 1, 'true', None]
    else: values = rule['enum'] + ['未知值', 1, None]
    for i, value in enumerate(values):
        result = record(f'編輯/{key}/{i}', 'editRecipe', {'recipe': base, 'changes': [{'key': key, 'value': value}]})
        if result['valid']:
            record(f'編輯投影/{key}/{i}', 'projectRecipes', {'filmPortra400': result['value']})

groups = [
    [{'key': 'printExposureHighlights', 'value': 14}, {'key': 'printExposureMidtones', 'value': -5}, {'key': 'printExposure', 'value': 15}],
    [{'key': 'printExposureShadows', 'value': -14}, {'key': 'printExposure', 'value': -15}],
    [{'key': 'paperWhite', 'value': 90}, {'key': 'printRecipe', 'value': 'warmFiber'}, {'key': 'paperProfile', 'value': 'matte'}],
    [{'key': 'vignette', 'value': 40}, {'key': 'printExposure', 'value': 1}, {'key': 'devignette', 'value': 60}],
    [{'cropValues': {'cropAspectRatio': 'oneOne', 'cropRotation': -18.5, 'cropWidth': 55}}],
    [{'key': 'shadowPlanContrast', 'value': -12.5}, {'key': 'hdrAmount', 'value': 25}, {'key': 'hdrAmount', 'value': 0}],
    [{'cropValues': {}}], [{'cropValues': {'exposure': 1}}], [], [None], [{'key': 'unknown', 'value': 1}],
]
for i, changes in enumerate(groups): record(f'群組/{i}', 'editRecipe', {'recipe': base, 'changes': changes})
for style in recipes:
    record('印相/'+style, 'editRecipe', {'recipe': recipes[style], 'changes': [{'key': 'printRecipe', 'value': 'matte'}]})

minimal = {'intensity': 50, 'brightness': 50, 'frameEnabled': False, 'frameStyle': 'whitePaper', 'dateEnabled': False, 'dateStyle': 'numeric'}
for style in recipes:
    for version in range(1, 13):
        recipe = copy.deepcopy(recipes[style])
        recipe['adjustment'] = {**minimal, 'schemaVersion': version, 'grain': 31, 'hdrEnabled': True,
            'filmEffects': {'print_exposure': 3, 'grain_mode': 'legacy', 'color_model': 'analytic', 'developer_chemistry': {'contrast': 1.1}}}
        record(f'遷移/{style}/v{version}', 'normalizeRecipe', recipe)

changes = [
    {'schemaVersion': None}, {'schemaVersion': 0}, {'schemaVersion': 13}, {'schemaVersion': 1.5}, {'schemaVersion': '12'},
    {'unknown': 1}, {'brightness': None}, {'intensity': '50'}, {'frameStyle': 'unknown'}, {'dateStyle': 'unknown'},
    {'exposure': 150, 'contrast': -300, 'vignette': 20, 'devignette': 60, 'cropScale': 500},
    {'filmEffects': {'print_exposure_highlights': None}}, {'filmEffects': {'developer_chemistry': {'contrast': 20}, 'scan_exposure': 500, 'deep_shadow_amount': 55}},
    {'filmEffects': {'grain_mode': 'crystal'}}, {'filmEffects': {'grain_mode': 'unknown'}}, {'filmEffects': None},
    {'sourceToneZones': {'shadows': {'base_tone': '-12.5', 'fade': 200, 'tint': False}, 'highlights': 'invalid'}},
    {'sourceToneZones': {'shadows': {'unknown': 4}}}, {'sourceToneZones': None},
    {'hdrToneCurve': {'black': 50, 'shadows': 'bad', 'midtones': '75.5', 'white': 3, 'detail': 70}},
    {'hdrToneCurve': None}, {'hdrToneCurve': {'unknown': 0}},
    {'colorCalibration': {'version': 1, 'name': '測試校準', 'provenance': '既存校準樣本', 'workingSpace': 'extendedLinearSRGB', 'stage': 'input', 'rows': [[1,0,0,0,0,0],[0,1,0,0,0,0],[0,0,1,0,0,0]]}},
    {'colorCalibration': {'version': 1, 'name': '', 'provenance': '測試', 'workingSpace': 'extendedLinearSRGB', 'stage': 'output', 'rows': []}},
]
for i, patch in enumerate(changes):
    recipe = copy.deepcopy(base)
    recipe['adjustment'].update(patch)
    record(f'正規化邊界/{i}', 'normalizeRecipe', recipe)
    record(f'嚴格投影邊界/{i}', 'projectRecipes', {'filmPortra400': recipe})

report = {'source': '移植前 Swift 引擎 1.26.0924 build 1107', 'referenceSHA256': hashlib.sha256(worker.read_bytes()).hexdigest(), 'catalog': catalog, 'cases': cases}
destination = root/'desktop/internal/recipes/testdata/swift-reference.json.gz'
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes(gzip.compress(json.dumps(report, ensure_ascii=False).encode(), mtime=0))
print(json.dumps({'cases': len(cases), 'fixture': str(destination)}, ensure_ascii=False))
