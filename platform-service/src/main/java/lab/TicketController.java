package lab;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.*;
@RestController
class TicketController {
    private static final Logger log = LoggerFactory.getLogger(TicketController.class);
    private final JdbcTemplate jdbc;
    TicketController(JdbcTemplate jdbc) { this.jdbc = jdbc; }
    record Ticket(long id, String title, String status) {}
    @GetMapping("/api/tickets/{id}")
    ResponseEntity<?> get(@PathVariable long id) {
        log.info("Platform service querying MySQL for ticket {}", id);
        var rows = jdbc.query("SELECT id, title, status FROM tickets WHERE id = ?",
            (rs, n) -> new Ticket(rs.getLong("id"), rs.getString("title"), rs.getString("status")), id);
        return rows.isEmpty()
            ? ResponseEntity.status(404).header("X-Lab-Platform-Service", "visited").body(Map.of("error", "ticket_not_found"))
            : ResponseEntity.ok().header("X-Lab-Platform-Service", "visited").body(rows.get(0));
    }
    @ExceptionHandler(DataAccessException.class)
    ResponseEntity<?> databaseFailure(DataAccessException e) {
        log.warn("Database query failed: {}", e.getClass().getSimpleName());
        return ResponseEntity.status(503).body(Map.of("error", "database_unavailable"));
    }
}
