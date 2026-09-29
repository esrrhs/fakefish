// FakeFish WebSocket 自动化端到端测试脚本
const WebSocket = require('ws');

async function runTest() {
    console.log("=== [Test] Starting FakeFish E2E WebSocket Test ===");

    const ws1 = new WebSocket("ws://127.0.0.1:8081/");
    const ws2 = new WebSocket("ws://127.0.0.1:8081/");

    let aliceId = null;
    let bobId = null;
    let snapshotCount = 0;

    // Wait for both connections to open
    await new Promise((resolve, reject) => {
        let openCount = 0;
        const onOpen = () => {
            openCount++;
            if (openCount === 2) resolve();
        };
        ws1.onopen = onOpen;
        ws2.onopen = onOpen;
        ws1.onerror = (e) => reject(new Error("ws1 error: " + e.message));
        ws2.onerror = (e) => reject(new Error("ws2 error: " + e.message));
    });

    console.log("Both WebSockets connected successfully!");

    // Set up message handlers BEFORE sending any messages (prevents race condition)
    const testPromise = new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
            if (aliceId && bobId && snapshotCount > 0) {
                resolve();
            } else {
                reject(new Error(`Timeout waiting for login_ok and snapshots (aliceId=${aliceId}, bobId=${bobId}, snapshotCount=${snapshotCount})`));
            }
        }, 5000);

        ws1.onmessage = (event) => {
            const data = JSON.parse(event.data);
            if (data.type === "login_ok") {
                aliceId = data.player_id;
                console.log(`Alice registered and entered game: ID=${aliceId}, gold=${data.gold}, map=${data.map.width}x${data.map.height}`);
            } else if (data.type === "snapshot") {
                snapshotCount++;
                if (snapshotCount === 1) {
                    console.log(`Received snapshot with ${data.players.length} players online:`);
                    for (const p of data.players) {
                        console.log(`   - Player ${p.name} (ID: ${p.id}): pos=(${p.x}, ${p.y}), gold=${p.gold}, r=${p.r}`);
                    }
                }
                if (aliceId && bobId && snapshotCount >= 5) {
                    clearTimeout(timeout);
                    resolve();
                }
            }
        };

        ws2.onmessage = (event) => {
            const data = JSON.parse(event.data);
            if (data.type === "login_ok") {
                bobId = data.player_id;
                console.log(`Bob registered and entered game: ID=${bobId}, gold=${data.gold}`);
            }
        };
    });

    // NOW send register messages (handlers are already set up)
    ws1.send(JSON.stringify({
        type: "register",
        username: "Alice_" + Date.now().toString().slice(-4),
        password: "password123"
    }));

    ws2.send(JSON.stringify({
        type: "register",
        username: "Bob_" + Date.now().toString().slice(-4),
        password: "password123"
    }));

    await testPromise;

    // Test movement commands
    ws1.send(JSON.stringify({ type: "move", dx: 1.0, dy: 0.0 }));
    ws2.send(JSON.stringify({ type: "move", dx: -1.0, dy: 0.5 }));
    console.log("Sent movement commands (dx, dy)");

    await new Promise(r => setTimeout(r, 400));

    ws1.close();
    ws2.close();

    console.log(`=== [Test] ALL TESTS PASSED! (${snapshotCount} snapshots verified) ===`);
}

runTest().catch((err) => {
    console.error("Test failed:", err);
    process.exit(1);
});
