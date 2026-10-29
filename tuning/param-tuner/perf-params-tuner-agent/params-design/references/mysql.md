# MySQL 参数调优参考

> **按需加载**：当 `app_info.jsonc` 中 `application.name` 为 MySQL 时加载本文件。
> **版本范围**：MySQL 5.7 ~ 8.0

## 场景适配

| 场景 | 场景名称 | 调优方向 | 关键差异 |
|------|---------|---------|---------|
| OLTP（在线事务处理） | 短事务高并发 | 缓冲池、连接池、redo log | innodb_flush_log_at_trx_commit=1 或 2 |
| OLAP（在线分析查询） | 长查询大扫描 | 排序缓冲、临时表、并行查询 | sort_buffer_size / tmp_table_size 偏大 |
| 混合负载 (HTAP) | 事务+分析 | 资源隔离、并行度 | innodb_parallel_read_threads |

## 参数清单

### InnoDB 缓冲池

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `innodb_buffer_pool_size` | uniform_int | InnoDB 缓冲池大小（bytes） | 134217728(128MB) | 物理内存 60%~75% |
| `innodb_buffer_pool_instances` | uniform_int | 缓冲池实例数 | 1 | 1 ~ 64（buffer_pool_size > 1GB 时建议 8） |
| `innodb_buffer_pool_chunk_size` | uniform_int | 缓冲池 chunk 大小（bytes） | 134217728(128MB) | 67108864 ~ 2147483648 |

### Redo Log 与 Binlog

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `innodb_log_file_size` | uniform_int | Redo log 文件大小（bytes） | 50331648(48MB) | 268435456 ~ 8589934592 |
| `innodb_log_files_in_group` | uniform_int | Redo log 文件数 | 2 | 2 ~ 4 |
| `innodb_flush_log_at_trx_commit` | categorical | 事务提交刷 redo log | 1 | 0 / 1 / 2 |
| `sync_binlog` | uniform_int | Binlog 刷盘频率（N 次事务后刷） | 0 | 0 ~ 1 |
| `binlog_cache_size` | uniform_int | Binlog 缓存大小（bytes） | 32768(32KB) | 32768 ~ 1048576 |

### IO 与存储引擎

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `innodb_io_capacity` | uniform_int | InnoDB IO 容量（IOPS） | 200 | 200 ~ 100000（SSD 建议 2000~5000） |
| `innodb_io_capacity_max` | uniform_int | InnoDB IO 容量上限（IOPS） | 2000 | 2000 ~ 200000（SSD 建议 5000~20000） |
| `innodb_flush_method` | categorical | InnoDB 刷盘方式 | fsync | O_DIRECT / O_DIRECT_NO_FSYNC / fsync |
| `innodb_doublewrite` | categorical | 双写缓冲 | ON | ON / OFF |

### 连接与线程

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `max_connections` | uniform_int | 最大连接数 | 151 | 100 ~ 100000 |
| `thread_cache_size` | uniform_int | 线程缓存数 | 151 | 16 ~ 4096 |
| `back_log` | uniform_int | 连接 backlog 队列 | 151 | 512 ~ 65535 |
| `wait_timeout` | uniform_int | 空闲连接超时（秒） | 28800 | 300 ~ 86400 |

### 排序与临时表

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `sort_buffer_size` | uniform_int | 排序缓冲（bytes） | 262144(256KB) | 262144 ~ 4194304 |
| `join_buffer_size` | uniform_int | Join 缓冲（bytes） | 262144(256KB) | 262144 ~ 4194304 |
| `tmp_table_size` | uniform_int | 内存临时表上限（bytes） | 16777216(16MB) | 16777216 ~ 268435456 |
| `max_heap_table_size` | uniform_int | Memory 引擎表上限（bytes） | 16777216(16MB) | 16777216 ~ 268435456 |

### 并行查询（MySQL 8.0+）

| 参数 | ptype | 说明 | default | 建议范围/可选值 |
|------|-------|------|---------|----------------|
| `innodb_parallel_read_threads` | uniform_int | 并行读线程数 | 4 | 2 ~ min(CPU核数/2, 32) |

## immutable 判定参考（OLTP 场景）

| 参数 | immutable 值 | 原因 |
|------|-------------|------|
| `innodb_doublewrite` | ON | 数据安全要求，防止页撕裂 |
| `innodb_flush_method` | O_DIRECT | 绕过 OS page cache，避免双缓冲 |
