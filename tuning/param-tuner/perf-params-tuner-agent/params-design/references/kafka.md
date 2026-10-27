# Kafka 参数调优参考

> **按需加载**：当 `app_info.jsonc` 中 `application.name` 为 Kafka 时加载本文件。
> **版本范围**：Kafka 2.8 ~ 3.6

## 场景适配

| 场景 | 场景名称 | 调优方向 | 关键差异 |
|------|---------|---------|---------|
| 消息队列 (Message Queue) | 高吞吐消息投递 | 网络 IO、批量、压缩 | batch.size / linger.ms 偏大 |
| 事件流 (Event Streaming) | 事件溯源、CQRS | 副本延迟、日志保留 | replica.lag.time.max.ms 偏小 |
| 日志收集 (Log Aggregation) | 海量日志聚合 | 分区数、保留策略 | num.partitions 偏大 |

## 参数清单

### Broker — 网络与 IO 线程

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `num.network.threads` | uniform_int | 网络请求处理线程数 | 3 | 3 ~ min(CPU核数, 32) |
| `num.io.threads` | uniform_int | 磁盘 IO 线程数 | 8 | 8 ~ min(CPU核数*2, 64) |
| `socket.send.buffer.bytes` | uniform_int | Socket 发送缓冲（bytes） | 102400(100KB) | 102400 ~ 1048576 |
| `socket.receive.buffer.bytes` | uniform_int | Socket 接收缓冲（bytes） | 102400(100KB) | 102400 ~ 1048576 |
| `socket.request.max.bytes` | uniform_int | 请求最大大小（bytes） | 104857600(100MB) | 104857600 ~ 1073741824 |

### Broker — 日志与存储

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `log.flush.interval.messages` | uniform_int | 消息数触发刷盘 | 9223372036854775807（不限） | 10000 ~ 1000000 |
| `log.flush.interval.ms` | uniform_int | 时间触发刷盘（ms） | null | 1000 ~ 60000 |
| `log.segment.bytes` | uniform_int | 日志段大小（bytes） | 1073741824(1GB) | 536870912 ~ 2147483648 |
| `log.retention.hours` | uniform_int | 日志保留时长（小时） | 168(7天) | 24 ~ 720 |
| `log.retention.bytes` | uniform_int | 日志保留大小（bytes） | -1（不限） | -1 ~ 物理磁盘 80% |
| `log.cleanup.policy` | categorical | 日志清理策略 | delete | delete / compact / delete,compact |

### Broker — 副本与一致性

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `num.replica.fetchers` | uniform_int | 副本拉取线程数 | 1 | 1 ~ min(CPU核数/4, 8) |
| `replica.fetch.max.bytes` | uniform_int | 副本拉取最大大小（bytes） | 1048576(1MB) | 1048576 ~ 10485760 |
| `replica.lag.time.max.ms` | uniform_int | 副本延迟最大时间（ms） | 30000 | 10000 ~ 60000 |
| `default.replication.factor` | uniform_int | 默认副本数 | 3 | 1 ~ 5 |
| `min.insync.replicas` | uniform_int | 最小同步副本数 | 1 | 1 ~ default.replication.factor |

### Broker — 内存与消息

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `message.max.bytes` | uniform_int | 单条消息最大大小（bytes） | 1048588(1MB) | 1048576 ~ 10485760 |
| `queued.max.requests` | uniform_int | 排队请求最大数 | 500 | 500 ~ 10000 |
| `num.partitions` | uniform_int | 默认分区数 | 1 | broker数 * 2 ~ broker数 * 10 |

### Producer

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `batch.size` | uniform_int | 批量大小（bytes） | 16384(16KB) | 16384 ~ 1048576 |
| `linger.ms` | uniform_int | 批量等待时间（ms） | 0 | 0 ~ 50 |
| `compression.type` | categorical | 压缩算法 | none | none / gzip / snappy / lz4 / zstd |
| `acks` | categorical | 确认级别 | 1 | 0 / 1 / all |
| `buffer.memory` | uniform_int | 生产者缓冲（bytes） | 33554432(32MB) | 33554432 ~ 268435456 |

### Consumer

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `fetch.min.bytes` | uniform_int | 最小拉取大小（bytes） | 1 | 1 ~ 1048576 |
| `fetch.max.wait.ms` | uniform_int | 最大拉取等待（ms） | 500 | 100 ~ 5000 |
| `max.partition.fetch.bytes` | uniform_int | 每分区拉取上限（bytes） | 1048576(1MB) | 1048576 ~ 10485760 |
| `session.timeout.ms` | uniform_int | 消费者会话超时（ms） | 45000 | 10000 ~ 120000 |
| `max.poll.records` | uniform_int | 单次 poll 最大记录数 | 500 | 100 ~ 10000 |

## immutable 判定参考（消息队列场景）

| 参数 | immutable 值 | 原因 |
|------|-------------|------|
| `compression.type` | lz4 | lz4 性能/压缩比最优，生产端固定 |
| `default.replication.factor` | 3 | 高可用标准，2 副本无法容忍 1 节点故障+1 副本降级 |
