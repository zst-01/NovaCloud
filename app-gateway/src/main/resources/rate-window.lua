-- 单个 key 的固定窗口；达到上限后不再加计数，不延长 TTL。
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local ttl = redis.call('PTTL', KEYS[1])
if ttl < 0 then
    redis.call('SET', KEYS[1], 1, 'PX', window)
    return 0
end
local count = tonumber(redis.call('GET', KEYS[1]))
if count >= limit then
    return math.max(ttl, 1)
end
redis.call('INCR', KEYS[1])
return 0
