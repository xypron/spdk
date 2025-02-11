#!/usr/bin/env bash

testdir=$(readlink -f $(dirname $0))
rootdir=$(readlink -f $testdir/../..)
source $rootdir/test/common/autotest_common.sh
source $testdir/common.sh

rpc_py=$rootdir/scripts/rpc.py

function at_ftl_exit() {
	killprocess "$spdk_tgt_pid"

	# delete any created lvols of the base device
	if [[ -n $device ]]; then
		"$rootdir/build/bin/spdk_tgt" &
		spdk_tgt_pid=$!
		waitforlisten "$spdk_tgt_pid"
		"$rpc_py" bdev_nvme_attach_controller -b nvme0 -t PCIe -a $device
		clear_lvols
		killprocess "$spdk_tgt_pid"
	fi

	# restore original driver
	$rootdir/scripts/setup.sh reset
	remove_shm
}

trap 'at_ftl_exit' SIGINT SIGTERM EXIT

# Bind device to vfio/uio driver before testing
PCI_ALLOWED="$device" PCI_BLOCKED="" DRIVER_OVERRIDE="" $rootdir/scripts/setup.sh

"$rootdir/build/bin/spdk_tgt" --wait-for-rpc &
spdk_tgt_pid=$!
waitforlisten "$spdk_tgt_pid"

$rpc_py bdev_set_options -d
$rpc_py framework_start_init

"$rpc_py" load_subsystem_config -j <($rootdir/scripts/gen_nvme.sh)

# 5GiB minimum for cache device
cache_size=$((5 * 1024 * 1024 * 1024 / 4096))
cache_disks=$("$rpc_py" bdev_get_bdevs | jq -r ".[] | select(.md_size==64 and .zoned == false and .num_blocks >= $cache_size).driver_specific.nvme[].pci_address")
for disk in $cache_disks; do
	nv_cache=$disk
	break
done

if [ -z "$nv_cache" ]; then
	echo "Couldn't find NVMe device to be used as non-volatile cache"
	exit 1
fi

# 5GiB minimum for base device (will be thin provisioned to 100GiB if necessary - it's enough for basic tests)
base_size=$((5 * 1024 * 1024 * 1024 / 4096))
base_disks=$("$rpc_py" bdev_get_bdevs | jq -r ".[] | select(.driver_specific.nvme[0].pci_address!=\"$nv_cache\" and .zoned == false and .num_blocks >= $base_size).driver_specific.nvme[].pci_address")
for disk in $base_disks; do
	device=$disk
	break
done

killprocess "$spdk_tgt_pid"

if [ -z "$device" ]; then
	echo "Couldn't find NVMe device to be used as base device"
	exit 1
fi

if [[ -z $SPDK_TEST_FTL_NIGHTLY ]]; then
	run_test "ftl_fio_basic" $testdir/fio.sh $device $nv_cache basic
	run_test "ftl_bdevperf" $testdir/bdevperf.sh $device $nv_cache
fi

if [ $SPDK_TEST_FTL_EXTENDED -eq 1 ]; then
	run_test "ftl_fio_extended" $testdir/fio.sh $device $nv_cache extended
fi

if [ $SPDK_TEST_FTL_NIGHTLY -eq 1 ]; then
	run_test "ftl_fio_nightly" $testdir/fio.sh $device $nv_cache nightly
fi
