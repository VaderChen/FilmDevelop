"""只精簡封裝副本的 DWARF；保留已簽署 Runtime 及所有載入區段。"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from windows_payload import PE


def sections(pe):
    symbols, count = pe.unpack('<II', pe.header + 12)
    strings = symbols + 18 * count
    table = pe.optional + pe.u16(pe.header + 20)
    result = []
    for index in range(pe.u16(pe.header + 6)):
        offset = table + index * 40
        name = pe.data[offset:offset + 8].split(b'\0', 1)[0]
        if name.startswith(b'/'):
            start = strings + int(name[1:])
            end = pe.data.find(b'\0', start)
            if start < 0 or end < start:
                raise ValueError('PE 區段名稱損壞')
            name = pe.data[start:end]
        name = name.decode('ascii')
        size, rva, raw_size, raw = pe.unpack('<IIII', offset + 8)
        flags = pe.u32(offset + 36)
        result.append((name, rva, size, flags, pe.data[raw:raw + raw_size] if raw else b''))
    return result


def debug(name):
    return name.startswith(('.debug_', '.zdebug_'))


def execution_signature(pe):
    # 比較所有非 DWARF 區段的載入位置、尺寸、旗標與原始位元。
    loaded = [(name, rva, size, flags, hashlib.sha256(data).hexdigest())
              for name, rva, size, flags, data in sections(pe) if not debug(name)]
    return (pe.machine, pe.image_base, pe.subsystem, pe.u32(pe.optional + 16),
            loaded, pe.imports(), pe.exports())


def strip_payload(folder):
    report = []
    tool = shutil.which('x86_64-w64-mingw32-strip')
    for path in sorted(Path(folder).rglob('*')):
        if not path.is_file() or path.suffix.lower() not in ('.exe', '.dll'):
            continue
        original = PE(path)
        names = [s[0] for s in sections(original) if debug(s[0])]
        if not names:
            continue
        if original.directory(4) != (0, 0):
            # Authenticode 簽章檔完全不改寫。
            continue
        if any(debug(name) and (flags & 0xA0000000 or not flags & 0x02000000)
               for name, _, _, flags, _ in sections(original)):
            raise ValueError(f'除錯區段被標示為載入內容：{path.name}')
        if not tool:
            raise ValueError('缺少 x86_64-w64-mingw32-strip，無法精簡 Windows 正式成品')
        before = execution_signature(original)
        with tempfile.TemporaryDirectory(prefix='.strip-', dir=path.parent) as temporary:
            target = Path(temporary) / path.name
            shutil.copy2(path, target)
            subprocess.run([tool, '--strip-debug', str(target)], check=True)
            stripped = PE(target)
            if execution_signature(stripped) != before or any(debug(s[0]) for s in sections(stripped)):
                raise ValueError(f'移除除錯資料後執行內容不一致：{path.name}')
            if len(stripped.data) >= len(original.data):
                raise ValueError(f'除錯資料未縮減：{path.name}')
            report.append(dict(path=path.relative_to(folder).as_posix(),
                               bytesBefore=len(original.data), bytesAfter=len(stripped.data),
                               loadedSectionsIdentical=True, importsExportsIdentical=True,
                               removedSections=names))
            os.replace(target, path)
    return {'mode': 'strip-debug', 'signedFilesUnmodified': True, 'files': report,
            'bytesSaved': sum(r['bytesBefore'] - r['bytesAfter'] for r in report)}
