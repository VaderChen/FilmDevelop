#!/usr/bin/env python3
"""跨平台檔案／命令列 Smoke；可選擇與真實照片的 Swift PFM 參考比對。"""
import argparse
import array
import pathlib
import subprocess
import sys
import tempfile


def pixels(path):
    with path.open('rb') as stream:
        assert stream.readline() == b'PF\n'
        dims = tuple(map(int, stream.readline().split()))
        assert float(stream.readline()) == -1.0
        values = array.array('f', stream.read())
        if sys.byteorder != 'little':
            values.byteswap()
        assert len(values) == dims[0] * dims[1] * 3
        return dims, values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('executable', type=pathlib.Path)
    parser.add_argument('--input', type=pathlib.Path)
    parser.add_argument('--reference', type=pathlib.Path)
    args = parser.parse_args()
    assert bool(args.input) == bool(args.reference)
    executable = str(args.executable.resolve())
    with tempfile.TemporaryDirectory(prefix='photocore-smoke-') as folder:
        root = pathlib.Path(folder)
        source, output, preview = (root / name for name in ('source.pfm', 'out.pfm', 'view.ppm'))
        subprocess.run([executable, '--generate', '--output', str(source)], check=True)
        subprocess.run([executable, '--input', str(source), '--output', str(output), '--ev', '1'], check=True)
        dim, a = pixels(source)
        other, b = pixels(output)
        assert dim == other and all(y == x * 2 for x, y in zip(a, b))
        subprocess.run([executable, '--input', str(source), '--output', str(output), '--ev', '1',
                        '--protect-peak', '--raw-map', '--preview', str(preview)], check=True)
        assert preview.read_bytes().startswith(b'P6\n768 256\n255\n')
        before = source.read_bytes()
        invalid = subprocess.run([executable, '--input', str(source), '--output', str(source)], capture_output=True)
        assert invalid.returncode != 0 and source.read_bytes() == before
        for extra in [['--ev', 'nan'], ['--zones', '1'], ['--strength', 'no']]:
            invalid = subprocess.run([executable, '--generate', '--output', str(output), *extra], capture_output=True)
            assert invalid.returncode != 0
        if args.input:
            subprocess.run([executable, '--input', str(args.input), '--output', str(output), '--ev', '0.7'], check=True)
            dims, expected = pixels(args.reference)
            actual_dims, actual = pixels(output)
            assert dims == actual_dims
            error = max(abs(x-y) / max(1, abs(y)) for x, y in zip(actual, expected))
            assert error <= 3e-5, error
            print(f'PASS：實際照片比對 {len(actual)} 色彩分量，最大正規化誤差 {error:.9g}')
        print('PASS：命令列曝光、影像往返、預覽、非法參數及來源保護')


if __name__ == '__main__':
    main()
