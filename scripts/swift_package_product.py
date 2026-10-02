"""為資料匯出工具建置並解析目前 SwiftPM 產物，不依賴固定架構或舊快取。"""
from pathlib import Path
import subprocess


def build_product(package, scratch, module, configuration='release'):
    command = ['swift', 'build', '--package-path', str(package),
               '--scratch-path', str(scratch), '-c', configuration]
    subprocess.run(command, check=True)
    products = subprocess.check_output(command + ['--show-bin-path'], text=True).strip()
    resolver = Path(__file__).with_name('swift-package-product.sh')
    result = subprocess.check_output(['bash', str(resolver), products, module])
    modules, *objects = [part.decode('utf-8') for part in result.rstrip(b'\0').split(b'\0')]
    return modules, objects
