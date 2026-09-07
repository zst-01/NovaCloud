# Kubernetes 学习与操作

## 先运行起来

Docker Desktop 中已启用单节点 Kubernetes。项目使用 `docker-desktop` 上下文。

在 `E:\工作\面经\NovaCloud` 打开 PowerShell 7：

```powershell
# 启动项目，自动创建配置、恢复 Pod 并验收
pwsh.exe -NoProfile -File .\scripts\start-k8s.ps1

# 已经启动，只恢复本机访问通道（重启电脑、Docker 或入口 Pod 后使用）
pwsh.exe -NoProfile -File .\scripts\k8s-forward.ps1

# 单独执行完整验收
pwsh.exe -NoProfile -File .\scripts\verify-k8s.ps1
```

- **Kubernetes 工作台**：<http://127.0.0.1:28080>
- **Kubernetes Nacos**：<http://127.0.0.1:28848/nacos>
- Compose 的工作台和 Nacos 仍是 18080 / 18848；只有相应 Compose 容器运行时才能访问。

登录用户名仍为 `demo`，无工单权限的对照账号为 `observer`。演示密码见本地 `.env` 中的 `DEMO_PASSWORD`，不要复制进运行日志。

`start-k8s.ps1` 默认复用已有本地 Java 镜像。修改 Java 代码后，先通过 `scripts/start.ps1` 编译、测试并重建镜像，再运行 Kubernetes 启动脚本。修改前端或 Nginx 配置后，直接重新运行 Kubernetes 启动脚本即可更新 ConfigMap 并重建对应 Pod。

## 一次工单请求怎么走

```text
Windows 浏览器 127.0.0.1:28080
  → kubectl port-forward
  → novacloud-app 中的 Nginx Pod
  → app-gateway:8080（Kubernetes Service）
  → app-service Pod（网关从 Nacos application 发现）
  → platform-gateway.novacloud-platform.svc.cluster.local:8080
  → platform-service Pod（网关从 Nacos platform 发现）
  → mysql.novacloud-infra.svc.cluster.local:3306
```

`platform-gateway.novacloud-platform.svc.cluster.local` 是 Kubernetes 内部域名：第一段是 Service 名，第二段是 Kubernetes 命名空间。这一跳依然使用部署时配置的 URL，不通过 Nacos 查找中台网关。

port-forward 是单机实验访问通道，Nginx 看到的是转发连接的来源，不能据此演示多台外部电脑的真实 IP 区分。当前可验证同来源限流和伪造头无法绕过；生产入口的客户端 IP 传递需要结合 Ingress/负载均衡器另行设计。

**Kubernetes 命名空间与 Nacos 命名空间是两件事：**

| 组件 | Kubernetes 命名空间 | Nacos 命名空间 |
|---|---|---|
| Nginx | novacloud-app | 不注册 |
| app-gateway、app-service | novacloud-app | application |
| platform-gateway、platform-service | novacloud-platform | platform |
| MySQL、Redis、Nacos | novacloud-infra | 不作为业务服务注册 |

命名空间用于组织资源；本实验没有 NetworkPolicy，不表示跨命名空间的网络被隔离。

## Compose 配置对应什么

| 原 Compose 内容 | Kubernetes 对应资源/行为 |
|---|---|
| 一个 service 的容器运行定义 | Deployment 管理 Pod，Pod 中运行容器 |
| `restart: unless-stopped` | Deployment 维持副本数；容器异常退出后由 kubelet 重启 |
| `mysql` 等服务名 | Service 提供稳定内部地址，CoreDNS 解析名称 |
| 普通 environment | ConfigMap + env/envFrom |
| `.env` 中的密码 | Secret；启动脚本从本地文件读取后提交，不写入清单 |
| 命名数据卷 | PVC 申请本机存储；重建 Pod 后重新挂载同一卷 |
| healthcheck | startupProbe 与 readinessProbe；Nginx 还有 livenessProbe |
| depends_on | 启动脚本按阶段等待 rollout；Kubernetes 本身不提供此字段 |
| mem_limit | resources.limits.memory；requests 是调度资源申请 |
| 本机 ports 映射 | 本实验用仅监听 127.0.0.1 的 port-forward |
| `docker compose logs` | `kubectl logs` |
| 前端与 Nginx 只读目录挂载 | 从原文件生成 ConfigMap 后只读挂载 |

Secret 的 Base64 不是加密。这里是本机学习环境，没有完成生产密码管理、集群加固或公网发布。

每个组件暂时只有一个副本。部署使用 Recreate，会有短暂中断；数据库采用独立 PVC，避免旧、新 Pod 同时写一个数据库目录。

## 看运行状态和日志

```powershell
kubectl --context docker-desktop get nodes
kubectl --context docker-desktop -n novacloud-app get pods,svc
kubectl --context docker-desktop -n novacloud-platform get pods,svc
kubectl --context docker-desktop -n novacloud-infra get pods,svc,pvc

kubectl --context docker-desktop -n novacloud-app logs deployment/app-gateway --tail=50
kubectl --context docker-desktop -n novacloud-platform logs deployment/platform-service --tail=50

# 从页面复制 TraceId，关联五层日志
./scripts/show-trace.ps1 -Runtime Kubernetes -TraceId 替换成32位编号
```

项目日志仍写到容器标准输出，由 Kubernetes 节点管理。`show-trace.ps1` 为共用验收格式给单副本日志加组件前缀；实际 Pod 名请用 `kubectl get pods` 查看。

本机 kubelet 实际配置为每个容器日志文件最多 `10Mi`、最多 `5` 个文件（2026-09-07 读取节点 configz 确认），不是 Compose 中的 10MB×3。

Pod 删除后，不能依赖 `kubectl logs` 查询它的历史日志；`--previous` 主要查询同一个 Pod 内上一次退出的容器。这里尚未搭建 Loki/ELK 等集中存储，也没有把 Compose 的 10MB×3 轮转设置照搬到 Kubernetes。长期日志保留需要单独建设。

## 数据保留、停止与回退

第一次启动：目标数据库为空时，脚本启动已有 Compose MySQL，将 `novacloud` 数据库逻辑复制进去。已有目标表时不重复导入，避免覆盖后续实验数据。`-FreshData` 仅用于明确要从项目 SQL 新建独立演示数据的场景，对已有数据库也不会执行清空。

两套 MySQL 此后独立变化，不自动同步。Redis 使用新的 PVC，迁移后需要重新登录；Compose 的旧会话和计数仍在原数据卷。Nacos 的两个命名空间在新集群中重新初始化。

```powershell
# 停止本项目的 Kubernetes Pod，保留 PVC 和集群
./scripts/stop-k8s.ps1

# 再启动 Kubernetes
./scripts/start-k8s.ps1

# 回到原 Compose 环境
./scripts/start.ps1 -SkipBuild
```

关闭转发只会让本机入口不可访问，不会停止 Pod：`./scripts/k8s-forward.ps1 -Action Stop`。转发进程和脱敏日志记录在忽略目录 `.k8s-local/`；脚本只停止自己记录且启动时间匹配的 kubectl 进程。

不要为普通停止删除 namespace/PVC，也不要使用 Docker Desktop 的 Reset Kubernetes Cluster；这些操作可能删除本项目数据。`hostpath` 数据仍属于这台电脑，PVC 不等于异机备份。

## 是否有管理界面

有。Docker Desktop 的 Kubernetes 设置用于启停本机集群；管理 Pod、Deployment、Service、日志可以使用专门的 Kubernetes 图形客户端。

之前提到的 Kubernetes Dashboard 已归档，官方现在推荐 Headlamp。本次迁移不额外安装管理平台；当前可使用上面的命令查看所有资源，Nacos 自身的网页也可直接打开。

参考：[Docker Desktop Kubernetes](https://docs.docker.com/desktop/use-desktop/kubernetes/)、[官方 Dashboard 状态](https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/)。实际搭建过程和验收结果见 [搭建日志](../搭建日志.md)。
