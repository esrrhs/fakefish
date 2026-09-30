// FakeFish 金币雨（feast）世界事件 E2E 测试
// 依赖 CI 将 feast_interval_s 调快至 12s；本地调试可临时调低间隔
const WebSocket = require('ws');

async function runFeastTest() {
    console.log("=== [Feast E2E Test] Starting Gold Rain Event Test ===");

    const ws = new WebSocket("ws://127.0.0.1:8081/");

    let playerId = null;
    let feastEvent = null;
    let lastSnap = null;

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

    const name = "FeastTest_" + Math.floor(Math.random() * 10000);
    ws.send(JSON.stringify({ type: "register", username: name, password: "123" }));
    await loginOk;
    console.log(`Player ${name} (ID: ${playerId}) logged in.`);

    const pingTimer = setInterval(() => ws.send(JSON.stringify({ type: "ping" })), 3000);

    ws.addEventListener("message", (m) => {
        const d = JSON.parse(m.data);
        if (d.type === "snapshot") {
            lastSnap = d;
        } else if (d.type === "feast") {
            feastEvent = d;
        }
    });

    // 等待金币雨事件（间隔 12s，45s 预算足够覆盖 2-3 次）
    console.log("Waiting for a feast event...");
    const t0 = Date.now();
    while (Date.now() - t0 < 45000 && feastEvent === null) {
        await new Promise(r => setTimeout(r, 100));
    }
    if (feastEvent === null) {
        console.error("FAIL: no feast event received within 45s");
        process.exit(1);
    }
    if (typeof feastEvent.x !== "number" || typeof feastEvent.y !== "number" || feastEvent.count !== 30) {
        console.error("FAIL: malformed feast event: " + JSON.stringify(feastEvent));
        process.exit(1);
    }
    console.log(`Feast received: (${Math.round(feastEvent.x)}, ${Math.round(feastEvent.y)}) +${feastEvent.count} pellets`);

    // 事件后快照的金币豆数量应明显超过基础 80
    let foodsAfter = 0;
    const t1 = Date.now();
    while (Date.now() - t1 < 5000) {
        if (lastSnap && lastSnap.foods && lastSnap.foods.length > 80) {
            foodsAfter = lastSnap.foods.length;
            break;
        }
        await new Promise(r => setTimeout(r, 100));
    }
    clearInterval(pingTimer);

    if (foodsAfter <= 80) {
        console.error("FAIL: foods count did not grow after feast (got " + foodsAfter + ")");
        process.exit(1);
    }
    console.log(`Snapshot foods after feast: ${foodsAfter} (> 80 base)`);

    ws.close();
    console.log("=== [Feast E2E Test] FULLY PASSED AND VERIFIED! ===");
}

runFeastTest().catch(err => {
    console.error("Feast test error:", err.message);
    process.exit(1);
});
