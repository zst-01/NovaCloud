package lab;

import java.io.IOException;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 1)
class SessionFilter extends OncePerRequestFilter {
    private final SessionStore sessions;
    SessionFilter(SessionStore sessions) { this.sessions = sessions; }
    @Override protected boolean shouldNotFilter(HttpServletRequest request) {
        return request.getRequestURI().equals("/actuator/health") || request.getRequestURI().equals("/actuator/health/redis")
            || (request.getRequestURI().equals("/api/auth/login") && request.getMethod().equals("POST"));
    }
    @Override protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        SessionStore.User user;
        String token = SessionStore.token(request.getHeader("Authorization"));
        if (java.util.Collections.list(request.getHeaders("Authorization")).size() != 1 || token == null) {
            reject(response, 401, "unauthorized"); return;
        }
        try { user = sessions.find(token); }
        catch (RuntimeException e) { reject(response, 503, "session_unavailable"); return; }
        if (user == null) { reject(response, 401, "unauthorized"); return; }
        boolean ownAccount = request.getRequestURI().equals("/api/auth/me") || request.getRequestURI().equals("/api/auth/logout");
        if (!ownAccount && !user.permissions().contains("ticket:read")) {
            reject(response, 403, "forbidden"); return;
        }
        request.setAttribute("sessionUser", user);
        chain.doFilter(request, response);
    }
    private void reject(HttpServletResponse response, int status, String error) throws IOException {
        response.setStatus(status);
        response.setContentType("application/json");
        response.setHeader("Cache-Control", "no-store");
        if (status == 401) response.setHeader("WWW-Authenticate", "Bearer");
        response.getWriter().write("{\"error\":\"" + error + "\"}");
    }
}
