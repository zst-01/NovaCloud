package lab;
import java.time.Duration;
import java.util.concurrent.ConcurrentHashMap;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;
import static org.assertj.core.api.Assertions.assertThat;
class TraceRequestTest {
    @Test void preservesTraceThroughRequestAndErrorResponse() {
        String trace = "0123456789abcdef0123456789abcdef";
        var exchange = MockServerWebExchange.from(MockServerHttpRequest.get("/api/tickets/9").header("X-Trace-Id", trace));
        new RequestLog().requestLoggingFilter().filter(exchange, downstream -> {
            assertThat(downstream.getRequest().getHeaders().getFirst("X-Trace-Id")).isEqualTo(trace);
            downstream.getResponse().setStatusCode(HttpStatus.NOT_FOUND);
            return downstream.getResponse().setComplete();
        }).block();
        assertThat(exchange.getResponse().getHeaders().get("X-Trace-Id")).containsExactly(trace);
    }
    @Test void replacesInvalidOrMissingTrace() {
        for (String value : new String[]{"", "bad trace", "a".repeat(100), "A".repeat(32)}) {
            var exchange = MockServerWebExchange.from(MockServerHttpRequest.get("/api/tickets/1").header("X-Trace-Id", value));
            new RequestLog().requestLoggingFilter().filter(exchange, downstream -> {
                assertThat(downstream.getRequest().getHeaders().getFirst("X-Trace-Id")).matches("[0-9a-f]{32}");
                return downstream.getResponse().setComplete();
            }).block();
            assertThat(exchange.getResponse().getHeaders().getFirst("X-Trace-Id")).matches("[0-9a-f]{32}");
        }
    }
    @Test void asynchronousRequestsKeepTheirOwnTrace() {
        var traces = ConcurrentHashMap.<String>newKeySet();
        Flux.range(1, 12).flatMap(i -> {
            String expected = String.format("%032x", i);
            var exchange = MockServerWebExchange.from(MockServerHttpRequest.get("/api/tickets/" + i).header("X-Trace-Id", expected));
            return new RequestLog().requestLoggingFilter().filter(exchange, downstream ->
                Mono.delay(Duration.ofMillis(13 - i)).then(Mono.defer(() -> {
                    assertThat(downstream.getRequest().getHeaders().getFirst("X-Trace-Id")).isEqualTo(expected);
                    return downstream.getResponse().setComplete();
                }))).doOnSuccess(ignored -> {
                    assertThat(exchange.getResponse().getHeaders().getFirst("X-Trace-Id")).isEqualTo(expected);
                    traces.add(expected);
                });
        }).blockLast();
        assertThat(traces).hasSize(12);
    }
}

