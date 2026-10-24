"""Small stdlib-only Appium client. JSON commands arrive on stdin, never argv."""
import argparse
import base64
import ipaddress
import json
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class AppiumError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, server, request_timeout=180):
        url = urllib.parse.urlsplit(server)
        try:
            loopback = ipaddress.ip_address(url.hostname).is_loopback
        except ValueError:
            loopback = url.hostname == 'localhost'
        if (url.scheme not in ('http', 'https') or not loopback or
                url.username or url.password or url.query or url.fragment or
                url.path not in ('', '/')):
            raise ValueError('Use a loopback Appium origin; use SSH forwarding for a Mac.')
        self.server = server.rstrip('/')
        self.request_timeout = request_timeout
        self.request_count = 0
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, method, path, data=None):
        self.request_count += 1
        body = None if data is None else json.dumps(data).encode()
        req = urllib.request.Request(self.server + path, body,
                                     {'Content-Type': 'application/json'}, method=method)
        try:
            with self.opener.open(req, timeout=self.request_timeout) as response:
                result = json.load(response)
        except urllib.error.HTTPError as exc:
            # Server error messages can echo typed passwords. Return only error codes.
            try:
                code = json.load(exc).get('value', {}).get('error', 'HTTP error')
            except (ValueError, AttributeError):
                code = 'HTTP error'
            finally:
                exc.close()
            if code in ('no such element', 'no such alert', 'invalid session id'):
                raise AppiumError(code) from None
            raise AppiumError(f'Appium HTTP {exc.code}; details suppressed') from None
        except (urllib.error.URLError, TimeoutError):
            raise AppiumError('Appium transport unavailable or timed out') from None
        value = result.get('value')
        if isinstance(value, dict) and value.get('error'):
            raise AppiumError('Appium command failed; details suppressed')
        return value

    def execute(self, command):
        action = command['action']
        if action == 'status':
            return self.request('GET', '/status')
        if action == 'start':
            udid = command['udid']
            if not isinstance(udid, str) or not udid.strip():
                raise ValueError('An explicit simulator UDID is required.')
            caps = {'platformName': 'iOS', 'appium:automationName': 'XCUITest',
                    'appium:udid': udid, 'appium:bundleId': command['bundleId'],
                    'appium:noReset': True, 'appium:fullReset': False,
                    'appium:newCommandTimeout': 600}
            return self.request('POST', '/session',
                                {'capabilities': {'alwaysMatch': caps, 'firstMatch': [{}]}})
        session = urllib.parse.quote(command['sessionId'], safe='')
        root = '/session/' + session
        if action == 'stop':
            return self.request('DELETE', root)
        if action in ('source', 'screenshot'):
            result = self.request('GET', root + '/' + action)
            output = pathlib.Path(command['output'])
            # Never overwrite earlier evidence.
            with output.open('xb') as stream:
                stream.write(base64.b64decode(result, validate=True) if action == 'screenshot'
                             else result.encode('utf-8'))
            return {'output': str(output.resolve())}
        if action == 'scroll':
            direction = command['direction']
            if direction not in ('up', 'down', 'left', 'right'):
                raise ValueError('Unsupported scroll direction.')
            return self.request('POST', root + '/execute/sync',
                                {'script': 'mobile: scroll', 'args': [{'direction': direction}]})
        if action not in ('find', 'wait', 'tap', 'type', 'text'):
            raise ValueError('Unsupported action.')
        locator = command['locator']
        if locator['using'] not in ('accessibility id', '-ios predicate string',
                                    '-ios class chain', 'xpath'):
            raise ValueError('Unsupported locator strategy.')
        timeout = float(command.get('timeoutSeconds', 15))
        if not 0 <= timeout <= 60:
            raise ValueError('timeoutSeconds must be between 0 and 60.')
        deadline = time.monotonic() + timeout
        while True:
            try:
                element = self.request('POST', root + '/element', locator)
                element_id = element['element-6066-11e4-a52e-4f735466cecf']
                path = root + '/element/' + urllib.parse.quote(element_id, safe='')
                if action != 'wait' or self.request('GET', path + '/displayed'):
                    break
            except AppiumError as exc:
                if str(exc) != 'no such element':
                    raise
            if time.monotonic() >= deadline:
                raise AppiumError('Element condition not met before timeout')
            time.sleep(0.3)
        if action in ('find', 'wait'):
            return {'elementId': element_id}
        if action == 'tap':
            return self.request('POST', path + '/click', {})
        if action == 'type':
            if command.get('clear', False):
                self.request('POST', path + '/clear', {})
            return self.request('POST', path + '/value', {'text': command['text']})
        return self.request('GET', path + '/text')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', default='http://127.0.0.1:4723')
    args = parser.parse_args()
    try:
        result = Client(args.server).execute(json.load(sys.stdin))
        print(json.dumps({'ok': True, 'value': result}))
        return 0
    except AppiumError as exc:
        print(json.dumps({'ok': False, 'error': str(exc)}))
        return 1
    except Exception:
        # Do not print commands, server bodies, or credentials on failure.
        print(json.dumps({'ok': False, 'error': 'Command failed. Check session, locator, and local server health; no request data logged.'}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
