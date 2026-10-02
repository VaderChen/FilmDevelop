#!/usr/bin/env python3
"""同步 Swift 配方模型與 Go 靜態目錄；不從 Go 重寫既有 Swift 金樣本。"""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
build = ROOT / 'build/swift-catalog'
build.mkdir(parents=True, exist_ok=True)
source = build / 'Export.swift'
source.write_text('''import Foundation
import PhotoStyleShared
@main enum Export {
 static func main() throws {
  let styles = try PhotoStyle.allCases.map { style -> [String:Any] in
   let adjustment = StyleAdjustment.default(for:style)
   return ["id":style.rawValue, "mergedInto":style.mergedInto?.rawValue ?? "",
    "isHiddenFromCatalog":style.isHiddenFromCatalog,
    "title":style.title, "subtitle":style.subtitle, "isMonochrome":style.isMonochrome,
    "isOriginal":style == .original, "supportsScanner":style.filmStock != nil || style == .original,
    "isFilmStock":style.isLibraryLook, "filmFamily":style.libraryFamily,
    "filmFamilyTitle":style.libraryFamilyTitle,
    "filmAlgorithm":style.libraryAlgorithm,
    "adjustment":try JSONSerialization.jsonObject(with:JSONEncoder().encode(adjustment)),
    "promptData":["prompts":style.llmDescriptions,"guidance":style.llmParameterGuidance,
                  "strength":[style.llmStrengthRange.lowerBound,style.llmStrengthRange.upperBound]]]
  }
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:styles,options:[.sortedKeys]))
 }
}
''')
products = ROOT / 'build/engine-macos/shared/arm64-apple-macosx/release'
subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-I',str(products/'Modules'),
    str(ROOT/'PhotoStyleApp/PhotoStyle.swift'),str(ROOT/'PhotoStyleApp/Comparable+Clamped.swift'),
    str(ROOT/'PhotoStyleApp/PhotoStylePromptCatalog.swift'),str(source),
    *map(str,(products/'PhotoStyleShared.build').glob('*.o')),'-o',str(build/'export')],check=True)
reference = json.loads(subprocess.check_output([str(build/'export')]))
(build/'reference.json').write_text(json.dumps(reference,ensure_ascii=False,indent=2)+'\n')
catalog_path = ROOT/'desktop/internal/recipes/catalog.json'
prompts_path = ROOT/'desktop/internal/application/prompts.json'
migration_path = ROOT/'desktop/internal/recipes/migration.json'
catalog = json.loads(catalog_path.read_text())
prompts = json.loads(prompts_path.read_text())
migration = json.loads(migration_path.read_text())
old = {style['id']:style for style in catalog['styles']}
styles = []
for raw in reference:
    style = dict(raw)
    prompt = style.pop('promptData')
    # 省略預設 false，維持移植前的金樣本形狀；隱藏項目仍完整保存。
    if not style['isHiddenFromCatalog']:
        del style['isHiddenFromCatalog']
    styles.append(style)
    prompts['styles'][style['id']] = prompt
    chemistry = style['adjustment']['filmEffects']['developer_chemistry']
    migration['developerDefaults'][style['id']] = chemistry
    if style['id'] not in old:
        fixture = ROOT/'desktop/internal/recipes/testdata'/f"swift-{style['id']}.json"
        if not args.check:
            fixture.write_text(json.dumps(style,ensure_ascii=False,indent=2)+'\n')
catalog['styles'] = styles
for path, value in [(catalog_path,catalog),(prompts_path,prompts),(migration_path,migration)]:
    if args.check:
        assert json.loads(path.read_text()) == value, f'靜態資料與 Swift 不一致：{path.name}'
    else:
        path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
print(f'Swift／Go 目錄同步完成：{len(styles)} 個識別（包含隱藏相容配方）')
