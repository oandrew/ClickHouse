#!/usr/bin/env bash

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. $CURDIR/../shell_config.sh

function query_with_retry
{
    retry=0
    until [ $retry -ge 5 ]
    do
        result=`$CLICKHOUSE_CLIENT $2 --query="$1" 2>&1`
        if [ "$?" == 0 ]; then
            echo -n $result
            return
        else
            retry=$(($retry + 1))
            sleep 3
        fi
    done
    echo "Query '$1' failed with '$result'"
}

$CLICKHOUSE_CLIENT --query="DROP TABLE IF EXISTS test.src;"
$CLICKHOUSE_CLIENT --query="DROP TABLE IF EXISTS test.dst_r1;"
$CLICKHOUSE_CLIENT --query="DROP TABLE IF EXISTS test.dst_r2;"

$CLICKHOUSE_CLIENT --query="CREATE TABLE test.src (p UInt64, k String, d UInt64) ENGINE = MergeTree PARTITION BY p ORDER BY k;"
$CLICKHOUSE_CLIENT --query="CREATE TABLE test.dst_r1 (p UInt64, k String, d UInt64) ENGINE = ReplicatedMergeTree('/clickhouse/test/dst_1', '1') PARTITION BY p ORDER BY k SETTINGS old_parts_lifetime=1, cleanup_delay_period=1, cleanup_delay_period_random_add=0;"
$CLICKHOUSE_CLIENT --query="CREATE TABLE test.dst_r2 (p UInt64, k String, d UInt64) ENGINE = ReplicatedMergeTree('/clickhouse/test/dst_1', '2') PARTITION BY p ORDER BY k SETTINGS old_parts_lifetime=1, cleanup_delay_period=1, cleanup_delay_period_random_add=0;"

$CLICKHOUSE_CLIENT --query="INSERT INTO test.src VALUES (0, '0', 1);"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.src VALUES (1, '0', 1);"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.src VALUES (1, '1', 1);"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.src VALUES (2, '0', 1);"

$CLICKHOUSE_CLIENT --query="SELECT 'Initial';"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.dst_r1 VALUES (0, '1', 2);"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.dst_r1 VALUES (1, '1', 2), (1, '2', 2);"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.dst_r1 VALUES (2, '1', 2);"

$CLICKHOUSE_CLIENT --query="SYSTEM SYNC REPLICA test.dst_r2;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.src;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r2;"


$CLICKHOUSE_CLIENT --query="SELECT 'REPLACE simple';"
query_with_retry "ALTER TABLE test.dst_r1 REPLACE PARTITION 1 FROM test.src;"
query_with_retry "ALTER TABLE test.src DROP PARTITION 1;"

$CLICKHOUSE_CLIENT --query="SYSTEM SYNC REPLICA test.dst_r2;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.src;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r2;"


$CLICKHOUSE_CLIENT --query="SELECT 'REPLACE empty';"
query_with_retry "ALTER TABLE test.src DROP PARTITION 1;"
query_with_retry "ALTER TABLE test.dst_r1 REPLACE PARTITION 1 FROM test.src;"

$CLICKHOUSE_CLIENT --query="SYSTEM SYNC REPLICA test.dst_r2;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r2;"


$CLICKHOUSE_CLIENT --query="SELECT 'REPLACE recursive';"
query_with_retry "ALTER TABLE test.dst_r1 DROP PARTITION 1;"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.dst_r1 VALUES (1, '1', 2), (1, '2', 2);"

$CLICKHOUSE_CLIENT --query="CREATE table test_block_numbers (m UInt64) ENGINE MergeTree() ORDER BY tuple();"
$CLICKHOUSE_CLIENT --query="INSERT INTO test_block_numbers SELECT max(max_block_number) AS m FROM system.parts WHERE database='test' AND  table='dst_r1' AND active AND name LIKE '1_%';"

query_with_retry "ALTER TABLE test.dst_r1 REPLACE PARTITION 1 FROM test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SYSTEM SYNC REPLICA test.dst_r2;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r2;"

$CLICKHOUSE_CLIENT --query="INSERT INTO test_block_numbers SELECT max(max_block_number) AS m FROM system.parts WHERE database='test' AND  table='dst_r1' AND active AND name LIKE '1_%';"
$CLICKHOUSE_CLIENT --query="SELECT (max(m) - min(m) > 1) AS new_block_is_generated FROM test_block_numbers;"
$CLICKHOUSE_CLIENT --query="DROP TEMPORARY TABLE test_block_numbers;"


$CLICKHOUSE_CLIENT --query="SELECT 'ATTACH FROM';"
query_with_retry "ALTER TABLE test.dst_r1 DROP PARTITION 1;"
$CLICKHOUSE_CLIENT --query="DROP TABLE test.src;"

$CLICKHOUSE_CLIENT --query="CREATE TABLE test.src (p UInt64, k String, d UInt64) ENGINE = MergeTree PARTITION BY p ORDER BY k;"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.src VALUES (1, '0', 1);"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.src VALUES (1, '1', 1);"

$CLICKHOUSE_CLIENT --query="INSERT INTO test.dst_r2 VALUES (1, '1', 2);"
query_with_retry "ALTER TABLE test.dst_r2 ATTACH PARTITION 1 FROM test.src;"

$CLICKHOUSE_CLIENT --query="SYSTEM SYNC REPLICA test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r2;"


$CLICKHOUSE_CLIENT --query="SELECT 'REPLACE with fetch';"
$CLICKHOUSE_CLIENT --query="DROP TABLE test.src;"
$CLICKHOUSE_CLIENT --query="CREATE TABLE test.src (p UInt64, k String, d UInt64) ENGINE = MergeTree PARTITION BY p ORDER BY k;"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.src VALUES (1, '0', 1);"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.src VALUES (1, '1', 1);"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.dst_r1 VALUES (1, '1', 2);" -- trash part to be

# Stop replication at the second replica and remove source table to use fetch instead of copying
$CLICKHOUSE_CLIENT --query="SYSTEM STOP REPLICATION QUEUES test.dst_r2;"
query_with_retry "ALTER TABLE test.dst_r1 REPLACE PARTITION 1 FROM test.src;"
$CLICKHOUSE_CLIENT --query="DROP TABLE test.src;"
$CLICKHOUSE_CLIENT --query="SYSTEM START REPLICATION QUEUES test.dst_r2;"

$CLICKHOUSE_CLIENT --query="SYSTEM SYNC REPLICA test.dst_r2;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r2;"


$CLICKHOUSE_CLIENT --query="SELECT 'REPLACE with fetch of merged';"
$CLICKHOUSE_CLIENT --query="DROP TABLE IF EXISTS test.src;"
query_with_retry "ALTER TABLE test.dst_r1 DROP PARTITION 1;"

$CLICKHOUSE_CLIENT --query="CREATE TABLE test.src (p UInt64, k String, d UInt64) ENGINE = MergeTree PARTITION BY p ORDER BY k;"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.src VALUES (1, '0', 1);"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.src VALUES (1, '1', 1);"
$CLICKHOUSE_CLIENT --query="INSERT INTO test.dst_r1 VALUES (1, '1', 2); -- trash part to be deleted"

$CLICKHOUSE_CLIENT --query="SYSTEM STOP MERGES test.dst_r2;"
$CLICKHOUSE_CLIENT --query="SYSTEM STOP REPLICATION QUEUES test.dst_r2;"
query_with_retry "ALTER TABLE test.dst_r1 REPLACE PARTITION 1 FROM test.src;"
$CLICKHOUSE_CLIENT --query="DROP TABLE test.src;"

# do not wait other replicas to execute OPTIMIZE

$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d), uniqExact(_part) FROM test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SYSTEM SYNC REPLICA test.dst_r1;"
query_with_retry "OPTIMIZE TABLE test.dst_r1 PARTITION 1;" "--replication_alter_partitions_sync=0 --optimize_throw_if_noop=1"

$CLICKHOUSE_CLIENT --query="SYSTEM SYNC REPLICA test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d), uniqExact(_part) FROM test.dst_r1;"

$CLICKHOUSE_CLIENT --query="SYSTEM START REPLICATION QUEUES test.dst_r2;"
$CLICKHOUSE_CLIENT --query="SYSTEM START MERGES test.dst_r2;"
$CLICKHOUSE_CLIENT --query="SYSTEM SYNC REPLICA test.dst_r2;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d), uniqExact(_part) FROM test.dst_r2;"

$CLICKHOUSE_CLIENT --query="SELECT 'After restart';"
$CLICKHOUSE_CLIENT --query="USE test;"
$CLICKHOUSE_CLIENT --query="SYSTEM RESTART REPLICA test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SYSTEM RESTART REPLICAS;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r2;"

$CLICKHOUSE_CLIENT --query="SELECT 'DETACH+ATTACH PARTITION';"
query_with_retry "ALTER TABLE test.dst_r1 DETACH PARTITION 0;"
query_with_retry "ALTER TABLE test.dst_r1 DETACH PARTITION 1;"
query_with_retry "ALTER TABLE test.dst_r1 DETACH PARTITION 2;"
query_with_retry "ALTER TABLE test.dst_r1 ATTACH PARTITION 1;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r1;"
$CLICKHOUSE_CLIENT --query="SYSTEM SYNC REPLICA test.dst_r2;"
$CLICKHOUSE_CLIENT --query="SELECT count(), sum(d) FROM test.dst_r2;"

$CLICKHOUSE_CLIENT --query="DROP TABLE IF EXISTS test.src;"
$CLICKHOUSE_CLIENT --query="DROP TABLE IF EXISTS test.dst_r1;"
$CLICKHOUSE_CLIENT --query="DROP TABLE IF EXISTS test.dst_r2;"