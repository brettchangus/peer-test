"""Workspace-scoped MAUI iOS sessions, compact observations and action batches."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import time
import xml.etree.ElementTree as ET

from ios_appium import AppiumError, Client


def read_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding='utf-8-sig'))


def contained(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError('Path escapes its workspace or evidence directory')
    return path


def project_info(workspace, settings):
    configured = settings.get('maui', {}).get('projectPath')
    candidates = [contained(workspace, configured)] if configured else []
    if not configured:
        for directory, names, files in os.walk(workspace):
            names[:] = [n for n in names if n not in {
                'bin', 'obj', '.git', '.agents', '.reviews', '.claude', '.codex', '.vs', 'node_modules', 'packages'}]
            candidates.extend(pathlib.Path(directory) / name for name in files if name.endswith('.csproj'))
    projects = []
    for path in candidates:
        tree = ET.parse(path)
        props = {e.tag.rsplit('}', 1)[-1]: (e.text or '').strip() for e in tree.iter()}
        props['_frameworks'] = ';'.join((e.text or '').strip() for e in tree.iter()
                                        if e.tag.rsplit('}', 1)[-1] in ('TargetFramework', 'TargetFrameworks'))
        props['_ids'] = {(e.text or '').strip() for e in tree.iter()
                         if e.tag.rsplit('}', 1)[-1] == 'ApplicationId'}
        if props.get('UseMaui', '').lower() == 'true':
            projects.append((path, props))
    if len(projects) != 1:
        raise ValueError('Configure maui.projectPath: expected exactly one MAUI project')
    path, props = projects[0]
    ios = settings.get('ios', {})
    bundle = ios.get('bundleId') or (next(iter(props['_ids'])) if len(props['_ids']) == 1 else '')
    if not bundle or '$(' in bundle:
        raise ValueError('Configure ios.bundleId from the evaluated project')
    framework = settings.get('maui', {}).get('targetFramework')
    if not framework:
        frameworks = props['_frameworks'].split(';')
        matches = {f for f in frameworks if re.fullmatch(r'net\d+\.\d+-ios', f)}
        framework = next(iter(matches)) if len(matches) == 1 else None
    if not framework:
        raise ValueError('Configure maui.targetFramework for the selected iOS project')
    return {'projectPath': path.relative_to(workspace).as_posix(), 'bundleId': bundle,
            'targetFramework': framework,
            'runtimeIdentifier': settings.get('maui', {}).get('runtimeIdentifier', 'iossimulator-arm64')}


class Workspace:
    MACHINE_FIELDS = {'serverUrl', 'udid', 'macHost', 'macUser', 'sshKeyPath',
                      'dotnetPath', 'macBuildRoot', 'appiumStartScript'}

    def __init__(self, workspace, environment='local', role='standardUser'):
        self.root = pathlib.Path(workspace).resolve()
        self.local = self.root / '.agents/skills/peer-review'
        self.settings = read_json(self.local / 'settings.local.json')
        if self.settings.get('schemaVersion') != 1 or self.settings.get('configured') is not True:
            raise ValueError('NeedsConfiguration: complete workspace settings first')
        self.environment = environment
        self.role = role
        self.env = self.settings['environments'][environment]
        self.account = self.env.get('accounts', {}).get(role, {})
        self.ios = dict(self.settings.get('ios', {}))
        if self.ios.get('machineProfilePath'):
            machine = pathlib.Path(self.ios['machineProfilePath']).expanduser()
            if not machine.is_absolute():
                machine = self.local / machine
            shared = read_json(machine)
            self.ios = {**{k: v for k, v in shared.items() if k in self.MACHINE_FIELDS}, **self.ios}
        self.info = project_info(self.root, {**self.settings, 'ios': self.ios})
        self.client = Client(self.ios['serverUrl'])

    def redact(self, value):
        # Only selected account values; never copy another app's credentials.
        for key in ('email', 'password'):
            secret = self.account.get(key)
            if secret:
                value = value.replace(secret, '[credential redacted]')
        return value

    def fingerprint(self):
        result = subprocess.run(['git', '-C', str(self.root), 'ls-files', '-co',
                                 '--exclude-standard', '-z'], capture_output=True, check=True)
        manifest = {}
        for name in sorted(set(filter(None, result.stdout.decode('utf-8').split('\0')))):
            if name.startswith(('.agents/', '.reviews/', '.claude/', '.codex/')):
                continue
            if {'bin', 'obj', '.git'} & set(pathlib.PurePosixPath(name).parts):
                continue
            if (self.root / name).is_symlink():
                raise ValueError('Source symlinks need an explicit build strategy')
            path = contained(self.root, name)
            if path.is_file():
                manifest[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        key = {'files': manifest, 'target': self.info,
               'build': self.settings.get('maui', {}).get('build', {}),
               'backendOrigin': self.ios.get('backendOrigin')}
        digest = hashlib.sha256(json.dumps(key, sort_keys=True).encode()).hexdigest()
        head = subprocess.check_output(['git', '-C', str(self.root), 'rev-parse', 'HEAD'],
                                       stderr=subprocess.DEVNULL).decode().strip()
        return {'fingerprint': digest, 'head': head, 'files': manifest}

    def preflight(self, offline=False):
        source = self.fingerprint()
        result = {'state': 'NeedsRuntimeVerification', 'application': self.info,
                  'environment': self.environment, 'role': self.role,
                  'accountConfigured': bool(self.account.get('email') and self.account.get('password')),
                  'backendOrigin': self.ios.get('backendOrigin'),
                  'scopeId': self.env.get('scopeId'), 'sourceHead': source['head'],
                  'sourceFingerprint': source['fingerprint'], 'sourceFiles': len(source['files']),
                  'udid': self.ios.get('udid'), 'checksNotPerformed':
                  ['Jira requirements', 'backend/account readiness', 'installed artifact/source parity']}
        if not offline:
            try:
                status = Client(self.ios['serverUrl'], request_timeout=5).execute({'action': 'status'})
                result['appiumReady'] = status.get('ready') is True
            except AppiumError:
                result['appiumReady'] = False
        return result

    def snapshot(self, output):
        output = pathlib.Path(output).resolve()
        if output.is_relative_to(self.root) and not output.is_relative_to(self.local / '.history'):
            raise ValueError('Workspace snapshots must be stored under ignored ticket history')
        source = self.fingerprint()
        output.mkdir(parents=True, exist_ok=True)
        archive = output / (source['fingerprint'] + '.tar.gz')
        reused = archive.exists()
        if not reused:
            with archive.open('xb') as stream, tarfile.open(fileobj=stream, mode='w:gz') as tar:
                for name in source['files']:
                    tar.add(contained(self.root, name), arcname=name, recursive=False)
        # Verify new snapshots too: source could change between hashing and archiving.
        with tarfile.open(archive, 'r:gz') as tar:
            members = tar.getmembers()
            if len(members) != len(source['files']) or {m.name for m in members} != set(source['files']) or any(not m.isfile() for m in members):
                raise ValueError('Snapshot member mismatch')
            for member in members:
                if hashlib.sha256(tar.extractfile(member).read()).hexdigest() != source['files'][member.name]:
                    raise ValueError('Snapshot content mismatch')
        manifest = output / (source['fingerprint'] + '.json')
        if not manifest.exists():
            manifest.write_text(json.dumps(source, indent=2), encoding='utf-8')
        return {'archive': str(archive), 'manifest': str(manifest), 'reused': reused,
                'fingerprint': source['fingerprint'], 'files': len(source['files']),
                'runtimeVerified': False}


class Run:
    def __init__(self, workspace, ticket):
        if not re.fullmatch(r'[A-Za-z]+-\d+', ticket):
            raise ValueError('Invalid ticket key')
        self.workspace = workspace
        self.root = workspace.local / '.history' / ticket.upper()
        self.root.mkdir(parents=True, exist_ok=True)
        self.state_path = self.root / 'native-session.json'
        self.binding = {'workspace': str(workspace.root), 'serverUrl': workspace.ios['serverUrl'],
                        'bundleId': workspace.info['bundleId'], 'udid': workspace.ios['udid'],
                        'environment': workspace.environment, 'role': workspace.role}
        self.client = workspace.client

    def start(self):
        if self.state_path.exists() and not read_json(self.state_path).get('closed'):
            self.state()  # Do not overwrite an owned session that may still be alive.
            raise ValueError('Existing session recorded; inspect or stop it before starting another')
        result = self.client.execute({'action': 'start', 'udid': self.binding['udid'],
                                      'bundleId': self.binding['bundleId']})
        state = {**self.binding, 'sessionId': result['sessionId'], 'closed': False}
        self.state_path.write_text(json.dumps(state), encoding='utf-8')
        return {'state': 'SessionStarted', 'sessionId': result['sessionId'],
                'bundleId': self.binding['bundleId']}

    def state(self):
        state = read_json(self.state_path)
        if state.get('closed') or any(state.get(k) != v for k, v in self.binding.items()):
            raise ValueError('Closed session or workspace/app/device/role binding changed')
        return state

    def alert(self):
        try:
            return self.client.request('GET', '/session/' + self.state()['sessionId'] + '/alert/text')
        except AppiumError as exc:
            if str(exc) == 'no such alert':
                return None
            raise

    def inspect(self, capture=None, contains=None, limit=24):
        sid = self.state()['sessionId']
        alert = self.alert()
        xml = self.client.request('GET', '/session/' + sid + '/source')
        tree = ET.fromstring(xml)
        sensitive = any(e.get('type') == 'XCUIElementTypeSecureTextField' and
                        e.get('visible') == 'true' for e in tree.iter())
        password = self.workspace.account.get('password')
        sensitive = sensitive or bool(password and any(
            password in value for e in tree.iter() for value in e.attrib.values()))
        rows = []
        for e in tree.iter():
            kind = e.get('type', '')
            if e.get('visible') != 'true' or kind in ('XCUIElementTypeKey', 'XCUIElementTypeOther'):
                continue
            label = e.get('label') or e.get('name') or e.get('value')
            if label:
                row = {'type': kind.removeprefix('XCUIElementType'),
                       'text': '[secure field]' if kind == 'XCUIElementTypeSecureTextField'
                       else self.workspace.redact(label)}
                name = self.workspace.redact(e.get('name') or '')
                if name and name != row['text']:
                    row['name'] = name
                if row not in rows:
                    rows.append(row)
            if kind == 'XCUIElementTypeSecureTextField':
                e.set('value', '[secure field]')
                e.set('label', '[secure field]')
                e.set('name', '[secure field]')
        for e in tree.iter():
            if e.get('type') == 'XCUIElementTypeSecureTextField':
                for name in ('value', 'label', 'name'):
                    e.set(name, '[secure field]')
            for name, value in list(e.attrib.items()):
                e.set(name, self.workspace.redact(value))
        paths = {}
        if capture:
            if not re.fullmatch(r'[A-Za-z0-9_-]+', capture):
                raise ValueError('Use a simple unique evidence name')
            source_path = self.root / (capture + '.xml')
            with source_path.open('x', encoding='utf-8') as stream:
                stream.write(ET.tostring(tree, encoding='unicode'))
            paths['source'] = source_path.name
            if not sensitive:
                path = self.root / (capture + '.png')
                self.client.execute({'action': 'screenshot', 'sessionId': sid, 'output': str(path)})
                paths['screenshot'] = path.name
        previous = self.root / 'native-observation.json'
        old = read_json(previous) if previous.exists() else []
        previous.write_text(json.dumps(rows), encoding='utf-8')
        added = [r for r in rows if r not in old]
        removed = [r for r in old if r not in rows]
        shown = rows if contains is not None else added
        if contains is not None:
            shown = [r for r in rows if contains.lower() in json.dumps(r).lower()]
        limit = max(1, min(int(limit), 100))
        def compact(row):
            result = {k: v[:180] for k, v in row.items()}
            if any(len(v) > 180 for v in row.values()):
                result['textTruncated'] = True
            return result
        return {'alert': self.workspace.redact(alert)[:500] if alert else None,
                'visibleCount': len(rows), 'changed': rows != old,
                'elements': [compact(r) for r in shown[:limit]],
                'removed': [compact(r) for r in removed[:limit]],
                'truncated': len(shown) > limit or len(removed) > limit,
                'screenshotSuppressed': sensitive, 'evidence': paths}

    def batch(self, command):
        start = time.monotonic()
        count = self.client.request_count
        completed = 0
        result = {'state': 'ActionsCompleted'}
        try:
            if 'flow' in command and 'actions' in command:
                raise ValueError('Choose a flow or actions, not both')
            actions = self.workspace.ios.get('flows', {})[command['flow']] if 'flow' in command else command.get('actions', [])
            for step in actions:
                action = dict(step)
                kind = action['action']
                if kind == 'alert-dismiss':
                    actual = self.alert()
                    if not actual or not action.get('expectedText') or action['expectedText'] not in actual:
                        raise ValueError('System alert did not match expected text')
                    self.client.request('POST', '/session/' + self.state()['sessionId'] + '/alert/dismiss', {})
                else:
                    if kind not in ('tap', 'type', 'wait', 'scroll', 'expect'):
                        raise ValueError('Unsupported batch action')
                    alert = self.alert()
                    if alert:
                        result = {'state': 'BlockedByAlert', 'alert': self.workspace.redact(alert)[:500]}
                        break
                    if 'selector' in action:
                        action['locator'] = self.workspace.ios.get('selectors', {})[action.pop('selector')]
                    if 'credential' in action:
                        if kind != 'type' or 'text' in action:
                            raise ValueError('Credential references are only allowed for text input')
                        field = action.pop('credential')
                        if field not in ('email', 'password') or not self.workspace.account.get(field):
                            raise ValueError('Selected role credential is missing')
                        if field == 'password':
                            found = self.client.execute({**action, 'action': 'find', 'sessionId': self.state()['sessionId']})
                            element = found['elementId']
                            kind = self.client.request('GET', '/session/' + self.state()['sessionId'] +
                                                       '/element/' + element + '/attribute/type')
                            if kind != 'XCUIElementTypeSecureTextField':
                                raise ValueError('Password input requires an actual secure field')
                        action['text'] = self.workspace.account[field]
                    if kind == 'expect':
                        expected = action.pop('text', None)
                        self.client.execute({**action, 'action': 'wait', 'sessionId': self.state()['sessionId']})
                        if expected is not None:
                            actual = self.client.execute({**action, 'action': 'text', 'sessionId': self.state()['sessionId']})
                            if actual != expected:
                                raise AppiumError('Visible text did not match expected value')
                    else:
                        self.client.execute({**action, 'sessionId': self.state()['sessionId']})
                completed += 1
        except Exception:
            result = {'state': 'ActionFailed', 'error': 'Step failed; request data suppressed'}
        # One compact observation; system alerts are queried separately from the app hierarchy.
        try:
            result['observation'] = self.inspect(command.get('capture'), command.get('contains'))
        except Exception:
            result['observationError'] = 'Observation/evidence unavailable; inspect session and unique output name'
            if result['state'] == 'ActionsCompleted':
                result['state'] = 'EvidenceFailed'
        result.update(completedActions=completed, appiumRequests=self.client.request_count - count,
                      elapsedSeconds=round(time.monotonic() - start, 3))
        with (self.root / 'native-batches.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(result) + '\n')
        return result

    def stop(self):
        state = self.state()
        self.client.execute({'action': 'stop', 'sessionId': state['sessionId']})
        state['closed'] = True
        self.state_path.write_text(json.dumps(state), encoding='utf-8')
        return {'state': 'SessionClosed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['preflight', 'snapshot', 'start', 'inspect', 'batch', 'stop'])
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--environment', default='local')
    parser.add_argument('--role', default='standardUser')
    parser.add_argument('--ticket')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--output')
    parser.add_argument('--capture')
    parser.add_argument('--contains')
    args = parser.parse_args()
    try:
        workspace = Workspace(args.workspace, args.environment, args.role)
        if args.operation == 'preflight':
            result = workspace.preflight(args.offline)
        elif args.operation == 'snapshot':
            if not args.output:
                raise ValueError('snapshot requires --output')
            result = workspace.snapshot(args.output)
        else:
            run = Run(workspace, args.ticket or '')
            if args.operation == 'batch':
                result = run.batch(json.load(sys.stdin))
            elif args.operation == 'inspect':
                result = run.inspect(args.capture, args.contains)
            else:
                result = getattr(run, args.operation)()
        print(json.dumps(result, ensure_ascii=True))
        return 0 if result.get('state') not in ('ActionFailed', 'BlockedByAlert', 'EvidenceFailed') else 1
    except Exception:
        print(json.dumps({'state': 'Blocked', 'error':
                         'Check configured workspace/profile, selected role, ticket, session and runtime. No request data logged.'}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
