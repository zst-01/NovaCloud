package lab;
import jakarta.servlet.ServletException;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import static org.assertj.core.api.Assertions.*;
class RequestTraceFilterTest {
    @AfterEach void clear() { MDC.clear(); }
    @Test void preservesTraceAndCleansMdcAfterHandledError() throws Exception {
        String trace = "0123456789abcdef0123456789abcdef";
        var request = new MockHttpServletRequest("GET", "/api/tickets/9");
        request.addHeader("X-Trace-Id", trace);
        var response = new MockHttpServletResponse();
        new RequestTraceFilter().doFilter(request, response, (req, res) -> {
            assertThat(MDC.get("traceId")).isEqualTo(trace);
            ((jakarta.servlet.http.HttpServletResponse)res).setStatus(404);
        });
        assertThat(response.getHeader("X-Trace-Id")).isEqualTo(trace);
        assertThat(response.getStatus()).isEqualTo(404);
        assertThat(MDC.get("traceId")).isNull();
    }
    @Test void restoresMdcEvenWhenChainThrows() {
        MDC.put("traceId", "parent-context");
        var request = new MockHttpServletRequest("GET", "/api/tickets/1");
        var response = new MockHttpServletResponse();
        assertThatThrownBy(() -> new RequestTraceFilter().doFilter(request, response, (req, res) -> {
            assertThat(MDC.get("traceId")).matches("[0-9a-f]{32}");
            throw new ServletException("test");
        })).isInstanceOf(ServletException.class);
        assertThat(MDC.get("traceId")).isEqualTo("parent-context");
    }
    @Test void reusingThreadDoesNotReuseTrace() throws Exception {
        var filter = new RequestTraceFilter();
        var first = new MockHttpServletResponse();
        var second = new MockHttpServletResponse();
        filter.doFilter(new MockHttpServletRequest("GET", "/first"), first, (req,res) -> {});
        var invalid = new MockHttpServletRequest("GET", "/second");
        invalid.addHeader("X-Trace-Id", "untrusted garbage");
        filter.doFilter(invalid, second, (req,res) -> {});
        assertThat(first.getHeader("X-Trace-Id")).matches("[0-9a-f]{32}");
        assertThat(second.getHeader("X-Trace-Id")).matches("[0-9a-f]{32}").isNotEqualTo(first.getHeader("X-Trace-Id"));
        assertThat(MDC.get("traceId")).isNull();
    }
}
