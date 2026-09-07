# 用一个编号查看整条请求链路

登录阶段更新：工单接口现在需要 Authorization。手动执行下文查询前，先参考 [登录鉴权学习与操作](登录鉴权学习与操作.md) 获取 `$headers`，并给请求加上 `-Headers $headers`；verify-trace.ps1 已自动处理登录和退出。

## 本阶段解决什么问题

同一时间可能有多个用户查询工单。以前五个环节各自打印日志，只凭接口路径很难知道哪些日志来自同一次请求。

现在 Nginx 给每个外部请求生成一个 TraceId，例如 32 位小写十六进制字符串。后续网关和服务继续使用这个编号，响应头中也返回它。

```text
Nginx 生成 X-Trace-Id
  → 应用层 Gateway 透传
  → 应用层服务：把编号放进当前请求的日志上下文
  → RestClient 把编号加入发往中台的请求头
  → 中台 Gateway 透传
  → 中台服务：数据库查询日志也带上编号
```

MySQL 本身没有接入追踪；带编号的是中台 Java 服务执行数据库查询时的日志。TraceId 只用于日志关联，不证明身份或权限，也不等于用户 token。

## 在你的电脑上操作

Docker Desktop 保持启动。进入本项目目录后，先输入 `pwsh.exe -NoProfile` 进入 PowerShell 7，接着执行：

```powershell
$response = Invoke-WebRequest 'http://127.0.0.1:18080/api/tickets/1'
$traceId = @($response.Headers['X-Trace-Id'])[0]
$response.Content
$traceId
./scripts/show-trace.ps1 -TraceId $traceId
```

查看最近两小时的对应日志，可以加 `-Since 2h`。也可以在浏览器开发者工具的 Network 面板选择查询请求，从 Response Headers 复制 `X-Trace-Id` 后交给该脚本。

## 日志如何读

Java 请求完成日志的消息格式示例（编号和耗时为示意值）：

```text
request_complete traceId=0123456789abcdef0123456789abcdef method=GET path=/api/tickets/1 status=200 durationMs=18
```

- TraceId：关联同一次请求。
- method、path：请求了哪个接口；path 不包含查询字符串。
- status：这一层返回的 HTTP 状态码。
- durationMs：Java 这一层所测得的耗时，单位毫秒。
- 服务名：Spring 日志前缀或 Docker Compose 日志行前面的容器服务名。

Nginx 使用 JSON 访问日志，包含 `service=nginx`、`traceId`、`status` 和 `durationSec`，耗时单位是秒。

这些耗时互相包含，不能直接相加。网关计时结束于响应提交前；MVC 计时到同步过滤器链退出；Nginx 记录它处理请求所花时间。它们不是同一种精确计时边界。

两个 MVC 服务把编号放入 MDC（当前线程的日志上下文），因此原有的中转、查询和数据库错误日志自动带上编号，并在请求结束后清理。网关使用响应式处理，回调可能切换线程，因此通过当前请求局部变量记录编号，不靠线程 MDC。

## 错误请求会出现在哪几层

| 请求情况 | 应出现完成日志的环节 |
| --- | --- |
| 正常查询 /api/tickets/1 | Nginx、两个网关、两个服务 |
| 工单不存在 /api/tickets/999999 | 同上，各层状态为 404 |
| 非数字 ID /api/tickets/invalid | Nginx、应用层网关、应用层服务；应用层参数校验返回 400 |
| 未匹配网关路由 /api/missing | Nginx、应用层网关；状态为 404 |
| Nginx 自身拒绝 /missing | 只有 Nginx；状态为 404 |
| 中台网关停止 | Nginx、应用层网关、应用层服务；返回 502 或 504 |
| 应用网关拒绝会话或权限 | Nginx、应用层网关；返回 401 或 403 |
| 登录或工单请求超限 | Nginx、应用层网关；返回 429，并附 Retry-After |

故障请求没有到达中台时，不会凭空产生中台日志。

表中的业务查询和未匹配路由 404 以已登录、权限满足且未超额为前提；否则会在更早阶段结束。

## 验证脚本

正常、错误路由和并发请求验证，不会停止容器：

```powershell
pwsh.exe -NoProfile -File .\scripts\verify-trace.ps1
```

额外执行一次中台网关停机实验（脚本通过 finally 自动恢复）：

```powershell
pwsh.exe -NoProfile -File .\scripts\verify-trace.ps1 -IncludeFailure
```

脚本检查每个编号在应经过的环节恰有一条请求完成日志，并核对状态码和耗时字段。并发请求必须使用不同编号。入口会替换外部传入的编号，便于避免人为复用编号混淆日志；内部直接访问时保留合法编号，缺失或非法则补发。

## 日志保存在哪里

- 搭建日志：项目中的《搭建日志.md》，记录改动和验证结果。
- 程序运行日志：服务标准输出，由 Docker 保存；`docker compose logs` 或 Docker Desktop 可查看。
- 五个请求处理容器（Nginx 和四个 Java 程序）使用 Docker 日志轮转：每个文件最多 10MB，最多保留 3 个文件，边界处可能略有超出。
- 同一容器正常停止再启动通常还能查看其日志；删除或重建容器会失去旧容器日志，轮转也会淘汰较早的日志。重要排障记录需提前导出到项目之外合适的位置，凭据不要写进导出文件。
- 本次没有新增日志数据库或集中检索后台；没有 span、采样、分布式追踪界面，也尚未把编号传播到 Kafka 消息。

参考：[Nginx 日志格式](https://nginx.org/en/docs/http/ngx_http_log_module.html)、[Nginx request_id 变量](https://nginx.org/en/docs/http/ngx_http_core_module.html#var_request_id)。
