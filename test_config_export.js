// FakeFish 脱敏配置导出 E2E（fakelua toml/ini 模块）：
//   1. GET /api/admin/config 必须 token 鉴权；非法 format 400
//   2. format=json：password/token/aes_key 等敏感值全部 "***"，普通标量明文（http_port）
//   3. format=toml / ini：text/plain；含 [server] 段、http_port 与打码值
//   4. 递归打码：嵌套层级中的敏感键同样不可见明文
const http = require('http');

const TOKEN = 'test123'; // CI 从 config.example.yaml 拷贝并 sed 出 token

function log(msg) { console.log('[config] ' + msg); }

function get(p) {
    return new Promise((resolve, reject) => {
        const req = http.request({ host: '127.0.0.1', port: 8080, path: p, method: 'GET' }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            const collect = () => resolve({
                status: res.statusCode,
                headers: res.headers,
                body: Buffer.concat(chunks).toString('utf8')
            });
            res.on('end', collect);
        });
        req.on('error', reject);
        req.end();
    });
}

// 递归收集所有"敏感键"的值（与 http_static.lua is_sensitive_key 同一组词）
function collectSensitive(t, acc) {
    if (t === null || typeof t !== 'object') return acc;
    for (const k of Object.keys(t)) {
        const v = t[k];
        const lk = k.toLowerCase();
        if (['password', 'secret', 'token', 'aes_key'].some((w) => lk.includes(w))) {
            acc.push([k, v]);
        } else if (v !== null && typeof v === 'object') {
            collectSensitive(v, acc);
        }
    }
    return acc;
}

async function run() {
    // ---- 鉴权 / format 校验 ----
    const noToken = await get('/api/admin/config');
    if (noToken.status !== 403) throw new Error('config without token expected 403, got ' + noToken.status);
    const badToken = await get('/api/admin/config?token=wrong');
    if (badToken.status !== 403) throw new Error('bad token expected 403, got ' + badToken.status);
    const badFmt = await get('/api/admin/config?token=' + TOKEN + '&format=xml');
    if (badFmt.status !== 400) throw new Error('xml format expected 400, got ' + badFmt.status);
    log('PASS: 无/坏 token -> 403，非法 format -> 400');

    // ---- JSON：全量脱敏 ----
    const jr = await get('/api/admin/config?token=' + TOKEN + '&format=json');
    if (jr.status !== 200) throw new Error('json config expected 200, got ' + jr.status);
    let j;
    try { j = JSON.parse(jr.body); } catch (e) { throw new Error('json body parse failed: ' + jr.body.slice(0, 200)); }
    if (j.code !== 0 || j.format !== 'json' || typeof j.config !== 'object' || j.config === null) {
        throw new Error('json envelope bad: ' + jr.body.slice(0, 200));
    }
    const sensitive = collectSensitive(j.config, []);
    if (sensitive.length === 0) throw new Error('expected sensitive keys in config');
    for (const [k, v] of sensitive) {
        if (v !== '***') throw new Error('sensitive key ' + k + ' must be ***, got: ' + JSON.stringify(v));
    }
    if (j.config.server.hotfix_token !== '***') {
        throw new Error('server.hotfix_token must be masked');
    }
    if (j.config.backup.aes_key !== '***') {
        throw new Error('backup.aes_key must be masked');
    }
    if (typeof j.config.server.http_port !== 'number' || j.config.server.http_port !== 8080) {
        throw new Error('non-sensitive scalar http_port must be exposed: ' + JSON.stringify(j.config.server.http_port));
    }
    log('PASS: json 全量脱敏（' + sensitive.length + ' 个敏感键全为 ***），http_port=8080 明文保留');

    // ---- TOML ----
    const tr = await get('/api/admin/config?token=' + TOKEN + '&format=toml');
    if (tr.status !== 200) throw new Error('toml expected 200, got ' + tr.status);
    if (!String(tr.headers['content-type']).includes('text/plain')) {
        throw new Error('toml content-type expected text/plain, got ' + tr.headers['content-type']);
    }
    if (!tr.body.includes('[server]') || !tr.body.includes('http_port = 8080')) {
        throw new Error('toml missing [server]/http_port:\n' + tr.body.slice(0, 400));
    }
    if (!tr.body.includes('***')) throw new Error('toml must contain masked value');
    if (!tr.body.includes('[backup]') || !/aes_key = '\*\*\*'/.test(tr.body)) {
        throw new Error('toml backup.aes_key must be masked:\n' + tr.body.slice(0, 600));
    }
    log('PASS: toml 导出 text/plain，含 [server]/http_port 与 aes_key 打码');

    // ---- INI ----
    const ir = await get('/api/admin/config?token=' + TOKEN + '&format=ini');
    if (ir.status !== 200) throw new Error('ini expected 200, got ' + ir.status);
    if (!String(ir.headers['content-type']).includes('text/plain')) {
        throw new Error('ini content-type expected text/plain, got ' + ir.headers['content-type']);
    }
    if (!ir.body.includes('[server]') || !/^http_port\s*=\s*8080/m.test(ir.body)) {
        throw new Error('ini missing [server]/http_port:\n' + ir.body.slice(0, 400));
    }
    if (!ir.body.includes('***')) throw new Error('ini must contain masked value');
    if (!/hotfix_token\s*=\s*\*\*\*/.test(ir.body)) {
        throw new Error('ini hotfix_token must be masked:\n' + ir.body.slice(0, 600));
    }
    log('PASS: ini 导出 text/plain，含 [server]/http_port 与 hotfix_token 打码');

    console.log('=== [Config Export E2E Test] ALL PASSED ===');
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Config Export E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
