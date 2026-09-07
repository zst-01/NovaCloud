package lab;

import java.time.Duration;
import java.util.List;
import org.springframework.core.io.ClassPathResource;
import org.springframework.data.redis.core.ReactiveStringRedisTemplate;
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Mono;

@Component
class RedisWindowLimiter {
    record Decision(boolean allowed, long retryAfterSeconds) {}
    private final ReactiveStringRedisTemplate redis;
    private final DefaultRedisScript<Long> script;
    RedisWindowLimiter(ReactiveStringRedisTemplate redis) {
        this.redis = redis;
        script = new DefaultRedisScript<>();
        script.setLocation(new ClassPathResource("rate-window.lua"));
        script.setResultType(Long.class);
    }
    Mono<Decision> acquire(String key, int limit, Duration window) {
        if (limit < 1 || window.toMillis() < 1) return Mono.error(new IllegalArgumentException("Invalid rate limit"));
        return redis.execute(script, List.of(key), List.of(Integer.toString(limit), Long.toString(window.toMillis())))
            .single().map(ttl -> new Decision(ttl == 0, ttl == 0 ? 0 : (ttl + 999) / 1000));
    }
}
