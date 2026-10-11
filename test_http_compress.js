// FakeFish HTTP gzip 协商压缩 E2E（fakelua compress.gzip_compress）：
//   1. 静态页 + Accept-Encoding: gzip → Content-Encoding: gzip，gunzip 与原文逐字节一致
//   2. 不带 Accept-Encoding → 原文下发，无 Content-Encoding
//   3. gzip;q=0 → 拒绝压缩，原文下发
//   4. JSON API（/api/rank）同样可 gzip，解压后是合法 JSON
//   5. 小响应（<128B，/api/motd）即使声明 gzip 也不压缩
const http = require('http');
const zlib = require('zlib');
const util = require('util');
const gunzip = util.promisify(zlib.gunzip);

function log(msg) { console.log('[compress] ' + msg); }

function request(path, headers = {}) {
    return new Promise((resolve, reject) => {
        const req = http.request({
            host: '127.0.0.1', port: 8080, path, method: 'GET', headers
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({
                status: res.statusCode,
                headers: res.headers,
                body: Buffer.concat(chunks)
            }));
        });
        req.on('error', reject);
        req.end();
    });
}

async function run() {
    // 1. gzip 静态页
    const gz = await request('/', { 'Accept-Encoding': 'gzip' });
    if (gz.status !== 200) throw new Error('status ' + gz.status);
    if (gz.headers['content-encoding'] !== 'gzip') {
        throw new Error('expected content-encoding gzip, got: ' + gz.headers['content-encoding']);
    }
    if (!/accept-encoding/i.test(gz.headers['vary'] || '')) {
        throw new Error('expected Vary: Accept-Encoding, got: ' + gz.headers['vary']);
    }
    const decompressed = await gunzip(gz.body);
    if (!decompressed.toString('utf8').startsWith('<!DOCTYPE html>')) {
        throw new Error('gunzipped body is not index.html');
    }
    log('PASS: / gzip 下发，Content-Encoding/Vary 正确');

    // 2. 不带 Accept-Encoding：原文
    const plain = await request('/');
    if (plain.headers['content-encoding']) {
        throw new Error('identity response must not be encoded: ' + plain.headers['content-encoding']);
    }
    if (!plain.body.equals(decompressed)) {
        throw new Error('gunzipped body differs from identity body');
    }
    log('PASS: 无 Accept-Encoding 时原文下发，解压结果与原文逐字节一致');

    // 3. q=0 明确拒绝 gzip
    const refused = await request('/', { 'Accept-Encoding': 'gzip;q=0' });
    if (refused.headers['content-encoding']) {
        throw new Error('gzip;q=0 must disable encoding, got: ' + refused.headers['content-encoding']);
    }
    if (!refused.body.equals(plain.body)) throw new Error('q=0 body differs from identity');
    log('PASS: gzip;q=0 回退原文');

    // 4. JSON API gzip：/api/feed 此时已积累多条进场/金币雨事件（前面的套件产生），
    //    响应稳定超过压缩阈值
    const feedGz = await request('/api/feed?limit=100', { 'Accept-Encoding': 'gzip, deflate' });
    if (feedGz.headers['content-encoding'] !== 'gzip') {
        throw new Error('feed expected gzip (accumulated entries make body large), got: '
                        + feedGz.headers['content-encoding'] + ' bytes=' + feedGz.body.length);
    }
    const feedJson = JSON.parse((await gunzip(feedGz.body)).toString('utf8'));
    if (feedJson.code !== 0 || !Array.isArray(feedJson.list)) {
        throw new Error('gunzipped feed JSON malformed: ' + JSON.stringify(feedJson).slice(0, 200));
    }
    if (feedJson.list.length < 1) throw new Error('feed expected >=1 entries by this phase');
    log('PASS: /api/feed gzip 解压为合法 JSON（entries=' + feedJson.list.length + '）');

    // rank 端点同样支持压缩；条目少未达阈值时允许原文，两种形态都必须是合法 JSON
    const rankGz = await request('/api/rank?limit=10', { 'Accept-Encoding': 'gzip' });
    const rankRaw = rankGz.headers['content-encoding'] === 'gzip'
        ? await gunzip(rankGz.body) : rankGz.body;
    const rankJson = JSON.parse(rankRaw.toString('utf8'));
    if (rankJson.code !== 0 || !Array.isArray(rankJson.list)) {
        throw new Error('rank JSON malformed: ' + rankRaw.toString('utf8').slice(0, 200));
    }

    // 5. 小响应不压缩（阈值 128B）
    const motd = await request('/api/motd', { 'Accept-Encoding': 'gzip' });
    if (motd.headers['content-encoding']) {
        throw new Error('small response must not be compressed');
    }
    JSON.parse(motd.body.toString('utf8'));
    log('PASS: 小响应（/api/motd）不压缩');

    console.log('=== [HTTP gzip Compression E2E Test] ALL PASSED ===');
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [HTTP gzip Compression E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
