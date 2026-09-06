package lab;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.*;
import org.springframework.data.redis.core.*;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import reactor.core.publisher.Mono;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class SessionAuthTest {
    ReactiveStringRedisTemplate redis;
    ReactiveValueOperations<String,String> values;
    SessionAuth filter;
    String token = "a".repeat(64);
    @BeforeEach @SuppressWarnings("unchecked") void setup() {
        redis = mock(ReactiveStringRedisTemplate.class);
        values = mock(ReactiveValueOperations.class);
        when(redis.opsForValue()).thenReturn(values);
        filter = new SessionAuth(redis, new ObjectMapper());
    }
    MockServerWebExchange call(String path, String auth, boolean allowed) {
        var request = MockServerHttpRequest.get(path);
        if (auth != null) request.header("Authorization", auth);
        request.header("X-User-Id", "admin");
        var exchange = MockServerWebExchange.from(request);
        var reached = new java.util.concurrent.atomic.AtomicBoolean();
        filter.filter(exchange, next -> {
            reached.set(true);
            assertThat(next.getRequest().getHeaders().getFirst("X-User-Id")).isNull();
            return Mono.empty();
        }).block();
        assertThat(reached.get()).isEqualTo(allowed);
        return exchange;
    }
    @Test void missingAndMalformedTokensRejectedWithoutRedis() {
        assertThat(call("/api/tickets/1", null, false).getResponse().getStatusCode().value()).isEqualTo(401);
        assertThat(call("/api/tickets/1", "Bearer bad", false).getResponse().getStatusCode().value()).isEqualTo(401);
        verifyNoInteractions(redis);
    }
    @Test void expiredSessionRejected() {
        when(values.get(anyString())).thenReturn(Mono.empty());
        assertThat(call("/api/tickets/1", "Bearer "+token, false).getResponse().getStatusCode().value()).isEqualTo(401);
    }
    @Test void validPermissionPassesAndSpoofedIdentityRemoved() {
        when(values.get("lab:session:"+token)).thenReturn(Mono.just("{\"username\":\"demo\",\"permissions\":[\"ticket:read\"]}"));
        call("/api/tickets/1", "Bearer "+token, true);
    }
    @Test void noPermissionDeniedButOwnProfileAllowed() {
        when(values.get(anyString())).thenReturn(Mono.just("{\"username\":\"observer\",\"permissions\":[]}"));
        assertThat(call("/api/tickets/1", "Bearer "+token, false).getResponse().getStatusCode().value()).isEqualTo(403);
        call("/api/auth/me", "Bearer "+token, true);
    }
    @Test void redisFailureClosed() {
        when(values.get(anyString())).thenReturn(Mono.error(new IllegalStateException("unavailable")));
        assertThat(call("/api/tickets/1", "Bearer "+token, false).getResponse().getStatusCode().value()).isEqualTo(503);
    }
    @Test void malformedStoredSessionClosed() {
        when(values.get(anyString())).thenReturn(Mono.just("invalid"));
        assertThat(call("/api/tickets/1", "Bearer "+token, false).getResponse().getStatusCode().value()).isEqualTo(503);
    }
    @Test void onlyHealthIsPublicAndUnknownRoutesAreProtected() {
        call("/actuator/health", null, true);
        assertThat(call("/api/missing", null, false).getResponse().getStatusCode().value()).isEqualTo(401);
        verifyNoInteractions(redis);
    }
    @Test void encodedOrMatrixPathsCannotBypassPermissions() {
        when(values.get(anyString())).thenReturn(Mono.just("{\"username\":\"observer\",\"permissions\":[]}"));
        for (String path : java.util.List.of("/api/%74ickets/1", "/%61pi/tickets/1", "/api/tickets;x=y/1", "/actuator/health/../../api/tickets/1")) {
            assertThat(call(path, "Bearer "+token, false).getResponse().getStatusCode().value()).isEqualTo(403);
        }
    }
}
