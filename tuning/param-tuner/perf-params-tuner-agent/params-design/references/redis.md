# Redis 参数调优参考

> **按需加载**：当 `app_info.jsonc` 中 `application.name` 为 Redis 时加载本文件。
> **版本范围**：Redis 6.2 ~ 7.2

## 场景适配

| 场景 | 场景名称 | 调优方向 | 关键差异 |
|------|---------|---------|---------|
| 缓存 (Cache) | 数据可丢失，追求吞吐/延迟 | maxmemory 淘汰策略、AOF 关闭、惰性删除 | appendonly=no（immutable） |
| 持久化 (Persistence) | 数据不可丢失，追求可靠性 | AOF 开启、fsync 策略、RDB 频率 | appendonly=yes（可调） |
| 消息队列 (Message Queue) | Stream/List 场景 | 内存紧凑编码、消费者超时 | 紧凑编码阈值（6.x ziplist / 7.x listpack） |

## 参数清单

### 内存容量与淘汰策略

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `maxmemory` | uniform_int | 最大内存限制（bytes） | 0（不限制） | 物理内存 60%~80% |
| `maxmemory-policy` | categorical | 淘汰策略 | noeviction | allkeys-lfu / allkeys-lru / volatile-lfu / volatile-lru / volatile-ttl / noeviction |
| `maxmemory-samples` | uniform_int | 淘汰采样数 | 5 | 3 ~ 10 |

### 网络与连接

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `tcp-backlog` | uniform_int | TCP 连接队列 | 511 | 511 ~ 65535 |
| `timeout` | uniform_int | 空闲连接超时（秒） | 0（不超时） | 0 ~ 3600 |
| `tcp-keepalive` | uniform_int | TCP keepalive 探测间隔（秒） | 0（禁用） | 0 ~ 300 |

### IO 多线程

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `io-threads` | uniform_int | IO 线程数 | 1 | 1 ~ min(CPU核数/4, 64) |
| `io-threads-do-reads` | categorical | IO 线程处理读请求 | no | yes / no |

### 惰性删除

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `lazyfree-lazy-eviction` | categorical | 内存淘汰异步释放 | no | yes / no |
| `lazyfree-lazy-expire` | categorical | 过期 key 异步释放 | no | yes / no |
| `lazyfree-lazy-server-del` | categorical | DEL/RENAME 异步释放 | no | yes / no |

### 持久化 — RDB

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `save` | categorical | RDB 保存策略 | `900 1 300 10 60 10000` | `900 1 300 10 60 10000` / `3600 1 300 100` / `""`（禁用） |
| `stop-writes-on-bgsave-error` | categorical | bgsave 失败时停止写入 | yes | yes / no |
| `rdbcompression` | categorical | RDB 压缩 | yes | yes / no |
| `rdbchecksum` | categorical | RDB 校验和 | yes | yes / no |

### 持久化 — AOF

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `appendonly` | categorical | 是否启用 AOF | no | yes / no |
| `appendfsync` | categorical | AOF 刷盘策略 | everysec | always / everysec / no |
| `auto-aof-rewrite-percentage` | uniform_int | AOF 重写增长百分比 | 100 | 0 ~ 200 |
| `auto-aof-rewrite-min-size` | uniform_int | AOF 重写最小大小（bytes） | 67108864 | 16777216 ~ 1073741824 |

### 紧凑编码

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `hash-max-ziplist-entries` | uniform_int | Hash 紧凑编码最大元素数（7.0+ 为 hash-max-listpack-entries） | 512 | 64 ~ 1024 |
| `hash-max-ziplist-value` | uniform_int | Hash 紧凑编码最大值 bytes（7.0+ 为 hash-max-listpack-value） | 64 | 32 ~ 512 |
| `set-max-intset-entries` | uniform_int | Set 整数编码最大元素数 | 512 | 64 ~ 2048 |
| `zset-max-ziplist-entries` | uniform_int | ZSet 紧凑编码最大元素数（7.0+ 为 zset-max-listpack-entries） | 128 | 64 ~ 1024 |
| `zset-max-ziplist-value` | uniform_int | ZSet 紧凑编码最大值 bytes（7.0+ 为 zset-max-listpack-value） | 64 | 32 ~ 512 |

### 后台任务与碎片整理

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `hz` | uniform_int | 后台任务频率 | 10 | 1 ~ 50 |
| `dynamic-hz` | categorical | 动态调整 hz | yes | yes / no |
| `activedefrag` | categorical | 主动碎片整理 | no | yes / no |
| `active-defrag-ignore-bytes` | uniform_int | 碎片整理忽略阈值（bytes） | 104857600 | 67108864 ~ 2147483648 |
| `active-defrag-threshold-lower` | uniform_int | 碎片率下限触发（%） | 10 | 5 ~ 30 |
| `active-defrag-threshold-upper` | uniform_int | 碎片率上限激增（%） | 100 | 20 ~ 60 |

## immutable 判定参考（缓存场景）

| 参数 | immutable 值 | 原因 |
|------|-------------|------|
| `appendonly` | no | 缓存数据可丢失，AOF 无需开启 |
| `appendfsync` | everysec | AOF 已关闭，此参数不生效 |
| `auto-aof-rewrite-percentage` | 100 | AOF 已关闭，此参数不生效 |
| `auto-aof-rewrite-min-size` | 67108864 | AOF 已关闭，此参数不生效 |
| `stop-writes-on-bgsave-error` | no | 缓存数据可丢失，不应因 bgsave 错误停写 |
| `rdbcompression` | yes | bgsave 子进程压缩，不影响主线程吞吐 |
| `rdbchecksum` | yes | 数据完整性校验，应始终开启 |
| `dynamic-hz` | yes | 自适应频率调整，无理由关闭 |
