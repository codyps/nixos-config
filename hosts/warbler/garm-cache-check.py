"""Root-only live checks for the Warbler cache's TLS and authorization boundary."""
import base64
import hashlib
from pathlib import Path
import ssl
import urllib.error
import urllib.request

AUTH = Path('/var/lib/garm-cache-auth')
CONTEXT = ssl.create_default_context(cafile=str(AUTH / 'server.crt'))
DATA = b'warbler cache authorization probe v1'
DIGEST = hashlib.sha256(DATA).hexdigest()


def request(path, method, credential, expected, data=None):
    headers = {}
    if credential:
        headers['Authorization'] = 'Basic ' + base64.b64encode(credential.encode()).decode()
    req = urllib.request.Request('https://10.77.0.1:9443' + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=CONTEXT, timeout=15) as response:
            status = response.status
            if method == 'GET' and expected == 200:
                assert response.read() == DATA, 'Cached content did not match'
    except urllib.error.HTTPError as error:
        status = error.code
    assert status == expected, f'{method} {path}: expected {expected}, got {status}'


def credentials(directory):
    return {role: role + ':' + (directory / (role + '.password')).read_text().strip()
            for role in ('reader', 'writer')}


if __name__ == '__main__':
    bazel = credentials(AUTH)
    rust = credentials(AUTH / 'zpl')
    for name, path, own, other in (
        ('Bazel', '/zpl-comparison/cas/' + DIGEST, bazel, rust),
        ('Rust', '/zpl/sccache/' + '/'.join(DIGEST[:3]) + '/' + DIGEST, rust, bazel),
    ):
        request(path, 'PUT', own['reader'], 401, DATA)
        request(path, 'PUT', own['writer'], 200, DATA)
        request(path, 'GET', own['reader'], 200)
        request(path, 'GET', other['reader'], 401)
        request(path, 'GET', None, 401)
        print(name + ': TLS, round trip, read-only, cross-repository and anonymous denial passed')
    request('/status', 'GET', bazel['writer'], 404)
    print('Backend status is not exposed to guests')
