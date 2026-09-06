package lab;

import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.redis.connection.RedisStandaloneConfiguration;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

@EnabledIfEnvironmentVariable(named = "REDIS_INTEGRATION", matches = "true")
class RedisIntegrationTest {
    @Test void realRedisStoresValueAndExpiresIt() {
        var config = new RedisStandaloneConfiguration(System.getenv("REDIS_HOST"), 6379);
        config.setPassword(System.getenv("REDIS_PASSWORD"));
        var factory = new LettuceConnectionFactory(config);
        factory.afterPropertiesSet();
        factory.start();
        var redis = new StringRedisTemplate(factory);
        String key = "lab:verify:" + UUID.randomUUID();
        try {
            redis.opsForValue().set(key, "java-redis-ok", Duration.ofSeconds(2));
            assertThat(redis.opsForValue().get(key)).isEqualTo("java-redis-ok");
            assertThat(redis.getExpire(key, TimeUnit.MILLISECONDS)).isBetween(1L, 2000L);
            await().atMost(Duration.ofSeconds(5)).pollInterval(Duration.ofMillis(100))
                .until(() -> Boolean.FALSE.equals(redis.hasKey(key)));
            assertThat(redis.opsForValue().get(key)).isNull();
        } finally {
            try { redis.delete(key); } finally { factory.destroy(); }
        }
    }
}
