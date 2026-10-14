// FakeFish 游客登录验证（guest.enabled=true 时生效）：
// 免注册直接进场、昵称由服务端生成且互不重复、金币与正式账号一致、
// 确实进入世界（出现在快照里）、不进历史排行榜（不落库）。
//
// 注意：本用例会往内存账号表里添两个游客账号，跑在 bot_count=0 的主阶段，
// 与 combat/split 等时序敏感用例互不干扰（游客只是普通球体，不主动觅食）。
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
    const g1 = m.name;

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

    // 4. 游客不进历史排行榜（纯内存账号，不落 MySQL）
    const pr = waitFor(ws, r => r.type === 'rank', 8000);
    ws.send(J({ type: 'get_rank', limit: 20 }));
    const r = await pr;
    const list = Array.isArray(r.list) ? r.list : [];
    const leaked = list.filter(e => e.name === g1 || e.name === m2.name);
    check('游客不出现在历史榜', leaked.length === 0, J(leaked));

    // 5. 游客名不能被注册接口占用（游客名含中文，不符合用户名字符集）
    const p3 = waitFor(ws2, x => x.type === 'register_fail' || x.type === 'login_ok', 8000);
    ws2.send(J({ type: 'register', username: g1, password: 'abc123' }));
    const m3 = await p3;
    check('游客名不能作为正式账号注册', m3.type === 'register_fail', J(m3));

    try { ws.close(); } catch (e) {}
    try { ws2.close(); } catch (e) {}

    console.log(failures === 0 ? '=== GUEST PROBE ALL PASSED ===' : ('=== ' + failures + ' FAILURES ==='));
    process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error('PROBE ERROR', e); process.exit(1); });
