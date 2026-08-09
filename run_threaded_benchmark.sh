#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 [benchmark args...]"
    echo
    echo "Runs examples.benchmark_threaded after pinning all Linux CPU frequency policies"
    echo "to the performance governor and maximum frequency. Original settings are restored"
    echo "when the benchmark exits."
    echo
    echo "Environment:"
    echo "  PYTHON=python                 Python executable to use"
    echo "  AIOFN_SKIP_CPU_FREQUENCY=1    Run without changing CPU frequency settings"
    echo
    echo "Examples:"
    echo "  $0 --save-plot"
    echo "  PYTHON=env314/bin/python $0 --loops asyncio,uvloop --variant native,aiofastnet"
}

write_sysfs() {
    local value=$1
    local path=$2

    if [[ -w $path ]]; then
        printf '%s\n' "$value" > "$path"
    else
        printf '%s\n' "$value" | sudo tee "$path" >/dev/null
    fi
}

restore() {
    local policy policy_name dir governor min_freq max_freq

    if [[ ${#SAVED_POLICIES[@]} -eq 0 ]]; then
        return
    fi

    echo "Restoring CPU frequency settings..."
    for policy in "${SAVED_POLICIES[@]}"; do
        policy_name=${policy##*/}
        dir="$STATE_DIR/$policy_name"

        governor=$(cat "$dir/scaling_governor" 2>/dev/null || true)
        min_freq=$(cat "$dir/scaling_min_freq" 2>/dev/null || true)
        max_freq=$(cat "$dir/scaling_max_freq" 2>/dev/null || true)

        [[ -n $min_freq && -e "$policy/scaling_min_freq" ]] && write_sysfs "$min_freq" "$policy/scaling_min_freq" || true
        [[ -n $max_freq && -e "$policy/scaling_max_freq" ]] && write_sysfs "$max_freq" "$policy/scaling_max_freq" || true
        [[ -n $governor && -e "$policy/scaling_governor" ]] && write_sysfs "$governor" "$policy/scaling_governor" || true
    done
}

cleanup() {
    restore
    [[ -n ${STATE_DIR:-} ]] && rm -rf "$STATE_DIR"
}

prepare_cpu_frequency() {
    local policy policy_name dir max_freq

    if [[ ${AIOFN_SKIP_CPU_FREQUENCY:-0} == "1" ]]; then
        echo "Skipping CPU frequency setup because AIOFN_SKIP_CPU_FREQUENCY=1"
        return
    fi

    if [[ $(uname -s) != "Linux" ]]; then
        echo "CPU frequency setup is only supported through Linux cpufreq; running benchmark without it."
        return
    fi

    shopt -s nullglob
    CPU_POLICIES=(/sys/devices/system/cpu/cpufreq/policy*)
    shopt -u nullglob

    if [[ ${#CPU_POLICIES[@]} -eq 0 ]]; then
        echo "No Linux cpufreq policies found; running benchmark without CPU frequency setup."
        return
    fi

    STATE_DIR=$(mktemp -d)
    for policy in "${CPU_POLICIES[@]}"; do
        policy_name=${policy##*/}
        dir="$STATE_DIR/$policy_name"
        mkdir -p "$dir"

        [[ -r "$policy/scaling_governor" ]] && cp "$policy/scaling_governor" "$dir/scaling_governor"
        [[ -r "$policy/scaling_min_freq" ]] && cp "$policy/scaling_min_freq" "$dir/scaling_min_freq"
        [[ -r "$policy/scaling_max_freq" ]] && cp "$policy/scaling_max_freq" "$dir/scaling_max_freq"
        SAVED_POLICIES+=("$policy")
    done

    for policy in "${SAVED_POLICIES[@]}"; do
        max_freq=$(cat "$policy/cpuinfo_max_freq")
        echo "Setting ${policy##*/} to performance governor and max frequency $max_freq"

        if [[ -r "$policy/scaling_available_governors" ]] && grep -qw performance "$policy/scaling_available_governors"; then
            write_sysfs performance "$policy/scaling_governor"
        fi
        write_sysfs "$max_freq" "$policy/scaling_max_freq"
        write_sysfs "$max_freq" "$policy/scaling_min_freq"
    done
}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT_DIR"

PYTHON=${PYTHON:-python}
export MPLCONFIGDIR=${MPLCONFIGDIR:-/tmp/aiofastnet-matplotlib}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    echo
    "$PYTHON" -m examples.benchmark_threaded --help
    exit 0
fi

STATE_DIR=
declare -a CPU_POLICIES=()
declare -a SAVED_POLICIES=()

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prepare_cpu_frequency

echo "Running threaded benchmark..."
"$PYTHON" -m examples.benchmark_threaded "$@"
