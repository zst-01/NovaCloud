# Redis 部署与连接实施方案

本阶段只准备登录会话所需的 Redis 基础设施，不提前实现登录或缓存业务。

- 单个 Redis Docker 容器，Windows 127.0.0.1:16379 映射内部 6379；中台服务使用 redis:6379。
- 随机密码保存到现有 .env；保留原 MySQL 密码，不输出凭据。
- 使用 redis-data 命名卷、AOF everysec 持久化，Redis 数据内存上限 128MB、容器上限 512MB，达到上限拒绝新增写入，不主动淘汰尚有效的会话。
- 中台服务通过 Spring Data Redis / Lettuce 连接，Actuator 纳入 Redis 健康检查；不增加对外读写 Redis 的接口。
- Maven 集成测试连接真实 Redis，使用唯一临时 key 验证写入、读取、TTL 和过期，并清理。
- 脚本验证密码校验、AOF 设置、Java 健康检查；可选重启 Redis 验证指定临时 key 保留。
- 每次启动自动验收，更新搭建日志及学习文档。

验收：8 个容器健康，原链路和 TraceId 通过；Java 真实 Redis 测试、未认证拒绝访问和重启保留检查通过。

资料：[Redis 持久化](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)、[内存策略](https://redis.io/docs/latest/develop/reference/eviction/)。everysec 在异常宕机时仍可能丢失约一秒数据；正常重启测试不代表断电零丢失。

## 实际验收结果（2026-09-06）

已完成：Redis 7.4.11 部署、24 个 Java 测试（含真实 Redis 测试）通过、原 19 项链路检查通过、11 个请求的 TraceId 验收通过。正常重启后临时数据保留，中台 Redis 健康检查为 UP，本项目 8 个容器均健康。详细过程见根目录搭建日志.md。
