package lab;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.embedded.*;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
class TicketControllerTest {
    EmbeddedDatabase db;
    MockMvc mvc;
    @BeforeEach void setup() {
        db = new EmbeddedDatabaseBuilder().generateUniqueName(true).setType(EmbeddedDatabaseType.H2).build();
        var jdbc = new JdbcTemplate(db);
        jdbc.execute("CREATE TABLE tickets(id BIGINT PRIMARY KEY, title VARCHAR(200), status VARCHAR(20))");
        jdbc.update("INSERT INTO tickets VALUES (1, 'From database', 'OPEN')");
        mvc = MockMvcBuilders.standaloneSetup(new TicketController(jdbc)).build();
    }
    @AfterEach void cleanup() { db.shutdown(); }
    @Test void readsStoredRow() throws Exception {
        mvc.perform(get("/api/tickets/1")).andExpect(status().isOk())
            .andExpect(jsonPath("$.title").value("From database"))
            .andExpect(header().string("X-Lab-Platform-Service", "visited"));
    }
    @Test void absentRecordIs404() throws Exception {
        mvc.perform(get("/api/tickets/99")).andExpect(status().isNotFound())
            .andExpect(jsonPath("$.error").value("ticket_not_found"));
    }
    @Test void invalidIdIs400() throws Exception {
        mvc.perform(get("/api/tickets/invalid")).andExpect(status().isBadRequest());
    }
    @Test void databaseFailureIs503() throws Exception {
        new JdbcTemplate(db).execute("DROP TABLE tickets");
        mvc.perform(get("/api/tickets/1")).andExpect(status().isServiceUnavailable())
            .andExpect(jsonPath("$.error").value("database_unavailable"));
    }
}
