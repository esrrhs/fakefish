// FakeFish 防篡改审计链 E2E（fakelua sqlite + crypto.sha256）：
//   1. GET /api/audit、/api/audit/verify 必须 token 鉴权（query string）
//   2. POST /api/admin/run ping 后，审计列表出现 admin.run 且每条带 sha256 链字段
//   3. 干净哈希链 verify -> ok=true
//   4. 用 sqlite3 CLI 直接往库里 INSERT 一条伪造记录（绕过服务端），verify 立即报 mismatch
//   5. 删除伪造行后哈希链恢复 ok=true（不留污染，不影响后续套件）
//   6. GET /api/admin/logs 可拉到文件日志尾部且包含审计事件
const http = require('http');
const { execSync } = require('child_process');
const path = require('path');

const TOKEN = 'test123'; // CI 在测试前写入 config.yaml（server.hotfix_token）
const AUDIT_DB = path.join(__dirname, 'data', 'audit.db');

function log(msg) { console.log('[audit] ' + msg); }

function request(method, p) {
    return new Promise((resolve, reject) => {
        const req = http.request({
            host: '127.0.0.1', port: 8080, path: p, method,
            headers: { 'Content-Type': 'application/json' }
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({
                status: res.statusCode,
                body: Buffer.concat(chunks).toString('utf8')
            }));
        });
        req.on('error', reject);
        req.end();
    });
}

function postJson(p, obj) {
    return new Promise((resolve, reject) => {
        const body = JSON.stringify(obj);
        const req = http.request({
            host: '127.0.0.1', port: 8080, path: p, method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(body)
            }
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({
                status: res.statusCode,
                body: Buffer.concat(chunks).toString('utf8')
            }));
        });
        req.on('error', reject);
        req.end(body);
    });
}

function sql(stmt) {
    execSync('sqlite3 ' + JSON.stringify(AUDIT_DB) + ' ' + JSON.stringify(stmt));
}

async function run() {
    // ---- 鉴权 ----
    const noToken = await request('GET', '/api/audit');
    if (noToken.status !== 403) throw new Error('audit without token expected 403, got ' + noToken.status);
    const badToken = await request('GET', '/api/audit/verify?token=wrong');
    if (badToken.status !== 403) throw new Error('verify bad token expected 403, got ' + badToken.status);
    log('PASS: /api/audit 与 /api/audit/verify 无/坏 token -> 403');

    // ---- 产生一条管理操作 ----
    const ping = await postJson('/api/admin/run', { token: TOKEN, cmd: 'ping' });
    if (ping.status !== 200 || JSON.parse(ping.body).exit !== 0) {
        throw new Error('admin ping failed: ' + ping.status + ' ' + ping.body);
    }

    // ---- 查询审计列表 ----
    const listRes = await request('GET', '/api/audit?token=' + TOKEN + '&limit=50');
    if (listRes.status !== 200) throw new Error('audit list expected 200, got ' + listRes.status);
    const lj = JSON.parse(listRes.body);
    if (lj.code !== 0 || typeof lj.count !== 'number' || lj.count < 1) {
        throw new Error('audit list bad shape: ' + listRes.body);
    }
    if (!Array.isArray(lj.list)) throw new Error('audit list.list must be array');
    const runRow = lj.list.find((r) => r.action === 'admin.run' && r.target === 'ping');
    if (!runRow) throw new Error('admin.run record not found in audit list: ' + listRes.body);
    if (runRow.actor !== 'http') throw new Error('admin.run actor expected http: ' + JSON.stringify(runRow));
    if (!/^[0-9a-f]{64}$/.test(runRow.hash) || typeof runRow.prev_hash !== 'string' || runRow.prev_hash.length === 0) {
        throw new Error('audit row hash chain fields bad: ' + JSON.stringify(runRow));
    }
    log('PASS: admin.run 已入审计链（actor=http，hash/prev_hash 为 sha256 hex）');

    // ---- 干净链校验 ----
    const okRes = await request('GET', '/api/audit/verify?token=' + TOKEN);
    const okj = JSON.parse(okRes.body);
    if (okj.code !== 0 || okj.ok !== true || okj.count < 1) {
        throw new Error('clean chain expected ok=true: ' + okRes.body);
    }
    log('PASS: verify 干净哈希链 ok=true（count=' + okj.count + '）');

    // ---- 外部进程伪造一行（绕过服务端正常 append 路径）----
    // 放在链尾：正常校验时它的 prev_hash 必须等于真实尾 hash，且自身 hash 必须满足
    // sha256(prev|ts|actor|...)；两个条件伪造行都不可能碰巧满足 -> mismatch
    sql("INSERT INTO records (ts,actor,action,target,detail,prev_hash,hash)"
        + " VALUES (999000001,'tamper','forge.e2e',NULL,'forged-outside-server','0','deadbeef')");
    const tampered = JSON.parse((await request('GET', '/api/audit/verify?token=' + TOKEN)).body);
    if (tampered.ok !== false || typeof tampered.broken !== 'string' || !tampered.broken.includes('mismatch')) {
        throw new Error('forged row must break chain with *mismatch*: ' + JSON.stringify(tampered));
    }
    log('PASS: 外部 INSERT 伪造记录被检出（' + tampered.broken + '）');

    // ---- 删除伪造行，链恢复（尾行追加再删，不影响历史链）----
    sql("DELETE FROM records WHERE actor='tamper' AND action='forge.e2e'");
    const healed = JSON.parse((await request('GET', '/api/audit/verify?token=' + TOKEN)).body);
    if (healed.ok !== true) {
        throw new Error('chain should heal after forged row removed: ' + JSON.stringify(healed));
    }
    log('PASS: 删除伪造行后哈希链恢复 ok=true');

    // ---- 文件日志尾部 ----
    const logsRes = await request('GET', '/api/admin/logs?token=' + TOKEN + '&lines=200');
    if (logsRes.status !== 200) throw new Error('logs expected 200, got ' + logsRes.status);
    const logsj = JSON.parse(logsRes.body);
    if (logsj.code !== 0 || !Array.isArray(logsj.lines) || logsj.lines.length === 0) {
        throw new Error('logs bad shape: ' + logsRes.body);
    }
    if (!logsj.lines.some((l) => l.includes('admin.run') && l.includes('[audit]'))) {
        throw new Error('logs tail should contain audit admin.run line: ' + JSON.stringify(logsj.lines.slice(-3)));
    }
    log('PASS: GET /api/admin/logs 读到文件日志尾部（' + logsj.count + ' 行，含审计事件）');

    console.log('=== [Audit Chain E2E Test] ALL PASSED ===');
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Audit Chain E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
