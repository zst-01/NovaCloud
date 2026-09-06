# Redis 已部署在哪里，怎样验证

## 当前用途

Redis 运行在 Docker 容器里，中台 Java 服务通过 Spring Data Redis / Lettuce 连接它。后续登录阶段现已使用 Redis 保存会话，两层网关也连接 Redis 校验会话，见 [登录鉴权学习与操作](登录鉴权学习与操作.md)。工单查询仍直接读取 MySQL。

```text
中台服务 → redis:6379 → Redis 容器
Windows 数据库工具 → 127.0.0.1:16379 → 同一个 Redis 容器
```

Redis 不在 Nacos 注册，它的地址通过部署配置提供。Redis 服务启动并通过健康检查后，Compose 才启动中台服务。

## 连接信息

- 宿主机地址：127.0.0.1
- 宿主机端口：16379
- 默认数据库：0
- 用户：default（使用只填密码的客户端时可不填用户）
- 密码：项目本地 .env 中的 REDIS_PASSWORD；请勿粘贴进聊天或搭建日志。

Redis 本身没有浏览器管理页面，不要用浏览器访问这个端口。可使用 Redis 客户端，也可以在项目目录通过容器里的 redis-cli 查看。

## 启动及验收

首次升级到本阶段需要重新编译中台服务：

```powershell
pwsh.exe -NoProfile -File .\scripts\start.ps1
```

以后代码未改变，可以加 `-SkipBuild`。启动脚本会先准备凭据、启动基础设施，再执行 Java 测试和镜像构建，最后验证原链路、TraceId 和 Redis。

单独验证 Redis：

```powershell
pwsh.exe -NoProfile -File .\scripts\verify-redis.ps1
```

包含一次正常重启的数据保留实验：

```powershell
pwsh.exe -NoProfile -File .\scripts\verify-redis.ps1 -Restart
```

脚本只使用唯一的 `lab:verify:` 临时 key，结束后删除该 key，不清空数据库。重启期间中台 Redis 连接可能短暂不可用，实验后检查恢复状态。

Java 集成测试只在 `REDIS_INTEGRATION=true` 时启用，正常完整启动脚本会设置它。直接在 IDE 运行普通单元测试时该项会跳过；不要将跳过说成已连接真实 Redis。

## 本次选的配置及原因

| 配置 | 含义 |
| --- | --- |
| redis-data 数据卷 | 普通停止或重建容器时保留 Redis 数据文件 |
| appendonly yes | 开启 AOF，记录写入操作 |
| appendfsync everysec | 通常每秒同步一次；异常宕机仍可能丢失约一秒数据 |
| maxmemory 128mb | Redis 数据内存达到限制时执行内存策略 |
| noeviction | 不主动淘汰有效 key；内存不足时拒绝需要新增内存的写操作 |
| 容器 512MB | 给 Redis 进程、持久化缓冲等留出额外空间 |
| TTL | key 到期后不能再读取；这是会话过期的基础能力 |

AOF 是数据持久化，不是运行日志，也不是独立备份。开启持久化不意味着过期的 key 能恢复为有效会话。正常重启保留实验不等于验证突然断电零数据丢失。

## 代码入口

- compose.yaml：Redis 容器、密码来源、端口、数据卷和健康检查。
- platform-service/src/main/resources/application.yml：Java 连接地址、密码和超时。
- platform-service/src/test/java/lab/RedisIntegrationTest.java：真实 Redis 的 Java 写入、读取和过期测试。
- scripts/init-env.ps1：补充缺失凭据，保留已有配置。
- scripts/verify-redis.ps1：部署和运行验证。

登录阶段已在 Redis 中保存 token 对应的用户会话和有效期，退出时删除当前会话；本篇仍侧重 Redis 部署本身。

来源：[Redis 持久化](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)、[Redis 内存淘汰策略](https://redis.io/docs/latest/develop/reference/eviction/)。
