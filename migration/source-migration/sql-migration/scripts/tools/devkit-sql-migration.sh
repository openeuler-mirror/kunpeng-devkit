#!/usr/bin/env bash
# devkit-sql-migration.sh
# 用法：
# 基本用法（无数据库连接信息，静态分析）：
#   JAVA_PATH=<java路径> JAR_PATH=<sql-analysis-x.x.x.jar路径> \
#   PROJECT_ROOT=<项目根目录> WORK_DIR=<工作目录> \
#   SOURCE_DB=<规范源数据库类型> TARGET_DB=<规范目标数据库类型> \
#   bash devkit-sql-migration.sh
#
# 方式1：环境变量指定数据库连接信息（自动启用动态兼容性评估，统一入口默认走此方式）：
#   JAVA_PATH=<java路径> JAR_PATH=<sql-analysis-x.x.x.jar路径> \
#   PROJECT_ROOT=<项目根目录> WORK_DIR=<工作目录> \
#   SOURCE_DB=<规范源数据库类型> TARGET_DB=<规范目标数据库类型> \
#   SOURCE_DB_USER=<用户名> SOURCE_DB_JDBC_URL=<URL> \
#   SOURCE_DB_DRIVER_JAR_PATH=<驱动JAR路径> SOURCE_DB_DRIVER_CLASS_NAME=<驱动类名> \
#   SOURCE_DB_PWD=<源库密码> \
#   TARGET_DB_USER=<用户名> TARGET_DB_JDBC_URL=<URL> \
#   TARGET_DB_DRIVER_JAR_PATH=<驱动JAR路径> TARGET_DB_DRIVER_CLASS_NAME=<驱动类名> \
#   TARGET_DB_PWD=<目标库密码> \
#   bash devkit-sql-migration.sh
#
# 方式2：通过JSON文件获取数据库连接信息（仅供独立调试，统一入口不使用此方式）：
#   JAVA_PATH=<java路径> JAR_PATH=<sql-analysis-x.x.x.jar路径> \
#   PROJECT_ROOT=<项目根目录> WORK_DIR=<工作目录> \
#   SOURCE_DB=<规范源数据库类型> TARGET_DB=<规范目标数据库类型> \
#   DB_PARAMS_MODE=1 DB_PARAMS_FILE_PATH=<配置文件路径> \
#   bash devkit-sql-migration.sh
#
# 说明：
#   - 方式1（环境变量）为统一入口 sql_migration.py 默认调用方式，由 db_env() 把
#     assets/db-connection.json 中的字段拆解到环境变量传入；密码不进入命令行参数。
#   - 方式2（JSON 文件模式）仅供独立调试使用，将 JSON 路径透传给 jar。
#     注意：JSON 文件不含密码，无论方式1 还是方式2，密码仍需通过
#     SOURCE_DB_PWD / TARGET_DB_PWD 环境变量提供。
#   - SOURCE_DB / TARGET_DB 应使用规范数据库名（如 'Oracle'，而非 'Oracle 11g'），
#     由统一入口在阶段 1 通过 sql_mig_route.json 归一化后传入。
#
# 密码自动化说明：
#   jar 包通过交互式提示读取源库和目标库密码（不支持 CLI 参数传递）
#   脚本会自动处理密码输入：
#   - 优先使用 expect（创建伪终端，兼容 Console.readPassword()）
#   - expect 不可用时回退到 stdin 管道（适用于 Scanner/BufferedReader 读取方式）
#   - 需设置 SOURCE_DB_PWD 和 TARGET_DB_PWD 环境变量

# 构建命令参数
CMD="${JAVA_PATH} -jar ${JAR_PATH}"
CMD="${CMD} -p ${PROJECT_ROOT}"
CMD="${CMD} -o ${WORK_DIR}/reports"
CMD="${CMD} --db-source-type ${SOURCE_DB}"
CMD="${CMD} --db-target-type ${TARGET_DB}"

# 处理数据库连接信息，并判断是否启用动态兼容性评估
HAS_DB_PARAMS=false
# 分别追踪源库和目标库是否有连接信息（决定需要哪个密码）
HAS_SOURCE_DB_PARAMS=false
HAS_TARGET_DB_PARAMS=false

if [ "${DB_PARAMS_MODE}" = "1" ]; then
    # 方式2：通过JSON文件获取数据库连接信息（仅供独立调试）
    if [ -z "${DB_PARAMS_FILE_PATH}" ]; then
        echo "错误：DB_PARAMS_MODE=1 需要指定 DB_PARAMS_FILE_PATH 环境变量"
        exit 1
    fi
    if [ ! -f "${DB_PARAMS_FILE_PATH}" ]; then
        echo "错误：数据库配置文件不存在：${DB_PARAMS_FILE_PATH}"
        exit 1
    fi
    CMD="${CMD} --db-params-file-path ${DB_PARAMS_FILE_PATH}"
    HAS_DB_PARAMS=true
    # 方式2 无法从外部判断 JSON 中包含哪些库的连接信息，保守起见都设为 true
    HAS_SOURCE_DB_PARAMS=true
    HAS_TARGET_DB_PARAMS=true
else
    # 方式1：通过环境变量指定数据库连接信息（统一入口默认走此方式）
    if [ -n "${SOURCE_DB_JDBC_URL}" ]; then
        CMD="${CMD} --source-db-jdbc-url ${SOURCE_DB_JDBC_URL}"
        HAS_DB_PARAMS=true
        HAS_SOURCE_DB_PARAMS=true
    fi
    if [ -n "${SOURCE_DB_USER}" ]; then
        CMD="${CMD} --source-db-user ${SOURCE_DB_USER}"
    fi
    if [ -n "${SOURCE_DB_DRIVER_JAR_PATH}" ]; then
        CMD="${CMD} --source-db-driver-jar-path ${SOURCE_DB_DRIVER_JAR_PATH}"
    fi
    if [ -n "${SOURCE_DB_DRIVER_CLASS_NAME}" ]; then
        CMD="${CMD} --source-db-driver-class-name ${SOURCE_DB_DRIVER_CLASS_NAME}"
    fi
    if [ -n "${TARGET_DB_JDBC_URL}" ]; then
        CMD="${CMD} --target-db-jdbc-url ${TARGET_DB_JDBC_URL}"
        HAS_DB_PARAMS=true
        HAS_TARGET_DB_PARAMS=true
    fi
    if [ -n "${TARGET_DB_USER}" ]; then
        CMD="${CMD} --target-db-user ${TARGET_DB_USER}"
    fi
    if [ -n "${TARGET_DB_DRIVER_JAR_PATH}" ]; then
        CMD="${CMD} --target-db-driver-jar-path ${TARGET_DB_DRIVER_JAR_PATH}"
    fi
    if [ -n "${TARGET_DB_DRIVER_CLASS_NAME}" ]; then
        CMD="${CMD} --target-db-driver-class-name ${TARGET_DB_DRIVER_CLASS_NAME}"
    fi
fi

# 自动启用动态兼容性评估：当检测到有数据库连接信息时自动启用
if [ "${HAS_DB_PARAMS}" = "true" ]; then
    CMD="${CMD} --enable-analysis-enhance"
    echo "检测到数据库连接信息，自动启用动态兼容性评估"
fi

# 执行命令
echo "执行DevKit SQL迁移..."
echo $CMD

# --- 密码自动化处理 ---
# jar 包通过交互式提示读取源库和目标库密码（"Please Input Source DB Password" / "Please Input Target DB Password"）
# 不支持 CLI 参数传递密码，需要通过标准输入完成自动化处理
# JSON 文件（方式2）不含密码，无论方式1 还是方式2 都需要通过环境变量传递密码
RESULT=0

# 判断需要哪些密码：仅对提供了连接信息的库要求密码
NEED_SOURCE_PWD=false
NEED_TARGET_PWD=false
if [ "${HAS_SOURCE_DB_PARAMS}" = "true" ] && [ -n "${SOURCE_DB_PWD:-}" ]; then
    NEED_SOURCE_PWD=true
fi
if [ "${HAS_TARGET_DB_PARAMS}" = "true" ] && [ -n "${TARGET_DB_PWD:-}" ]; then
    NEED_TARGET_PWD=true
fi

# 需要密码自动化：有 DB 连接信息且至少有一个密码已设置
NEED_PWD_AUTOMATION=false
if [ "${HAS_DB_PARAMS}" = "true" ] && { [ "${NEED_SOURCE_PWD}" = "true" ] || [ "${NEED_TARGET_PWD}" = "true" ]; }; then
    NEED_PWD_AUTOMATION=true
fi

if [ "${NEED_PWD_AUTOMATION}" = "true" ]; then
    # 有数据库连接信息且有密码环境变量，需自动处理交互式密码输入
    if command -v expect >/dev/null 2>&1; then
        # 优先使用 expect：创建伪终端，兼容 Console.readPassword()
        echo "使用 expect 自动处理密码输入..."
        # 通过环境变量传递敏感信息给 expect，避免 heredoc 中转义问题
        # expect 脚本说明：
        #   - 使用 exp_continue 循环处理密码提示，不依赖固定顺序（Source/Target 可任意顺序出现）
        #   - 密码只发送 1 次。若 jar 再次提示（密码错误），立即报错退出。
        #     若数据库连接模式执行失败，可按流程降级为无数据库连接模式重跑。
        #   - eof 分支处理 jar 不提示密码的情况（如密码已在其他途径提供）
        #   - timeout 分支处理 jar 卡死的情况
        #   - send -- 防止密码以 '-' 开头被误判为 expect 选项
        #   - lindex 而非 lassign，兼容 Tcl 8.4+
        CMD_TO_RUN="$CMD" SRC_PWD="$SOURCE_DB_PWD" TGT_PWD="$TARGET_DB_PWD" expect << 'EXPECT_EOF'
set timeout 1800
set cmd $env(CMD_TO_RUN)
set src_pwd $env(SRC_PWD)
set tgt_pwd $env(TGT_PWD)
set src_sent 0
set tgt_sent 0
spawn bash -c "$cmd"
expect {
    -re {Source.*[Pp]assword} {
        if {$src_sent > 0} {
            send_error "Error: Source DB Password rejected (wrong password). Fallback to no-DB mode.\n"
            exit 1
        }
        send -- "$src_pwd\r"
        set src_sent 1
        exp_continue
    }
    -re {Target.*[Pp]assword} {
        if {$tgt_sent > 0} {
            send_error "Error: Target DB Password rejected (wrong password). Fallback to no-DB mode.\n"
            exit 1
        }
        send -- "$tgt_pwd\r"
        set tgt_sent 1
        exp_continue
    }
    eof {}
    timeout {
        send_error "Error: Timeout waiting for jar to complete\n"
        exit 1
    }
}
# 捕获子进程退出码（lindex 兼容 Tcl 8.4+，lassign 仅 8.5+）
set wait_result [wait]
exit [lindex $wait_result 3]
EXPECT_EOF
        RESULT=$?
    else
        # 回退方案：stdin 管道（适用于 jar 使用 Scanner/BufferedReader 读取密码的场景）
        # 限制：
        #   1. 若 jar 使用 Console.readPassword()，System.console() 在 stdin 重定向时返回 null，
        #      jar 可能崩溃或无法读取密码。此场景需安装 expect。
        #   2. 密码只发送 1 次。若密码错误 jar 会提示重新输入，但 stdin 已无数据，
        #      jar 将收到 EOF 并报错退出。可按流程降级为无数据库连接模式重跑。
        #   3. 仅发送已设置的密码（按 Source → Target 顺序，与 jar 提示顺序一致）。
        echo "警告：expect 不可用，使用 stdin 管道传递密码（可靠性较低，建议安装 expect）..."
        STDIN_PWD=""
        if [ "${NEED_SOURCE_PWD}" = "true" ]; then
            STDIN_PWD="${SOURCE_DB_PWD}"
        fi
        if [ "${NEED_TARGET_PWD}" = "true" ]; then
            if [ -n "${STDIN_PWD}" ]; then
                STDIN_PWD="${STDIN_PWD}\n${TARGET_DB_PWD}"
            else
                STDIN_PWD="${TARGET_DB_PWD}"
            fi
        fi
        printf "%b\n" "${STDIN_PWD}" | eval "$CMD"
        RESULT=$?
        # 敏感信息使用完毕后立即清空：STDIN_PWD 是脚本本地中转变量，残留风险最大
        unset STDIN_PWD
    fi
else
    # 无需密码自动化的场景：
    # 1. 无数据库连接信息：jar 不会提示输入密码
    # 2. 有连接信息但对应密码环境变量缺失：报错防止挂起
    if [ "${HAS_SOURCE_DB_PARAMS}" = "true" ] && [ -z "${SOURCE_DB_PWD:-}" ]; then
        echo "错误：检测到源库连接信息但未设置 SOURCE_DB_PWD 环境变量"
        echo "jar 包会交互式提示输入密码，当前自动化流程无法处理"
        echo "请设置 SOURCE_DB_PWD 环境变量后重试"
        exit 1
    fi
    if [ "${HAS_TARGET_DB_PARAMS}" = "true" ] && [ -z "${TARGET_DB_PWD:-}" ]; then
        echo "错误：检测到目标库连接信息但未设置 TARGET_DB_PWD 环境变量"
        echo "jar 包会交互式提示输入密码，当前自动化流程无法处理"
        echo "请设置 TARGET_DB_PWD 环境变量后重试"
        exit 1
    fi
    eval "$CMD"
    RESULT=$?
fi

# 敏感信息使用完毕后立即清空：所有密码自动化路径已汇合，统一清理本脚本进程持有的密码环境变量
# 注意：inline env（expect 路径的 SRC_PWD/TGT_PWD）作用域仅限 expect 子进程，无需单独清理
unset CMD_TO_RUN SRC_PWD TGT_PWD 2>/dev/null || true
unset NEED_SOURCE_PWD NEED_TARGET_PWD NEED_PWD_AUTOMATION 2>/dev/null || true
unset SOURCE_DB_PWD TARGET_DB_PWD 2>/dev/null || true

# 检查执行结果
if [ $RESULT -eq 0 ]; then
    echo "DevKit SQL迁移执行成功"
else
    echo "DevKit SQL迁移执行失败，退出码：$RESULT"
    if [ "${HAS_DB_PARAMS}" = "true" ]; then
        echo "提示：数据库连接信息可能导致失败（密码错误/连接不通），可降级为无数据库连接模式重跑（不传 DB 参数和密码）"
    fi
    exit 1
fi
