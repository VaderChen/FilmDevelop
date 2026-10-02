"""直接讀取 PE 結構，檢查 Windows 封裝的架構、資源與 DLL 相依。"""
from pathlib import Path
import json
import struct
import xml.etree.ElementTree as ET


SYSTEM_DLLS = set('''kernel32.dll kernelbase.dll ntdll.dll user32.dll gdi32.dll
advapi32.dll ole32.dll oleaut32.dll shell32.dll shlwapi.dll version.dll bcrypt.dll
crypt32.dll secur32.dll ws2_32.dll iphlpapi.dll winmm.dll winhttp.dll wininet.dll
userenv.dll ucrtbase.dll msvcrt.dll setupapi.dll comdlg32.dll comctl32.dll dwmapi.dll
dxgi.dll d3d11.dll d3d12.dll propsys.dll rpcrt4.dll wtsapi32.dll imm32.dll
opengl32.dll usp10.dll powrprof.dll shcore.dll windowscodecs.dll dbghelp.dll'''.split())

# 驅動相依與系統 DLL 分開記錄；僅已知的 GPU 模組可使用此例外。
DRIVER_DEPENDENCIES = {'engine/libphotocompute.dll': {'vulkan-1.dll'},
                       'engine/ggml-vulkan.dll': {'vulkan-1.dll'}}
VC_RUNTIME_DLLS = {'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'msvcp140_1.dll'}


class PE:
    def __init__(self, path):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        if self.data[:2] != b'MZ':
            raise ValueError(f'不是 Windows PE：{path}')
        self.header = self.u32(60)
        if self.data[self.header:self.header + 4] != b'PE\0\0':
            raise ValueError(f'PE 標頭無效：{path}')
        self.machine = self.u16(self.header + 4)
        self.optional = self.header + 24
        self.magic = self.u16(self.optional)
        if self.magic not in (0x10b, 0x20b):
            raise ValueError(f'不支援的 PE 格式：{path}')
        self.directories = self.optional + (112 if self.magic == 0x20b else 96)
        self.image_base = self.unpack('<Q' if self.magic == 0x20b else '<I',
                                      self.optional + (24 if self.magic == 0x20b else 28))[0]
        self.subsystem = self.u16(self.optional + 68)
        self.sections = []
        table = self.optional + self.u16(self.header + 20)
        for index in range(self.u16(self.header + 6)):
            size, base, raw_size, raw = self.unpack('<IIII', table + index * 40 + 8)
            self.sections.append((base, size, raw_size, raw))

    def unpack(self, format_, offset):
        if offset < 0 or offset + struct.calcsize(format_) > len(self.data):
            raise ValueError(f'PE 資料截斷：{self.path}')
        return struct.unpack_from(format_, self.data, offset)

    def u16(self, offset):
        return self.unpack('<H', offset)[0]

    def u32(self, offset):
        return self.unpack('<I', offset)[0]

    def offset(self, rva):
        # Go 的壓縮偵錯區段可能宣告較大的 VirtualSize；從最高 RVA 找實際原始區段。
        for base, _, size, raw in sorted(self.sections, reverse=True):
            if base <= rva < base + size and raw + rva - base < len(self.data):
                return raw + rva - base
        if 0 <= rva < self.u32(self.optional + 60):
            return rva
        raise ValueError(f'PE 位址無法解析：{self.path}: {rva:#x}')

    def directory(self, index):
        count = self.u32(self.directories - 4)
        if index >= count:
            return 0, 0
        return self.unpack('<II', self.directories + 8 * index)

    def string(self, rva):
        at = self.offset(rva)
        end = self.data.find(b'\0', at, at + 512)
        if end < 0:
            raise ValueError(f'PE 字串無效：{self.path}')
        return self.data[at:end].decode('ascii')

    def imports(self):
        result = set()
        for directory, stride, name_offset in ((1, 20, 12), (13, 32, 4)):
            rva, size = self.directory(directory)
            if not rva:
                continue
            at = self.offset(rva)
            for index in range(min(size // stride, 4096)):
                entry = at + index * stride
                if not any(self.data[entry:entry + stride]):
                    break
                name = self.u32(entry + name_offset)
                if directory == 13 and not self.u32(entry) & 1:
                    name -= self.image_base
                result.add(self.string(name).lower())
            else:
                raise ValueError(f'PE 匯入表沒有結束標記：{self.path}')
        return sorted(result)

    def exports(self):
        rva, _ = self.directory(0)
        if not rva:
            return []
        table = self.offset(rva)
        count = self.u32(table + 24)
        if count > 100000:
            raise ValueError(f'PE 匯出數量異常：{self.path}')
        names = self.offset(self.u32(table + 32))
        return sorted(self.string(self.u32(names + 4 * i)) for i in range(count))

    def resources(self, type_id):
        rva, size = self.directory(2)
        if not rva:
            return []
        base = self.offset(rva)
        result = []

        def walk(relative, depth):
            if depth > 3 or relative + 16 > size:
                raise ValueError(f'PE 資源目錄無效：{self.path}')
            at = base + relative
            count = self.u16(at + 12) + self.u16(at + 14)
            if relative + 16 + count * 8 > size:
                raise ValueError(f'PE 資源項目超出範圍：{self.path}')
            for i in range(count):
                identifier, address = self.unpack('<II', at + 16 + i * 8)
                if depth == 0 and identifier != type_id:
                    continue
                if address & 0x80000000:
                    walk(address & 0x7fffffff, depth + 1)
                else:
                    if address + 16 > size:
                        raise ValueError(f'PE 資源資料無效：{self.path}')
                    data_rva, data_size = self.unpack('<II', base + address)
                    start = self.offset(data_rva)
                    blob = self.data[start:start + data_size]
                    if len(blob) != data_size:
                        raise ValueError(f'PE 資源截斷：{self.path}')
                    result.append(blob)
        walk(0, 0)
        return result

    def version(self):
        resources = self.resources(16)
        if len(resources) != 1:
            raise ValueError(f'缺少唯一的 Windows 版本資源：{self.path}')
        data = resources[0]
        key = 'VS_VERSION_INFO\0'.encode('utf-16le')
        if data[6:6 + len(key)] != key:
            raise ValueError(f'Windows 版本資源格式錯誤：{self.path}')
        offset = (6 + len(key) + 3) & ~3
        fixed = struct.unpack_from('<13I', data, offset)
        if fixed[0] != 0xfeef04bd:
            raise ValueError(f'Windows 固定版本資訊無效：{self.path}')
        version = '.'.join(map(str, (fixed[2] >> 16, fixed[2] & 65535,
                                    fixed[3] >> 16, fixed[3] & 65535)))
        return version, fixed[7], data


def validate_gui(path, info, expected_manifest=None):
    pe = PE(path)
    if pe.machine != 0x8664 or pe.magic != 0x20b or pe.subsystem != 2:
        raise ValueError('桌面主程式必須是 Windows x64 GUI')
    version, flags, strings = pe.version()
    if version != info['numericVersion'] or flags != 0:
        raise ValueError('桌面程式版本或旗標不符；請重新建置')
    if info['displayVersion'].encode('utf-16le') not in strings or '開發版'.encode('utf-16le') in strings:
        raise ValueError('桌面程式顯示版本不符；請重新建置')
    if not pe.resources(3) or not pe.resources(14):
        raise ValueError('桌面程式缺少圖示資源')
    manifests = pe.resources(24)
    if len(manifests) != 1:
        raise ValueError('桌面程式缺少唯一的 Windows Manifest')
    manifest = manifests[0].rstrip(b'\0')
    if expected_manifest is not None and manifest != Path(expected_manifest).read_bytes():
        raise ValueError('桌面程式內嵌 Manifest 與建置資料不同')
    xml = ET.fromstring(manifest)
    level = xml.find('.//{urn:schemas-microsoft-com:asm.v3}requestedExecutionLevel')
    if level is None or level.get('level') != 'asInvoker':
        raise ValueError('桌面程式不應要求系統管理員權限')
    return {'numericVersion': version, 'iconVerified': True, 'manifestVerified': True,
            'requiresAdministrator': False}


def validate_payload(folder):
    folder = Path(folder)
    files = {}
    for path in sorted(folder.rglob('*')):
        if path.is_symlink():
            raise ValueError(f'安裝內容不可包含符號連結：{path}')
        if not path.is_file():
            continue
        relative = path.relative_to(folder).as_posix()
        if relative.casefold() in files:
            raise ValueError(f'Windows 檔名大小寫衝突：{relative}')
        files[relative.casefold()] = path
    prerequisites = folder / 'Prerequisites/prerequisites.json'
    runtime_available = False
    if prerequisites.is_file():
        config = json.loads(prerequisites.read_text())
        runtime = config.get('visualCppX64', {})
        runtime_available = (config.get('schema') == 1 and runtime.get('minimumVersion') == '14.44.35211.0'
                             and set(runtime.get('dlls', [])) == VC_RUNTIME_DLLS
                             and runtime.get('sha256') == '843068991daaa1f73ad9f6239bce4d0f6a07a51f18c37ea2a867e9beca71295c'
                             and (folder / 'Prerequisites/ensure-prerequisites.ps1').is_file())
        if not runtime_available:
            raise ValueError('Microsoft 執行環境的安裝前置條件不完整')
    result = []
    for key, path in files.items():
        if path.suffix.lower() not in ('.exe', '.dll'):
            continue
        pe = PE(path)
        if pe.machine != 0x8664 or pe.magic != 0x20b:
            raise ValueError(f'安裝內容混入非 x64 程式：{path.name}')
        imports = pe.imports()
        resolved = {}
        for name in imports:
            if name in SYSTEM_DLLS or name.startswith(('api-ms-win-', 'ext-ms-win-')):
                resolved[name] = 'windows'
            elif name in DRIVER_DEPENDENCIES.get(key, set()):
                resolved[name] = 'gpu-driver'
            elif name in VC_RUNTIME_DLLS and runtime_available:
                resolved[name] = 'prerequisite:Microsoft-Visual-C++-x64-14.44.35211.0'
            else:
                dependency = (path.parent / name).relative_to(folder).as_posix().casefold()
                if dependency not in files:
                    raise ValueError(f'安裝內容缺少 DLL：{path.name} → {name}')
                resolved[name] = dependency
        item = {'file': path.relative_to(folder).as_posix(), 'architecture': 'x64',
                'imports': resolved}
        if key == 'engine/libphotocompute.dll':
            expected = {'photo_compute_abi', 'photo_compute_create', 'photo_compute_destroy',
                        'photo_compute_process', 'photo_compute_transfers', 'photo_compute_device_info', 'photo_compute_process_inputs'}
            if set(pe.exports()) != expected:
                raise ValueError('PhotoCompute DLL 匯出與 ABI 2 不符')
            item['exports'] = pe.exports()
        result.append(item)
    if not result:
        raise ValueError('安裝內容沒有 Windows 執行檔')
    return result
