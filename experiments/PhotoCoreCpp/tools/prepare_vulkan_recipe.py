#!/usr/bin/env python3
"""直接沿用 CPU 配方驗證，避免 GPU 另有一套寬鬆入口。"""
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
text = source.read_text()
start = '    std::ifstream file(std::filesystem::u8path(path));'
end = '    auto image = develop(std::move(source), e, strength, stage);'
if text.count(start) != 1 or text.count(end) != 1:
    raise RuntimeError('CPU 配方入口已改變，必須重新確認接線')
body = text[text.index(start):text.index(end)].replace('    const auto &db = impl_->data;\n', '')
destination.write_text('#include "pipeline.hpp"\n#include <filesystem>\n#include <fstream>\nnamespace photocore::vk {\nRecipe prepare_recipe(const std::string &path, const film_cpu::Database &db) {\nusing namespace film_cpu;\n'+body+'return {e,&p,strength};\n}\n}\n')
