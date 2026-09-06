# TraceId 与请求日志实施方案

## 已批准范围
仅实现请求日志关联，保留既有业务、两层网关和 Nacos 命名空间。Redis、登录鉴权、Kafka 均属于后续阶段。

## 约定
- Nginx 每次生成 32 位小写十六进制编号，通过 X-Trace-Id 传给应用层网关，并覆盖外部传入值；响应只返回一个同名头。
- 两个网关、两个业务服务沿用合法编号；容器内直接访问时，缺失或非法编号会重新生成。
- Gateway 使用 WebFilter，在响应提交时记录状态码和响应提交前耗时；异步链路只使用每请求局部变量，不把线程 MDC 当作响应式上下文。
- 两个同步 MVC 服务使用 OncePerRequestFilter 设置 MDC，处理结束后恢复或清理。应用层 RestClient 从当前 MDC 透传编号。
- Nginx 记录 JSON 访问日志及秒级 request_time，Java 请求日志记录 durationMs；不把不同测量边界的耗时混为一谈。
- 记录 HTTP 方法、路径（不包含查询字符串）、状态码、TraceId、耗时；不记录请求体、密码、Authorization 或完整 token。
- Docker 对四个 Java 服务及 Nginx 的标准输出日志设置轮转（单文件 10MB，最多 3 个文件）。日志保留在容器日志中；删除容器会失去其日志，搭建日志和学习文档另存于项目。
- 本阶段为基于 X-Trace-Id 的 HTTP 日志关联，不实现 span、采样、OpenTelemetry 后端或 Kafka 上下文传播。

## 实施与验收
- [x] 先运行 TraceId 验收脚本，观察现有环境缺少编号而失败。
- [x] 网关、Servlet 过滤器和 RestClient 传播测试；覆盖异常后的 MDC 清理、非法编号及并发隔离。
- [x] 接入 Nginx 编号及日志、Java 日志和 Docker 日志轮转。
- [x] 构建测试，启动后检查正常、404、400、并发请求的日志及响应编号。
- [x] 短暂停止中台网关验证 502/504 错误链路日志，恢复后重验。
- [x] 更新 README、搭建日志和学习文档，交付查询脚本及实际验证记录。

## 2026-09-06 实际结果
- 23 个 Java 自动测试通过，0 失败、0 错误。
- 启动脚本完成镜像部署、Nginx 配置检查及重载，原 19 项链路检查通过。
- TraceId 常规验收通过 11 个请求；故障模式共 12 个请求，含 6 个并发请求、中台网关停止后的 504、404 和 400。
- 验证响应编号与每个实际经过环节的完成日志对应，日志状态码及耗时字段正确。
- 中台网关恢复后原链路再次验收通过；最终 7 个容器健康。
- show-trace.ps1 实测找到五层完成日志及两个业务日志；本次带测试 Authorization 和查询参数的正常请求日志未包含测试敏感标记。
- 从实际容器配置核对五个请求处理容器均启用 json-file / max-size=10m / max-file=3；未人为填满日志测试轮转边界。

参考：[Nginx 日志模块](https://nginx.org/en/docs/http/ngx_http_log_module.html)、[Nginx request_id](https://nginx.org/en/docs/http/ngx_http_core_module.html#var_request_id)。
