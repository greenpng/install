#!/bin/sh
# green-v6 数据服务初始化: 创建 管理面/业务面 依赖的 3 个附加库
# (greenv6 由 compose 的 POSTGRES_DB 创建, 这里补齐 biz/admin/assoc)
set -e
for db in gv6_biz gv6_admin gv6_assoc; do
  if ! psql -U gv6 -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    psql -U gv6 -d postgres -c "CREATE DATABASE \"$db\";"
    echo "created database $db"
  else
    echo "database $db already exists"
  fi
done
