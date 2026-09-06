package lab;

import java.net.SocketTimeoutException;
import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.*;

@RestController
@RequestMapping("/api/auth")
class AuthProxy {
    private final RestClient client;
    AuthProxy(RestClient client) { this.client = client; }
    @PostMapping("/login")
    ResponseEntity<String> login(@RequestBody String body) { return forward(HttpMethod.POST, "/api/auth/login", body); }
    @GetMapping("/me")
    ResponseEntity<String> me() { return forward(HttpMethod.GET, "/api/auth/me", null); }
    @PostMapping("/logout")
    ResponseEntity<String> logout() { return forward(HttpMethod.POST, "/api/auth/logout", null); }
    private ResponseEntity<String> forward(HttpMethod method, String path, String body) {
        try {
            var request = client.method(method).uri(path);
            if (body != null) request.contentType(MediaType.APPLICATION_JSON).body(body);
            var upstream = request.retrieve().toEntity(String.class);
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
        headers.setCacheControl("no-store");
        headers.set("X-Lab-App-Service", "visited");
        if (upstream != null) {
            for (String name : new String[]{"X-Lab-Platform-Gateway", "X-Lab-Platform-Service", "WWW-Authenticate"}) {
                if (upstream.containsKey(name)) headers.put(name, upstream.get(name));
            }
        }
        return new ResponseEntity<>(body, headers, status);
    }
}
