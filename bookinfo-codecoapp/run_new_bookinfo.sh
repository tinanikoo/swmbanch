#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

BASE_NS="${BASE_NS:-kubelet-density-heavy}"
SCHEDULER="${1:-qos}" # qos | def
ITERATIONS="${ITERATIONS:-1}"
INTER_EXPERIMENT_SLEEP="${INTER_EXPERIMENT_SLEEP:-10}"
MAX_WAIT_TIMEOUT="${MAX_WAIT_TIMEOUT:-5m}"
WAIT_CREATE_TIMEOUT="${WAIT_CREATE_TIMEOUT:-300}"
WAIT_POLL_SECONDS="${WAIT_POLL_SECONDS:-2}"

TEMPLATE_FILE="kubelet-density-heavy.bookinfo.template.yml"
SUMMARY_FILE="kube-burner-bookinfo-podlatency-summary.log"
DELETE_LOG="deletion_times.log"
CREATION_LOG="creation_readiness.log"
RUN_STATUS_LOG="run_status.log"

if [[ "${SCHEDULER}" != "qos" && "${SCHEDULER}" != "def" ]]; then
  echo "Usage: $0 {qos|def}"
  exit 1
fi

OBJECT_FILE="bookinfo-microservices-${SCHEDULER}.yml"

experiments=(
  "jobIterations=1 qps=1 burst=1 bookinfo_replicas=5"
  "jobIterations=1 qps=100 burst=100 bookinfo_replicas=5"
  "jobIterations=1 qps=500 burst=500 bookinfo_replicas=5"
  "jobIterations=1 qps=1000 burst=1000 bookinfo_replicas=5"

  "jobIterations=1 qps=1 burst=1 bookinfo_replicas=10"
  "jobIterations=1 qps=100 burst=100 bookinfo_replicas=10"
  "jobIterations=1 qps=500 burst=500 bookinfo_replicas=10"
  "jobIterations=1 qps=1000 burst=1000 bookinfo_replicas=10"

  "jobIterations=1 qps=1 burst=1 bookinfo_replicas=40"
  "jobIterations=1 qps=100 burst=100 bookinfo_replicas=40"
  "jobIterations=1 qps=500 burst=500 bookinfo_replicas=40"
  "jobIterations=1 qps=1000 burst=1000 bookinfo_replicas=40"
)

init_logs() {
  : > "${SUMMARY_FILE}"
  : > "${CREATION_LOG}"
  : > "${RUN_STATUS_LOG}"
  {
    echo "# podLatency summary"
    echo "# started: $(date --iso-8601=seconds)"
    echo "# scheduler: ${SCHEDULER}"
    echo
  } >> "${SUMMARY_FILE}"
  {
    echo "# creation/readiness summary"
    echo "# started: $(date --iso-8601=seconds)"
    echo "# scheduler: ${SCHEDULER}"
    echo "# wait_create_timeout_seconds: ${WAIT_CREATE_TIMEOUT}"
    echo "# wait_poll_seconds: ${WAIT_POLL_SECONDS}"
    echo
  } >> "${CREATION_LOG}"
  {
    echo "# run status"
    echo "# started: $(date --iso-8601=seconds)"
    echo "# scheduler: ${SCHEDULER}"
    echo "# max_wait_timeout: ${MAX_WAIT_TIMEOUT}"
    echo
  } >> "${RUN_STATUS_LOG}"
}

extract_podlatency_block() {
  local src_log="$1"
  local experiment_desc="$2"
  local run_id="$3"
  local uuid=""
  uuid="$(awk -F'UUID ' '/Starting kube-burner/{print $NF; exit}' "${src_log}" 2>/dev/null || true)"

  {
    echo "============================================================"
    echo "ts=$(date --iso-8601=seconds)"
    echo "run=${run_id}"
    echo "experiment=${experiment_desc}"
    echo "uuid=${uuid}"
    echo "log=${src_log}"
    echo "------------------------------------------------------------"
    awk '
      /Stopping measurement: (podLatency|serviceLatency)/ && !p {p=1}
      p {print}
      /Finished execution with UUID:/ {p=0; exit}
    ' "${src_log}"
    echo
  } >> "${SUMMARY_FILE}"
}

measure_delete_time() {
  local ns="${BASE_NS}"
  local experiment_desc="$1"
  local run_id="$2"

  local start_ts_ms end_ts_ms duration_ms sec ms_rem duration
  start_ts_ms=$(date +%s%3N)

  kubectl delete codecoapp -n "${ns}" --all --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete deploy,svc,pod -n "${ns}" --all --ignore-not-found=true >/dev/null 2>&1 || true

  while true; do
    local remaining
    remaining=$(kubectl get pods,deploy,svc,codecoapp -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    [[ "${remaining}" -eq 0 ]] && break
    sleep 0.2
  done

  end_ts_ms=$(date +%s%3N)
  duration_ms=$((end_ts_ms - start_ts_ms))
  sec=$((duration_ms / 1000))
  ms_rem=$((duration_ms % 1000))
  duration=$(printf "%d.%03d" "${sec}" "${ms_rem}")

  echo "DeleteDurationSeconds run=${run_id} ${experiment_desc} duration=${duration}s" | tee -a "${DELETE_LOG}" >/dev/null
}

wait_for_creation_readiness() {
  local ns="${BASE_NS}"
  local experiment_desc="$1"
  local run_id="$2"
  local replicas="$3"
  local job_iters="$4"

  local components_per_codecoapp=4
  local expected_pods expected_containers
  expected_pods=$((replicas * components_per_codecoapp * job_iters))
  expected_containers="${expected_pods}"

  local started_at now elapsed
  started_at=$(date +%s)

  while true; do
    local observed_pods ready_pods observed_containers ready_containers

    observed_pods=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    ready_pods=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | awk '
      {
        split($2, a, "/")
        if (a[1] == a[2]) c++
      }
      END {print c + 0}
    ' || echo 0)
    observed_containers=$(kubectl get pods -n "${ns}" -o jsonpath='{range .items[*]}{.status.containerStatuses[*].name}{"\n"}{end}' 2>/dev/null | awk '{c += NF} END {print c + 0}' || echo 0)
    ready_containers=$(kubectl get pods -n "${ns}" -o jsonpath='{range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null | awk '
      {
        for (i = 1; i <= NF; i++) if ($i == "true") c++
      }
      END {print c + 0}
    ' || echo 0)

    if [[ "${ready_pods}" -ge "${expected_pods}" && "${ready_containers}" -ge "${expected_containers}" ]]; then
      {
        echo "CreateReady run=${run_id} ${experiment_desc} expectedPods=${expected_pods} observedPods=${observed_pods} readyPods=${ready_pods} expectedContainers=${expected_containers} observedContainers=${observed_containers} readyContainers=${ready_containers} pod_ready=${ready_pods} container_ready=${ready_containers}"
      } | tee -a "${CREATION_LOG}" >/dev/null
      return 0
    fi

    now=$(date +%s)
    elapsed=$((now - started_at))
    if [[ "${elapsed}" -ge "${WAIT_CREATE_TIMEOUT}" ]]; then
      {
        echo "CreateTimeout run=${run_id} ${experiment_desc} expectedPods=${expected_pods} observedPods=${observed_pods} readyPods=${ready_pods} expectedContainers=${expected_containers} observedContainers=${observed_containers} readyContainers=${ready_containers} pod_ready=${ready_pods} container_ready=${ready_containers}"
        echo "Resources snapshot (namespace=${ns}):"
        kubectl get codecoapp,pods,deploy,svc -n "${ns}" --ignore-not-found=true || true
        echo "Recent events (namespace=${ns}):"
        kubectl get events -n "${ns}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 20 || true
        echo
      } >> "${CREATION_LOG}"
      return 1
    fi

    sleep "${WAIT_POLL_SECONDS}"
  done
}

init_logs

if ls kubelet-density-heavy_bookinfo_*.log >/dev/null 2>&1; then
  counter=$(ls kubelet-density-heavy_bookinfo_*.log | grep -o '[0-9]*\.log' | grep -o '[0-9]*' | sort -n | tail -1)
  counter=$((counter + 1))
else
  counter=1
fi

for (( run=1; run<=ITERATIONS; run++ )); do
  echo "============================================================"
  echo "Starting run ${run} of ${ITERATIONS}"
  echo "Using template file: ${TEMPLATE_FILE}"
  echo "Namespace: ${BASE_NS}"
  echo "Scheduler: ${SCHEDULER}"
  echo "Object template: ${OBJECT_FILE}"
  echo "============================================================"

  for experiment in "${experiments[@]}"; do
    echo "------------------------------------------------------------"
    echo "Running experiment: ${experiment}"
    echo "------------------------------------------------------------"

    kubectl delete namespace "${BASE_NS}" --ignore-not-found=true >/dev/null 2>&1 || true
    while kubectl get namespace "${BASE_NS}" >/dev/null 2>&1; do
      sleep 1
    done
    kubectl create namespace "${BASE_NS}" >/dev/null

    eval "${experiment}"

    export JOB_ITERATIONS="${jobIterations}"
    export QPS="${qps}"
    export BURST="${burst}"
    export BOOKINFO_REPLICAS="${bookinfo_replicas}"
    export NAMESPACE="${BASE_NS}"
    export OBJECT_TEMPLATE="${OBJECT_FILE}"

    envsubst < "${TEMPLATE_FILE}" > kubelet-density-heavy.yml

    if grep -q '^[[:space:]]*maxWaitTimeout:' kubelet-density-heavy.yml; then
      sed -i -E "s|^([[:space:]]*maxWaitTimeout:).*|\\1 ${MAX_WAIT_TIMEOUT}|" kubelet-density-heavy.yml
    else
      sed -i -E "/^[[:space:]]*qps:/a\\  maxWaitTimeout: ${MAX_WAIT_TIMEOUT}" kubelet-density-heavy.yml
    fi

    kube-burner init -c kubelet-density-heavy.yml

    if ls kube-burner-*.log >/dev/null 2>&1; then
      log_file=$(ls -t kube-burner-*.log | head -n 1)
      new_log_file="kubelet-density-heavy_bookinfo_${SCHEDULER}_jobIterations${jobIterations}_qps${qps}_burst${burst}_replicas${bookinfo_replicas}_${counter}.log"
      mv "${log_file}" "${new_log_file}"
      extract_podlatency_block "${new_log_file}" "${experiment}" "${run}"
    else
      new_log_file=""
    fi

    creation_rc=0
    wait_for_creation_readiness "${experiment}" "${run}" "${bookinfo_replicas}" "${jobIterations}" || creation_rc=$?
    measure_delete_time "${experiment}" "${run}"

    if [[ "${creation_rc}" -ne 0 ]]; then
      echo "$(date --iso-8601=seconds) ERROR: creation readiness timeout run=${run} experiment='${experiment}'" | tee -a "${RUN_STATUS_LOG}" >&2
      exit 1
    fi
    echo "$(date --iso-8601=seconds) OK: run=${run} experiment='${experiment}'" >> "${RUN_STATUS_LOG}"

    counter=$((counter + 1))
    echo "Sleeping ${INTER_EXPERIMENT_SLEEP}s before next experiment..."
    sleep "${INTER_EXPERIMENT_SLEEP}"
  done
done

echo "All Bookinfo CodecoApp experiments completed."
