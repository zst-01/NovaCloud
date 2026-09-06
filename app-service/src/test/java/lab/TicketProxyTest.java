package lab;
import java.net.SocketTimeoutException;
import org.junit.jupiter.api.*;
import org.springframework.http.*;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.*;
class TicketProxyTest {
    MockRestServiceServer server;
    TicketProxy proxy;
    @BeforeEach void setup() {
        var builder = RestClient.builder().baseUrl("http://platform-gateway:8080");
        server = MockRestServiceServer.bindTo(builder).build();
        proxy = new TicketProxy(builder.build());
    }
    @AfterEach void verify() { server.verify(); }
    @Test void forwardsBodyAndHopHeaders() {
        server.expect(requestTo("http://platform-gateway:8080/api/tickets/1"))
            .andRespond(withSuccess("{\"id\":1}", MediaType.APPLICATION_JSON).header("X-Lab-Platform-Service", "visited"));
        var response = proxy.get(1);
        assertThat(response.getStatusCode().value()).isEqualTo(200);
        assertThat(response.getBody()).isEqualTo("{\"id\":1}");
        assertThat(response.getHeaders().getFirst("X-Lab-Platform-Service")).isEqualTo("visited");
    }
    @Test void preservesNotFound() {
        server.expect(requestTo("http://platform-gateway:8080/api/tickets/9"))
            .andRespond(withStatus(HttpStatus.NOT_FOUND).body("{\"error\":\"ticket_not_found\"}"));
        var response = proxy.get(9);
        assertThat(response.getStatusCode().value()).isEqualTo(404);
        assertThat(response.getBody()).contains("ticket_not_found");
    }
    @Test void connectionFailureIs502() {
        server.expect(requestTo("http://platform-gateway:8080/api/tickets/1"))
            .andRespond(withException(new java.net.ConnectException("refused")));
        assertThat(proxy.get(1).getStatusCode().value()).isEqualTo(502);
    }
    @Test void timeoutIs504() {
        server.expect(requestTo("http://platform-gateway:8080/api/tickets/1"))
            .andRespond(withException(new SocketTimeoutException("timeout")));
        assertThat(proxy.get(1).getStatusCode().value()).isEqualTo(504);
    }
}
