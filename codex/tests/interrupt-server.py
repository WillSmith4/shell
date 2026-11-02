import http.server
import pathlib
import sys
import threading

root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        (root / 'ready').write_text('request received')
        threading.Event().wait(75)
    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'home' / 'config.toml').write_text(f'''model = "fixture"
model_provider = "fixture"
[model_providers.fixture]
name = "local interruption fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
''')
(root / 'server-ready').write_text(str(server.server_port))
server.serve_forever()
