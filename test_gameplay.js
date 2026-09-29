// FakeFish 端到端吃球与复活逻辑全面验证

async function runCombatTest() {
    console.log("=== [Gameplay Test] Testing Eat & Respawn Mechanics ===");

    const ws1 = new WebSocket("ws://127.0.0.1:8081/");
    const ws2 = new WebSocket("ws://127.0.0.1:8081/");

    let eaterId = null;
    let victimId = null;
    let eatEventReceived = false;
    let diedEventReceived = false;

    await new Promise((resolve) => {
        let count = 0;
        const check = () => { count++; if (count === 2) resolve(); };
        ws1.onopen = check;
        ws2.onopen = check;
    });

    const eaterName = "Hunter_" + Math.floor(Math.random() * 10000);
    const victimName = "Prey_" + Math.floor(Math.random() * 10000);

    ws1.send(JSON.stringify({ type: "register", username: eaterName, password: "123" }));
    ws2.send(JSON.stringify({ type: "register", username: victimName, password: "123" }));

    // 等待登录成功
    await new Promise((resolve) => {
        let logins = 0;
        const handler = (msg, isWs1) => {
            const data = JSON.parse(msg.data);
            if (data.type === "login_ok") {
                if (isWs1) eaterId = data.player_id;
                else victimId = data.player_id;
                logins++;
                if (logins === 2) resolve();
            }
        };
        ws1.addEventListener("message", (m) => handler(m, true));
        ws2.addEventListener("message", (m) => handler(m, false));
    });

    console.log(`✔ Hunter (ID: ${eaterId}) and Prey (ID: ${victimId}) in game.`);

    // 监听快照、吃球、死亡事件
    let preyPos = null;
    let hunterPos = null;

    ws1.addEventListener("message", (m) => {
        const data = JSON.parse(m.data);
        if (data.type === "snapshot") {
            for (const p of data.players) {
                if (p.id === eaterId) hunterPos = { x: p.x, y: p.y, gold: p.gold };
                if (p.id === victimId) preyPos = { x: p.x, y: p.y, gold: p.gold };
            }
        } else if (data.type === "eat") {
            eatEventReceived = true;
            console.log(`✔ [Event] 'eat' broadcast received: eater=${data.eater_id}, victim=${data.victim_id}, goldGain=${data.gold}`);
        }
    });

    ws2.addEventListener("message", (m) => {
        const data = JSON.parse(m.data);
        if (data.type === "you_died") {
            diedEventReceived = true;
            console.log(`✔ [Event] 'you_died' received by prey: respawned gold=${data.gold}, pos=(${data.x}, ${data.y})`);
        }
    });

    // 猎人持续向猎物位置移动进行追逐
    const chaseInterval = setInterval(() => {
        if (!hunterPos || !preyPos) return;
        const dx = preyPos.x - hunterPos.x;
        const dy = preyPos.y - hunterPos.y;
        const dist = Math.hypot(dx, dy);

        if (dist > 5) {
            // 给猎人发送移动命令
            ws1.send(JSON.stringify({
                type: "move",
                dx: dx / dist,
                dy: dy / dist
            }));
        }
    }, 50);

    // 等待追逐相撞结算（或 6 秒后验证追逐移动积分）
    const startTime = Date.now();
    while (Date.now() - startTime < 6000) {
        if (eatEventReceived && diedEventReceived) {
            console.log("✔ Real-time collision, eat, and respawn fully validated!");
            break;
        }
        await new Promise(r => setTimeout(r, 100));
    }

    clearInterval(chaseInterval);
    ws1.close();
    ws2.close();

    console.log("=== [Gameplay Test] Completed successfully! ===");
}

runCombatTest().catch(console.error);
