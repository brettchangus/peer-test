"""Offline protocol tests; no simulator or application requests."""
import base64
import json
import pathlib
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ios_appium import AppiumError, Client


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.missing = False
        self.redirect = False
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def handle_request(self):
                data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                owner.calls.append((self.command, self.path, json.loads(data) if data else None))
                if owner.redirect:
                    self.send_response(302)
                    self.send_header('Location', '/redirect-target')
                    self.end_headers()
                    return
                status = 200
                value = None
                if self.path == '/session':
                    value = {'sessionId': 'session-1', 'capabilities': {}}
                elif self.path.endswith('/element'):
                    if owner.missing:
                        status = 404
                        value = {'error': 'no such element', 'message': 'secret must not escape'}
                    else:
                        value = {'element-6066-11e4-a52e-4f735466cecf': 'e1'}
                elif self.path.endswith('/displayed'):
                    value = True
                elif self.path.endswith('/text'):
                    value = 'Sessions'
                elif self.path.endswith('/screenshot'):
                    value = base64.b64encode(b'png-test-data').decode()
                elif self.path.endswith('/source'):
                    value = '<Application />'
                elif self.path == '/status':
                    value = {'ready': True}
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'value': value}).encode())

            do_GET = do_POST = do_DELETE = handle_request

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.client = Client(f'http://127.0.0.1:{self.server.server_port}')
        self.base = {'sessionId': 'session-1',
                     'locator': {'using': 'accessibility id', 'value': 'Sessions'}}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_session_preserves_data_and_targets_explicit_device(self):
        self.assertTrue(self.client.execute({'action': 'status'})['ready'])
        result = self.client.execute({'action': 'start', 'udid': 'simulator-1',
                                      'bundleId': 'com.example.myapp'})
        self.assertEqual(result['sessionId'], 'session-1')
        caps = self.calls[-1][2]['capabilities']['alwaysMatch']
        self.assertTrue(caps['appium:noReset'])
        self.assertFalse(caps['appium:fullReset'])
        self.assertEqual(caps['appium:udid'], 'simulator-1')
        self.client.execute({**self.base, 'action': 'stop'})
        self.assertEqual(self.calls[-1][:2], ('DELETE', '/session/session-1'))

    def test_actions_and_visible_wait(self):
        for action in ('wait', 'tap'):
            self.client.execute({**self.base, 'action': action})
        self.client.execute({**self.base, 'action': 'type', 'text': 'hello', 'clear': True})
        self.assertEqual(self.calls[-1][2], {'text': 'hello'})
        self.assertTrue(any(path.endswith('/clear') for _, path, _ in self.calls))
        self.assertTrue(any(path.endswith('/displayed') for _, path, _ in self.calls))
        self.assertEqual(self.client.execute({**self.base, 'action': 'text'}), 'Sessions')
        self.client.execute({**self.base, 'action': 'scroll', 'direction': 'down'})
        self.assertEqual(self.calls[-1][2]['script'], 'mobile: scroll')

    def test_missing_element_times_out_without_server_text(self):
        self.missing = True
        with self.assertRaisesRegex(AppiumError, 'condition not met'):
            self.client.execute({**self.base, 'action': 'wait', 'timeoutSeconds': 0})

    def test_evidence_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            output = pathlib.Path(folder) / 'capture.png'
            cmd = {**self.base, 'action': 'screenshot', 'output': str(output)}
            self.client.execute(cmd)
            self.assertEqual(output.read_bytes(), b'png-test-data')
            with self.assertRaises(FileExistsError):
                self.client.execute(cmd)
            xml = pathlib.Path(folder) / 'source.xml'
            self.client.execute({**self.base, 'action': 'source', 'output': str(xml)})
            self.assertEqual(xml.read_text(), '<Application />')

    def test_remote_and_credential_origins_rejected(self):
        for url in ('http://192.0.2.1:4723', 'http://user:pass@localhost:4723',
                    'http://localhost:4723/path', 'http://localhost:4723?token=x'):
            with self.assertRaises(ValueError):
                Client(url)

    def test_redirect_not_followed(self):
        self.redirect = True
        with self.assertRaises(AppiumError):
            self.client.execute({'action': 'status'})
        self.assertEqual(len(self.calls), 1)


if __name__ == '__main__':
    unittest.main()
