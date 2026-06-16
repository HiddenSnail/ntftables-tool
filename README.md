# nftables-tool

基于 nftables 的 IP 白名单端口访问控制工具。以白名单方式，让指定 IP 段访问指定中间件端口，支持多种中间件内置模板，一键管理。

## 依赖

- Linux 内核 >= 3.13（nftables 要求）
- nftables（工具会自动检测并安装）
- systemd（用于开机自启，可选）
- root 权限（操作 nftables 需要）

## 快速开始

```bash
# 1. 克隆或复制本项目到目标服务器
cd /opt/nftablestool

# 2. 赋予执行权限
chmod +x nftables-tool.sh

# 3. 安装 nftables（如果系统未安装）
sudo ./nftables-tool.sh install

# 4. 初始化安全基线
sudo ./nftables-tool.sh init

# 5. 查看可用模板
./nftables-tool.sh template list

# 6. 添加白名单：允许 10.0.1.0/24 网段访问 MongoDB
sudo ./nftables-tool.sh allow mongodb 10.0.1.0/24

# 7. 查看当前规则
./nftables-tool.sh list
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
允许指定 IP 地址或网段访问模板对应的中间件端口。支持 CIDR 格式。

```bash
# 允许单个 IP
sudo ./nftables-tool.sh allow redis 192.168.0.5

# 允许整个网段
sudo ./nftables-tool.sh allow mongodb 10.0.1.0/24

# 多端口模板（自动为所有端口添加规则）
sudo ./nftables-tool.sh allow seaweedfs 10.0.0.0/16
```

### `deny <template> <ip[/mask]>`
从白名单中移除指定 IP。集合为空时会提示清理链和规则。

```bash
sudo ./nftables-tool.sh deny mongodb 10.0.1.0/24
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
| `seaweedfs` | 9333, 8080, 8888 | SeaweedFS（全组件合一） |
| `seaweedfs-master` | 9333 | SeaweedFS Master 节点 |
| `seaweedfs-volume` | 8080 | SeaweedFS Volume 服务器 |
| `seaweedfs-filer` | 8888 | SeaweedFS Filer 服务器 |
| `mysql` | 3306 | MySQL / MariaDB |
| `postgresql` | 5432 | PostgreSQL |
| `elasticsearch` | 9200, 9300 | Elasticsearch（HTTP + transport） |
| `kafka` | 9092, 9093 | Apache Kafka |
| `zookeeper` | 2181, 2888, 3888 | Apache ZooKeeper |
| `consul` | 8300, 8301, 8302, 8500, 8600 | HashiCorp Consul |
| `etcd` | 2379, 2380 | etcd 键值存储 |

> 💡 **多端口中间件拆分策略**：像 SeaweedFS 这种不同端口有不同安全需求的中间件，我们提供了按组件拆分的子模板。你可以对不同端口设置不同的白名单策略。其他多端口模板（Elasticsearch、ZooKeeper 等）也可参考 `custom.conf.example` 自行创建子模板。

## 自定义模板

在 `templates/` 目录下创建 `.conf` 文件即可。参考 `templates/custom.conf.example`：

```bash
# my-service.conf
NAME="My Service"
DESCRIPTION="我的自定义服务"
PORTS=("8080" "9090")
PROTOCOL="tcp"
```

创建后即可直接使用：

```bash
sudo ./nftables-tool.sh allow my-service 10.0.1.0/24
```

## nftables 结构

```
table inet nftables-tool {
    chain input {
        type filter hook input priority 0; policy accept;   # ← 默认放行，最小干扰
        # 仅拦截已声明的端口
        tcp dport 27017 jump mongodb_chain
        tcp dport 6379  jump redis_chain
        tcp dport 8888  jump seaweedfs-filer_chain
        # 未匹配的流量：policy accept → 交给系统其他规则处理
    }

    chain mongodb_chain {
        ip saddr @mongodb_allow accept   # 白名单 IP → 放行
        reject                            # 非白名单 IP → 拒绝
    }

    set mongodb_allow {
        type ipv4_addr
        elements = { 10.0.1.0/24 }
    }
}
```

与 iptables `-j RETURN` 的对应关系：

| iptables 模式 | nftables 等价 |
|---|---|
| `-j ACCEPT` | 规则末尾 `accept` |
| `-j DROP` | 规则末尾 `drop` 或 `reject` |
| `-j RETURN` | 不匹配任何规则，回退到 chain policy（本工具设为 `accept`） |

## 注意事项

- 所有需要修改防火墙规则的操作均需 root 权限（sudo）
- `init` 初次执行时默认放行 SSH（22 端口），避免远程连接中断
- 规则自动持久化到 `/etc/nftables.conf`，重启后保留
- 本工具使用独立表 `inet nftables-tool`，不会影响系统已有的 nftables 规则
- `reset` 仅删除本工具的表，其他表不受影响
