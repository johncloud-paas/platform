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

-- Build a human-readable message for a Suricata eve.json record. Only `alert`
-- events carry `alert.signature`; flow/dns/http/tls/stats/etc. do not, so a bare
-- _msg_field=alert.signature leaves most events with an empty message. Pick the
-- most descriptive field available per event_type, always falling back to
-- event_type so _msg is never empty.
function suricata_message(tag, timestamp, record)
    local et = record["event_type"]
    local msg

    local alert = record["alert"]
    if type(alert) == "table" and alert["signature"] then
        msg = alert["signature"]
    elseif et == "dns" and type(record["dns"]) == "table" and record["dns"]["rrname"] then
        msg = "dns " .. tostring(record["dns"]["rrname"])
    elseif et == "http" and type(record["http"]) == "table" then
        local h = record["http"]
        msg = "http " .. tostring(h["http_method"] or "") .. " " .. tostring(h["hostname"] or "") .. tostring(h["url"] or "")
    elseif et == "tls" and type(record["tls"]) == "table" then
        msg = "tls " .. tostring(record["tls"]["sni"] or record["tls"]["subject"] or "")
    elseif et then
        msg = tostring(et)
    else
        msg = "suricata event"
    end

    record["event_msg"] = msg
    return 2, timestamp, record
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
