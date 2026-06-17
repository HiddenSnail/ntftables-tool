# nftables-tool

基于 nftables 的 IP 白名单端口访问控制工具。以白名单方式，让指定 IP 段访问指定中间件端口。内置 10+ 中间件模板，支持端口范围，一键管理。

## 设计原则

- **最小干扰**：input 链默认 `policy accept`，仅拦截通过 `allow` 声明的端口，其余流量原样放行，不影响系统已有防火墙规则
- **ipset 风格**：IP 白名单和端口都用 nftables named set 管理，增删元素不触碰规则本身
- **独立表隔离**：使用专属表 `inet nftables-tool`，`reset` 仅清除自己

## 依赖

- Linux 内核 >= 3.13
- nftables（`install` 命令自动检测并安装）
- systemd（可选，用于开机自启）
- root 权限

## 快速开始

```bash
# 1. 部署到服务器
cd /opt/nftablestool
chmod +x nftables-tool.sh

# 2. 安装 nftables（未安装时自动检测包管理器）
sudo ./nftables-tool.sh install

# 3. 初始化表结构（input 默认 accept，零干扰）
sudo ./nftables-tool.sh init

# 4. 查看可用模板
./nftables-tool.sh template list

# 5. 添加白名单：仅允许 10.0.1.0/24 访问 MongoDB
sudo ./nftables-tool.sh allow mongodb 10.0.1.0/24

# 6. 添加白名单：允许集群内网访问 SeaweedFS 全组件
sudo ./nftables-tool.sh allow seaweedfs 10.0.0.0/16

# 7. 查看规则
./nftables-tool.sh list
./nftables-tool.sh status

# 8. 清除某个模板的全部配置（链/规则/集合）
sudo ./nftables-tool.sh purge mongodb
```

## 命令参考

### `install`
检测系统中是否已安装 nftables，若未安装则自动选择合适的包管理器安装。

```bash
sudo ./nftables-tool.sh install
```

### `init`
初始化 nftables 表结构，并持久化配置。**input 链默认策略为 ACCEPT**，工具仅拦截通过 `allow` 声明的端口，其余流量原样放行，不影响系统已有的其他防火墙规则。

```bash
sudo ./nftables-tool.sh init
```

### `template list`
列出所有可用的中间件模板。

```bash
./nftables-tool.sh template list
```

### `template show <name>`
查看指定模板的端口和协议详情。

```bash
./nftables-tool.sh template show mongodb
```

### `allow <template> <ip[/mask]>`
允许指定 IP 地址或网段访问模板对应的端口。支持 CIDR 格式。模板定义的所有端口（含范围）通过一个端口集合统一管理，input 链仅追加一条跳转规则。

```bash
# 单个 IP
sudo ./nftables-tool.sh allow redis 192.168.0.5

# CIDR 网段
sudo ./nftables-tool.sh allow mongodb 10.0.1.0/24

# 模板包含端口范围时，自动处理（如 seaweedfs: 9333, 9080-9180, 8888）
sudo ./nftables-tool.sh allow seaweedfs 10.0.0.0/16
```

### `deny <template> <ip[/mask]>`
从白名单中移除指定 IP。

```bash
sudo ./nftables-tool.sh deny mongodb 10.0.1.0/24
```

### `purge <template>`
一键清除指定模板的所有配置，包括 input 跳转规则、专用链、IP 白名单集合和端口集合。

```bash
sudo ./nftables-tool.sh purge mongodb
```

### `list [template]`
列出白名单规则。可选指定模板名进行过滤。

```bash
# 列出全部
./nftables-tool.sh list

# 只看 MongoDB
./nftables-tool.sh list mongodb
```

### `status`
显示 nftables 运行状态和本工具规则概况。

```bash
./nftables-tool.sh status
```

### `save`
手动将当前规则持久化到 `/etc/nftables.conf`。

```bash
sudo ./nftables-tool.sh save
```

### `reset`
清除本工具创建的所有规则（仅删除 `inet nftables-tool` 表，不影响其他表）。

```bash
sudo ./nftables-tool.sh reset
```

## 内置模板

| 模板名 | 端口 | 说明 |
|--------|------|------|
| `mongodb` | 27017 | MongoDB 数据库 |
| `redis` | 6379 | Redis 缓存 |
| `seaweedfs` | 9333, 9080-9180, 8888 | SeaweedFS 分布式文件系统（master/volume/filer） |
| `mysql` | 3306 | MySQL / MariaDB |
| `postgresql` | 5432 | PostgreSQL |
| `elasticsearch` | 9200, 9300 | Elasticsearch（HTTP API + transport） |
| `kafka` | 9092, 9093 | Apache Kafka（plain + SSL） |
| `zookeeper` | 2181, 2888, 3888 | Apache ZooKeeper（client/peer/leader） |
| `consul` | 8300, 8301, 8302, 8500, 8600 | HashiCorp Consul（RPC/serf/HTTP/DNS） |
| `etcd` | 2379, 2380 | etcd 键值存储（client + peer） |

> 💡 **端口范围支持**：`.conf` 模板的 `PORTS` 支持端口范围语法（如 `9080-9180`），nftables `inet_service` 类型原生处理。SeaweedFS 的 volume 端口已使用范围表示。

## 自定义模板

在 `templates/` 目录下创建 `.conf` 文件即可。参考 `templates/custom.conf.example`：

```bash
# my-cluster.conf — 使用端口范围的集群模板
NAME="My App Cluster"
DESCRIPTION="应用集群（HTTP + 动态端口池）"
PORTS=("443" "8000-9000")
PROTOCOL="tcp"
```

创建后即可直接使用：

```bash
sudo ./nftables-tool.sh allow my-cluster 10.0.1.0/24
```

> 💡 **按组件拆分**：如果同一中间件的不同端口需要不同白名单策略，创建多个子模板即可。例如对 SeaweedFS 分别建 `seaweedfs-filer.conf`（`PORTS=("8888")`）和 `seaweedfs-volume.conf`（`PORTS=("9080-9180")`），各自独立管理。

## nftables 结构

```
table inet nftables-tool {
    chain input {
        type filter hook input priority 0; policy accept;
        # 每条跳转规则引用一个端口集合（ipset 风格）
        tcp dport @mongodb_ports   jump mongodb_chain
        tcp dport @seaweedfs_ports jump seaweedfs_chain
        # 未命中任何 dport → policy accept → 放行，不干扰其他规则
    }

    chain seaweedfs_chain {
        ip saddr @seaweedfs_allow accept   # IP 在白名单 → 放行
        reject                              # 其余 → 拒绝
    }

    set seaweedfs_allow {                   # IP 白名单集合
        type ipv4_addr
        elements = { 10.0.0.0/16 }
    }

    set seaweedfs_ports {                   # 端口集合（含范围）
        type inet_service
        elements = { 8888, 9080-9180, 9333 }
    }
}
```

### 流量路径

```
入站请求
  │
  ▼
input chain (policy accept)
  │
  ├─ dport ∈ @seaweedfs_ports？ → jump seaweedfs_chain
  │   ├─ saddr ∈ @seaweedfs_allow？ → accept ✓
  │   └─ 否 → reject ✗
  │
  └─ dport 不在任何端口集合中 → policy accept → 放行（交给系统其他规则）
```

### 与 iptables 对标

| iptables | nftables 等价 |
|---|---|
| `-m set --match-set IPS src -j ACCEPT` | `ip saddr @xxx_allow accept` |
| `-m set --match-set PORTS dst -j DROP` | `tcp dport @xxx_ports jump xxx_chain` → `reject` |
| `-j RETURN` | 不命中任何规则 → `policy accept` |

## 注意事项

- 所有修改防火墙的操作需要 root 权限（`sudo`）
- `init` 不会添加任何 allow/deny 规则，仅创建空表框架
- `allow` / `deny` 操作后自动持久化到 `/etc/nftables.conf`，重启保留
- `reset` 仅删除 `inet nftables-tool` 表，不影响系统其他 nftables/iptables 规则
- 模板文件位置：`templates/*.conf`，命名即模板名（不含 `.conf` 后缀）
