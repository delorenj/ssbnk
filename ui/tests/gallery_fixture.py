from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import json
import sys


dist = Path(sys.argv[1]).resolve()
port = int(sys.argv[2])


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(dist), **kwargs)

    def do_GET(self):
        if self.path.startswith('/api/screenshots?'):
            offset = int(parse_qs(urlparse(self.path).query).get('offset', ['0'])[0])
            items = [dict(filename=f'shot-{i:02}.svg', url=f'/shot-{i:02}.svg',
                          timestamp='2026-11-18T12:00:00Z', size=123) for i in range(49)]
            items[2]['url'] = items[0]['url']
            payload = dict(screenshots=items[offset:offset + 48], total=49, limit=48, offset=offset)
            self.respond(json.dumps(payload).encode(), 'application/json')
        elif self.path.startswith('/shot-'):
            self.respond(b'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="60"/>', 'image/svg+xml')
        else:
            super().do_GET()

    def respond(self, body, content_type):
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
