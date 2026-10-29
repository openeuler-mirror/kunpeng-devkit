# Spark 参数调优参考

> **按需加载**：当 `app_info.jsonc` 中 `application.name` 为 Spark 时加载本文件。
> **版本范围**：Spark 3.0 ~ 3.5

## 场景适配

| 场景 | 场景名称 | 调优方向 | 关键差异 |
|------|---------|---------|---------|
| Batch（批处理） | 大数据量离线计算 | 并行度、Shuffle、序列化 | spark.sql.shuffle.partitions 偏大 |
| Streaming（流处理） | 实时微批处理 | 延迟、背压、批次间隔 | spark.streaming.backpressure.enabled=true |
| SQL（交互查询） | 即席查询 | 缓存、自适应执行 | spark.sql.adaptive.enabled=true |
| MLlib（机器学习） | 模型训练 | 内存、迭代计算 | spark.memory.fraction 偏大 |

## 参数清单

### 内存配置

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `spark.executor.memory` | uniform_int | Executor 堆内存（MB） | 1024 | 2048 ~ 65536 |
| `spark.executor.memoryOverhead` | uniform_int | Executor 堆外内存（MB） | executor.memory*0.1 | 512 ~ 16384 |
| `spark.driver.memory` | uniform_int | Driver 堆内存（MB） | 1024 | 1024 ~ 32768 |
| `spark.memory.fraction` | uniform_float | Spark 内存占比 | 0.6 | 0.5 ~ 0.8 |
| `spark.memory.storageFraction` | uniform_float | 存储内存占比 | 0.5 | 0.3 ~ 0.7 |

### 并行度与分区

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `spark.sql.shuffle.partitions` | uniform_int | SQL Shuffle 分区数 | 200 | executor_core数 * executor数 * 2~4 |
| `spark.default.parallelism` | uniform_int | RDD 默认并行度 | 总核数 | executor_core数 * executor数 * 2~4 |
| `spark.sql.adaptive.enabled` | categorical | 自适应查询执行 | false | true / false |
| `spark.sql.adaptive.coalescePartitions.enabled` | categorical | 自适应合并分区 | true | true / false |

### 序列化

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `spark.serializer` | categorical | 序列化器 | JavaSerializer | KryoSerializer / JavaSerializer |
| `spark.kryoserializer.buffer.max` | uniform_int | Kryo 最大缓冲（MB） | 64 | 64 ~ 512 |
| `spark.kryo.registrationRequired` | categorical | 是否强制注册类 | false | true / false |

### Shuffle

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `spark.shuffle.file.buffer` | uniform_int | Shuffle 缓冲（KB） | 32 | 32 ~ 256 |
| `spark.reducer.maxSizeInFlight` | uniform_int | Reducer 拉取缓冲（MB） | 48 | 48 ~ 256 |
| `spark.shuffle.io.retryCount` | uniform_int | Shuffle IO 重试次数 | 3 | 3 ~ 10 |
| `spark.shuffle.io.backLog` | uniform_int | Shuffle 连接队列 | 0 | 100 ~ 1024 |
| `spark.shuffle.service.enabled` | categorical | 外部 Shuffle 服务 | false | true / false |

### 执行器资源

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `spark.executor.cores` | uniform_int | Executor CPU 核数 | 1 | 2 ~ 8（HDFS 限 5） |
| `spark.executor.instances` | uniform_int | Executor 实例数 | 2 | 2 ~ 500 |
| `spark.task.cpus` | uniform_int | 每个 Task CPU 核数 | 1 | 1 ~ 4 |

### 流处理（Streaming）

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `spark.streaming.backpressure.enabled` | categorical | 背压机制 | false | true / false |
| `spark.streaming.backpressure.initialRate` | uniform_int | 背压初始速率 | 0 | 1000 ~ 100000 |
| `spark.streaming.receiver.maxRate` | uniform_int | Receiver 最大速率 | 0 | 1000 ~ 100000 |

## immutable 判定参考（Batch 场景）

| 参数 | immutable 值 | 原因 |
|------|-------------|------|
| `spark.serializer` | KryoSerializer | Kryo 性能远优于 Java 序列化 |
| `spark.sql.adaptive.enabled` | true | AQE 自适应执行在 3.0+ 已稳定 |
