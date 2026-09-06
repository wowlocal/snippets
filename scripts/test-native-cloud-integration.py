#!/usr/bin/env python3
"""Exchange disposable encrypted records across macOS, iPhone/iPad simulators and Android.

Uses the configured native email/SMTP test server and existing app integration phases.
Never points app storage at a live support directory. Android must be an explicitly
provided disposable emulator: the Android phase harness erases that test installation.
Credentials are kept in private fixtures/logs and never printed.
"""
import argparse
import base64
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

REPO = Path(__file__).resolve().parents[1]
os.umask(0o077)
class Failed(Exception): pass

def require(value, label):
    if not value: raise Failed(label)

def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)

class Suite:
    def __init__(self, args):
        self.args = args
        self.root = Path(tempfile.mkdtemp(prefix='snippets-native-sync.'))
        self.root.chmod(0o700)
        self.origin = args.origin_file.read_text().strip()
        require(re.fullmatch(r'https://[A-Za-z0-9.-]+(?::[0-9]+)?', self.origin), 'canonical_https_origin')
        self.report = {'started': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'status': 'running', 'phases': []}
        self.simulators = []
        self.tokens = None
        self.initial_refresh = None
        self.space = None
        self.stage = 'prepare'
        self.environment = os.environ.copy()
        self.environment['SNIPPETS_SUPPORT_DIR'] = str(self.root / 'host-support')
        self.environment['JAVA_HOME'] = self.environment.get('JAVA_HOME', '/Applications/Android Studio.app/Contents/jbr/Contents/Home')
        self.adb = shutil.which('adb') or str(Path.home() / 'Library/Android/sdk/platform-tools/adb')

    def run_command(self, command, label, timeout=900):
        self.stage = label
        with (self.root / (label + '.log')).open('w') as log:
            try:
                result = subprocess.run(command, cwd=REPO, env=self.environment, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
            except subprocess.TimeoutExpired: raise Failed(label + '_timeout')
        require(result.returncode == 0, label)

    def capture(self, command):
        result = subprocess.run(command, cwd=REPO, env=self.environment, capture_output=True, timeout=90)
        require(result.returncode == 0, 'metadata_command')
        return result.stdout.decode().strip()

    def request(self, path, method='GET', body=None, token=None, base=None):
        headers = {'Accept': 'application/json'}
        if body is not None: headers['Content-Type'] = 'application/json'
        if token: headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request((base or self.origin) + path, method=method, headers=headers,
                                         data=None if body is None else json.dumps(body).encode())
        try:
            with urllib.request.urlopen(request, timeout=25) as response:
                raw = response.read(70 * 1024 * 1024)
                return response.status, json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            raw = error.read(256 * 1024)
            try: body = json.loads(raw)
            except ValueError: body = None
            return error.code, body

    def authenticate(self):
        self.stage = 'native_email_authentication'
        status, discovery = self.request('/.well-known/snippets-sync')
        require(status == 200 and discovery.get('nativeAuth', {}).get('flow') == 'email_code', 'native_discovery')
        self.instance = discovery['serverInstanceId']
        email = 'native-sync-' + secrets.token_hex(12) + '@snippets.test'
        status, challenge = self.request('/v2/auth/email/start', 'POST', {'email': email})
        require(status == 200, 'send_code')
        code = None
        for _ in range(40):
            status, mailbox = self.request('/api/v1/messages?limit=100', base=self.args.mailpit)
            require(status == 200, 'mailpit_available')
            for message in mailbox.get('messages', []):
                if any(recipient.get('Address', '').lower() == email for recipient in message.get('To', [])):
                    match = re.search(r'(?<![0-9])([0-9]{6})(?![0-9])', message.get('Subject', ''))
                    if match: code = match.group(1); break
            if code: break
            time.sleep(.25)
        require(code is not None, 'smtp_delivery')
        status, issued = self.request('/v2/auth/email/verify', 'POST', {'challengeId': challenge['challengeId'], 'code': code})
        require(status == 200 and issued['account']['email'] == email, 'verify_code')
        self.tokens = issued
        self.initial_refresh = issued['refresh_token']
        self.store_tokens()
        status, self.space = self.request('/v2/spaces', 'POST', token=self.tokens['access_token'])
        require(status == 201 and self.space['scope']['serverInstanceId'] == self.instance, 'create_disposable_space')
        self.report['native_email_authentication'] = 'passed'

    def store_tokens(self):
        atomic_json(self.root / 'credentials.json', {'initialRefreshToken': self.initial_refresh, 'current': self.tokens})

    def access_token(self):
        previous = self.tokens
        status, updated = self.request('/v2/auth/refresh', 'POST', {'refreshToken': previous['refresh_token']})
        require(status == 200 and updated['account']['id'] == previous['account']['id'], 'native_refresh')
        require(updated['refresh_token'] != previous['refresh_token'], 'native_refresh_rotated')
        self.tokens = updated
        self.store_tokens()
        status, _ = self.request('/v2/auth/revoke', 'POST', {'token': previous['access_token'], 'tokenTypeHint': 'access_token'})
        require(status == 204, 'retire_exact_access')
        return updated['access_token']

    def prepare_builds(self):
        if not self.args.skip_build:
            for platform, scheme, destination, derived in [
                ('macos', 'Snippets', 'platform=macOS,arch=arm64', self.args.macos_derived),
                ('ios', 'Snippets iOS', 'generic/platform=iOS Simulator', self.args.ios_derived)]:
                signing = (['PRODUCT_BUNDLE_IDENTIFIER=com.khm.snippets.debug.native-sync',
                            'CODE_SIGN_IDENTITY=Apple Development', 'CODE_SIGN_STYLE=Manual',
                            'CODE_SIGN_ENTITLEMENTS=', 'PROVISIONING_PROFILE_SPECIFIER=',
                            'DEVELOPMENT_TEAM=H8QG3CBM96'] if platform == 'macos' else ['CODE_SIGNING_ALLOWED=NO'])
                self.run_command(['xcodebuild', '-quiet', '-project', 'Snippets.xcodeproj', '-scheme', scheme,
                                  '-configuration', 'Debug', '-destination', destination, '-derivedDataPath', str(derived),
                                  *signing, 'SNIPPETS_CLOUD_ENABLED=YES', 'SNIPPETS_CLOUD_BASE_URL=' + self.origin, 'build-for-testing'], platform + '-build', 1200)
        self.xctestruns = {}
        for platform, derived in [('macos', self.args.macos_derived), ('ios', self.args.ios_derived)]:
            paths = list((derived / 'Build/Products').glob('*.xctestrun'))
            require(len(paths) == 1, platform + '_test_artifact')
            self.xctestruns[platform] = paths[0]
            info_path = 'Debug*/*.app/Contents/Info.plist' if platform == 'macos' else 'Debug*/*.app/Info.plist'
            app_infos = [plistlib.loads(path.read_bytes()) for path in (derived / 'Build/Products').glob(info_path)]
            require(any(info.get('SnippetsCloudBaseURL') == self.origin for info in app_infos),
                    platform + '_artifact_origin_pin')
            if platform == 'macos':
                require(any(info.get('CFBundleIdentifier') == 'com.khm.snippets.debug.native-sync' for info in app_infos),
                        'macos_isolated_test_bundle')
        require(self.args.android_serial.startswith('emulator-'), 'disposable_android_emulator_required')

    def create_simulator(self, family):
        self.stage = family + '-simulator-setup'
        inventory = json.loads(self.capture(['xcrun', 'simctl', 'list', '-j']))
        runtimes = [r for r in inventory['runtimes'] if r.get('isAvailable') and r.get('name', '').startswith('iOS')]
        runtimes.sort(key=lambda r: tuple(int(p) for p in r['version'].split('.')), reverse=True)
        types = [d for d in inventory['devicetypes'] if d['name'].startswith('iPhone' if family == 'iphone' else 'iPad')]
        preferred = next((d for d in types if ('iPhone 17 Pro' == d['name'] if family == 'iphone' else '11-inch' in d['name'] and 'M4' in d['name'])), types[-1] if types else None)
        require(runtimes and preferred, family + '_simulator_available')
        identifier = self.capture(['xcrun', 'simctl', 'create', 'Snippets Native Sync ' + family + ' ' + secrets.token_hex(3), preferred['identifier'], runtimes[0]['identifier']])
        self.simulators.append(identifier)
        return identifier

    def apple_phase(self, phase, simulator=None, surface=None):
        platform = 'ios' if simulator else 'macos'
        label = (surface or platform) + '-' + phase
        print('Phase:', label, flush=True)
        if simulator:
            self.run_command(['xcrun', 'simctl', 'boot', simulator], label + '-boot')
            self.run_command(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], label + '-boot-ready', 300)
        token = self.access_token()
        source = self.xctestruns[platform]
        document = plistlib.loads(source.read_bytes())
        def absolute(value):
            if isinstance(value, str): return value.replace('__TESTROOT__', str(source.parent))
            if isinstance(value, list): return [absolute(item) for item in value]
            if isinstance(value, dict): return {key: absolute(item) for key, item in value.items()}
            return value
        document = absolute(document)
        targets = ([target for configuration in document['TestConfigurations'] for target in configuration['TestTargets']]
                   if 'TestConfigurations' in document else [value for key, value in document.items() if not key.startswith('__')])
        for target in targets:
            environment = target.setdefault('EnvironmentVariables', {})
            environment.update({'SNIPPETS_CLOUD_E2E': '1', 'SNIPPETS_CLOUD_E2E_SERVER_URL': self.origin,
                                'SNIPPETS_CLOUD_E2E_ACCESS_TOKEN': token, 'SNIPPETS_CLOUD_E2E_SPACE_ID': self.space['scope']['spaceId'],
                                'SNIPPETS_CLOUD_E2E_SERVER_INSTANCE_ID': self.instance, 'SNIPPETS_CLOUD_E2E_APPLE_PHASE': phase,
                                'SNIPPETS_SUPPORT_DIR': str(self.root / (label + '-host-support'))})
            environment.pop('SNIPPETS_CLOUD_E2E_CONFIG_PATH', None)
        fixture = self.root / (label + '.xctestrun')
        fixture.write_bytes(plistlib.dumps(document)); fixture.chmod(0o600)
        target = 'Snippets iOSTests' if simulator else 'Snippets macOSTests'
        destination = 'platform=iOS Simulator,id=' + simulator if simulator else 'platform=macOS,arch=arm64'
        try:
            self.run_command(['xcodebuild', '-quiet', '-xctestrun', str(fixture), '-destination', destination,
                              '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(self.root / (label + '.xcresult')), 'test-without-building',
                              '-only-testing:' + target + '/SnippetsCloudAppIntegrationTests/testCrossPlatformSyncPhase'], label, 360)
            summary = json.loads(self.capture(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                              '--path', str(self.root / (label + '.xcresult')), '--format', 'json']))
            require(summary.get('passedTests') == 1 and summary.get('skippedTests') == 0, label + '_executed_assertions')
        finally:
            if simulator:
                subprocess.run(['xcrun', 'simctl', 'shutdown', simulator], capture_output=True)
        self.report['phases'].append({'surface': surface or platform, 'phase': phase, 'status': 'passed'})
        self.save_report()

    def prepare_android(self):
        if self.args.android_ready_file:
            print('Waiting for the disposable Android emulator hand-off.', flush=True)
            deadline = time.monotonic() + 1800
            while not self.args.android_ready_file.exists():
                require(time.monotonic() < deadline, 'android_handoff_timeout')
                time.sleep(2)
        require(self.args.allow_disposable_android_reset, 'explicit_disposable_android_reset_required')
        self.stage = 'android-prepare'
        state = self.capture([self.adb, '-s', self.args.android_serial, 'get-state'])
        require(state == 'device', 'android_emulator_available')
        for label, path in [('app', self.args.android_apk), ('tests', self.args.android_test_apk)]:
            require(path.is_file(), 'android_' + label + '_artifact')
            self.run_command([self.adb, '-s', self.args.android_serial, 'install', '-r', '-t', str(path)], 'android-install-' + label)

    def android_phase(self, phase):
        label = 'android-' + phase
        print('Phase:', label, flush=True)
        token = self.access_token()
        command = [self.adb, '-s', self.args.android_serial, 'shell', 'am', 'instrument', '-w', '-r',
                   '-e', 'class', 'com.khm.snippets.android.CloudEndToEndTest',
                   '-e', 'snippetsServerUrl', self.origin, '-e', 'snippetsAccessToken', token,
                   '-e', 'snippetsSpaceId', self.space['scope']['spaceId'], '-e', 'snippetsPhase', phase,
                   'com.khm.snippets.android.test/androidx.test.runner.AndroidJUnitRunner']
        self.run_command(command, label, 360)
        log = (self.root / (label + '.log')).read_text()
        require('OK (1 test)' in log and 'FAILURES!!!' not in log, label + '_assertions')
        self.report['phases'].append({'surface': 'android', 'phase': phase, 'status': 'passed'})
        self.save_report()

    def records(self, live, deleted):
        status, page = self.request('/v2/spaces/' + self.space['scope']['spaceId'] + '/changes?limit=50', token=self.access_token())
        require(status == 200 and page['fullSnapshot'] and not page['hasMore'], 'complete_server_snapshot')
        require(sum(not record['deleted'] for record in page['records']) == live and sum(record['deleted'] for record in page['records']) == deleted, 'server_record_counts')
        return page

    def chaos(self, kind):
        self.chaos_generation = uuid.uuid4().hex
        value = {'generation': self.chaos_generation, 'kind': kind}
        if self.space: value['spaceID'] = self.space['scope']['spaceId'].lower()
        atomic_json(self.args.chaos_file, value)

    def assert_chaos(self):
        require(self.args.chaos_state_file.exists(), 'chaos_hook_installed')
        state = json.loads(self.args.chaos_state_file.read_text())
        require(state['generation'] == self.chaos_generation and state['triggered'] == 1 and state['upstreamAttempts'] == 1, 'chaos_executed_once')

    def cas_conflict(self):
        self.stage = 'server-cas-conflict'
        page = self.records(3, 0)
        record = page['records'][0]
        wire = {key: record[key] for key in ('id', 'rev', 'deleted', 'blob')}
        status, result = self.request('/v2/spaces/' + self.space['scope']['spaceId'] + '/records/batch', 'POST',
                                     {'expectedScope': page['scope'], 'items': [{'record': wire, 'expectedRecordVersion': None}]}, self.tokens['access_token'])
        require(status == 200 and result['outcomes'][0]['kind'] == 'conflict', 'stale_insert_conflict')
        require(result['outcomes'][0]['authoritativeRecord'] == record, 'conflict_preserves_authority')
        self.records(3, 0)
        self.report['server_cas_conflict'] = 'passed'

    def save_report(self):
        atomic_json(self.root / 'result.json', self.report)
        if self.args.report_file: atomic_json(self.args.report_file, self.report)

    def execute(self):
        print('Private integration artifacts:', self.root, flush=True)
        try:
            self.prepare_builds()
            self.authenticate()
            self.chaos('disabled')
            self.apple_phase('mac-seed'); self.records(1, 0)
            if self.args.apple_ready_file:
                print('Waiting for the Apple simulator test hand-off.', flush=True)
                deadline = time.monotonic() + 1800
                while not self.args.apple_ready_file.exists():
                    require(time.monotonic() < deadline, 'apple_handoff_timeout')
                    time.sleep(2)
            iphone = self.create_simulator('iphone')
            ipad = self.create_simulator('ipad') if self.args.include_ipad else None
            self.apple_phase('ios-seed', iphone, 'iphone'); self.records(2, 0)
            self.prepare_android()
            self.android_phase('contribute'); self.records(3, 0)
            self.apple_phase('mac-update-android'); self.records(3, 0)
            self.apple_phase('ios-update-mac', iphone, 'iphone'); self.records(3, 0)
            self.android_phase('verify')
            self.apple_phase('mac-verify')
            self.apple_phase('ios-verify', iphone, 'iphone')
            if ipad: self.apple_phase('ios-verify', ipad, 'ipad')
            self.cas_conflict()
            self.chaos('lost_ack'); self.android_phase('delete-lost-ack'); self.assert_chaos(); self.chaos('disabled'); self.records(2, 1)
            self.chaos('truncate'); self.apple_phase('mac-chaos-truncated-fetch'); self.assert_chaos(); self.chaos('disabled')
            self.chaos('stale_cursor'); self.android_phase('chaos-stale-cursor'); self.assert_chaos(); self.chaos('disabled')
            self.apple_phase('ios-verify-deletion', iphone, 'iphone')
            if ipad: self.apple_phase('ios-verify-deletion', ipad, 'ipad')
            self.android_phase('verify-deletion')
            page = self.records(2, 1)
            probes = [b'snippets-macos-e2e-initial-8d134f53', b'snippets-macos-e2e-final-from-ios-8d134f53',
                      b'snippets-ios-e2e-initial-91a8c211', b'snippets-android-e2e-initial-4f6c77f8',
                      b'snippets-android-e2e-final-from-macos-4f6c77f8']
            require(all(not any(probe in base64.b64decode(record['blob']) for probe in probes)
                        for record in page['records']), 'wire_ciphertext_excludes_plaintext')
            self.report['plaintext_probes_absent'] = True
            self.report['final_records'] = {'live': 2, 'tombstones': 1}
            self.report['chaos'] = ['lost_ack', 'truncated_page', 'stale_cursor']
            self.report['status'] = 'passed'
        except KeyboardInterrupt:
            self.report['status'] = 'interrupted'; self.report['failed_stage'] = self.stage
        except Exception as error:
            self.report['status'] = 'failed'; self.report['failed_stage'] = self.stage
            self.report['failure'] = str(error) if isinstance(error, Failed) else type(error).__name__
        finally:
            self.chaos('disabled')
            if self.initial_refresh:
                try:
                    status, _ = self.request('/v2/auth/revoke', 'POST', {'token': self.initial_refresh, 'tokenTypeHint': 'refresh_token'})
                    require(status == 204, 'logout_family')
                    status, _ = self.request('/v2/spaces', token=self.tokens['access_token'])
                    require(status == 401, 'denied_after_logout')
                    self.report['logout'] = 'passed'
                except Exception:
                    self.report['logout'] = 'failed'; self.report['status'] = 'failed'
            for identifier in self.simulators:
                subprocess.run(['xcrun', 'simctl', 'shutdown', identifier], capture_output=True)
                subprocess.run(['xcrun', 'simctl', 'delete', identifier], capture_output=True)
            self.report['completed'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            self.save_report()
            # Remove all bearer fixtures once the family is retired. Logs contain only
            # synthetic test assertions and are retained privately for diagnosis.
            if self.report.get('logout') == 'passed':
                for path in [self.root / 'credentials.json', *self.root.glob('*.xctestrun')]:
                    path.unlink(missing_ok=True)
            print(json.dumps(self.report, indent=2), flush=True)
        return 0 if self.report['status'] == 'passed' else 1

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    fixture = REPO / 'build/cloud-test'
    parser.add_argument('--origin-file', type=Path, default=fixture / 'origin')
    parser.add_argument('--mailpit', default='http://127.0.0.1:8027')
    parser.add_argument('--macos-derived', type=Path, default=Path('/tmp/snippets-native-sync-macos-derived'))
    parser.add_argument('--ios-derived', type=Path, default=Path('/tmp/snippets-native-sync-ios-derived'))
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--include-ipad', action='store_true')
    parser.add_argument('--android-serial', required=True)
    parser.add_argument('--allow-disposable-android-reset', action='store_true')
    parser.add_argument('--android-ready-file', type=Path)
    parser.add_argument('--apple-ready-file', type=Path)
    parser.add_argument('--android-apk', type=Path, default=REPO / 'app/build/outputs/apk/debug/app-debug.apk')
    parser.add_argument('--android-test-apk', type=Path, default=REPO / 'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk')
    parser.add_argument('--chaos-file', type=Path, default=fixture / 'native-sync-chaos.json')
    parser.add_argument('--chaos-state-file', type=Path, default=fixture / 'native-sync-chaos-state.json')
    parser.add_argument('--report-file', type=Path, default=fixture / 'native-sync-result.json')
    args = parser.parse_args()
    return Suite(args).execute()

if __name__ == '__main__':
    sys.exit(main())
