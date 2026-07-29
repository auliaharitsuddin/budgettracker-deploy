# Mimics GitHub Pages: unknown path -> serve 404.html with HTTP status 404.
import http.server, os, sys
root = sys.argv[1]; port = int(sys.argv[2])
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw): super().__init__(*a, directory=root, **kw)
    def send_error(self, code, message=None, explain=None):
        if code == 404 and os.path.exists(os.path.join(root, "404.html")):
            body = open(os.path.join(root, "404.html"), "rb").read()
            self.send_response(404)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().send_error(code, message, explain)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()

# Kept in the repo (not just as a throwaway) because it is the only way to
# exercise smoke.sh's --target=pages path without deploying: GitHub Pages
# serves 404.html with HTTP 404, and python -m http.server does not, so a
# plain static server cannot reproduce the case that matters.
#
#   python tests/pages_sim.py <dir> <port>
