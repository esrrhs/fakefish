// FakeFish 鉴权与会话健壮性验证（内存/MySQL 模式均可运行）：
// 注册/登录、错误密码、未知用户、重复注册、login_ok.gold 数值化、
// 畸形字段包不崩溃（move/get_rank/login 传错类型）、同账号新会话踢掉旧会话
const WebSocket = require('ws');
const URL = 'ws://127.0.0.1:8081/';
let failures = 0;
function check(name, cond, extra) {
  if (cond) { console.log('PASS: ' + name); }
  else { failures++; console.log('FAIL: ' + name + (extra ? ' -> ' + extra : '')); }
}
const open = () => new Promise((res, rej) => { const ws = new WebSocket(URL); ws.once('open', () => res(ws)); ws.once('error', rej); });
function waitFor(ws, pred, t = 8000) {
  return new Promise((resolve, reject) => {
    const to = setTimeout(() => reject(new Error('timeout')), t);
    ws.on('message', function h(buf) {
      let m; try { m = JSON.parse(buf); } catch (e) { return; }
      let hit = false; try { hit = pred(m); } catch (e) {}
      if (hit) { clearTimeout(to); ws.removeListener('message', h); resolve(m); }
    });
  });
}
const J = (o) => JSON.stringify(o);

(async () => {
  const user = 'Probe_' + Date.now();

  // 1. register
  let ws = await open();
  let p = waitFor(ws, m => m.type === 'login_ok' || m.type === 'register_fail');
  ws.send(J({ type: 'register', username: user, password: 'abc123' }));
  let m = await p;
  check('register -> login_ok', m.type === 'login_ok', J(m));
  check('login_ok.gold is number=100', typeof m.gold === 'number' && m.gold === 100, J(m));
  ws.close();

  // 2. wrong password
  ws = await open();
  p = waitFor(ws, m => m.type === 'login_fail' || m.type === 'login_ok');
  ws.send(J({ type: 'login', username: user, password: 'bad' }));
  m = await p;
  check('wrong password -> 密码错误', m.type === 'login_fail' && m.reason === '密码错误', J(m));
  ws.close();

  // 3. unknown user
  ws = await open();
  p = waitFor(ws, m => m.type === 'login_fail' || m.type === 'login_ok');
  ws.send(J({ type: 'login', username: 'Nobody_' + Date.now(), password: 'x' }));
  m = await p;
  check('unknown user -> 账号不存在', m.type === 'login_fail' && m.reason === '账号不存在，请先注册', J(m));

  // 4. duplicate register
  p = waitFor(ws, m => m.type === 'register_fail' || m.type === 'login_ok');
  ws.send(J({ type: 'register', username: user, password: 'abc123' }));
  m = await p;
  check('dup register -> 用户名已被注册', m.type === 'register_fail' && m.reason === '用户名已被注册', J(m));

  // 5. correct login
  p = waitFor(ws, m => m.type === 'login_ok' || m.type === 'login_fail');
  ws.send(J({ type: 'login', username: user, password: 'abc123' }));
  m = await p;
  check('correct login -> login_ok', m.type === 'login_ok', J(m));

  // 6. malformed packets must not kill the connection; pong still works
  ws.send(J({ type: 'move', dx: 'abc', dy: 'def' }));
  ws.send(J({ type: 'move' }));
  ws.send(J({ type: 'get_rank', limit: 'x' }));
  ws.send(J({ type: 'login', username: 12345, password: 67890 }));
  ws.send(J({ type: 'register', username: ['a'], password: { x: 1 } }));
  ws.send('{bad json');
  let pongOk = false;
  ws.send(J({ type: 'ping' }));
  const pong = await waitFor(ws, m => m.type === 'pong', 5000).catch(() => null);
  check('connection alive & pong after malformed packets', pong && pong.type === 'pong');

  // 7. same account login on a new connection kicks old one
  const gotError = new Promise((resolve) => {
    ws.on('close', () => resolve('closed'));
    ws.on('message', (buf) => {
      const mm = JSON.parse(buf);
      if (mm.type === 'error') resolve(J(mm));
    });
  });
  const ws2 = await open();
  const p2 = waitFor(ws2, m => m.type === 'login_ok' || m.type === 'login_fail');
  ws2.send(J({ type: 'login', username: user, password: 'abc123' }));
  m = await p2;
  check('second session login_ok', m.type === 'login_ok', J(m));
  const oldResult = await Promise.race([gotError, new Promise(r => setTimeout(() => r('nothing'), 5000))]);
  check('old session notified+closed', oldResult !== 'nothing' && oldResult.indexOf('别处登录') >= 0, oldResult);

  ws2.close();
  console.log(failures === 0 ? '=== AUTH PROBE ALL PASSED ===' : ('=== ' + failures + ' FAILURES ==='));
  process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error('PROBE ERROR', e); process.exit(1); });
