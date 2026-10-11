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
  const myPid = m.player_id;

  // 6. malformed packets must not kill the connection; pong still works
  ws.send(J({ type: 'move', dx: 'abc', dy: 'def' }));
  ws.send(J({ type: 'move' }));
  ws.send(J({ type: 'get_rank', limit: 'x' }));
  ws.send(J({ type: 'login', username: 12345, password: 67890 }));
  ws.send(J({ type: 'register', username: ['a'], password: { x: 1 } }));
  ws.send('{bad json');
  // NaN/Inf 无法经 JSON.stringify 发送（会被序列化成 null），直接发原始词法：
  // 无论服务端 decode 失败拒收还是 finite 守卫丢弃，都不得让自身坐标变成 NaN/Inf
  ws.send('{"type":"move","dx":NaN,"dy":1}');
  ws.send('{"type":"move","dx":1e999,"dy":-1e999}');
  ws.send('{"type":"move","dx":Infinity,"dy":-Infinity}');

  let badCoord = false;
  const coordWatcher = (buf) => {
    let mm; try { mm = JSON.parse(buf); } catch (e) { return; }
    if (mm.type === 'snapshot' && Array.isArray(mm.players)) {
      for (const c of mm.players) {
        if (c.id === myPid && (!Number.isFinite(c.x) || !Number.isFinite(c.y))) badCoord = true;
      }
    }
  };
  ws.on('message', coordWatcher);
  await new Promise(r => setTimeout(r, 2000));
  ws.removeListener('message', coordWatcher);
  check('own coords stay finite after NaN/Inf move', !badCoord);

  let pongOk = false;
  ws.send(J({ type: 'ping' }));
  const pong = await waitFor(ws, m => m.type === 'pong', 5000).catch(() => null);
  check('connection alive & pong after malformed packets', pong && pong.type === 'pong');

  // 6.5 get_rank 的 limit 钳制：非数值默认 10、下限 1、上限 20、小数向下取整。
  // 先多注册两个账号并等排行缓存刷新（内存/MySQL 均为周期 5s），保证榜内 >=3 条，
  // 截断行为才可断言。请求必须串行：服务端 pending_rank 每帧被最新请求覆盖。
  // 注意用户名上限 20 字符，不能拼在 19 字符的 user 后面
  const stamp = String(Date.now()).slice(-8);
  for (const prefix of ['Ra', 'Rb']) {
    const wsr = await open();
    const pr = waitFor(wsr, mm => mm.type === 'login_ok' || mm.type === 'register_fail');
    wsr.send(J({ type: 'register', username: prefix + stamp, password: 'abc123' }));
    await pr;
    wsr.close();
  }
  await new Promise(r => setTimeout(r, 6000));

  const askRank = (raw) => {
    const pr = waitFor(ws, mm => mm.type === 'rank' && Array.isArray(mm.list), 5000);
    if (typeof raw === 'string') ws.send(raw);
    else ws.send(J({ type: 'get_rank', limit: raw }));
    return pr.then(rm => rm.list);
  };
  let list = await askRank(1);
  check('get_rank limit=1 -> exactly 1 entry', list.length === 1, J(list));
  list = await askRank(0);
  check('get_rank limit=0 clamps to 1', list.length === 1, J(list));
  list = await askRank(-5);
  check('get_rank limit=-5 clamps to 1', list.length === 1, J(list));
  list = await askRank(2.9);
  check('get_rank limit=2.9 floors to 2', list.length === 2, J(list));
  // 非数值字段走默认 10
  {
    const pr = waitFor(ws, mm => mm.type === 'rank' && Array.isArray(mm.list) && mm.list.length <= 10, 5000);
    ws.send(J({ type: 'get_rank', limit: 'str' }));
    const rm = await pr;
    check('get_rank limit="str" defaults to <=10', Array.isArray(rm.list) && rm.list.length <= 10, J(rm.list));
  }
  list = await askRank(100);
  check('get_rank limit=100 clamps to <=20', list.length <= 20, J(list));
  check('get_rank cache has >=3 entries (upper-clamp observable)', list.length >= 3, J(list));
  // 原始词法 NaN：decode 成功则按默认 10 处理，失败则整包拒收；两者都不得打死连接
  ws.send('{"type":"get_rank","limit":NaN}');
  await new Promise(r => setTimeout(r, 300));
  ws.send(J({ type: 'ping' }));
  const pong2 = await waitFor(ws, mm => mm.type === 'pong', 5000).catch(() => null);
  check('connection alive after get_rank NaN', pong2 && pong2.type === 'pong');

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

  // 8. 只建连不登录的连接：即使持续发消息，也必须在建连 conn_timeout_s(15s) 后被踢
  const wsIdle = await open();
  const idleTimer = setInterval(() => { try { wsIdle.send(J({ type: 'ping' })); } catch (e) {} }, 2000);
  const idleClosed = await new Promise((resolve) => {
    wsIdle.on('close', () => resolve(true));
    setTimeout(() => resolve(false), 20000);
  });
  clearInterval(idleTimer);
  try { wsIdle.close(); } catch (e) {}
  check('never-login connection closed after conn timeout', idleClosed === true);

  console.log(failures === 0 ? '=== AUTH PROBE ALL PASSED ===' : ('=== ' + failures + ' FAILURES ==='));
  process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error('PROBE ERROR', e); process.exit(1); });
