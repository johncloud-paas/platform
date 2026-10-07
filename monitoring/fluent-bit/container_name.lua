local name_cache = {}

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
    return 1, timestamp, record
end
