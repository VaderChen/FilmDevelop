#!/usr/bin/env python3
"""從唯一契約產生 Go／Swift／C++ 型別；--check 用於偵測產物漂移。"""
import argparse
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[2]
spec = json.loads((root / "engine/contract/protocol.json").read_text())
types = spec["types"]

def field_type(t, language):
    optional = t.endswith("?")
    t = t.removesuffix("?")
    names = {
        "go": {"string": "string", "int": "int", "double": "float64", "bool": "bool", "json": "json.RawMessage"},
        "swift": {"string": "String", "int": "Int", "double": "Double", "bool": "Bool", "json": "JSONValue"},
        "cpp": {"string": "std::string", "int": "int64_t", "double": "double", "bool": "bool", "json": "nlohmann::json"},
    }
    name = names[language].get(t, t)
    if optional:
        return {"go": "*" + name, "swift": name + "?", "cpp": "std::optional<" + name + ">"}[language]
    return name

go = '// 此檔由 engine/contract/generate.py 產生，請修改 protocol.json。\npackage contract\nimport "encoding/json"\n'
go += f'const Version = {spec["version"]}\nconst MaxMessageBytes = {spec["transport"]["maxMessageBytes"]}\n'
swift = '// 此檔由 engine/contract/generate.py 產生，請修改 protocol.json。\nimport Foundation\n'
swift += f'enum EngineProtocol {{ static let version = {spec["version"]}; static let maxMessageBytes = {spec["transport"]["maxMessageBytes"]} }}\n'
cpp = '// 此檔由 engine/contract/generate.py 產生，請修改 protocol.json。\n#pragma once\n#include <cstdint>\n#include <optional>\n#include <string>\n#include <limits>\n#include <stdexcept>\n#include <nlohmann/json.hpp>\nnamespace filmdevelop::contract {\n'
cpp += f'inline constexpr int version = {spec["version"]};\ninline constexpr size_t maxMessageBytes = {spec["transport"]["maxMessageBytes"]};\n'
for name, fields in types.items():
    go += f'type {name} struct {{\n'
    swift += f'struct {name}: Codable {{\n'
    cpp += f'struct {name} {{\n'
    for key, typ in fields.items():
        gkey = 'ID' if key == 'id' else key[0].upper() + key[1:]
        go += f' {gkey} {field_type(typ,"go")} `json:"{key}{",omitempty" if typ.endswith("?") else ""}"`\n'
        swift += f' var {key}: {field_type(typ,"swift")}\n'
        cpp += f' {field_type(typ,"cpp")} {key};\n'
    go += '}\n'
    swift += '}\n'
    cpp += '};\n'
    cpp += f'inline void from_json(const nlohmann::json& j, {name}& v) {{\n'
    cpp += ' if (!j.is_object()) throw std::invalid_argument("契約需要物件");\n'
    cpp += ' for (const auto& field : j.items()) if (' + ' && '.join('field.key() != "'+k+'"' for k in fields) + ') throw std::invalid_argument("未知契約欄位：" + field.key());\n'
    for key, typ in fields.items():
        if typ == 'int':
            cpp += f' if (!j.at("{key}").is_number_integer() || (j.at("{key}").is_number_unsigned() && j.at("{key}").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：{key}");\n'
        if typ.endswith('?'):
            cpp += f' if (j.contains("{key}") && !j.at("{key}").is_null()) v.{key} = j.at("{key}").get<{field_type(typ[:-1],"cpp")}>(); else v.{key}.reset();\n'
        else:
            cpp += f' j.at("{key}").get_to(v.{key});\n'
    cpp += '}\n'
    cpp += f'inline void to_json(nlohmann::json& j, const {name}& v) {{\n j = nlohmann::json::object();\n'
    for key, typ in fields.items():
        if typ.endswith('?'):
            cpp += f' if (v.{key}) j["{key}"] = *v.{key}; else j["{key}"] = nullptr;\n'
        else: cpp += f' j["{key}"] = v.{key};\n'
    cpp += '}\n'
cpp += '}\n'
go = subprocess.run(['gofmt'], input=go, text=True, capture_output=True, check=True).stdout
outputs = {
    root / 'desktop/internal/contract/generated.go': go,
    root / 'engine/macos/Contract.generated.swift': swift,
    root / 'engine/cpp/Contract.generated.hpp': cpp,
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
for path, content in outputs.items():
    if args.check:
        if not path.exists() or path.read_text() != content:
            raise SystemExit(f'契約產物不同步：{path.relative_to(root)}')
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
print('共用契約產物檢查完成' if args.check else '已產生 Go／Swift／C++ 契約')
