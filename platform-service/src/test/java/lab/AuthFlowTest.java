package lab;
import java.time.Duration;
import java.util.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.*;
import org.springframework.data.redis.core.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.embedded.*;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class AuthFlowTest {
    EmbeddedDatabase db;
    JdbcTemplate jdbc;
    MockMvc mvc;
    Map<String,String> data;
    StringRedisTemplate redis;
    ObjectMapper mapper = new ObjectMapper();
    @BeforeEach @SuppressWarnings("unchecked") void setup() {
        db = new EmbeddedDatabaseBuilder().generateUniqueName(true).setType(EmbeddedDatabaseType.H2).build();
        jdbc = new JdbcTemplate(db);
        var users = new DemoUsers(jdbc, "test-password");
        users.run(null);
        users.run(null);
        redis = mock(StringRedisTemplate.class);
        ValueOperations<String,String> values = mock(ValueOperations.class);
        when(redis.opsForValue()).thenReturn(values);
        data = new HashMap<>();
        doAnswer(a -> { data.put(a.getArgument(0), a.getArgument(1)); return null; })
            .when(values).set(anyString(), anyString(), eq(Duration.ofMinutes(30)));
        when(values.get(anyString())).thenAnswer(a -> data.get(a.getArgument(0)));
        when(redis.delete(anyString())).thenAnswer(a -> data.remove(a.getArgument(0)) != null);
        var sessions = new SessionStore(redis, mapper);
        mvc = MockMvcBuilders.standaloneSetup(new AuthController(users, sessions))
            .addFilters(new SessionFilter(sessions)).build();
    }
    @AfterEach void cleanup() { db.shutdown(); }
    String login(String username) throws Exception {
        var result = mvc.perform(post("/api/auth/login").contentType("application/json")
            .content("{\"username\":\""+username+"\",\"password\":\"test-password\"}"))
            .andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store"))
            .andExpect(jsonPath("$.expiresIn").value(1800)).andReturn();
        return mapper.readTree(result.getResponse().getContentAsString()).get("token").asText();
    }
    @Test void loginProfileLogoutAndReuse() throws Exception {
        String token = login("demo");
        assertThat(token).matches("[0-9a-f]{64}");
        assertThat(login("demo")).isNotEqualTo(token);
        mvc.perform(get("/api/auth/me").header("Authorization","Bearer "+token))
            .andExpect(status().isOk()).andExpect(jsonPath("$.username").value("demo"))
            .andExpect(jsonPath("$.permissions[0]").value("ticket:read"))
            .andExpect(jsonPath("$.password").doesNotExist());
        mvc.perform(post("/api/auth/logout").header("Authorization","Bearer "+token)).andExpect(status().isOk());
        mvc.perform(get("/api/auth/me").header("Authorization","Bearer "+token)).andExpect(status().isUnauthorized());
    }
    @Test void invalidCredentialsDoNotCreateSession() throws Exception {
        for (String username : List.of("demo", "unknown")) {
            mvc.perform(post("/api/auth/login").contentType("application/json")
                .content("{\"username\":\""+username+"\",\"password\":\"wrong\"}"))
                .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.error").value("invalid_credentials"));
        }
        assertThat(data).isEmpty();
    }
    @Test void missingPasswordAndOverlongPasswordAre400() throws Exception {
        for (String body : List.of("{}", "{\"username\":\"demo\",\"password\":\""+ "x".repeat(73)+"\"}")) {
            mvc.perform(post("/api/auth/login").contentType("application/json").content(body)).andExpect(status().isBadRequest());
        }
    }
    @Test void directServiceRequiresSessionAndPermission() throws Exception {
        mvc.perform(get("/api/tickets/1").header("X-User-Id","demo")).andExpect(status().isUnauthorized());
        String token = login("observer");
        mvc.perform(get("/api/tickets/1").header("Authorization","Bearer "+token)).andExpect(status().isForbidden());
        mvc.perform(get("/api/auth/me").header("Authorization","Bearer "+token)).andExpect(status().isOk());
        for (String path : List.of("/api/%74ickets/1", "/%61pi/tickets/1", "/api/tickets;x=y/1", "/actuator/health/../../api/tickets/1")) {
            mvc.perform(get(java.net.URI.create(path)).header("Authorization","Bearer "+token)).andExpect(status().isForbidden());
        }
    }
    @Test void unavailableRedisDoesNotAllowRequest() throws Exception {
        when(redis.opsForValue()).thenThrow(new org.springframework.dao.DataAccessResourceFailureException("offline"));
        mvc.perform(get("/api/auth/me").header("Authorization","Bearer "+"a".repeat(64))).andExpect(status().isServiceUnavailable());
        mvc.perform(post("/api/auth/login").contentType("application/json")
            .content("{\"username\":\"demo\",\"password\":\"test-password\"}")).andExpect(status().isServiceUnavailable());
    }
    @Test void seedIsIdempotentAndPasswordsHashed() {
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM lab_users", Integer.class)).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT password_hash FROM lab_users WHERE username='demo'", String.class))
            .startsWith("$2a$").isNotEqualTo("test-password");
        new DemoUsers(jdbc, "different-password").run(null);
        assertThat(new DemoUsers(jdbc, "unused").authenticate("demo","test-password")).isNotNull();
    }
}
