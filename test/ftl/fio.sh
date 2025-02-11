#!/usr/bin/env bash

testdir=$(readlink -f $(dirname $0))
rootdir=$(readlink -f $testdir/../..)
source $rootdir/test/common/autotest_common.sh
source $testdir/common.sh

declare -A suite
suite['basic']='randw-verify randw-verify-j2 randw-verify-depth128'
suite['extended']='drive-prep randw-verify-qd128-ext randw-verify-qd2048-ext randw randr randrw'
suite['nightly']='drive-prep randw-verify-qd256-nght randw-verify-qd256-nght randw-verify-qd256-nght'

rpc_py=$rootdir/scripts/rpc.py

fio_kill() {
	killprocess $svcpid
	rm -f $FTL_JSON_CONF
}

device=$1
cache_device=$2
tests=${suite[$3]}
uuid=$4
timeout=240

if [[ $CONFIG_FIO_PLUGIN != y ]]; then
	echo "FIO not available"
	exit 1
fi

if [ -z "$tests" ]; then
	echo "Invalid test suite '$2'"
	exit 1
fi

export FTL_BDEV_NAME=ftl0
export FTL_JSON_CONF=$testdir/config/ftl.json

trap "fio_kill; exit 1" SIGINT SIGTERM EXIT

"$SPDK_BIN_DIR/spdk_tgt" -m 7 &
svcpid=$!
waitforlisten $svcpid

split_bdev=$(create_base_bdev nvme0 $device $((1024 * 101)))
nv_cache=$(create_nv_cache_bdev nvc0 $cache_device $split_bdev)

$rpc_py -t $timeout bdev_ftl_create -b ftl0 -d $split_bdev -c $nv_cache

waitforbdev ftl0

(
	echo '{"subsystems": ['
	$rpc_py save_subsystem_config -n bdev
	echo ']}'
	# Temporary hack so tests are always creating new instance, until clean restore is reintroduced later
) | sed 's/"uuid": "[a-f0-9\-]\{36\}"/"uuid": "00000000-0000-0000-0000-000000000000"/g' > $FTL_JSON_CONF

killprocess $svcpid
trap - SIGINT SIGTERM EXIT

for test in ${tests}; do
	timing_enter $test
	fio_bdev $testdir/config/fio/$test.fio
	timing_exit $test
done

rm -f $FTL_JSON_CONF
remove_shm
