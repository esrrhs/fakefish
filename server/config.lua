package "Config"

local config_data = {}

function load(path)
    if path == nil or path == "" then
        path = "config.yaml"
    end

    local f = io.open(path, "r")
    if not f then
        f = io.open("config.example.yaml", "r")
        if not f then
            print("[Config] Could not open config file: " .. path)
            return false
        end
        print("[Config] Loaded default fallback: config.example.yaml")
    else
        print("[Config] Loaded config file: " .. path)
    end

    local content = f:read("*a")
    f:close()

    local parsed = yaml.decode(content)
    if not parsed then
        print("[Config] YAML parse failed!")
        return false
    end

    config_data = parsed
    return true
end

function get()
    return config_data
end

function get_server()
    if config_data["server"] == nil then
        config_data["server"] = {}
    end
    return config_data["server"]
end

function get_mysql()
    if config_data["mysql"] == nil then
        config_data["mysql"] = {}
    end
    return config_data["mysql"]
end

function get_game()
    if config_data["game"] == nil then
        config_data["game"] = {}
    end
    return config_data["game"]
end
