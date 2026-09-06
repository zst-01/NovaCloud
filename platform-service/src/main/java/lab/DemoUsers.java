package lab;

import java.util.List;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Component;

@Component
class DemoUsers implements ApplicationRunner {
    private final JdbcTemplate jdbc;
    private final String initialPassword;
    private final BCryptPasswordEncoder encoder = new BCryptPasswordEncoder();
    private final String dummyHash = encoder.encode("not-a-real-account");
    DemoUsers(JdbcTemplate jdbc, @Value("${DEMO_PASSWORD}") String initialPassword) {
        this.jdbc = jdbc; this.initialPassword = initialPassword;
    }
    @Override public void run(ApplicationArguments args) {
        jdbc.execute("CREATE TABLE IF NOT EXISTS lab_users (username VARCHAR(50) PRIMARY KEY, password_hash VARCHAR(100) NOT NULL, can_read BOOLEAN NOT NULL)");
        for (String username : List.of("demo", "observer")) {
            if (jdbc.queryForObject("SELECT COUNT(*) FROM lab_users WHERE username = ?", Integer.class, username) == 0) {
                jdbc.update("INSERT INTO lab_users (username, password_hash, can_read) VALUES (?, ?, ?)",
                    username, encoder.encode(initialPassword), username.equals("demo"));
            }
        }
    }
    SessionStore.User authenticate(String username, String password) {
        var rows = jdbc.query("SELECT username, password_hash, can_read FROM lab_users WHERE username = ?",
            (rs, n) -> new Account(rs.getString(1), rs.getString(2), rs.getBoolean(3)), username);
        String hash = rows.isEmpty() ? dummyHash : rows.get(0).hash();
        boolean matches = encoder.matches(password, hash);
        if (rows.isEmpty() || !matches) return null;
        var account = rows.get(0);
        return new SessionStore.User(account.username(), account.canRead() ? List.of("ticket:read") : List.of());
    }
    private record Account(String username, String hash, boolean canRead) {}
}
