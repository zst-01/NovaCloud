package lab;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.HexFormat;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.gateway.filter.*;
import org.springframework.cloud.gateway.route.Route;
import org.springframework.core.Ordered;
import org.springframework.http.*;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;
import static org.springframework.cloud.gateway.support.ServerWebExchangeUtils.GATEWAY_ROUTE_ATTR;

@Component
class RateLimitFilter implements GlobalFilter, Ordered {
    private final RedisWindowLimiter limiter;
    private final int loginLimit, ticketLimit;
    private final Duration loginWindow, ticketWindow;
    RateLimitFilter(RedisWindowLimiter limiter,
            @Value("${lab.rate.login.limit:10}") int loginLimit,
            @Value("${lab.rate.login.window-seconds:30}") int loginSeconds,
            @Value("${lab.rate.tickets.limit:20}") int ticketLimit,
            @Value("${lab.rate.tickets.window-seconds:10}") int ticketSeconds) {
        if (loginLimit < 1 || ticketLimit < 1 || loginSeconds < 1 || ticketSeconds < 1) {
            throw new IllegalArgumentException("Rate limits and windows must be positive");
        }
        this.limiter = limiter;
        this.loginLimit = loginLimit;
        this.ticketLimit = ticketLimit;
        this.loginWindow = Duration.ofSeconds(loginSeconds);
        this.ticketWindow = Duration.ofSeconds(ticketSeconds);
    }
    @Override public int getOrder() { return -5; }
    @Override public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        Route route = exchange.getAttribute(GATEWAY_ROUTE_ATTR);
        if (route == null) return chain.filter(exchange);
        boolean login = route.getId().equals("app-login");
        if (!login && !route.getId().equals("app-tickets")) return chain.filter(exchange);
        String identity = login ? clientAddress(exchange) : exchange.getAttribute("lab.auth.username");
        if (identity == null || identity.isBlank()) return reject(exchange, 503, 0);
        String key = key(login ? "login" : "tickets", identity);
        // 异常映射仅包围 Redis 操作，不吞掉下游业务错误。
        return limiter.acquire(key, login ? loginLimit : ticketLimit, login ? loginWindow : ticketWindow)
            .map(decision -> new Result(decision.allowed() ? 200 : 429, decision.retryAfterSeconds()))
            .onErrorReturn(new Result(503, 0))
            .flatMap(result -> result.status() == 200 ? chain.filter(exchange)
                : reject(exchange, result.status(), result.retryAfterSeconds()));
    }
    private String clientAddress(ServerWebExchange exchange) {
        // 只有 Nginx 作为对外入口；它覆盖客户端头。Docker 内网视为受信任代理网络。
        String supplied = exchange.getRequest().getHeaders().getFirst("X-Lab-Client-IP");
        if (supplied != null && supplied.matches("[0-9a-fA-F:.]{1,64}")) return supplied;
        var remote = exchange.getRequest().getRemoteAddress();
        return remote == null || remote.getAddress() == null ? null : remote.getAddress().getHostAddress();
    }
    static String key(String kind, String identity) {
        try {
            return "lab:rate:" + kind + ":" + HexFormat.of().formatHex(
                MessageDigest.getInstance("SHA-256").digest(identity.getBytes(StandardCharsets.UTF_8)));
        } catch (java.security.NoSuchAlgorithmException e) { throw new IllegalStateException(e); }
    }
    private Mono<Void> reject(ServerWebExchange exchange, int status, long retry) {
        var response = exchange.getResponse();
        response.setStatusCode(HttpStatus.valueOf(status));
        response.getHeaders().setContentType(MediaType.APPLICATION_JSON);
        response.getHeaders().setCacheControl("no-store");
        if (status == 429) response.getHeaders().set("Retry-After", Long.toString(retry));
        String json = status == 429 ? "{\"error\":\"rate_limited\",\"retryAfter\":"+retry+"}"
            : "{\"error\":\"rate_limit_unavailable\"}";
        return response.writeWith(Mono.just(response.bufferFactory().wrap(json.getBytes(StandardCharsets.UTF_8))));
    }
    private record Result(int status, long retryAfterSeconds) {}
}
