#!/usr/bin/env python3
import argparse
import http.client
import json
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

HOP_BY_HOP_HEADERS = {
    'connection',
    'content-length',
    'host',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
}
STREAM_CONTENT_TYPES = ('text/event-stream', 'application/x-ndjson')


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = 'OpenClawTenantProxy/1.0'

    def _auth_ok(self):
        required = self.server.require_bearer
        if not required:
            return True
        auth = self.headers.get('Authorization', '')
        return auth == f'Bearer {required}'

    def _send_json(self, status_code, payload):
        body = json.dumps(payload).encode()
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _build_connection(self):
        upstream = self.server.upstream
        port = upstream.port or (443 if upstream.scheme == 'https' else 80)
        if upstream.scheme == 'https':
            return http.client.HTTPSConnection(
                upstream.hostname,
                port,
                timeout=300,
                context=ssl.create_default_context(),
            )
        return http.client.HTTPConnection(upstream.hostname, port, timeout=300)

    def _target_path(self):
        upstream_path = self.server.upstream.path.rstrip('/')
        request_path = self.path if self.path.startswith('/') else f'/{self.path}'
        if not upstream_path:
            return request_path or '/'
        if request_path == upstream_path or request_path.startswith(f'{upstream_path}/'):
            return request_path
        return f'{upstream_path}{request_path}' or '/'

    def _forward_headers(self):
        headers = {}
        for key, value in self.headers.items():
            if key.lower() in HOP_BY_HOP_HEADERS or key.lower() == 'authorization':
                continue
            headers[key] = value
        headers['Authorization'] = f'Bearer {self.server.upstream_api_key}'
        headers['Host'] = self.server.upstream_host
        return headers

    def _forward(self):
        if not self._auth_ok():
            self._send_json(401, {'error': 'unauthorized'})
            return

        length = int(self.headers.get('Content-Length', '0') or '0')
        body = self.rfile.read(length) if length else None
        headers = self._forward_headers()
        connection = self._build_connection()
        try:
            connection.request(self.command, self._target_path(), body=body, headers=headers)
            response = connection.getresponse()
            content_type = response.getheader('Content-Type', '')
            is_stream = any(kind in content_type for kind in STREAM_CONTENT_TYPES)

            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() in HOP_BY_HOP_HEADERS:
                    continue
                if is_stream and key.lower() == 'content-length':
                    continue
                self.send_header(key, value)

            if is_stream:
                self.end_headers()
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            else:
                data = response.read()
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except Exception as exc:
            self._send_json(502, {'error': 'upstream_error', 'detail': str(exc)})
        finally:
            connection.close()

    def do_HEAD(self):
        self._forward()

    def do_GET(self):
        self._forward()

    def do_POST(self):
        self._forward()

    def do_PUT(self):
        self._forward()

    def do_PATCH(self):
        self._forward()

    def do_DELETE(self):
        self._forward()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Allow', 'GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def log_message(self, fmt, *args):
        return


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--listen', default='0.0.0.0')
    ap.add_argument('--port', type=int, required=True)
    ap.add_argument('--upstream', required=True)
    ap.add_argument('--api-key', required=True)
    ap.add_argument('--require-bearer', default='')
    args = ap.parse_args()

    upstream = urlsplit(args.upstream)
    if upstream.scheme not in {'http', 'https'} or not upstream.hostname:
        raise SystemExit('upstream must be a valid http(s) URL')

    server = ReusableThreadingHTTPServer((args.listen, args.port), ProxyHandler)
    server.upstream = upstream
    server.upstream_api_key = args.api_key
    server.require_bearer = args.require_bearer
    server.upstream_host = upstream.netloc
    server.serve_forever()


if __name__ == '__main__':
    main()
