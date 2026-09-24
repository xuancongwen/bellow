"""Real cleanup executable against a loopback mock; run after swift build on macOS."""
import http.server
import json
import os
import pathlib
import subprocess
import threading
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = ROOT / '.build/release/VoxClean'

@unittest.skipUnless(BINARY.exists(), 'Requires swift build -c release on macOS')
class CleanupTests(unittest.TestCase):
    def invoke(self, reply, status=200):
        requests = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.send_response(status); self.end_headers(); self.wfile.write(reply)
            def log_message(self, *args): pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            result = subprocess.run([str(BINARY)], input='how do I restart the server', text=True, capture_output=True,
                env={**os.environ, 'BELLOW_OLLAMA': f'http://127.0.0.1:{server.server_port}'}, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(requests[0]['keep_alive'], -1)
            self.assertEqual(requests[0]['messages'][0]['content'], 'how do I restart the server')
            return result.stdout
        finally: server.shutdown(); server.server_close(); thread.join()

    def test_success(self):
        self.assertEqual(self.invoke(json.dumps({'done': True, 'message': {'content': 'How do I restart the server?'}}).encode()), 'How do I restart the server?')
    def test_http_failure_preserves_original(self):
        self.assertEqual(self.invoke(b'error', 500), 'how do I restart the server')
    def test_empty_response_preserves_original(self):
        self.assertEqual(self.invoke(b'{"done":true,"message":{"content":""}}'), 'how do I restart the server')
    def test_truncated_response_preserves_original(self):
        self.assertEqual(self.invoke(b'{"done":true,"done_reason":"length","message":{"content":"How"}}'), 'how do I restart the server')
    def test_malformed_response_preserves_original(self):
        self.assertEqual(self.invoke(b'not json'), 'how do I restart the server')
