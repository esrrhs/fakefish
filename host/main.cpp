#include "fakelua.h"
#include <iostream>
#include <string>
#include <vector>
#include <filesystem>

using namespace fakelua;

int main(int argc, char **argv) {
    std::string config_path = "config.yaml";
    std::string script_path = "server/main.lua";
    int jit_type = static_cast<int>(JIT_GCC);

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg.rfind("--config=", 0) == 0) {
            config_path = arg.substr(9);
        } else if (arg.rfind("--script=", 0) == 0) {
            script_path = arg.substr(9);
        } else if (arg.rfind("--jit=", 0) == 0) {
            jit_type = std::stoi(arg.substr(6));
        } else if (arg == "--help" || arg == "-h") {
            std::cout << "FakeFish Game Server\n"
                      << "Usage: " << argv[0] << " [options]\n"
                      << "Options:\n"
                      << "  --config=FILE   Path to configuration YAML (default: config.yaml)\n"
                      << "  --script=FILE   Path to entry Lua script (default: server/main.lua)\n"
                      << "  --jit=TYPE      JIT type (0=TCC, 1=GCC, 2=Interp, default: 1)\n"
                      << "  --help, -h      Show this help message\n";
            return 0;
        }
    }

    std::cout << "[FakeFish] Starting with config: " << config_path 
              << ", script: " << script_path << std::endl;

    const FakeluaStateGuard guard;
    const auto s = guard.GetState();
    if (!s) {
        std::cerr << "[FakeFish] Failed to initialize FakeLua State!" << std::endl;
        return 1;
    }

    CompileConfig cfg;
    cfg.debug_mode = false;
    cfg.disable_jit[JIT_TCC] = true;

    // 按依赖顺序预编译各核心逻辑模块
    const std::vector<std::string> module_files = {
        "server/config.lua",
        "server/combat.lua",
        "server/db.lua",
        "server/auth.lua",
        "server/world.lua",
        "server/net_ws.lua",
        "server/http_static.lua",
        script_path
    };

    for (const auto &file : module_files) {
        try {
            CompileFile(s, file, cfg);
        } catch (const std::exception &e) {
            std::cerr << "[FakeFish] Failed to compile script " << file 
                      << ": " << e.what() << std::endl;
            return 1;
        }
    }

    int code = 0;
    try {
        Call(s, static_cast<JITType>(jit_type), "Main.start", code, config_path);
    } catch (const std::exception &e) {
        std::cerr << "[FakeFish] Runtime exception during Main.start: " << e.what() << std::endl;
        return 1;
    }

    std::cout << "[FakeFish] Server exited with code: " << code << std::endl;
    return code;
}
