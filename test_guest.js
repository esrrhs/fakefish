// FakeFish 游客登录验证（guest.enabled=true 时生效）：
// 免注册直接进场、昵称由服务端生成且互不重复、金币与正式账号一致、
// 确实进入世界（出现在快照里）、凭证可复用同一游客（战绩延续）、
// 伪造凭证拿不到别人身份、游客进历史排行榜（账号落库）。
//
// 注意：本用例会往世界里添若干游客，故排在 combat/powerup/feast/zone/split
// 之后（见 scripts/e2e-main.txt），避免扰动时序敏感的活世界用例。
const WebSocket = require('ws');
const URL = 'ws://127.0.0.1:8081/';
let failures = 0;

function check(name, cond, extra) {
    if (cond) { console.log('PASS: ' + name); }
    else { failures++; console.log('FAIL: ' + name + (extra ? ' -> ' + extra : '')); }
}

const open = () => new Promise((res, rej) => {
    const ws = new WebSocket(URL);
    ws.once('open', () => res(ws));
    ws.once('error', rej);
});

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
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

(async () => {
    // 1. 游客免注册进场
    let ws = await open();
    let p = waitFor(ws, m => m.type === 'login_ok' || m.type === 'login_fail');
    ws.send(J({ type: 'guest' }));
    let m = await p;
    check('guest -> login_ok', m.type === 'login_ok', J(m));
    check('guest login_ok 带服务端生成的 name', typeof m.name === 'string' && m.name.length > 0, J(m));
    check('guest name 使用游客前缀', typeof m.name === 'string' && m.name.indexOf('游客') === 0, J(m));
    check('guest gold 与正式账号一致(100)', typeof m.gold === 'number' && m.gold === 100, J(m));
    check('guest 拿到可复用的凭证 guest_token', typeof m.guest_token === 'string' && m.guest_token.length === 64, J(m));
    const g1 = m.name;
    const g1tok = m.guest_token;
    const g1pid = m.player_id;

    // 2. 确实进了世界：后续快照里能找到自己
    const snap = await waitFor(
        ws,
        s => s.type === 'snapshot' && Array.isArray(s.players) && s.players.some(x => x.id === m.player_id),
        8000
    );
    const me = snap.players.find(x => x.id === m.player_id);
    check('guest 出现在世界快照中', !!me, J(snap.players.slice(0, 3)));
    check('guest 快照昵称与 login_ok 一致', !!me && me.name === g1, me ? me.name : 'n/a');

    // 3. 第二个游客：昵称必须不与第一个重复
    const ws2 = await open();
    let p2 = waitFor(ws2, x => x.type === 'login_ok' || x.type === 'login_fail');
    ws2.send(J({ type: 'guest' }));
    const m2 = await p2;
    check('第二个游客也进场成功', m2.type === 'login_ok', J(m2));
    check('两个游客昵称互不重复', m2.type === 'login_ok' && m2.name !== g1, `${g1} vs ${m2.name}`);

    // 4. 凭证复用：带回 {name, token} 应回到同一个游客（战绩延续的前提）
    const ws3 = await open();
    const p3 = waitFor(ws3, x => x.type === 'login_ok' || x.type === 'login_fail');
    ws3.send(J({ type: 'guest', name: g1, token: g1tok }));
    const m3 = await p3;
    check('凭证复用 -> login_ok', m3.type === 'login_ok', J(m3));
    check('凭证复用 -> 同一个游客昵称', m3.type === 'login_ok' && m3.name === g1, `${g1} vs ${m3.name}`);
    check('凭证复用 -> 同一个账号 id', m3.type === 'login_ok' && m3.player_id === g1pid, `${g1pid} vs ${m3.player_id}`);
    check('凭证复用 -> 金币延续(100)', m3.type === 'login_ok' && m3.gold === 100, J(m3));

    // 5. 伪造凭证：不能冒用别人身份，只能拿到一个全新的游客
    const ws4 = await open();
    const p4 = waitFor(ws4, x => x.type === 'login_ok' || x.type === 'login_fail');
    ws4.send(J({ type: 'guest', name: g1, token: 'deadbeef'.repeat(8) }));
    const m4 = await p4;
    check('伪造凭证 -> 仍是 login_ok（降级为新游客）', m4.type === 'login_ok', J(m4));
    check('伪造凭证 -> 拿不到原游客身份', m4.type === 'login_ok' && m4.name !== g1, `${g1} vs ${m4.name}`);

    // 6. 游客进历史排行榜（账号落库）。榜是 5s 心跳刷新的缓存，先等一轮。
    //    必须用 ws3 发：第 4 步用同一凭证复用时已把 ws（旧会话）顶下线，
    //    向已断开的连接发请求自然收不到应答（与正式账号同账号互踢一致）。
    await sleep(6000);
    const pr = waitFor(ws3, r => r.type === 'rank', 8000);
    ws3.send(J({ type: 'get_rank', limit: 20 }));
    const r = await pr;
    const list = Array.isArray(r.list) ? r.list : [];
    const inList = list.some(e => e.name === g1);
    // 榜若已满 20 且全是更高战绩，被挤出也算合理，不算失败
    const squeezedOut = list.length >= 20 && list.every(e => e.best_gold > 100);
    check('游客进历史榜（或被更高战绩挤出）', inList || squeezedOut, J(list.slice(0, 3)));

    // 7. 游客名不能被注册接口占用（游客名含中文，不符合用户名字符集 [^\w_]）
    const p5 = waitFor(ws2, x => x.type === 'register_fail' || x.type === 'login_ok', 8000);
    ws2.send(J({ type: 'register', username: g1, password: 'abc123' }));
    const m5 = await p5;
    check('游客名不能作为正式账号注册', m5.type === 'register_fail', J(m5));

    try { ws.close(); } catch (e) {}
    try { ws2.close(); } catch (e) {}
    try { ws3.close(); } catch (e) {}
    try { ws4.close(); } catch (e) {}

    console.log(failures === 0 ? '=== GUEST PROBE ALL PASSED ===' : ('=== ' + failures + ' FAILURES ==='));
    process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error('PROBE ERROR', e); process.exit(1); });
