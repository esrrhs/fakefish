// FakeFish UDP 指标推送口 E2E（fakelua net.udp_server）：
//   1. 向 metrics 口发一个 UDP 数据报登记为 peer
//   2. 在一个推送周期内收到服务端 JSON 指标帧
//   3. 校验字段结构（online/bots/uptime_s/ws_recv/ws_sent）
//   4. 发送 unregister，确认之后不再收到推送
const dgram = require('dgram');

const METRICS_HOST = '127.0.0.1';
const METRICS_PORT = 8092;
const PUSH_INTERVAL_S = 5;

function log(msg) { console.log('[metrics] ' + msg); }

async function run() {
    const sock = dgram.createSocket('udp4');
    await new Promise((resolve, reject) => {
        sock.once('error', reject);
        sock.bind(0, '127.0.0.1', resolve);
    });

    const got = [];
    const waitForMetric = (timeoutMs) => new Promise((resolve) => {
        const timer = setTimeout(() => {
            sock.removeListener('message', onMsg);
            resolve(null);
        }, timeoutMs);
        function onMsg(buf) {
            let m;
            try { m = JSON.parse(buf.toString()); } catch (e) { return; }
            clearTimeout(timer);
            sock.removeListener('message', onMsg);
            resolve(m);
        }
        sock.on('message', onMsg);
    });

    try {
        // 1. 登记
        sock.send(JSON.stringify({ type: 'register' }), METRICS_PORT, METRICS_HOST);
        log('register datagram sent to ' + METRICS_HOST + ':' + METRICS_PORT);

        // 2. 等待推送（间隔 5s，留 8s 余量；CI 上给宽到 12s）
        const deadline = PUSH_INTERVAL_S * 1000 + 7000;
        const m1 = await waitForMetric(deadline);
        if (!m1) throw new Error('no metric frame received within ' + deadline + 'ms after register');
        log('metric frame: ' + JSON.stringify(m1));

        // 3. 结构断言
        if (typeof m1.ts !== 'number') throw new Error('metric.ts not number: ' + JSON.stringify(m1));
        for (const k of ['online', 'bots', 'uptime_s', 'ws_recv', 'ws_sent']) {
            if (typeof m1[k] !== 'number') throw new Error('metric.' + k + ' not number: ' + JSON.stringify(m1));
        }
        if (!m1.map || typeof m1.map.width !== 'number' || typeof m1.map.height !== 'number') {
            throw new Error('metric.map malformed: ' + JSON.stringify(m1));
        }
        log('PASS: metric frame structure valid (online=' + m1.online + ', bots=' + m1.bots
            + ', recv=' + m1.ws_recv + ', sent=' + m1.ws_sent + ')');

        // 4. unregister：注销后再等一个周期不应再收到（若实现退化为广播，这里会失败）
        sock.send(JSON.stringify({ type: 'unregister' }), METRICS_PORT, METRICS_HOST);
        const m2 = await waitForMetric(PUSH_INTERVAL_S * 1000 + 3000);
        if (m2 !== null) {
            throw new Error('still receiving metric frames after unregister: ' + JSON.stringify(m2));
        }
        log('PASS: no metric frame after unregister');

        console.log('=== [Metrics UDP E2E Test] ALL PASSED ===');
    } finally {
        sock.close();
    }
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Metrics UDP E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
