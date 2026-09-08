# fastutil 类型→类映射

fastutil 提供类型特化的容器，直接存储基本类型（无装箱）。类名编码了 key 和 value 的类型：map 用 `Key2ValueOpenHashMap`，set 用 `KeyOpenHashSet`。

## 类名中的基本类型 token

| Java 包装类 / 基本类型 | fastutil token |
|---|---|
| `byte` / `Byte`    | `Byte`   |
| `short` / `Short`  | `Short`  |
| `int` / `Integer`  | `Int`    |
| `long` / `Long`    | `Long`   |
| `float` / `Float`  | `Float`  |
| `double` / `Double`| `Double` |
| `char` / `Character` | `Char` |
| `boolean` / `Boolean` | `Boolean` |
| 引用类型 (`T`) | `Object` |

## 常见 map 替换

| 原始 | fastutil (key→value) |
|---|---|
| `HashMap<Long, Integer>`  | `Long2IntOpenHashMap` |
| `HashMap<Long, Long>`    | `Long2LongOpenHashMap` |
| `HashMap<Long, Double>`  | `Long2DoubleOpenHashMap` |
| `HashMap<Long, String>`  | `Long2ObjectOpenHashMap<String>` (value 是引用 → 用 `Object`) |
| `HashMap<Long, MyType>`  | `Long2ObjectOpenHashMap<MyType>` |
| `HashMap<Integer, Integer>` | `Int2IntOpenHashMap` |
| `HashMap<Integer, Long>`   | `Int2LongOpenHashMap` |
| `HashMap<Integer, MyType>` | `Int2ObjectOpenHashMap<MyType>` |
| `HashMap<Short, Integer>`  | `Short2IntOpenHashMap` |
| `HashMap<Short, MyType>`   | `Short2ObjectOpenHashMap<MyType>` |
| `HashMap<Byte, Integer>`   | `Byte2IntOpenHashMap` |
| `HashMap<String, Long>`    | *保持原样* —— String 是引用 key；fastutil 的 `Object2LongOpenHashMap<String>` 可用但对引用 key 相比原生 `HashMap` 收益甚微。大收益来自基本类型 key。 |

## Set 替换

| 原始 | fastutil |
|---|---|
| `HashSet<Long>`     | `LongOpenHashSet` |
| `HashSet<Integer>`  | `IntOpenHashSet` |
| `HashSet<Short>`    | `ShortOpenHashSet` |
| `HashSet<Byte>`      | `ByteOpenHashSet` |
| `HashSet<Double>`   | `DoubleOpenHashSet` |

## 并发注意事项

fastutil **不**提供并发 map。若原来是 `ConcurrentHashMap<Long, Integer>`：
- 方案 A：保留 `ConcurrentHashMap`（保留线程安全，失去 value 的装箱收益，但 long key 仍会装箱）。
- 方案 B：用加条纹锁（striped locks）保护的 fastutil map，或按 key hash 分片后每片一个 `Long2IntOpenHashMap`。
- 方案 C：若读多写少，copy-on-write 或读锁保护的 `Long2IntOpenHashMap` 即可。

除非装箱成本被实测为瓶颈，否则默认保留 `ConcurrentHashMap` —— 正确性优先。

## 迭代变化

- `for (Map.Entry<Long,Integer> e : map.entrySet())` → `for (Long2IntMap.Entry e : map.long2IntEntrySet())`（类型特化 entry set 避免迭代时装箱）。
- `map.get(k)` 现在接受 `long`，返回 `int`；`map.getOrDefault(k, def)` 同理。
- `containsKey(k)` 接受 `long`。
- key 不存在时默认返回 `0`（或该类型的零值）——若 `0` 在业务上是合法值，用 2 参构造器 `new Long2IntOpenHashMap(defaultValue)` 或检查 `containsKey` 区分。**这是最常见的迁移 bug** —— 把"不存在"静默当作 `0`。

## API 表面

所有 fastutil map 实现对应的 `Key2ValueMap` 接口，该接口*同时*继承 `java.util.Map<Key,Value>`（装箱），因此装箱 API 仍可用于渐进迁移——但只有在热路径上使用类型特化方法（`get(long)`、`put(long,int)`）才能真正避免装箱。
