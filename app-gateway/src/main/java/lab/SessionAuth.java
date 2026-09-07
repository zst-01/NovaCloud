package lab;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.data.redis.core.ReactiveStringRedisTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.server.*;
import reactor.core.publisher.Mono;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 1)
class SessionAuth implements WebFilter {
    private final ReactiveStringRedisTemplate redis;
    private final ObjectMapper mapper;
    SessionAuth(ReactiveStringRedisTemplate redis, ObjectMapper mapper) { this.redis = redis; this.mapper = mapper; }
    @Override public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        String path = exchange.getRequest().getPath().value();
        // 默认校验，避免编码路径、矩阵参数或新增路由绕过保护。
        boolean publicPath = path.equals("/actuator/health")
            || (path.equals("/api/auth/login") && exchange.getRequest().getMethod() == org.springframework.http.HttpMethod.POST);
        var request = exchange.getRequest().mutate().headers(headers -> {
            headers.remove("X-User-Id"); headers.remove("X-User-Name"); headers.remove("X-User-Roles");
        }).build();
        var clean = exchange.mutate().request(request).build();
        if (publicPath) return chain.filter(clean);
        var values = request.getHeaders().get("Authorization");
        if (values == null || values.size() != 1 || !values.get(0).matches("(?i:Bearer) [0-9a-f]{64}")) {
            return reject(clean, 401);
        }
        String token = values.get(0).substring(7);
        // 先完成会话判断，再调用下游；下游业务异常不误报成 Redis 故障。
        return redis.opsForValue().get("lab:session:" + token)
            .map(value -> {
                try {
                    var user = mapper.readTree(value);
                    if (!user.path("username").isTextual() || !user.path("permissions").isArray()) return 503;
                    // 服务端会话中的主键，仅放到本次 exchange 属性，不接受客户端身份头。
                    clean.getAttributes().put("lab.auth.username", user.path("username").asText());
                    if (path.equals("/api/auth/me") || path.equals("/api/auth/logout")) return 200;
                    for (var permission : user.path("permissions")) if (permission.asText().equals("ticket:read")) return 200;
                    return 403;
                } catch (java.io.IOException e) { return 503; }
            }).defaultIfEmpty(401).onErrorReturn(503)
            .flatMap(status -> status == 200 ? chain.filter(clean) : reject(clean, status));
    }
    private Mono<Void> reject(ServerWebExchange exchange, int status) {
        var response = exchange.getResponse();
        response.setStatusCode(HttpStatus.valueOf(status));
        response.getHeaders().setContentType(MediaType.APPLICATION_JSON);
        response.getHeaders().setCacheControl("no-store");
        if (status == 401) response.getHeaders().set("WWW-Authenticate", "Bearer");
        String error = status == 401 ? "unauthorized" : status == 403 ? "forbidden" : "session_unavailable";
        return response.writeWith(Mono.just(response.bufferFactory().wrap(
            ("{\"error\":\"" + error + "\"}").getBytes(java.nio.charset.StandardCharsets.UTF_8))));
    }
}
