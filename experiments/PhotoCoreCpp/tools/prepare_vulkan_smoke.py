#!/usr/bin/env python3
"""僅在建置目錄建立接線副本；沿用原始 CPU 公式，正式核心來源保持不變。"""
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
text = source.read_text()
call = 'unmix(logD + cal.middle, p, db, scanLight, cal)'
anchor = 'separated = ' + call + ';'
if text.count(anchor) != 1:
    raise RuntimeError('光譜來源已改變，必須重新確認 GPU Smoke 接線位置')
text = '#include "hook.hpp"\n' + text.replace(anchor,
    'separated = photocore::smoke::route_unmix(logD + cal.middle, p, db, scanLight, cal, [&] { return '+call+'; });')
text += '''
namespace photocore::smoke {
void benchmark_cpu_unmix(const std::vector<film_cpu::V>& input, std::vector<film_cpu::V>& output,
    const film_cpu::Profile& p, const film_cpu::Database& db,
    const std::array<double,13>& light, const film_cpu::CalibrationData& cal) {
    if (input.size() != output.size()) throw std::invalid_argument("CPU 量測緩衝區長度不符");
    for (std::size_t i=0; i<input.size(); ++i)
        output[i] = film_cpu::unmix(input[i], p, db, light, cal);
}
}
'''
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(text)
