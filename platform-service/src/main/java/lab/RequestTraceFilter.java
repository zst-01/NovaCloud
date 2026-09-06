package lab;

import java.io.IOException;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
class RequestTraceFilter extends OncePerRequestFilter {
    private static final Logger log = LoggerFactory.getLogger(RequestTraceFilter.class);
    private static final Pattern TRACE_ID = Pattern.compile("[0-9a-f]{32}");

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return request.getRequestURI().startsWith("/actuator/");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String supplied = request.getHeader("X-Trace-Id");
        String traceId = supplied != null && TRACE_ID.matcher(supplied).matches()
            ? supplied : UUID.randomUUID().toString().replace("-", "");
        String previous = MDC.get("traceId");
        long start = System.nanoTime();
        boolean failed = false;
        MDC.put("traceId", traceId);
        response.setHeader("X-Trace-Id", traceId);
        try {
            chain.doFilter(request, response);
        } catch (ServletException | IOException | RuntimeException e) {
            failed = true;
            throw e;
        } finally {
            log.info("request_complete traceId={} method={} path={} status={} durationMs={}",
                traceId, request.getMethod(), request.getRequestURI(), failed ? 500 : response.getStatus(),
                TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start));
            // Tomcat 会复用线程，必须恢复原值，防止下一次请求继承本次编号。
            if (previous == null) MDC.remove("traceId");
            else MDC.put("traceId", previous);
        }
    }
}
