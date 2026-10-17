// Isolated teaching fixture. CPU work stays off the HTTP event loop.
const http = require('node:http');
const { Worker } = require('node:worker_threads');
const worker = new Worker([
  "const { parentPort } = require('node:worker_threads');",
  'let until = 0;',
  "parentPort.on('message', value => { until = value; });",
  'setInterval(() => {',
  '  if (Date.now() < until) {',
  '    const end = performance.now() + 20;',
  '    while (performance.now() < end) Math.sqrt(Math.random());',
  '  }',
  '}, 25);',
].join('\n'), { eval: true });
http.createServer((req, res) => {
  if (req.url === '/burn' && req.method === 'POST') worker.postMessage(Date.now() + 30000);
  else if (req.url !== '/healthz') { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'content-type': 'text/plain' }).end('ok');
}).listen(8080, '0.0.0.0');
