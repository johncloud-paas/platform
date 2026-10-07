local name_cache = {}

local level_patterns = {
    -- JSON: "level":"info" or "level": "info"
    '"level"%s*:%s*"(%a+)"',
    -- JSON severity: "severity":"INFO"
    '"severity"%s*:%s*"(%a+)"',
    -- key=value: level=info or level="info"
    '%f[%w]level="?(%a+)"?',
    -- uppercase keyword at word boundary
    '%f[%A]([A-Z][A-Z]+)%f[%A]',
}

local level_map = {
    trace = "trace", trc = "trace",
    debug = "debug", dbg = "debug",
    info  = "info",  inf = "info", information = "info",
    warn  = "warn",  warning = "warn",
    error = "error", err = "error",
    fatal = "fatal", crit = "fatal", critical = "fatal",
}

local function extract_log_level(msg)
    if not msg then return "unknown" end
    for _, pat in ipairs(level_patterns) do
        local m = msg:match(pat)
        if m then
            local lvl = level_map[m:lower()]
            if lvl then return lvl end
        end
    end
    return "unknown"
end

function extract_container_name(tag, timestamp, record)
    -- tag: docker.var.lib.docker.containers.<hex_id>.<hex_id>-json.log
    local container_id = tag:match("containers%.(%x+)%.")
    if not container_id then
        return 1, timestamp, record
    end

    local name = name_cache[container_id]
    if not name then
        local f = io.open("/var/lib/docker/containers/" .. container_id .. "/config.v2.json", "r")
        if f then
            local content = f:read("*a")
            f:close()
            name = content:match('"Name":"/?([^"]+)"')
            if name then
                name_cache[container_id] = name
            end
        end
    end

    if name then
        record["container_name"] = name
    end

    record["log_level"] = extract_log_level(record["_msg"])

    return 1, timestamp, record
end
