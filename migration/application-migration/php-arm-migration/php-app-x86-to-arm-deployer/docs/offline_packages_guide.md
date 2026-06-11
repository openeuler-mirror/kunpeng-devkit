# 离线包准备说明

目标机无法访问外网或 yum 源不可用时，请提前准备离线包并上传到：

```bash
/opt/migration/packages/
```

## 必需文件

### 1. PHP 源码包

```text
php-7.0.33.tar.gz
```

官方地址：

```text
https://www.php.net/distributions/php-7.0.33.tar.gz
https://museum.php.net/php7/php-7.0.33.tar.gz
```

上传路径：

```bash
/opt/migration/packages/php-7.0.33.tar.gz
```

### 2. 应用包

支持：

```text
app.tar.gz
app.zip
```

建议上传路径：

```bash
/opt/migration/packages/app.tar.gz
```

或：

```bash
/opt/migration/packages/app.zip
```

## 可能需要的 RPM 包

PHP 编译常见依赖：

```text
gcc
gcc-c++
make
autoconf
automake
libtool
bison
re2c
libxml2-devel
openssl-devel
curl-devel
zlib-devel
bzip2-devel
libjpeg-devel
libpng-devel
freetype-devel
sqlite-devel
readline-devel
gettext-devel
libXpm-devel
libxslt-devel
libicu-devel
libzip-devel
```

nginx 常见包：

```text
nginx
nginx-filesystem
pcre
pcre-devel
openssl
zlib
```

不同 openEuler 22.03 环境的包名和依赖可能略有差异，请以目标机 yum 依赖解析结果为准。

## 推荐离线准备方法

在同版本、同架构、可联网的 openEuler 22.03 ARM64 机器上执行：

```bash
mkdir -p /tmp/php_arm_offline_rpms
cd /tmp/php_arm_offline_rpms
```

如果有 `yumdownloader`：

```bash
yum install -y yum-utils

yumdownloader --resolve --destdir=/tmp/php_arm_offline_rpms \
  gcc gcc-c++ make autoconf automake libtool bison re2c \
  libxml2-devel openssl-devel curl-devel zlib-devel bzip2-devel \
  libjpeg-devel libpng-devel freetype-devel sqlite-devel readline-devel \
  gettext-devel libXpm-devel libxslt-devel libicu-devel libzip-devel nginx
```

然后打包：

```bash
tar -czf php_arm_offline_rpms.tar.gz -C /tmp/php_arm_offline_rpms .
```

上传到目标机后解压：

```bash
mkdir -p /opt/migration/packages
tar -zxf php_arm_offline_rpms.tar.gz -C /opt/migration/packages/
```

执行器会在 yum 安装失败后自动尝试：

```bash
yum localinstall -y /opt/migration/packages/*.rpm
```

## 注意事项

1. RPM 必须是 aarch64 架构。
2. RPM 版本应与 openEuler 22.03 兼容。
3. 不建议在目标机上升级或替换 glibc。
4. 不建议混用不同系统版本的核心库 RPM。
5. 如果存在企业内网 yum 源，优先配置内网 yum 源。
