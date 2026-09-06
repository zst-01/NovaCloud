package lab;

import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.web.server.WebFilter;
import reactor.core.publisher.Mono;

@Configuration
class RequestLog {
    private static final Logger log = LoggerFactory.getLogger(RequestLog.class);
    private static final Pattern TRACE_ID = Pattern.compile("[0-9a-f]{32}");

    @Bean
    @Order(Ordered.HIGHEST_PRECEDENCE)
    WebFilter requestLoggingFilter() {
        return (exchange, chain) -> {
            if (exchange.getRequest().getPath().value().startsWith("/actuator/")) {
                return chain.filter(exchange);
            }
            String supplied = exchange.getRequest().getHeaders().getFirst("X-Trace-Id");
            String traceId = supplied != null && TRACE_ID.matcher(supplied).matches()
                ? supplied : UUID.randomUUID().toString().replace("-", "");
            long start = System.nanoTime();
            // 响应式请求可能跨线程：编号保存在当前请求的局部变量中，不放入线程 MDC。
            var request = exchange.getRequest().mutate()
                .headers(headers -> headers.set("X-Trace-Id", traceId)).build();
            exchange.getResponse().beforeCommit(() -> Mono.fromRunnable(() -> {
                exchange.getResponse().getHeaders().set("X-Trace-Id", traceId);
                int status = exchange.getResponse().getStatusCode() == null
                    ? 200 : exchange.getResponse().getStatusCode().value();
                log.info("request_complete traceId={} method={} path={} status={} durationMs={}",
                    traceId, request.getMethod(), request.getURI().getRawPath(), status,
                    TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start));
            }));
            return chain.filter(exchange.mutate().request(request).build());
        };
    }
}
