package lab;
import java.net.InetSocketAddress;
import java.util.concurrent.atomic.AtomicReference;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;
import static org.assertj.core.api.Assertions.assertThat;
class PlatformClientTraceTest {
    @Test void realClientForwardsCurrentTraceWithoutRetainingItForNextRequest() throws Exception {
        var received = new AtomicReference<String>();
        var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/api/tickets/1", exchange -> {
            received.set(exchange.getRequestHeaders().getFirst("X-Trace-Id"));
            exchange.sendResponseHeaders(200, 2);
            exchange.getResponseBody().write("{}".getBytes());
            exchange.close();
        });
        server.start();
        try {
            var client = new PlatformClient().platformRestClient("http://127.0.0.1:" + server.getAddress().getPort());
            String trace = "0123456789abcdef0123456789abcdef";
            MDC.put("traceId", trace);
            client.get().uri("/api/tickets/1").retrieve().toBodilessEntity();
            assertThat(received.get()).isEqualTo(trace);
            MDC.remove("traceId");
            client.get().uri("/api/tickets/1").retrieve().toBodilessEntity();
            assertThat(received.get()).isNull();
        } finally {
            MDC.clear();
            server.stop(0);
        }
    }
}
