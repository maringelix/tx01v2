const http = require('node:http');
const { performance } = require('node:perf_hooks');
const burn = process.env.MODE === 'burn';
const duration = burn ? 240000 : 120000;
const times = [];
let failed = 0;
function request() {
  return new Promise(resolve => {
    const start = performance.now();
    let finished = false;
    const done = ok => {
      if (finished) return;
      finished = true;
      times.push(performance.now() - start);
      if (!ok) failed++;
      resolve();
    };
    const req = http.request({
      hostname: 'capacity', port: 8080, path: burn ? '/burn' : '/healthz',
      method: burn ? 'POST' : 'GET', timeout: 2000, agent: false,
    }, res => { res.resume(); res.on('end', () => done(res.statusCode === 200)); });
    req.on('timeout', () => req.destroy());
    req.on('error', () => done(false));
    req.end();
  });
}
(async () => {
  const until = Date.now() + duration;
  while (Date.now() < until) {
    await Promise.all(Array.from({ length: burn ? 5 : 2 }, request));
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  times.sort((a, b) => a - b);
  const p99Ms = times[Math.min(times.length - 1, Math.ceil(times.length * 0.99) - 1)];
  console.log(JSON.stringify({ requests: times.length, failed, p99Ms, mode: burn ? 'burn' : 'observe' }));
  if (!burn && (failed / times.length > 0.01 || p99Ms > 1000 || times.length < 100)) process.exitCode = 1;
})();
