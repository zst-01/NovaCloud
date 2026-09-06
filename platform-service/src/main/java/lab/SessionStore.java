package lab;

import java.security.SecureRandom;
import java.time.Duration;
import java.util.HexFormat;
import java.util.List;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

@Service
class SessionStore {
    static final Duration TTL = Duration.ofMinutes(30);
    record User(String username, List<String> permissions) {}
    private final StringRedisTemplate redis;
    private final ObjectMapper mapper;
    private final SecureRandom random = new SecureRandom();
    SessionStore(StringRedisTemplate redis, ObjectMapper mapper) { this.redis = redis; this.mapper = mapper; }
    static String token(String authorization) {
        return authorization != null && authorization.matches("(?i:Bearer) [0-9a-f]{64}")
            ? authorization.substring(7) : null;
    }
    String create(User user) {
        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        String token = HexFormat.of().formatHex(bytes);
        try {
            redis.opsForValue().set("lab:session:" + token, mapper.writeValueAsString(user), TTL);
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) { throw new IllegalStateException(e); }
        return token;
    }
    User find(String token) {
        if (token == null) return null;
        String value = redis.opsForValue().get("lab:session:" + token);
        if (value == null) return null;
        try { return mapper.readValue(value, User.class); }
        catch (com.fasterxml.jackson.core.JsonProcessingException e) { throw new IllegalStateException("Invalid session data", e); }
    }
    void delete(String token) { redis.delete("lab:session:" + token); }
}
