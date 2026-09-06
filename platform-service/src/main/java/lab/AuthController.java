package lab;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/auth")
class AuthController {
    private final DemoUsers users;
    private final SessionStore sessions;
    AuthController(DemoUsers users, SessionStore sessions) { this.users = users; this.sessions = sessions; }
    record Credentials(String username, String password) {}
    @PostMapping("/login")
    ResponseEntity<?> login(@RequestBody Credentials credentials) {
        if (credentials.username() == null || !credentials.username().matches("[a-zA-Z0-9_]{1,50}")
            || credentials.password() == null || credentials.password().isEmpty()
            || credentials.password().getBytes(StandardCharsets.UTF_8).length > 72) {
            return reply(400, Map.of("error", "invalid_credentials_format"));
        }
        var user = users.authenticate(credentials.username(), credentials.password());
        if (user == null) return reply(401, Map.of("error", "invalid_credentials"));
        String token = sessions.create(user);
        return reply(200, Map.of("token", token, "tokenType", "Bearer", "expiresIn", SessionStore.TTL.toSeconds()));
    }
    @GetMapping("/me")
    ResponseEntity<?> me(HttpServletRequest request) { return reply(200, request.getAttribute("sessionUser")); }
    @PostMapping("/logout")
    ResponseEntity<?> logout(@RequestHeader("Authorization") String authorization) {
        sessions.delete(SessionStore.token(authorization));
        return reply(200, Map.of("message", "logged_out"));
    }
    @ExceptionHandler(DataAccessException.class)
    ResponseEntity<?> unavailable(DataAccessException e) { return reply(503, Map.of("error", "auth_store_unavailable")); }
    private ResponseEntity<?> reply(int status, Object body) {
        return ResponseEntity.status(status).header("Cache-Control", "no-store")
            .header("X-Lab-Platform-Service", "visited").body(body);
    }
}
