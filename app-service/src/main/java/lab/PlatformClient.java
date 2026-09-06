package lab;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;
import org.slf4j.MDC;
@Configuration
class PlatformClient {
    @Bean RestClient platformRestClient(@Value("${PLATFORM_GATEWAY_URL}") String url) {
        var factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(2000);
        factory.setReadTimeout(5000);
        return RestClient.builder().baseUrl(url).requestFactory(factory)
            .requestInterceptor((request, body, execution) -> {
                String traceId = MDC.get("traceId");
                var attributes = org.springframework.web.context.request.RequestContextHolder.getRequestAttributes();
                if (attributes instanceof org.springframework.web.context.request.ServletRequestAttributes servlet) {
                    String authorization = servlet.getRequest().getHeader("Authorization");
                    if (authorization != null) request.getHeaders().set("Authorization", authorization);
                }
                if (traceId != null && traceId.matches("[0-9a-f]{32}")) {
                    request.getHeaders().set("X-Trace-Id", traceId);
                }
                return execution.execute(request, body);
            }).build();
    }
}
