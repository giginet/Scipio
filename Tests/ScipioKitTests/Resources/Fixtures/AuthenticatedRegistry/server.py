"""Loopback Swift package registry used by RegistryTests; credentials are fixtures."""
import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer

manifest = b'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RegistryLibrary", products: [
    .library(name: "RegistryLibrary", targets: ["RegistryLibrary"])
], targets: [.target(name: "RegistryLibrary")])
'''
archive_buffer = io.BytesIO()
with zipfile.ZipFile(archive_buffer, "w") as archive:
    archive.writestr("RegistryLibrary/Package.swift", manifest)
    archive.writestr("RegistryLibrary/Sources/RegistryLibrary/Library.swift", "public struct Library {}")
archive = archive_buffer.getvalue()
checksum = hashlib.sha256(archive).hexdigest()
package_name = sys.argv[2]
package_path = "/example/" + package_name


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        expected = "Basic " + base64.b64encode(b"fixture:fixture-password").decode()
        if self.headers.get("Authorization") != expected:
            Path(sys.argv[1]).with_suffix(".rejected").write_text("401")
            self.send_response(401)
            self.end_headers()
            return
        path = self.path.split("?")[0]
        if path == package_path:
            body = json.dumps({"releases": {"1.0.0": {}}}).encode()
            content_type = "application/json"
        elif path == package_path + "/1.0.0":
            body = json.dumps({"id": "example." + package_name, "version": "1.0.0", "resources": [
                {"name": "source-archive", "type": "application/zip", "checksum": checksum}
            ]}).encode()
            content_type = "application/json"
        elif path == package_path + "/1.0.0/Package.swift":
            body = manifest
            content_type = "text/x-swift"
        elif path == package_path + "/1.0.0.zip":
            Path(sys.argv[1]).with_suffix(".downloaded").write_text("200")
            body = archive
            content_type = "application/zip"
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Version", "1")
        self.send_header("Content-Length", str(len(body)))
        if content_type == "application/zip":
            self.send_header("Content-Disposition", 'attachment; filename="library.zip"')
        self.end_headers()
        self.wfile.write(body)


server = HTTPServer(("127.0.0.1", 0), Handler)
port_file = Path(sys.argv[1])
temporary_port_file = port_file.with_suffix(".tmp")
temporary_port_file.write_text(str(server.server_port))
temporary_port_file.replace(port_file)
server.serve_forever()
