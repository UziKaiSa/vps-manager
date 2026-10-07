"""Gateway checks authenticate a node without posting synthetic metrics."""
import base64
import hashlib
import io
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path
from unittest.mock import patch

TEXT = (Path(__file__).resolve().parents[1] / 'vps-manager.sh').read_text(encoding='utf-8')
HANDSHAKE = TEXT.split("<<'PY_GATEWAY_HANDSHAKE'\n", 1)[1].split('\nPY_GATEWAY_HANDSHAKE', 1)[0]


def handshake(endpoint, status=101, valid_accept=True, token='test-only-node'):
    class Connection:
        def __init__(self, *args, **kwargs):
            self.closed = False
            self.requested = None

        def request(self, method, path, headers):
            self.requested = (method, path, headers)

        def getresponse(self):
            key = self.requested[2]['Sec-WebSocket-Key']
            expected = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            class Reply:
                def getheader(self, name):
                    return expected if valid_accept else 'wrong'
            reply = Reply()
            reply.status = status
            return reply

        def close(self):
            self.closed = True

    connection = Connection()
    output = io.StringIO()
    with patch('sys.argv', ['check', endpoint]), patch('os.fdopen', return_value=io.StringIO(token)), \
         patch('http.client.HTTPSConnection', return_value=connection), redirect_stdout(output), redirect_stderr(output):
        try:
            exec(compile(HANDSHAKE, '<gateway-check>', 'exec'), {})
        except SystemExit as result:
            code = result.code
    assert output.getvalue() == ''
    return code, connection


def test_gateway_handshake_authenticates_only_read_only_upgrade():
    code, connection = handshake('https://monitor.example.com')
    assert code == 0 and connection.closed
    method, path, headers = connection.requested
    assert method == 'GET'
    assert path == '/api/clients/v2/rpc?token=test-only-node'
    assert headers['Upgrade'] == 'websocket'


def test_gateway_check_rejects_access_redirect_bad_token_and_false_upgrade():
    for status in [200, 302, 403, 502]:
        code, connection = handshake('https://monitor.example.com', status=status)
        assert code == 1 and connection.closed
    assert handshake('https://monitor.example.com', valid_accept=False)[0] == 1


def test_gateway_check_never_sends_token_to_insecure_or_credential_url():
    for endpoint in ['http://monitor.example.com', 'https://user@monitor.example.com',
                     'https://monitor.example.com?x=1', 'https://monitor.example.com#x']:
        code, connection = handshake(endpoint)
        assert code == 1 and connection.requested is None
    assert handshake('https://monitor.example.com', token='')[0] == 1


def test_gateway_mode_pins_reporting_and_keeps_legacy_modes_separate():
    runner = TEXT.split('komari_write_local_runner() {',1)[1].split('\n}\n',1)[0]
    installer = TEXT.split('komari_install_agent() {',1)[1].split('\n}\n',1)[0]
    mode = TEXT.split('install_komari_gateway() {',1)[1].split('\n}\n',1)[0]
    assert '--interval 1' in runner and 'args+=(--interval 1)' in installer
    assert 'local KOMARI_GATEWAY_MODE=1' in mode
    assert 'install_komari_warp' not in mode and 'client_secret' not in mode
    assert TEXT.count('in 1) install_komari_gateway') == 2
    assert TEXT.count('1) 公网直装\\n  2) 配置/修复 WARP') == 2
