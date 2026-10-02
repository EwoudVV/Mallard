#!/usr/bin/env python3
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from pathlib import Path
from functools import partial
from urllib.parse import urlsplit,parse_qs
import time
import json
root=Path(__file__).resolve().parents[1]/'Tests/Fixtures'
class FixtureHandler(SimpleHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_POST(self):
        if self.path!='/upload-check':
            self.send_error(404);return
        size=int(self.headers.get('Content-Length','0'))
        if size<0 or size>2*1024*1024:
            self.send_error(413);return
        body=self.rfile.read(size)
        reply=json.dumps({'received':len(body)}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(reply)));self.end_headers();self.wfile.write(reply)
    def do_GET(self):
        request=urlsplit(self.path)
        if request.path=='/visual.html' and parse_qs(request.query).get('slow')==['1']:
            time.sleep(4)
        super().do_GET()

ThreadingHTTPServer(('127.0.0.1',8742),partial(FixtureHandler,directory=str(root))).serve_forever()
