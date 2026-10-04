#!/usr/bin/env python3
"""啟動獨立液化原型，僅監聽本機；不連接正式 App 或讀取其照片庫。"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import mimetypes
import webbrowser

mimetypes.add_type('text/javascript', '.mjs')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=8766, help='本機連接埠，0 表示自動選擇')
parser.add_argument('--open', action='store_true', help='啟動後以預設瀏覽器開啟')
args = parser.parse_args()
if not 0 <= args.port <= 65535:
    parser.error('連接埠須為 0..65535')
folder = Path(__file__).resolve().parent
handler = partial(SimpleHTTPRequestHandler, directory=str(folder))
with ThreadingHTTPServer(('127.0.0.1', args.port), handler) as server:
    server.daemon_threads = True
    url = 'http://127.0.0.1:%d/' % server.server_port
    print('液化原型：' + url, flush=True)
    print('照片僅在瀏覽器記憶體處理；按 Ctrl+C 關閉此原型服務。', flush=True)
    if args.open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
