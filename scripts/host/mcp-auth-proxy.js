#!/usr/bin/env node
// mcp-auth-proxy.js — Bearer-token auth proxy for MCP SSE endpoints.
//
// Validates Authorization header, proxies valid requests to supergateway
// on localhost. No npm dependencies — Node stdlib only.
//
// Usage: node mcp-auth-proxy.js <listen_port> <upstream_port>
// Env:   MCP_PROXY_TOKEN (required)
'use strict';

const http = require('http');

const TOKEN = process.env.MCP_PROXY_TOKEN;
const [LISTEN_PORT, UPSTREAM_PORT] = process.argv.slice(2).map(Number);

if (!TOKEN) {
  console.error('FATAL: MCP_PROXY_TOKEN not set');
  process.exit(1);
}
if (!LISTEN_PORT || !UPSTREAM_PORT) {
  console.error('Usage: mcp-auth-proxy.js <listen_port> <upstream_port>');
  process.exit(1);
}

const server = http.createServer((req, res) => {
  if (req.headers.authorization !== `Bearer ${TOKEN}`) {
    res.writeHead(401, { 'Content-Type': 'text/plain' });
    res.end('Unauthorized');
    return;
  }

  const headers = Object.assign({}, req.headers);
  delete headers.authorization;
  delete headers.host;

  const proxyReq = http.request(
    {
      hostname: '127.0.0.1',
      port: UPSTREAM_PORT,
      path: req.url,
      method: req.method,
      headers: headers,
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }
  );

  proxyReq.on('error', (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'text/plain' });
      res.end(`Upstream unavailable: ${err.message}`);
    }
  });

  req.pipe(proxyReq);
});

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log(
    `mcp-auth-proxy :${LISTEN_PORT} -> 127.0.0.1:${UPSTREAM_PORT}`
  );
});
