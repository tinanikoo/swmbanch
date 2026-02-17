#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

BASE_NS="${BASE_NS:-kubelet-density-heavy}"
TEMPLATE_FILE="kubelet-density-heavy.template-codecoapp-only.yml"
MAX_WAIT_TIMEOUT="${MAX_WAIT_TIMEOUT:-5m}"
KUBEBURNER_TIMEOUT="${KUBEBURNER_TIMEOUT:-6m}"
INTER_EXPERIMENT_SLEEP="${INTER_EXPERIMENT_SLEEP:-10}"
WAIT_CREATE_TIMEOUT="${WAIT_CREATE_TIMEOUT:-300}"
WAIT_POLL_SECONDS="${WAIT_POLL_SECONDS:-2}"
WAIT_COUNTER_MODE="${WAIT_COUNTER_MODE:-observed}" # observed | ready
POST_CREATION_DELAY_SECONDS="${POST_CREATION_DELAY_SECONDS:-90}"
DELETE_WAIT_TIMEOUT="${DELETE_WAIT_TIMEOUT:-180}"
DELETE_POLL_SECONDS="${DELETE_POLL_SECONDS:-1}"
DELETE_WAIT_INCLUDE_SERVICES="${DELETE_WAIT_INCLUDE_SERVICES:-false}" # true | false
iterations="${iterations:-1}"
SCHEDULER_MODE="${1:-qos}" # qos | def

if [[ "${SCHEDULER_MODE}" != "qos" && "${SCHEDULER_MODE}" != "def" ]]; then
  echo "Usage: $0 {qos|def}"
  exit 1
fi

if [[ "${SCHEDULER_MODE}" == "qos" ]]; then
  SCHEDULER_NAME="qos-scheduler"
else
  SCHEDULER_NAME="default-scheduler"
fi

DELETE_LOG="${SCRIPT_DIR}/deletion_times-perfapp-postgres-codecoapp-cam-only.log"
SUMMARY_FILE="${SCRIPT_DIR}/kube-burner-perfapp-postgres-codecoapp-cam-only-podlatency-summary.log"
: > "${SUMMARY_FILE}"
echo "# podLatency summary (selected kube-burner output)" >> "${SUMMARY_FILE}"

experiments=(
  "jobIterations=1 qps=1 burst=1 codecoapp_replicas=5"
  "jobIterations=1 qps=100 burst=100 codecoapp_replicas=5"
  "jobIterations=1 qps=500 burst=500 codecoapp_replicas=5"
  "jobIterations=1 qps=1000 burst=1000 codecoapp_replicas=5"

  "jobIterations=1 qps=1 burst=1 codecoapp_replicas=10"
  "jobIterations=1 qps=100 burst=100 codecoapp_replicas=10"
  "jobIterations=1 qps=500 burst=500 codecoapp_replicas=10"
  "jobIterations=1 qps=1000 burst=1000 codecoapp_replicas=10"

  "jobIterations=1 qps=1 burst=1 codecoapp_replicas=20"
  "jobIterations=1 qps=100 burst=100 codecoapp_replicas=20"
  "jobIterations=1 qps=500 burst=500 codecoapp_replicas=20"
  "jobIterations=1 qps=1000 burst=1000 codecoapp_replicas=20"
)

capture_creation_status() {
  local experiment_desc="$1"
  local run_id="$2"
  local run_log_file="$3"
  local replicas="$4"
  local job_iters="$5"
  local ns="${BASE_NS}"
  local components_per_instance=2
  local expected_pods observed_pods ready_pods ts metric_line

  expected_pods=$((replicas * components_per_instance * job_iters))
  observed_pods=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
  ready_pods=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | awk '
    {
      split($2, a, "/")
      if (a[1] == a[2]) c++
    }
    END {print c + 0}
  ' || echo 0)

  echo "CreatePods run=${run_id} ${experiment_desc} ready=${ready_pods}/${expected_pods} observed=${observed_pods}" | tee -a "${SUMMARY_FILE}"

  if [[ -n "${run_log_file}" && -f "${run_log_file}" ]]; then
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    metric_line="time=\"${ts}\" level=info msg=\"${BASE_NS}: PodCreation readyPods: ${ready_pods}/${expected_pods} observedPods: ${observed_pods}\" file=\"run_new_perfapp_postgres_codecoapp_cam.sh:capture_creation_status\""
    if grep -q 'Finished execution with UUID:' "${run_log_file}"; then
      awk -v ins="${metric_line}" '
        /Finished execution with UUID:/ && !done { print ins; done=1 }
        { print }
      ' "${run_log_file}" > "${run_log_file}.tmp" && mv "${run_log_file}.tmp" "${run_log_file}"
    else
      echo "${metric_line}" >> "${run_log_file}"
    fi
  fi
}

wait_for_creation_readiness() {
  local replicas="$1"
  local job_iters="$2"
  local ns="${BASE_NS}"
  local components_per_instance=2
  local expected_pods observed_pods ready_pods now elapsed started_at codecoapps plans

  expected_pods=$((replicas * components_per_instance * job_iters))
  started_at=$(date +%s)

  while true; do
    observed_pods=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    ready_pods=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | awk '
      {
        split($2, a, "/")
        if (a[1] == a[2]) c++
      }
      END {print c + 0}
    ' || echo 0)
    codecoapps=$(kubectl get codecoapp -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    plans=$(kubectl get assignmentplan -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}:{.status.phase}{" "}{end}' 2>/dev/null || echo "no-assignmentplan")

    local current_count criterion
    if [[ "${WAIT_COUNTER_MODE}" == "ready" ]]; then
      current_count="${ready_pods}"
      criterion="readyPods"
    else
      current_count="${observed_pods}"
      criterion="observedPods"
    fi

    if [[ "${current_count}" -ge "${expected_pods}" ]]; then
      echo "create-progress criterion=${criterion} value=${current_count}/${expected_pods} readyPods=${ready_pods}/${expected_pods} observedPods=${observed_pods}/${expected_pods} codecoapps=${codecoapps} assignmentplan='${plans}'"
      return 0
    fi

    now=$(date +%s)
    elapsed=$((now - started_at))
    if [[ "${elapsed}" -ge "${WAIT_CREATE_TIMEOUT}" ]]; then
      echo "create-timeout criterion=${criterion} value=${current_count}/${expected_pods} readyPods=${ready_pods}/${expected_pods} observedPods=${observed_pods}/${expected_pods} codecoapps=${codecoapps} assignmentplan='${plans}' waited=${elapsed}s" >&2
      {
        echo "---- create-timeout snapshot ----"
        echo "experiment timeout in namespace=${ns}"
        kubectl get codecoapp,pods,deploy,svc,assignmentplan -n "${ns}" --ignore-not-found=true || true
        echo "Recent events:"
        kubectl get events -n "${ns}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 30 || true
        echo "--------------------------------"
      } >> "${SUMMARY_FILE}"
      return 1
    fi

    echo "create-wait criterion=${criterion} value=${current_count}/${expected_pods} readyPods=${ready_pods}/${expected_pods} observedPods=${observed_pods}/${expected_pods} codecoapps=${codecoapps} assignmentplan='${plans}' elapsed=${elapsed}s"
    sleep "${WAIT_POLL_SECONDS}"
  done
}

extract_podlatency_block() {
  local src_log="$1"
  local experiment_desc="$2"
  local run_id="$3"

  {
    echo "============================================================"
    echo "run=${run_id} experiment=${experiment_desc}"
    echo "log=${src_log}"
    echo "------------------------------------------------------------"

    awk '
      /Stopping measurement: (podLatency|serviceLatency)/ && !p {p=1}
      p {print}
      /👋 Exiting kube-burner/ {p=0; exit}
    ' "${src_log}" | sed -E '
      /file="service_latency.go:[0-9]+"/ s/: Ready 99th:/: ServiceLatency 99th:/
      /file="base_measurement.go:[0-9]+"/{
      s/50th: ([0-9]+)/50th: \1ms/g
      s/99th: ([0-9]+)/99th: \1ms/g
      s/max: ([0-9]+)/max: \1ms/g
      s/avg: ([0-9]+)/avg: \1ms/g
      }
    '

    echo
  } >> "${SUMMARY_FILE}"
}

measure_delete_time() {
  local ns="${BASE_NS}"
  local experiment_desc="$1"
  local run_id="$2"
  local run_log_file="${3:-}"

  local start_ts_ms end_ts_ms duration_ms sec ms_rem duration ts metric_line
  local delete_started_at now delete_elapsed
  local remaining_pods remaining_deploy remaining_codecoapp remaining_svc remaining
  start_ts_ms=$(date +%s%3N)
  delete_started_at=$(date +%s)

  echo "delete-start namespace=${ns}"
  kubectl delete codecoapp -n "${ns}" --all --wait=false --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete deploy,svc,pod -n "${ns}" --all --wait=false --ignore-not-found=true >/dev/null 2>&1 || true

  while true; do
    remaining_pods=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    remaining_deploy=$(kubectl get deploy -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    remaining_codecoapp=$(kubectl get codecoapp -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    remaining_svc=$(kubectl get svc -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    remaining=$((remaining_pods + remaining_deploy + remaining_codecoapp))
    if [[ "${DELETE_WAIT_INCLUDE_SERVICES}" == "true" ]]; then
      remaining=$((remaining + remaining_svc))
    fi

    if [[ "${remaining}" -eq 0 ]]; then
      break
    fi

    now=$(date +%s)
    delete_elapsed=$((now - delete_started_at))
    if [[ "${delete_elapsed}" -ge "${DELETE_WAIT_TIMEOUT}" ]]; then
      echo "delete-timeout remaining=${remaining} waited=${delete_elapsed}s" >&2
      {
        echo "---- delete-timeout snapshot ----"
        echo "experiment timeout in namespace=${ns}"
        kubectl get codecoapp,pods,deploy,svc,assignmentplan -n "${ns}" --ignore-not-found=true || true
        echo "Recent events:"
        kubectl get events -n "${ns}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 30 || true
        echo "--------------------------------"
      } >> "${SUMMARY_FILE}"
      break
    fi

    echo "delete-wait remaining=${remaining} pods=${remaining_pods} deploy=${remaining_deploy} codecoapp=${remaining_codecoapp} svc=${remaining_svc} includeServices=${DELETE_WAIT_INCLUDE_SERVICES} elapsed=${delete_elapsed}s"
    sleep "${DELETE_POLL_SECONDS}"
  done

  end_ts_ms=$(date +%s%3N)
  duration_ms=$((end_ts_ms - start_ts_ms))
  sec=$((duration_ms / 1000))
  ms_rem=$((duration_ms % 1000))
  duration=$(printf "%d.%03d" "${sec}" "${ms_rem}")

  echo "DeleteDurationSeconds run=${run_id} ${experiment_desc} duration=${duration}s" | tee -a "${DELETE_LOG}"

  if [[ -n "${run_log_file}" && -f "${run_log_file}" ]]; then
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    metric_line="time=\"${ts}\" level=info msg=\"${BASE_NS}: DeleteDuration 99th: ${duration_ms}ms max: ${duration_ms}ms avg: ${duration_ms}ms\" file=\"run_new_perfapp_postgres_codecoapp_cam.sh:measure_delete_time\""
    if grep -q 'Finished execution with UUID:' "${run_log_file}"; then
      awk -v ins="${metric_line}" '
        /Finished execution with UUID:/ && !done { print ins; done=1 }
        { print }
      ' "${run_log_file}" > "${run_log_file}.tmp" && mv "${run_log_file}.tmp" "${run_log_file}"
    else
      echo "${metric_line}" >> "${run_log_file}"
    fi
  fi
}

if ls kubelet-density-heavy_perfapp-postgres_codecoapp-cam-only_*.log >/dev/null 2>&1; then
  counter=$(ls kubelet-density-heavy_perfapp-postgres_codecoapp-cam-only_*.log | grep -o '[0-9]*\.log' | grep -o '[0-9]*' | sort -n | tail -1)
  counter=$((counter + 1))
else
  counter=1
fi

for (( run=1; run<=iterations; run++ )); do
  echo "============================================================"
  echo "Starting run ${run} of ${iterations}"
  echo "Namespace: ${BASE_NS}"
  echo "Template: ${TEMPLATE_FILE}"
  echo "Scheduler mode: ${SCHEDULER_MODE}"
  echo "Scheduler name: ${SCHEDULER_NAME}"
  echo "Summary log: ${SUMMARY_FILE}"
  echo "Delete log: ${DELETE_LOG}"
  echo "============================================================"

  for experiment in "${experiments[@]}"; do
    echo "Running experiment: ${experiment}"

    kubectl delete namespace "${BASE_NS}" --ignore-not-found=true >/dev/null 2>&1 || true
    while kubectl get namespace "${BASE_NS}" >/dev/null 2>&1; do
      sleep 1
    done
    kubectl create namespace "${BASE_NS}" >/dev/null

    eval "${experiment}"

    export JOB_ITERATIONS="${jobIterations}"
    export QPS="${qps}"
    export BURST="${burst}"
    export CODECOAPP_REPLICAS="${codecoapp_replicas}"
    export NAMESPACE="${BASE_NS}"
    export SCHEDULER_NAME="${SCHEDULER_NAME}"

    envsubst < "${TEMPLATE_FILE}" > kubelet-density-heavy.codecoapp-only.yml

    if grep -q '^[[:space:]]*maxWaitTimeout:' kubelet-density-heavy.codecoapp-only.yml; then
      sed -i -E "s|^([[:space:]]*maxWaitTimeout:).*|\\1 ${MAX_WAIT_TIMEOUT}|" kubelet-density-heavy.codecoapp-only.yml
    fi

    if command -v timeout >/dev/null 2>&1; then
      timeout "${KUBEBURNER_TIMEOUT}" kube-burner init -c kubelet-density-heavy.codecoapp-only.yml || true
    else
      kube-burner init -c kubelet-density-heavy.codecoapp-only.yml || true
    fi

    if ls kube-burner-*.log >/dev/null 2>&1; then
      log_file=$(ls -t kube-burner-*.log | head -n 1)
      new_log_file="kubelet-density-heavy_perfapp-postgres_codecoapp-cam-only_jobIterations${jobIterations}_qps${qps}_burst${burst}_replicas${codecoapp_replicas}_${counter}.log"
      mv "${log_file}" "${new_log_file}"
      sed -i -E '/file="service_latency.go:[0-9]+"/ s/: Ready 99th:/: ServiceLatency 99th:/' "${new_log_file}"
    else
      new_log_file=""
    fi

    wait_for_creation_readiness "${codecoapp_replicas}" "${jobIterations}" || true
    echo "post-creation-delay sleeping ${POST_CREATION_DELAY_SECONDS}s before capture/deletion..."
    sleep "${POST_CREATION_DELAY_SECONDS}"
    capture_creation_status "${experiment}" "${run}" "${new_log_file}" "${codecoapp_replicas}" "${jobIterations}"
    measure_delete_time "${experiment}" "${run}" "${new_log_file}"
    if [[ -n "${new_log_file}" && -f "${new_log_file}" ]]; then
      extract_podlatency_block "${new_log_file}" "${experiment}" "${run}"
    fi

    counter=$((counter + 1))
    echo "Sleeping ${INTER_EXPERIMENT_SLEEP}s before next experiment..."
    sleep "${INTER_EXPERIMENT_SLEEP}"
  done
done

echo "All perfapp+postgres CodecoApp-only CAM experiments completed."
