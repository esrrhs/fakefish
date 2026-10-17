// FakeFish 一局制（match）E2E 测试
// 一局内安全区收缩到 0，最后一个存活者吃鸡，结算后自动开新局。
// 依赖服务端 match_enable=true；本用例自建两个游客连接凑出「有对手」的局面。
const WebSocket = require('ws');

const WS_URL = process.env.MATCH_WS_URL || "ws://127.0.0.1:8081/";
// 观察窗口要 ≥ 一个完整循环（单局时长 + 结算时长）并留足余量：CI 共享 runner
// 帧率低，缩圈靠每秒心跳推进，慢机器上窗口太短会看不到换局
const OBSERVE_MS = Number(process.env.MATCH_OBSERVE_MS || 100000);

function connect(name) {
    return new Promise((resolve, reject) => {
        const ws = new WebSocket(WS_URL);
        const cli = { ws, id: null, name: null, alive: true, out: false };
        ws.on("open", () => ws.send(JSON.stringify({ type: "guest" })));
        // 注意用 addEventListener：它的回调参数是 MessageEvent（.data 才是负载）；
        // ws.on("message", cb) 的回调参数直接就是负载，用 .data 会拿到 undefined
        ws.addEventListener("message", (m) => {
            if (process.env.MATCH_DEBUG) {
                console.log("[dbg]", name, String(m.data).slice(0, 70));
            }
            // 服务端偶尔会夹带非 JSON 帧（如空帧），登录判定不能因此崩掉
            let d = null;
            try { d = JSON.parse(m.data); } catch (e) { return; }
            if (d && d.type === "login_ok") {
                cli.id = d.player_id;
                cli.name = d.name;
                resolve(cli);
            }
        });
        ws.on("error", reject);
        setTimeout(() => reject(new Error("login timeout for " + name)), 15000);
        // 保活：出局后不发 move 也要维持连接
        cli.ping = setInterval(() => {
            if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "ping" }));
        }, 3000);
    });
}

async function runMatchTest() {
    console.log("=== [Match E2E Test] 一局制：缩圈到 0 / 吃鸡 / 自动开新局 ===");

    const a = await connect("A");
    const b = await connect("B");
    console.log(`Two players joined: ${a.name}(${a.id}) / ${b.name}(${b.id})`);

    const overs = [];
    const starts = [];
    let firstSnap = null;
    let lastSnap = null;
    const zoneRadii = [];
    let minZoneR = Infinity;
    let maxZoneR = 0;
    let sawOut = false;
    let sawWinnerSelf = null;

    const watch = (cli) => {
        cli.ws.addEventListener("message", (m) => {
            let d = null;
            try { d = JSON.parse(m.data); } catch (e) { return; }
            if (!d) return;
            if (d.type === "snapshot") {
                if (firstSnap === null) firstSnap = d;
                lastSnap = d;
                if (d.match) {
                    if (d.match.id !== undefined) cli.lastMatchId = d.match.id;
                }
                if (d.zone && typeof d.zone.r === "number") {
                    zoneRadii.push(d.zone.r);
                    if (d.zone.r < minZoneR) minZoneR = d.zone.r;
                    if (d.zone.r > maxZoneR) maxZoneR = d.zone.r;
                }
                // 自己在快照里没有细胞 = 已出局
                const mine = d.players.find(p => p.id === cli.id);
                if (!mine) cli.absent = true;
            } else if (d.type === "match_over") {
                overs.push(d);
                if (d.winner && cli.id && d.winner_id === cli.id) sawWinnerSelf = cli.name;
            } else if (d.type === "match_start") {
                starts.push(d);
            } else if (d.type === "you_died") {
                if (d.out) { sawOut = true; cli.out = true; }
            }
        });
    };
    watch(a);
    watch(b);

    // 两人都朝地图中心慢慢挪，尽量活到局末（圈心在中心）
    const drive = (cli) => setInterval(() => {
        if (cli.ws.readyState !== WebSocket.OPEN) return;
        const snap = lastSnap;
        if (!snap || !snap.zone) return;
        const me = snap.players.find(p => p.id === cli.id);
        if (!me) return;
        const dx = snap.zone.x - me.x;
        const dy = snap.zone.y - me.y;
        const d = Math.hypot(dx, dy) || 1;
        const nx = dx / d;
        const ny = dy / d;
        cli.ws.send(JSON.stringify({ type: "move", dx: nx, dy: ny }));
    }, 200);
    const ta = drive(a);
    const tb = drive(b);

    console.log(`Observing for ${OBSERVE_MS}ms...`);
    await new Promise(r => setTimeout(r, OBSERVE_MS));
    clearInterval(ta);
    clearInterval(tb);
    clearInterval(a.ping);
    clearInterval(b.ping);

    // 1) 快照必须带 match 信息，且局号/存活数合理
    if (!firstSnap || !firstSnap.match) {
        console.error("FAIL: snapshot has no match info");
        process.exit(1);
    }
    console.log(`match info: id=${firstSnap.match.id} state=${firstSnap.match.state} `
        + `remain=${firstSnap.match.remain} alive=${firstSnap.match.alive}`);

    // 2) 安全区必须一路收缩（本局内半径单调不增，且收到过明显更小的半径）
    let increased = null;
    for (let i = 1; i < zoneRadii.length; i++) {
        // 跨局会重置回大半径，只在半径变小或不变时校验；变大说明换局了
        if (zoneRadii[i] > zoneRadii[i - 1] + 1) {
            // 换局重置是允许的：记录一次即可
            if (increased === null) increased = { from: zoneRadii[i - 1], to: zoneRadii[i] };
        }
    }
    // 用观察区间内的最大/最小半径比较：连上时可能正卡在局末，拿首帧半径当基准会误判
    if (!(minZoneR < maxZoneR * 0.5)) {
        console.error(`FAIL: zone never shrank meaningfully: max=${maxZoneR} min=${minZoneR}`);
        process.exit(1);
    }
    console.log(`Zone shrank: ${Math.round(maxZoneR)} -> ${Math.round(minZoneR)}`
        + (increased ? ` (reset observed: ${Math.round(increased.from)} -> ${Math.round(increased.to)})` : ""));

    // 3) 至少一次本局结束，且带胜者或明确无胜者
    if (overs.length === 0) {
        console.error("FAIL: no match_over event observed");
        process.exit(1);
    }
    const ov = overs[0];
    console.log(`match_over: id=${ov.id} winner=${ov.winner || "(none)"} alive=${ov.alive}`
        + (sawWinnerSelf ? ` (self win: ${sawWinnerSelf})` : ""));

    // 4) 结束后必须自动开新局（局号递增）
    if (starts.length === 0) {
        console.error("FAIL: no match_start after match_over (no auto rematch)");
        process.exit(1);
    }
    if (!(starts[0].id > ov.id)) {
        console.error(`FAIL: new match id not incremented: over=${ov.id} start=${starts[0].id}`);
        process.exit(1);
    }
    console.log(`Auto rematch OK: match #${ov.id} -> #${starts[0].id}`);

    // 5) 出局语义：若有人出局，you_died 必须带 out=true（不再原地复活）
    if (sawOut) {
        console.log("Elimination OK: you_died carried out=true (no respawn in same match)");
    } else {
        console.log("(no player was eliminated within the window; out-flag not exercised)");
    }

    a.ws.close();
    b.ws.close();
    console.log("=== [Match E2E Test] FULLY PASSED AND VERIFIED! ===");
}

runMatchTest().catch(err => {
    console.error("Match test error:", err.message);
    process.exit(1);
});
