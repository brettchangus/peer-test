"""Offline behavior tests for generic MAUI profiles and compact native runs."""
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from ios_appium import AppiumError
from maui_peer import Run, Workspace, project_info


class FakeClient:
    def __init__(self):
        self.request_count = 0
        self.calls = []
        self.alert_text = None
        self.xml = '<App><e type="XCUIElementTypeStaticText" visible="true" label="Ready" /></App>'
        self.input_type = 'XCUIElementTypeSecureTextField'

    def request(self, method, path, data=None):
        self.request_count += 1
        self.calls.append((method, path, data))
        if path.endswith('/alert/text'):
            if self.alert_text is None:
                raise AppiumError('no such alert')
            return self.alert_text
        if path.endswith('/alert/dismiss'):
            self.alert_text = None
        elif path.endswith('/source'):
            return self.xml
        elif path.endswith('/attribute/type'):
            return self.input_type

    def execute(self, cmd):
        self.request_count += 1
        self.calls.append(('execute', cmd['action'], cmd))
        if cmd['action'] == 'start':
            return {'sessionId': 'fixture-session'}
        if cmd['action'] == 'find':
            return {'elementId': 'fixture-element'}
        if cmd['action'] == 'screenshot':
            with pathlib.Path(cmd['output']).open('xb') as stream:
                stream.write(b'fixture-png')
        if cmd['action'] == 'text':
            return 'Ready'


class MauiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.app = self.root / 'AnyApp'
        self.app.mkdir()
        self.project = self.app / 'AnyApp.csproj'
        self.project.write_text('''<Project><PropertyGroup>
<UseMaui>true</UseMaui><ApplicationId>com.example.anyapp</ApplicationId>
<TargetFrameworks>net10.0-android;net10.0-ios</TargetFrameworks>
</PropertyGroup><PropertyGroup Condition="windows"><TargetFrameworks>$(TargetFrameworks);net10.0-windows</TargetFrameworks></PropertyGroup></Project>''')
        self.local = self.root / '.agents/skills/peer-review'
        self.local.mkdir(parents=True)
        self.path = self.local / 'settings.local.json'
        self.settings = {'schemaVersion': 1, 'configured': True,
                         'environments': {'local': {'baseUrl': 'https://localhost:12345',
                            'scopeId': None, 'accounts': {'standardUser':
                            {'email': 'synthetic@example.invalid', 'password': 'synthetic<&password'}}}},
                         'ios': {'serverUrl': 'http://127.0.0.1:4723', 'udid': 'fixture-sim',
                            'selectors': {'next': {'using': 'accessibility id', 'value': 'Next'}},
                            'flows': {'next': [{'action': 'tap', 'selector': 'next'}]}}}
        self.save()
        self.ws = Workspace(self.root)
        self.client = FakeClient()
        self.ws.client = self.client

    def save(self):
        self.path.write_text(json.dumps(self.settings))

    def tearDown(self):
        self.temp.cleanup()

    def started(self):
        run = Run(self.ws, 'APP-12')
        run.start()
        return run

    def test_distinct_apps_use_their_own_project_and_bundle(self):
        first = self.ws.info
        self.project.write_text(self.project.read_text().replace('com.example.anyapp', 'com.example.other'))
        second = project_info(self.root, self.settings)
        self.assertEqual(first['bundleId'], 'com.example.anyapp')
        self.assertEqual(second['bundleId'], 'com.example.other')
        self.assertEqual(second['targetFramework'], 'net10.0-ios')
        self.assertNotEqual(first['bundleId'], second['bundleId'])

    def test_multiple_projects_require_explicit_selection(self):
        other = self.root / 'Other.csproj'
        other.write_text(self.project.read_text())
        with self.assertRaises(ValueError):
            project_info(self.root, self.settings)
        self.settings['maui'] = {'projectPath': 'AnyApp/AnyApp.csproj'}
        self.assertEqual(project_info(self.root, self.settings)['projectPath'], 'AnyApp/AnyApp.csproj')
        self.settings['maui']['projectPath'] = '../outside.csproj'
        with self.assertRaises(ValueError):
            project_info(self.root, self.settings)

    def test_conditional_bundle_identity_requires_explicit_profile(self):
        text = self.project.read_text().replace('</Project>',
            '<PropertyGroup Condition="Other"><ApplicationId>com.example.variant</ApplicationId></PropertyGroup></Project>')
        self.project.write_text(text)
        with self.assertRaises(ValueError):
            project_info(self.root, self.settings)
        self.settings['ios']['bundleId'] = 'com.example.anyapp'
        self.assertEqual(project_info(self.root, self.settings)['bundleId'], 'com.example.anyapp')

    def test_offline_preflight_reports_unverified_runtime_without_network(self):
        with patch.object(self.ws, 'fingerprint', return_value={'head': 'revision',
                          'fingerprint': 'digest', 'files': {'source.cs': 'hash'}}):
            result = self.ws.preflight(offline=True)
        self.assertEqual(result['state'], 'NeedsRuntimeVerification')
        self.assertNotIn('synthetic', json.dumps(result))
        self.assertEqual(self.client.calls, [])

    def test_shared_machine_does_not_supply_account_or_app_identity(self):
        shared = self.local / 'machine.json'
        shared.write_text(json.dumps({'macHost': 'fixture-host', 'bundleId': 'wrong.app',
                                      'accounts': {'password': 'must-not-load'}}))
        self.settings['ios']['machineProfilePath'] = 'machine.json'
        self.save()
        ws = Workspace(self.root)
        self.assertEqual(ws.ios['macHost'], 'fixture-host')
        self.assertEqual(ws.info['bundleId'], 'com.example.anyapp')
        self.assertNotIn('accounts', ws.ios)

    def test_unconfigured_workspace_blocked_before_network(self):
        self.settings['configured'] = False
        self.save()
        with patch('maui_peer.Client') as client:
            with self.assertRaisesRegex(ValueError, 'NeedsConfiguration'):
                Workspace(self.root)
            client.assert_not_called()

    def test_session_binding_prevents_cross_app_or_role_reuse(self):
        run = self.started()
        with self.assertRaises(ValueError):
            run.start()
        run.binding['bundleId'] = 'different.app'
        with self.assertRaises(ValueError):
            run.inspect()

    def test_compact_inspection_diffs_and_redacts_invisible_secure_fields(self):
        run = self.started()
        self.client.xml = '''<App><e type="XCUIElementTypeStaticText" visible="true" label="Ready"/>
<e type="XCUIElementTypeSecureTextField" visible="false" value="synthetic&lt;&amp;password"/></App>'''
        first = run.inspect('proof')
        second = run.inspect()
        self.assertTrue(first['changed'])
        self.assertFalse(second['changed'])
        self.assertEqual(second['elements'], [])
        self.assertTrue(first['screenshotSuppressed'])
        self.assertNotIn('synthetic', (run.root / 'proof.xml').read_text())
        with self.assertRaises(FileExistsError):
            run.inspect('proof')

    def test_system_alert_stops_actions_and_requires_explicit_matching_dismiss(self):
        run = self.started()
        self.client.alert_text = 'Would Like to Send Notifications'
        result = run.batch({'flow': 'next'})
        self.assertEqual(result['state'], 'BlockedByAlert')
        self.assertEqual(result['completedActions'], 0)
        self.assertFalse(any(x[:2] == ('execute', 'tap') for x in self.client.calls))
        result = run.batch({'actions': [{'action': 'alert-dismiss', 'expectedText': 'wrong prompt'}]})
        self.assertEqual(result['state'], 'ActionFailed')
        self.assertIsNotNone(self.client.alert_text)
        result = run.batch({'actions': [{'action': 'alert-dismiss', 'expectedText': 'Send Notifications'},
                                        {'action': 'tap', 'selector': 'next'}]})
        self.assertEqual(result['completedActions'], 2)

    def test_observation_output_bounds_long_labels_without_losing_saved_source(self):
        run = self.started()
        self.client.xml = '<App><e type="XCUIElementTypeStaticText" visible="true" label="' + 'x' * 5000 + '"/></App>'
        result = run.inspect('long-label')
        self.assertLess(len(json.dumps(result)), 1000)
        self.assertTrue(result['elements'][0]['textTruncated'])
        self.assertIn('x' * 5000, (run.root / 'long-label.xml').read_text())

    def test_credential_reference_never_written_to_batch_results(self):
        run = self.started()
        result = run.batch({'actions': [{'action': 'type', 'selector': 'next', 'credential': 'password'}]})
        self.assertEqual(result['state'], 'ActionsCompleted')
        self.assertNotIn('synthetic', (run.root / 'native-batches.jsonl').read_text())
        self.assertTrue(any(x[0] == 'execute' and x[1] == 'type' and
                            x[2]['text'] == 'synthetic<&password' for x in self.client.calls))

    def test_password_reference_refuses_plain_text_fields(self):
        run = self.started()
        self.client.input_type = 'XCUIElementTypeTextField'
        result = run.batch({'actions': [{'action': 'type', 'selector': 'next', 'credential': 'password'}]})
        self.assertEqual(result['state'], 'ActionFailed')
        self.assertFalse(any(x[:2] == ('execute', 'type') for x in self.client.calls))

    def test_failed_expectation_stops_remaining_batch_and_keeps_metrics(self):
        run = self.started()
        result = run.batch({'actions': [{'action': 'expect', 'selector': 'next', 'text': 'Wrong'},
                                        {'action': 'tap', 'selector': 'next'}]})
        self.assertEqual(result['state'], 'ActionFailed')
        self.assertEqual(result['completedActions'], 0)
        self.assertGreater(result['appiumRequests'], 0)
        self.assertFalse(any(x[:2] == ('execute', 'tap') for x in self.client.calls))

    def test_snapshot_reuse_detects_untracked_changes_and_corrupt_archives(self):
        subprocess.run(['git', 'init', str(self.root)], capture_output=True, check=True)
        cache = self.local / '.history/snapshots'
        with patch('maui_peer.subprocess.check_output', return_value=b'fixture-head\n'):
            first = self.ws.snapshot(cache)
            again = self.ws.snapshot(cache)
            self.assertTrue(again['reused'])
            self.assertFalse(again['runtimeVerified'])
            (self.app / 'NewBehavior.cs').write_text('new behavior')
            changed = self.ws.snapshot(cache)
            self.assertNotEqual(first['fingerprint'], changed['fingerprint'])
            pathlib.Path(changed['archive']).write_bytes(b'corrupt')
            with self.assertRaises(Exception):
                self.ws.snapshot(cache)


if __name__ == '__main__':
    unittest.main()
