#!/usr/bin/env python3
"""A tiny tribute webserver for Dolly Parton. No dependencies.

    python3 dolly.py            # http://localhost:8080
    python3 dolly.py 9000       # custom port
"""

import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dolly Parton &mdash; A Tribute</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    font-family: Georgia, "Times New Roman", serif;
    background: radial-gradient(1200px 800px at 50% -10%, #3b1d4e, #170d22 60%, #0c0712);
    color: #f6ecff; padding: 3rem 1.25rem;
  }
  main { max-width: 46rem; text-align: center; }
  .halo { font-size: 3rem; letter-spacing: .4rem; }
  h1 {
    margin: .4rem 0 .2rem; font-size: clamp(2.5rem, 9vw, 5rem); line-height: 1.05;
    background: linear-gradient(100deg, #ffd977, #ff8fc7 55%, #b48bff);
    -webkit-background-clip: text; background-clip: text; color: transparent;
  }
  .dates { font-style: italic; opacity: .75; letter-spacing: .12em; }
  blockquote {
    margin: 2.5rem auto; font-size: clamp(1.15rem, 3.6vw, 1.6rem); line-height: 1.5;
    border-left: 3px solid #ff8fc7; padding-left: 1.25rem; text-align: left; max-width: 34rem;
  }
  blockquote footer { margin-top: .75rem; font-size: .95rem; opacity: .7; font-style: normal; }
  ul { list-style: none; padding: 0; display: grid; gap: .75rem; text-align: left;
       max-width: 34rem; margin: 2rem auto; }
  li { background: rgba(255,255,255,.05); border: 1px solid rgba(255,255,255,.09);
       border-radius: .7rem; padding: .8rem 1rem; }
  li b { color: #ffd977; font-family: system-ui, sans-serif; font-size: .8rem;
         letter-spacing: .1em; display: block; margin-bottom: .2rem; }
  .butterflies { font-size: 1.6rem; letter-spacing: .8rem; margin-top: 2.5rem; opacity: .8; }
  a { color: #ff8fc7; }
</style>
</head>
<body>
<main>
  <div class="halo">&#10023; &#127928; &#10023;</div>
  <h1>Dolly Parton</h1>
  <p class="dates">Songwriter &middot; Singer &middot; Philanthropist &middot; Tennessee&rsquo;s finest</p>

  <blockquote>
    &ldquo;Find out who you are and do it on purpose.&rdquo;
    <footer>&mdash; Dolly Parton</footer>
  </blockquote>

  <ul>
    <li><b>The Songbook</b>Jolene. I Will Always Love You. Coat of Many Colors. 9 to 5.
        Thousands more, most of them written by her own hand.</li>
    <li><b>Imagination Library</b>Hundreds of millions of free books mailed to children
        around the world, one month at a time.</li>
    <li><b>Dollywood</b>A theme park in the Smokies that turned a hometown into a livelihood
        for thousands of her neighbors.</li>
    <li><b>The Rest of It</b>Wildfire relief, vaccine research funding, and a lifetime of
        being unfailingly kind to absolutely everybody.</li>
  </ul>

  <p style="opacity:.8">
    &ldquo;If you don&rsquo;t like the road you&rsquo;re walking, start paving another one.&rdquo;
  </p>

  <div class="butterflies">&#129419; &#129419; &#129419;</div>
</main>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"\N{SPARKLES} Dolly is live at http://localhost:{port}  (Ctrl-C to stop)")
    try:
        ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nGoodnight, y'all.")
