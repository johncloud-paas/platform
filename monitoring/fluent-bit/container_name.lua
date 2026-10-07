function extract_container_name(tag, timestamp, record)
    local container_name = tag:match("docker%.([^.]+)")
    if container_name then
        record["container_name"] = container_name
    end
    return 1, timestamp, record
end
