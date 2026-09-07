# Kubernetes 本机迁移方案

用户已确认执行：启用 Docker Desktop Kubernetes，把现有 8 个容器迁移，验证页面、登录、鉴权、限流和日志；Kafka 暂不接入。

## 部署设计

- 本机 Docker Desktop 4.42.1，使用自带单节点 kubeadm 集群，所有脚本固定 `--context docker-desktop`。
- `novacloud-app`：nginx、app-gateway、app-service。
- `novacloud-platform`：platform-gateway、platform-service。
- `novacloud-infra`：mysql、redis、nacos。
- 每个组件使用单副本 Deployment 和 ClusterIP Service。MySQL、Redis、Nacos 使用独立 PVC 和 Recreate 更新策略，避免两个进程同时写同一目录。
- 普通配置放 ConfigMap，密码由 `.env` 在内存中生成 Secret，不写入受版本管理的清单。
- 保留 Nacos 的 application/platform 两个命名空间。同层网关依然通过 Nacos 发现业务服务；应用服务通过 `http://platform-gateway.novacloud-platform.svc.cluster.local:8080` 调用中台网关。
- Kubernetes 命名空间与 Nacos 命名空间是两套独立概念。这里没有配置 NetworkPolicy，命名空间本身不禁止跨层访问。
- 本机通过仅监听 127.0.0.1 的 port-forward 访问：工作台 28080，Nacos 28848。原 Compose 18080/18848 保留，便于明确比较与回退。

## 数据与启动顺序

1. 检查镜像、Docker、Kubernetes Ready 节点和默认存储类。
2. 创建命名空间、配置、Secret 和 PVC。
3. 启动 MySQL、Redis、Nacos，等待探针就绪；初始化 Nacos 命名空间。
4. 在首次部署且目标数据库无业务表时，将 Compose 的 novacloud 数据库逻辑复制到新的 MySQL PVC；已有 Kubernetes 数据库不覆盖。保留 Compose 原数据卷。
5. 依次启动中台服务、中台网关、应用服务、应用网关、Nginx。
6. 启动本地转发，再执行实际 HTTP 与容器内验收。

两套数据库此后不会自动同步。Redis 从空数据卷开始，会话需要重新登录；原 Compose Redis 数据不删除。

## 验收标准

- 8 个 Deployment 可用，3 个 PVC Bound；健康检查与资源限制生效。
- Nacos 每个命名空间两个健康服务，注册地址属于 Kubernetes Pod。
- 首页、资源、完整五层链路、MySQL 查询、400/404 行为保持一致。
- 登录、匿名 401、observer 403、会话 TTL、退出失效与中台直接鉴权通过。
- 登录 10 次/30 秒、同用户工单 20 次/10 秒；真实并发超额 429、Retry-After、窗口恢复通过。
- TraceId 能关联五层日志；拒绝请求停在正确的层，日志不记录密码或 token。
- Redis AOF 与 TTL 验证；Pod 重建后持久化数据保持。
- 浏览器流程复验；记录实际结果及未完成项。

## 回退和范围

停止本项目 port-forward 后继续使用 `scripts/start.ps1 -SkipBuild` 的 Compose 环境即可。普通停止或更新不删除 PVC。禁用/重置 Docker Desktop Kubernetes 会影响整个本机集群，不用作项目日常停止方式。

不改 Java 业务逻辑，不增加 Kafka、生产集群、Ingress、集中式日志平台或高可用数据库。Kubernetes 管理界面另见学习文档；旧 Dashboard 已归档，官方建议 Headlamp。

参考：[Docker Desktop Kubernetes](https://docs.docker.com/desktop/use-desktop/kubernetes/)、[Kubernetes Dashboard 状态](https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/)。
