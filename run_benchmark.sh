#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 CPU [benchmark args...]"
    echo
    echo "Example:"
    echo "  $0 3"
    echo "  PYTHON=env314/bin/python $0 3 --help"
}

expand_cpu_list() {
    local list=${1//,/ }
    local item start end cpu

    for item in $list; do
        if [[ $item == *-* ]]; then
            start=${item%-*}
            end=${item#*-}
            for ((cpu = start; cpu <= end; cpu++)); do
                echo "$cpu"
            done
        else
            echo "$item"
        fi
    done
}

write_sysfs() {
    local value=$1
    local path=$2
    echo "$value" | sudo tee "$path" >/dev/null
}

restore() {
    local cpu dir governor min_freq max_freq

    if [[ ${#SAVED_CPUS[@]} -eq 0 ]]; then
        return
    fi

    echo "Restoring CPU frequency settings..."
    for cpu in "${SAVED_CPUS[@]}"; do
        dir="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
        governor=${OLD_GOVERNOR[$cpu]}
        min_freq=${OLD_MIN_FREQ[$cpu]}
        max_freq=${OLD_MAX_FREQ[$cpu]}

        [[ -n $min_freq ]] && write_sysfs "$min_freq" "$dir/scaling_min_freq"
        [[ -n $max_freq ]] && write_sysfs "$max_freq" "$dir/scaling_max_freq"
        [[ -n $governor ]] && write_sysfs "$governor" "$dir/scaling_governor"
    done
}

if [[ $# -lt 1 || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 1
fi

CPU=$1
shift
PYTHON=${PYTHON:-python}
CPUFREQ="/sys/devices/system/cpu/cpu${CPU}/cpufreq"

if [[ ! -d $CPUFREQ ]]; then
    echo "CPU $CPU does not expose cpufreq controls at $CPUFREQ" >&2
    exit 1
fi

declare -a POLICY_CPUS=()
declare -a SAVED_CPUS=()
declare -A SEEN=()
declare -A OLD_GOVERNOR=()
declare -A OLD_MIN_FREQ=()
declare -A OLD_MAX_FREQ=()

if [[ -r "$CPUFREQ/related_cpus" ]]; then
    while read -r cpu; do
        [[ -n ${SEEN[$cpu]:-} ]] && continue
        SEEN[$cpu]=1
        POLICY_CPUS+=("$cpu")
    done < <(expand_cpu_list "$(cat "$CPUFREQ/related_cpus")")
else
    POLICY_CPUS=("$CPU")
fi

trap restore EXIT INT TERM

echo "Selected logical CPU: $CPU"
if [[ -r "/sys/devices/system/cpu/cpu${CPU}/topology/thread_siblings_list" ]]; then
    echo "SMT siblings: $(cat "/sys/devices/system/cpu/cpu${CPU}/topology/thread_siblings_list")"
fi
echo "Frequency policy CPUs: ${POLICY_CPUS[*]}"

for cpu in "${POLICY_CPUS[@]}"; do
    dir="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
    [[ -d $dir ]] || continue

    OLD_GOVERNOR[$cpu]=$(cat "$dir/scaling_governor" 2>/dev/null || true)
    OLD_MIN_FREQ[$cpu]=$(cat "$dir/scaling_min_freq" 2>/dev/null || true)
    OLD_MAX_FREQ[$cpu]=$(cat "$dir/scaling_max_freq" 2>/dev/null || true)
    SAVED_CPUS+=("$cpu")
done

for cpu in "${SAVED_CPUS[@]}"; do
    dir="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
    max_freq=$(cat "$dir/cpuinfo_max_freq")

    echo "Setting CPU $cpu to performance governor and max frequency $max_freq"
    write_sysfs performance "$dir/scaling_governor"
    write_sysfs "$max_freq" "$dir/scaling_max_freq"
    write_sysfs "$max_freq" "$dir/scaling_min_freq"
done

echo "Running benchmark on logical CPU $CPU..."
taskset -c "$CPU" "$PYTHON" -m examples.benchmark "$@"
