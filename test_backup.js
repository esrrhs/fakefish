// FakeFish 加密世界备份 E2E（fakelua compress.zstd + crypto AES-128-CBC +
// base64 + crc32 + uuid + random PCG）：
//   1. 鉴权：无 token 403；路径穿越 id 400
//   2. create -> list 可见 -> inspect 摘要字段（motd/rank_count/events_count/stats）
//   3. 备份含特定 MOTD；清掉 MOTD 后 restore -> MOTD 回到备份时内容
//   4. 翻转密文信封 body 一个字符 -> inspect 报 crc32 mismatch（恢复原文件后正常）
//   5. delete 后 list 不再包含；收尾清空 MOTD、删除本测试全部产物
const http = require('http');
const fs = require('fs');
const path = require('path');

const TOKEN = 'test123'; // CI 在测试前写入 config.yaml（server.hotfix_token）
const BACKUP_DIR = path.join(__dirname, 'data', 'backups');

function log(msg) { console.log('[backup] ' + msg); }

function post(obj) {
    return new Promise((resolve, reject) => {
        const body = JSON.stringify(obj);
        const req = http.request({
            host: '127.0.0.1', port: 8080, path: '/api/admin/backup', method: 'POST',
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

function get(p) {
    return new Promise((resolve, reject) => {
        const req = http.request({ host: '127.0.0.1', port: 8080, path: p, method: 'GET' }, (res) => {
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

function postMotd(motd) {
    return new Promise((resolve, reject) => {
        const body = JSON.stringify({ token: TOKEN, motd });
        const req = http.request({
            host: '127.0.0.1', port: 8080, path: '/api/admin/motd', method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(body)
            }
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
        });
        req.on('error', reject);
        req.end(body);
    });
}

async function bk(action, extra) {
    const r = await post(Object.assign({ token: TOKEN, action }, extra || {}));
    let j = null;
    try { j = JSON.parse(r.body); } catch (e) { /* 保留 null */ }
    return { status: r.status, json: j };
}

async function run() {
    const stamp = Date.now() % 1000000;
    const created = [];

    // ---- 鉴权 / 路径穿越 ----
    const noAuth = await post({ action: 'list' });
    if (noAuth.status !== 403) throw new Error('list without token expected 403, got ' + noAuth.status);
    const traverse = await bk('inspect', { id: '../../etc/passwd' });
    if (traverse.status !== 400) throw new Error('traversal id expected 400, got ' + traverse.status);
    log('PASS: 无 token -> 403；路径穿越 id -> 400');

    // ---- create 第一份（无 MOTD 状态）----
    const c1 = await bk('create', { reason: 'e2e-a-' + stamp });
    if (c1.status !== 200 || !c1.json || c1.json.code !== 0 || !c1.json.backup) {
        throw new Error('create#1 failed: ' + c1.status + ' ' + JSON.stringify(c1.json));
    }
    const b1 = c1.json.backup;
    created.push(b1.name);
    if (!/^backup-\d+-[0-9a-f-]{36}\.fkbk$/.test(b1.name)) throw new Error('bad backup name: ' + b1.name);
    if (typeof b1.cipher_bytes !== 'number' || b1.cipher_bytes <= 0) {
        throw new Error('cipher_bytes bad: ' + JSON.stringify(b1));
    }
    log('PASS: create -> ' + b1.name + '（密文 ' + b1.cipher_bytes + ' 字节）');

    // ---- list 可见 ----
    const l1 = await bk('list');
    if (l1.status !== 200 || !l1.json || !Array.isArray(l1.json.list)) {
        throw new Error('list bad: ' + JSON.stringify(l1.json));
    }
    const row1 = l1.json.list.find((x) => x.name === b1.name);
    if (!row1 || row1.corrupt !== false || row1.id !== b1.id) {
        throw new Error('created backup missing from list: ' + JSON.stringify(l1.json.list));
    }
    log('PASS: list 包含新备份（信封可读，corrupt=false）');

    // ---- 设 MOTD 后 create 第二份 ----
    const notice = 'Phase18备份回滚-' + stamp;
    const setM = await postMotd(notice);
    if (setM.status !== 200) throw new Error('set motd failed: ' + setM.status);
    const c2 = await bk('create', { reason: 'e2e-b-' + stamp });
    if (c2.status !== 200 || !c2.json || c2.json.code !== 0) {
        throw new Error('create#2 failed: ' + JSON.stringify(c2.json));
    }
    const b2 = c2.json.backup;
    created.push(b2.name);

    // ---- inspect（用 8 位短 id）----
    const shortId = b2.id.substring(0, 8);
    const ins = await bk('inspect', { id: shortId });
    if (ins.status !== 200 || !ins.json || ins.json.code !== 0 || !ins.json.backup) {
        throw new Error('inspect by short id failed: ' + ins.status + ' ' + JSON.stringify(ins.json));
    }
    const sum = ins.json.backup;
    if (sum.motd !== notice) throw new Error('inspect motd mismatch: ' + JSON.stringify(sum.motd));
    if (typeof sum.rank_count !== 'number' || typeof sum.events_count !== 'number'
        || typeof sum.feed_count !== 'number' || typeof sum.stats !== 'object' || sum.stats === null) {
        throw new Error('inspect summary fields bad: ' + JSON.stringify(sum));
    }
    if (sum.id !== b2.id || sum.name !== b2.name) throw new Error('inspect identity bad: ' + JSON.stringify(sum));
    log('PASS: inspect（短 id）摘要完整：motd/排行榜/事件/feed/stats，events_count=' + sum.events_count);

    // ---- 清空 MOTD 后 restore ----
    const clr = await postMotd(null);
    if (clr.status !== 200) throw new Error('clear motd failed: ' + clr.status);
    const motdGone = JSON.parse((await get('/api/motd')).body);
    if (motdGone.motd !== null) throw new Error('motd should be null before restore: ' + JSON.stringify(motdGone));

    const rst = await bk('restore', { id: b2.id });
    if (rst.status !== 200 || !rst.json || rst.json.code !== 0) {
        throw new Error('restore failed: ' + rst.status + ' ' + JSON.stringify(rst.json));
    }
    if (!Array.isArray(rst.json.result.restored) || !rst.json.result.restored.includes('motd')) {
        throw new Error('restore result bad: ' + JSON.stringify(rst.json));
    }
    const motdBack = JSON.parse((await get('/api/motd')).body);
    if (motdBack.motd !== notice) throw new Error('motd should return to backed-up value: ' + JSON.stringify(motdBack));
    log('PASS: restore 后 MOTD 回到备份时内容："' + notice + '"');

    // ---- 篡改信封 body：翻一个 base64 字符 ----
    // 共享卷（virtiofs/FUSE）存在秒级属性/页缓存：同秒原地重写同尺寸文件后，
    // 对端短时间内可能读到旧页。因此对「篡改被检出」做有界轮询（最终必须失败），
    // 不断言单次请求即生效，避免环境竞态 flaky。
    const fp = path.join(BACKUP_DIR, b2.name);
    const original = fs.readFileSync(fp, 'utf8');
    const env = JSON.parse(original);
    if (typeof env.body !== 'string' || env.body.length < 16 || typeof env.crc !== 'number') {
        throw new Error('envelope on disk bad shape');
    }
    env.body = (env.body[0] === 'A' ? 'B' : 'A') + env.body.substring(1);
    fs.writeFileSync(fp, JSON.stringify(env));

    const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));
    let tampered = null;
    for (let i = 0; i < 10; i++) {
        tampered = await bk('inspect', { id: b2.id });
        if (tampered.status === 400) break;
        await sleepMs(300);
    }
    if (tampered.status !== 400 || !tampered.json || !String(tampered.json.msg).includes('crc32 mismatch')) {
        throw new Error('tampered envelope expected eventual 400 crc32 mismatch: '
            + tampered.status + ' ' + JSON.stringify(tampered.json));
    }
    log('PASS: 篡改密文信封 1 个字符 -> inspect 400 "crc32 mismatch"');

    // ---- 恢复原文件，inspect 重新通过（同样容忍缓存传播延迟）----
    fs.writeFileSync(fp, original);
    let healed = null;
    for (let i = 0; i < 10; i++) {
        healed = await bk('inspect', { id: b2.id });
        if (healed.status === 200) break;
        await sleepMs(300);
    }
    if (healed.status !== 200) throw new Error('restored envelope should inspect OK: ' + JSON.stringify(healed.json));
    log('PASS: 信封复原后 inspect 恢复正常（CRC32 完整性校验链有效）');

    // ---- 删除本测试创建的两份备份 ----
    for (const name of created) {
        const d = await bk('delete', { id: name });
        if (d.status !== 200 || !d.json || d.json.code !== 0) {
            throw new Error('delete ' + name + ' failed: ' + JSON.stringify(d.json));
        }
        if (fs.existsSync(path.join(BACKUP_DIR, name))) {
            throw new Error('backup file should be removed after delete: ' + name);
        }
    }
    const l2 = await bk('list');
    if (l2.json.list.some((x) => created.includes(x.name))) {
        throw new Error('deleted backups still listed');
    }
    log('PASS: delete 后文件移除、list 不再包含');

    // ---- 收尾：清空 MOTD ----
    await postMotd(null);
    log('PASS: 收尾清空 MOTD');

    console.log('=== [Encrypted Backup E2E Test] ALL PASSED ===');
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Encrypted Backup E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
