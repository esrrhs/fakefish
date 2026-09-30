// FakeFish 动态安全区（收缩毒圈）E2E 测试
// 依赖 CI 将 zone_shrink_interval_s 调快至 12s、zone_hold_s 调至 6s；本地调试可临时调低
const WebSocket = require('ws');

async function runZoneTest() {
    console.log("=== [Zone E2E Test] Starting Shrinking Safe-Zone Test ===");

    const ws = new WebSocket("ws://127.0.0.1:8081/");

    let playerId = null;
    let lastSnap = null;
    const zoneEvents = [];
    let wasOutside = false;
    let goldWhenOutside = null;
    let minGoldObserved = 100;

    const loginOk = new Promise((resolve, reject) => {
        ws.addEventListener("message", (m) => {
            const d = JSON.parse(m.data);
            if (d.type === "login_ok") {
                playerId = d.player_id;
                resolve();
            } else if (d.type === "login_fail" || d.type === "register_fail") {
                reject(new Error("auth failed: " + d.reason));
            }
        });
        ws.addEventListener("error", () => reject(new Error("ws error")));
    });

    await new Promise((resolve, reject) => {
        ws.onopen = resolve;
        ws.addEventListener("error", () => reject(new Error("connect failed")));
    });

    const name = "ZoneTest_" + Math.floor(Math.random() * 10000);
    ws.send(JSON.stringify({ type: "register", username: name, password: "123" }));
    await loginOk;
    console.log(`Player ${name} (ID: ${playerId}) logged in.`);

    const pingTimer = setInterval(() => ws.send(JSON.stringify({ type: "ping" })), 3000);

    ws.addEventListener("message", (m) => {
        const d = JSON.parse(m.data);
        if (d.type === "snapshot") {
            lastSnap = d;
            const me = d.players.find(p => p.id === playerId);
            const z = d.zone;
            if (z) {
                if (typeof z.x !== "number" || typeof z.y !== "number"
                    || typeof z.r !== "number" || z.r <= 0
                    || !Number.isInteger(z.phase) || z.phase < 0
                    || !Number.isInteger(z.next_in)) {
                    console.error("FAIL: malformed zone in snapshot: " + JSON.stringify(z));
                    process.exit(1);
                }
            }
            if (me) {
                if (me.gold < minGoldObserved) minGoldObserved = me.gold;
                if (z) {
                    const dx = me.x - z.x;
                    const dy = me.y - z.y;
                    const outside = (dx * dx + dy * dy) > z.r * z.r;
                    if (outside && !wasOutside) {
                        wasOutside = true;
                        goldWhenOutside = me.gold;
                    }
                }
            }
        } else if (d.type === "zone") {
            zoneEvents.push(d);
        }
    });

    // 观察 80s：CI 一个完整收缩-重置周期约 66s
    console.log("Observing zone shrink/reset cycle for 80s...");
    await new Promise(r => setTimeout(r, 80000));
    clearInterval(pingTimer);

    console.log(`Zone events observed: ${zoneEvents.length}, wasOutside=${wasOutside}, minGold=${minGoldObserved}`);

    // 1) 至少观察到 2 次收缩事件；同一周期内相邻收缩半径严格递减（reset 后重新起算）
    const shrinks = zoneEvents.filter(e => !e.reset);
    if (shrinks.length < 2) {
        console.error("FAIL: expected at least 2 shrink events, got " + shrinks.length);
        process.exit(1);
    }
    let prevR = null;
    const seq = [];
    for (const e of zoneEvents) {
        if (e.reset) {
            prevR = null; // 新周期：不再与上周期半径比较
        } else {
            if (prevR !== null && !(e.r < prevR)) {
                console.error("FAIL: shrink radius did not decrease within cycle: "
                    + prevR + " -> " + e.r);
                process.exit(1);
            }
            prevR = e.r;
            seq.push(Math.round(e.r));
        }
    }
    console.log(`Shrink sequence OK (per cycle): ${seq.join(" > ")}`);

    // 2) 必须观察到重置：reset 事件且半径恢复到初始值附近
    const reset = zoneEvents.find(e => e.reset);
    if (!reset) {
        console.error("FAIL: no reset event observed");
        process.exit(1);
    }
    if (reset.r < 1400) {
        console.error("FAIL: reset radius not restored, got " + reset.r);
        process.exit(1);
    }
    console.log(`Reset OK: radius restored to ${Math.round(reset.r)}`);

    // 3) 若曾处于圈外，金币必须因安全区伤害而下降
    if (wasOutside && minGoldObserved >= goldWhenOutside) {
        console.error(`FAIL: outside at gold ${goldWhenOutside} but gold never dropped (min ${minGoldObserved})`);
        process.exit(1);
    }
    if (wasOutside) {
        console.log(`Zone damage OK: gold ${goldWhenOutside} -> ${minGoldObserved}`);
    }

    ws.close();
    console.log("=== [Zone E2E Test] FULLY PASSED AND VERIFIED! ===");
}

runZoneTest().catch(err => {
    console.error("Zone test error:", err.message);
    process.exit(1);
});
