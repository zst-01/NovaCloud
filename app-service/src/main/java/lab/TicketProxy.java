package lab;
import java.net.SocketTimeoutException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.*;
@RestController
class TicketProxy {
    private static final Logger log = LoggerFactory.getLogger(TicketProxy.class);
    private final RestClient client;
    TicketProxy(RestClient client) { this.client = client; }
    @GetMapping("/api/tickets/{id}")
    ResponseEntity<String> get(@PathVariable long id) {
        log.info("App service forwarding ticket {} to configured platform gateway URL", id);
        try {
            var upstream = client.get().uri("/api/tickets/{id}", id).retrieve().toEntity(String.class);
            return reply(upstream.getStatusCode(), upstream.getHeaders(), upstream.getBody());
        } catch (RestClientResponseException e) {
            return reply(e.getStatusCode(), e.getResponseHeaders(), e.getResponseBodyAsString());
        } catch (ResourceAccessException e) {
            boolean timeout = e.getMostSpecificCause() instanceof SocketTimeoutException;
            return reply(timeout ? HttpStatus.GATEWAY_TIMEOUT : HttpStatus.BAD_GATEWAY, null,
                timeout ? "{\"error\":\"platform_timeout\"}" : "{\"error\":\"platform_unavailable\"}");
        }
    }
    private ResponseEntity<String> reply(HttpStatusCode status, HttpHeaders upstream, String body) {
        var headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.set("X-Lab-App-Service", "visited");
        if (upstream != null) {
            for (String name : new String[]{"X-Lab-Platform-Gateway", "X-Lab-Platform-Service"}) {
                if (upstream.containsKey(name)) headers.put(name, upstream.get(name));
            }
        }
        return new ResponseEntity<>(body, headers, status);
    }
}
