package lab;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.web.server.WebFilter;
import static org.assertj.core.api.Assertions.assertThat;
class RequestLogTest {
    @Test void loggingFilterCanBeRegisteredWithoutBeanNameCollision() {
        new ApplicationContextRunner().withUserConfiguration(RequestLog.class)
            .run(context -> {
                assertThat(context).hasNotFailed();
                assertThat(context).hasSingleBean(WebFilter.class);
            });
    }
}
