package lab;

import java.time.Duration;
import org.junit.jupiter.api.*;
import org.springframework.cloud.gateway.route.Route;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import reactor.core.publisher.Mono;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.springframework.cloud.gateway.support.ServerWebExchangeUtils.GATEWAY_ROUTE_ATTR;

class RateLimitFilterTest {
    RedisWindowLimiter limiter;
    RateLimitFilter filter;
    @BeforeEach void setup() {
        limiter = mock(RedisWindowLimiter.class);
        filter = new RateLimitFilter(limiter,10,30,20,10);
    }
    MockServerWebExchange exchange(String routeId, String path) {
        var exchange = MockServerWebExchange.from(MockServerHttpRequest.get(path)
            .header("X-Lab-Client-IP","192.0.2.1").header("X-User-Id","forged"));
        exchange.getAttributes().put(GATEWAY_ROUTE_ATTR, Route.async().id(routeId)
            .uri("http://app-service").predicate(e -> true).build());
        return exchange;
    }
    @Test void loginLimitReturns429AndRetryAfterWithoutDownstream() {
        when(limiter.acquire(anyString(),eq(10),eq(Duration.ofSeconds(30))))
            .thenReturn(Mono.just(new RedisWindowLimiter.Decision(false,12)));
        var e = exchange("app-login","/api/auth/login");
        filter.filter(e, ignored -> { fail("must not forward"); return Mono.empty(); }).block();
        assertThat(e.getResponse().getStatusCode().value()).isEqualTo(429);
        assertThat(e.getResponse().getHeaders().getFirst("Retry-After")).isEqualTo("12");
        assertThat(e.getResponse().getBodyAsString().block()).contains("rate_limited");
        verify(limiter).acquire(RateLimitFilter.key("login","192.0.2.1"),10,Duration.ofSeconds(30));
    }
    @Test void matchedRouteUsesServerVerifiedIdentityEvenForEncodedPaths() {
        var e = exchange("app-tickets","/api/%74ickets/1");
        e.getAttributes().put("lab.auth.username","demo");
        when(limiter.acquire(anyString(),anyInt(),any())).thenReturn(Mono.just(new RedisWindowLimiter.Decision(true,0)));
        var forwarded = new java.util.concurrent.atomic.AtomicBoolean();
        filter.filter(e, ignored -> { forwarded.set(true); return Mono.empty(); }).block();
        assertThat(forwarded.get()).isTrue();
        verify(limiter).acquire(RateLimitFilter.key("tickets","demo"),20,Duration.ofSeconds(10));
    }
    @Test void missingServerIdentityCannotUseSpoofedHeader() {
        var e = exchange("app-tickets","/api/tickets/1");
        filter.filter(e, ignored -> { fail("must not forward"); return Mono.empty(); }).block();
        assertThat(e.getResponse().getStatusCode().value()).isEqualTo(503);
        verifyNoInteractions(limiter);
    }
    @Test void redisFailureReturns503() {
        when(limiter.acquire(anyString(),anyInt(),any())).thenReturn(Mono.error(new IllegalStateException("offline")));
        var e = exchange("app-login","/api/auth/login");
        filter.filter(e, ignored -> { fail("must not forward"); return Mono.empty(); }).block();
        assertThat(e.getResponse().getStatusCode().value()).isEqualTo(503);
        assertThat(e.getResponse().getBodyAsString().block()).contains("rate_limit_unavailable");
    }
    @Test void authRoutesDoNotConsumeQuota() {
        filter.filter(exchange("app-auth","/api/auth/logout"), ignored -> Mono.empty()).block();
        verifyNoInteractions(limiter);
    }
    @Test void downstreamErrorsAreNotReclassifiedAsRedisFailure() {
        when(limiter.acquire(anyString(),anyInt(),any())).thenReturn(Mono.just(new RedisWindowLimiter.Decision(true,0)));
        var e = exchange("app-login","/api/auth/login");
        assertThatThrownBy(() -> filter.filter(e, ignored -> Mono.error(new IllegalArgumentException("business"))).block())
            .isInstanceOf(IllegalArgumentException.class).hasMessage("business");
    }
}
