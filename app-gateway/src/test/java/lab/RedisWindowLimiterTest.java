package lab;

import java.time.Duration;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.redis.connection.RedisStandaloneConfiguration;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;
import org.springframework.data.redis.core.ReactiveStringRedisTemplate;
import reactor.core.publisher.Flux;
import static org.assertj.core.api.Assertions.*;
import static org.awaitility.Awaitility.await;

@EnabledIfEnvironmentVariable(named="REDIS_INTEGRATION", matches="true")
class RedisWindowLimiterTest {
    LettuceConnectionFactory factory;
    ReactiveStringRedisTemplate redis;
    String key;
    @BeforeEach void setup() {
        var config = new RedisStandaloneConfiguration(System.getenv("REDIS_HOST"), 6379);
        config.setPassword(System.getenv("REDIS_PASSWORD"));
        factory = new LettuceConnectionFactory(config);
        factory.afterPropertiesSet();
        factory.start();
        redis = new ReactiveStringRedisTemplate(factory);
        key = "lab:verify:rate:" + UUID.randomUUID();
    }
    @AfterEach void cleanup() {
        try { redis.delete(key, key+":other").block(); } finally { factory.destroy(); }
    }
    @Test void concurrentLimiterInstancesShareOneAtomicQuota() {
        var first = new RedisWindowLimiter(redis);
        var second = new RedisWindowLimiter(redis);
        var results = Flux.range(0,60).flatMap(i ->
            (i % 2 == 0 ? first : second).acquire(key, 10, Duration.ofSeconds(10)), 30).collectList().block();
        assertThat(results).filteredOn(r -> r.allowed()).hasSize(10);
        assertThat(results).filteredOn(r -> !r.allowed()).hasSize(50);
        assertThat(redis.opsForValue().get(key).block()).isEqualTo("10");
        assertThat(second.acquire(key+":other",10,Duration.ofSeconds(10)).block().allowed()).isTrue();
    }
    @Test void rejectionsDoNotExtendWindowAndExpiryRestoresQuota() throws Exception {
        var limiter = new RedisWindowLimiter(redis);
        assertThat(limiter.acquire(key,1,Duration.ofSeconds(2)).block().allowed()).isTrue();
        long before = redis.getExpire(key).block().toMillis();
        Thread.sleep(150);
        var blocked = limiter.acquire(key,1,Duration.ofSeconds(2)).block();
        assertThat(blocked.allowed()).isFalse();
        assertThat(blocked.retryAfterSeconds()).isBetween(1L,2L);
        assertThat(redis.getExpire(key).block().toMillis()).isLessThan(before);
        await().atMost(Duration.ofSeconds(4)).until(() -> !Boolean.TRUE.equals(redis.hasKey(key).block()));
        assertThat(limiter.acquire(key,1,Duration.ofSeconds(2)).block().allowed()).isTrue();
    }
}
