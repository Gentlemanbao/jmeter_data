#!/bin/sh

# 设置 JVM 内存（根据你的机器调整）
export JAVA_OPTS="$JAVA_OPTS -Xms2g -Xmx2g"

# 启用 JMX（用于 JMX Exporter）
export JAVA_OPTS="$JAVA_OPTS -Dcom.sun.management.jmxremote"
export JAVA_OPTS="$JAVA_OPTS -Dcom.sun.management.jmxremote.port=9999"
export JAVA_OPTS="$JAVA_OPTS -Dcom.sun.management.jmxremote.rmi.port=9999"
export JAVA_OPTS="$JAVA_OPTS -Dcom.sun.management.jmxremote.authenticate=false"
export JAVA_OPTS="$JAVA_OPTS -Dcom.sun.management.jmxremote.ssl=false"
export JAVA_OPTS="$JAVA_OPTS -Djava.rmi.server.hostname=47.92.159.196"  # 如 192.168.1.100

# 添加 JMX Exporter Agent（关键！）
# 假设你把 jmx_prometheus_javaagent-0.20.0.jar 放在 /opt/monitor/
export JAVA_OPTS="$JAVA_OPTS -javaagent:/opt/apache-tomcat-9.0.113/bin/jmx_prometheus_javaagent-0.20.0.jar=5556:/opt/apache-tomcat-9.0.113/bin/tomcat.yaml"