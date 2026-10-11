#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把内置 MySQL(o9e-mysql 容器)中的平台数据迁移到外部 PostgreSQL / 金仓(PG 兼容模式)。

用法(在**目标部署目录**执行,其 .env 已是 DB_TYPE=postgres 且 external-db-init.sh 已跑过):
    python3 migrate-mysql-to-pg.py                 # 迁移 n9e_v6 与 topo_studio
    SRC_MYSQL_CONTAINER=o9e-mysql python3 ...       # 源 MySQL 容器名(默认 o9e-mysql)
    INIT_DOCKER_NETWORK=<网络> python3 ...           # 目标库也是本机容器时,客户端容器加入其网络

前提:
  - 目标表结构由新版 n9e / topo-studio 自己建好(先连目标库启动一次再停掉),本脚本只搬数据;
  - 迁移期间 n9e / topo-studio 必须已停止(源与目标都不能有写入);
  - 新部署 .env 的 N9E_SECRET_MASTER_KEY 必须与源环境一致,否则密钥库密文无法解密。

做的事:目标表清空(含建表时写入的默认数据)→ 逐表复制两边共有的列(按目标列类型转换布尔 / 二进制 /
文本特殊字符)→ 重置全部自增序列 → 逐表核对行数。源库只读。口令只经容器环境变量传递,不打印。
"""
import os
import subprocess
import sys
import tempfile
import time

DIR = os.path.dirname(os.path.abspath(__file__))


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
                v = v[1:-1]
            env[k] = v
    return env


ENV = load_env(os.path.join(DIR, '.env'))
if ENV.get('DB_TYPE') != 'postgres':
    sys.exit('[migrate] 目标 .env 的 DB_TYPE 须为 postgres')
SRC = os.environ.get('SRC_MYSQL_CONTAINER', 'o9e-mysql')
NET = os.environ.get('INIT_DOCKER_NETWORK', '')
PSQL_IMAGE = os.environ.get('PSQL_IMAGE', 'postgres:17-alpine')
HOST, PORT = ENV['DB_HOST'], ENV['DB_PORT']
SSLMODE = ENV.get('DB_SSLMODE', 'prefer')

# 常驻一个 psql 客户端容器,所有目标库操作都 docker exec 进去(每次新起容器要数秒,表多时是主要耗时)。
# 两个业务账号口令经 --env-file 注入容器环境变量,exec 时在容器内取用,不出现在命令行。
HELPER = 'o9e-migrate-psql-%d' % os.getpid()


def start_helper():
    tmp = tempfile.mkdtemp(prefix='migrate-')
    os.chmod(tmp, 0o700)
    envf = os.path.join(tmp, 'pg.env')
    with open(envf, 'w') as f:
        f.write('PW_N9E=%s\nPW_TOPO=%s\n' % (ENV['N9E_DB_PASSWORD'], ENV['TOPO_DB_PASSWORD']))
    os.chmod(envf, 0o600)
    cmd = ['docker', 'run', '-d', '--rm', '--name', HELPER, '--env-file', envf]
    if NET:
        cmd += ['--network', NET]
    r = subprocess.run(cmd + [PSQL_IMAGE, 'sleep', '86400'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       universal_newlines=True)
    subprocess.run(['rm', '-rf', tmp])
    if r.returncode != 0:
        sys.exit('[migrate] 启动 psql 客户端容器失败: %s' % r.stderr.strip()[:300])


def stop_helper():
    subprocess.run(['docker', 'rm', '-f', HELPER], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def psql_cmd(db, user, pwvar, extra):
    return ['docker', 'exec', '-i', HELPER, 'sh', '-c', 'PGPASSWORD="$%s" exec psql "$@"' % pwvar, 'psql',
            'host=%s port=%s user=%s dbname=%s sslmode=%s connect_timeout=10' % (HOST, PORT, user, db, SSLMODE),
            '-v', 'ON_ERROR_STOP=1', '-q'] + extra


def pg_query(db, user, pwvar, sql):
    r = subprocess.run(psql_cmd(db, user, pwvar, ['-At', '-F', '\t', '-c', sql]),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if r.returncode != 0:
        raise RuntimeError('目标库执行失败: %s' % r.stderr.strip()[:300])
    return [l.split('\t') for l in r.stdout.splitlines() if l]


def mysql_cmd(db):
    # root 口令取容器内 MYSQL_ROOT_PASSWORD,走 socket,不经命令行
    return ['docker', 'exec', '-i', SRC, 'sh', '-c',
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N -B --raw --default-character-set=utf8mb4 %s' % db]


def my_query(db, sql):
    r = subprocess.run(mysql_cmd(db), input=sql, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       universal_newlines=True)
    if r.returncode != 0:
        raise RuntimeError('源库执行失败: %s' % r.stderr.strip()[:300])
    return [l.split('\t') for l in r.stdout.splitlines() if l]


# 源列 → PG COPY 文本格式(\N 表示 NULL,反斜杠 / 制表 / 换行 / 回车转义,去掉 PG 不接受的 NUL)。
# 下面字符串写给 MySQL:'\\' 在 MySQL 字面量里是一个反斜杠。
def col_expr(col, pg_type):
    c = '`%s`' % col
    if pg_type == 'bytea':
        return r"IF(%s IS NULL, '\\N', CONCAT('\\\\x', HEX(%s)))" % (c, c)
    if pg_type == 'boolean':
        return r"IF(%s IS NULL, '\\N', IF(%s, 't', 'f'))" % (c, c)
    if pg_type in ('smallint', 'integer', 'bigint', 'numeric', 'real', 'double precision'):
        return r"IFNULL(CAST(%s AS CHAR), '\\N')" % c
    return (r"IFNULL(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(CAST(%s AS CHAR), '\\', '\\\\'), "
            r"CHAR(9), '\\t'), CHAR(10), '\\n'), CHAR(13), '\\r'), CHAR(0), ''), '\\N')" % c)


def migrate_db(src_db, tgt_db, user, pwvar):
    print('[migrate] ===== %s → %s(%s@%s:%s)' % (src_db, tgt_db, user, HOST, PORT))
    tgt_cols = {}
    for t, c, typ in pg_query(tgt_db, user, pwvar,
                              "SELECT table_name, column_name, data_type FROM information_schema.columns "
                              "WHERE table_schema='public' ORDER BY table_name, ordinal_position"):
        tgt_cols.setdefault(t, []).append((c, typ))
    src_cols = {}
    for t, c in my_query(src_db, "SELECT table_name, column_name FROM information_schema.columns "
                                 "WHERE table_schema=DATABASE() ORDER BY table_name, ordinal_position"):
        src_cols.setdefault(t, set()).add(c)

    only_src = sorted(set(src_cols) - set(tgt_cols))
    only_tgt = sorted(set(tgt_cols) - set(src_cols))
    tables = sorted(set(src_cols) & set(tgt_cols))
    if only_src:
        print('[migrate] 源有目标无(跳过,多为遗留备份表):%s' % ', '.join(only_src))
    if only_tgt:
        print('[migrate] 目标有源无(保持为空):%s' % ', '.join(only_tgt))

    # 清空目标表(建表时写入的默认数据)并重置序列
    pg_query(tgt_db, user, pwvar, 'TRUNCATE %s RESTART IDENTITY CASCADE' % ', '.join('"%s"' % t for t in tables))

    # 源表行数一次查完,空表无需复制(目标已清空)
    n_pre = dict((r[0], int(r[1])) for r in my_query(src_db, ' UNION ALL '.join(
        "SELECT '%s', COUNT(*) FROM `%s`" % (t, t) for t in tables)))

    total, problems = 0, []
    for t in tables:
        if not n_pre[t]:
            continue
        cols = [(c, typ) for c, typ in tgt_cols[t] if c in src_cols[t]]
        skipped = sorted(src_cols[t] - set(c for c, _ in tgt_cols[t]))
        sel = "SELECT CONCAT_WS(CHAR(9), %s) FROM `%s`" % (', '.join(col_expr(c, typ) for c, typ in cols), t)
        copy = 'COPY "%s" (%s) FROM STDIN' % (t, ', '.join('"%s"' % c for c, _ in cols))
        t0 = time.time()
        src = subprocess.Popen(mysql_cmd(src_db), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
        dst = subprocess.Popen(psql_cmd(tgt_db, user, pwvar, ['-c', copy]), stdin=src.stdout,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        src.stdin.write((sel + ';\n').encode('utf-8'))
        src.stdin.close()
        src.stdout.close()
        _, derr = dst.communicate()
        serr = src.stderr.read()
        src.wait()
        if src.returncode != 0 or dst.returncode != 0:
            problems.append(t)
            print('[migrate] !! %s 失败:%s %s' % (t, serr.decode(errors='replace').strip()[:200],
                                                 derr.decode(errors='replace').strip()[:300]))
            continue
        n_src = int(my_query(src_db, 'SELECT COUNT(*) FROM `%s`' % t)[0][0])
        n_tgt = int(pg_query(tgt_db, user, pwvar, 'SELECT COUNT(*) FROM "%s"' % t)[0][0])
        total += n_tgt
        mark = '✓' if n_src == n_tgt else '!! 行数不一致'
        if n_src != n_tgt:
            problems.append(t)
        if n_src or skipped or n_src != n_tgt:
            print('[migrate]   %-40s 源 %7d  目标 %7d  %5.1fs %s%s' % (
                t, n_src, n_tgt, time.time() - t0, mark,
                ('  (源多出列已跳过:%s)' % ','.join(skipped)) if skipped else ''))

    # 自增序列设为当前最大值,避免新数据撞号
    seqs = pg_query(tgt_db, user, pwvar,
                    "SELECT table_name, column_name FROM information_schema.columns "
                    "WHERE table_schema='public' AND column_default LIKE 'nextval(%%'")
    seqs = [(t, c) for t, c in seqs if t in tables]
    if seqs:
        pg_query(tgt_db, user, pwvar, '; '.join(
            "SELECT setval(pg_get_serial_sequence('\"%s\"', '%s'), "
            "COALESCE((SELECT MAX(\"%s\") FROM \"%s\"), 0) + 1, false)" % (t, c, c, t) for t, c in seqs))
    print('[migrate] %s:%d 张表、%d 行;重置序列 %d 个;问题表 %d 个%s' % (
        tgt_db, len(tables), total, len(seqs), len(problems),
        (':' + ', '.join(problems)) if problems else ''))
    return problems


if __name__ == '__main__':
    t0 = time.time()
    start_helper()
    try:
        bad = migrate_db(ENV.get('N9E_DB_NAME', 'n9e_v6'), ENV.get('N9E_DB_NAME', 'n9e_v6'),
                         ENV['N9E_DB_USER'], 'PW_N9E')
        bad += migrate_db(ENV.get('TOPO_DB_NAME', 'topo_studio'), ENV.get('TOPO_DB_NAME', 'topo_studio'),
                          ENV['TOPO_DB_USER'], 'PW_TOPO')
    finally:
        stop_helper()
    print('[migrate] 完成,用时 %.0fs;%s' % (time.time() - t0, '全部一致' if not bad else '有问题,勿切换'))
    sys.exit(1 if bad else 0)
