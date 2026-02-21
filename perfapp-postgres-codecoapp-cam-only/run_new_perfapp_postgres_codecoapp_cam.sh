#!/bin/bash
# TINA SAMIZADEH 21 FEB  

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
WAIT_COUNTER_MODE="${WAIT_COUNTER_MODE:-ready}" # observed | ready
POST_CREATION_DELAY_SECONDS="${POST_CREATION_DELAY_SECONDS:-90}"
DELETE_WAIT_TIMEOUT="${DELETE_WAIT_TIMEOUT:-180}"
DELETE_POLL_SECONDS="${DELETE_POLL_SECONDS:-1}"
DELETE_WAIT_INCLUDE_SERVICES="${DELETE_WAIT_INCLUDE_SERVICES:-true}" # true | false
WAIT_SERVICE_TIMEOUT="${WAIT_SERVICE_TIMEOUT:-300}"
SERVICE_POLL_SECONDS="${SERVICE_POLL_SECONDS:-1}"
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
#tina
experiments=(
  "jobIterations=1 qps=1 burst=1 codecoapp_replicas=1"
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

calc_stats_from_file_ms() {
  local values_file="$1"
  if [[ ! -s "${values_file}" ]]; then
    echo "na na na 0"
    return 0
  fi

  local count p99_index p99 max avg
  count=$(wc -l < "${values_file}")
  p99_index=$(( (99 * count + 99) / 100 ))
  p99=$(sort -n "${values_file}" | sed -n "${p99_index}p")
  max=$(sort -n "${values_file}" | tail -n 1)
  avg=$(awk '{s+=$1} END {if (NR>0) printf "%.0f", s/NR; else print "na"}' "${values_file}")
  echo "${p99} ${max} ${avg} ${count}"
}

to_epoch_ms() {
  local ts="$1"
  if [[ -z "${ts}" || "${ts}" == "null" ]]; then
    echo ""
    return 0
  fi
  date -d "${ts}" +%s%3N 2>/dev/null || echo ""
}

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
  local experiment_desc="$1"
  local run_id="$2"
  local run_log_file="$3"
  local replicas="$4"
  local job_iters="$5"
  local creation_anchor_ts="${6:-}"
  local ns="${BASE_NS}"
  local components_per_instance=2
  local expected_pods expected_containers observed_pods ready_pods observed_containers ready_containers
  local now elapsed started_at codecoapps plans since_anchor
  local observed_ready_seconds="" pod_ready_seconds="" container_ready_seconds=""
  local timing_line timing_msg ts metric_line
  local pod_ready_values_file pod_ready_stats p99_ms max_ms avg_ms sample_count
  pod_ready_values_file=$(mktemp)

  expected_pods=$((replicas * components_per_instance * job_iters))
  expected_containers="${expected_pods}"
  started_at=$(date +%s)
  if [[ -z "${creation_anchor_ts}" ]]; then
    creation_anchor_ts="${started_at}"
  fi

  while true; do
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
    codecoapps=$(kubectl get codecoapp -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    plans=$(kubectl get assignmentplan -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}:{.status.phase}{" "}{end}' 2>/dev/null || echo "no-assignmentplan")
    now=$(date +%s)
    since_anchor=$((now - creation_anchor_ts))

    if [[ -z "${observed_ready_seconds}" && "${observed_pods}" -ge "${expected_pods}" ]]; then
      observed_ready_seconds="${since_anchor}"
    fi
    if [[ -z "${pod_ready_seconds}" && "${ready_pods}" -ge "${expected_pods}" ]]; then
      pod_ready_seconds="${since_anchor}"
    fi
    if [[ -z "${container_ready_seconds}" && "${ready_containers}" -ge "${expected_containers}" ]]; then
      container_ready_seconds="${since_anchor}"
    fi

    local current_count criterion
    if [[ "${WAIT_COUNTER_MODE}" == "ready" ]]; then
      current_count="${ready_pods}"
      criterion="readyPods"
    else
      current_count="${observed_pods}"
      criterion="observedPods"
    fi

    if [[ "${current_count}" -ge "${expected_pods}" ]]; then
      while IFS='|' read -r pod_name ready_ts; do
        [[ -z "${pod_name}" || -z "${ready_ts}" ]] && continue
        ready_epoch_ms=$(to_epoch_ms "${ready_ts}")
        [[ -z "${ready_epoch_ms}" ]] && continue
        delta_ms=$((ready_epoch_ms - creation_anchor_ts * 1000))
        if [[ "${delta_ms}" -ge 0 ]]; then
          echo "${delta_ms}" >> "${pod_ready_values_file}"
        fi
      done < <(kubectl get pods -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{"\n"}{end}' 2>/dev/null || true)

      pod_ready_stats=$(calc_stats_from_file_ms "${pod_ready_values_file}")
      read -r p99_ms max_ms avg_ms sample_count <<< "${pod_ready_stats}"
      echo "ContainerReadyLatency run=${run_id} ${experiment_desc} 99th=${p99_ms}ms max=${max_ms}ms avg=${avg_ms}ms samples=${sample_count}" | tee -a "${SUMMARY_FILE}"

      timing_line="CreateReadinessSeconds run=${run_id} ${experiment_desc} observedReady=${observed_ready_seconds:-na}s podReady=${pod_ready_seconds:-na}s containerReady=${container_ready_seconds:-na}s expectedPods=${expected_pods} observedPods=${observed_pods} readyPods=${ready_pods} expectedContainers=${expected_containers} readyContainers=${ready_containers} status=ok"
      echo "${timing_line}" | tee -a "${SUMMARY_FILE}"
      timing_msg="${BASE_NS}: CreateReadiness observedReady: ${observed_ready_seconds:-na}s podReady: ${pod_ready_seconds:-na}s containerReady: ${container_ready_seconds:-na}s expectedPods: ${expected_pods} observedPods: ${observed_pods} readyPods: ${ready_pods} expectedContainers: ${expected_containers} readyContainers: ${ready_containers} status: ok"
      if [[ -n "${run_log_file}" && -f "${run_log_file}" ]]; then
        ts=$(date +"%Y-%m-%d %H:%M:%S")
        metric_line="time=\"${ts}\" level=info msg=\"${timing_msg}\" file=\"run_new_perfapp_postgres_codecoapp_cam.sh:wait_for_creation_readiness\""
        if grep -q 'Finished execution with UUID:' "${run_log_file}"; then
          awk -v ins="${metric_line}" '
            /Finished execution with UUID:/ && !done { print ins; done=1 }
            { print }
          ' "${run_log_file}" > "${run_log_file}.tmp" && mv "${run_log_file}.tmp" "${run_log_file}"
        else
          echo "${metric_line}" >> "${run_log_file}"
        fi

        metric_line="time=\"${ts}\" level=info msg=\"${BASE_NS}: ContainerReadyLatency 99th: ${p99_ms}ms max: ${max_ms}ms avg: ${avg_ms}ms samples: ${sample_count}\" file=\"run_new_perfapp_postgres_codecoapp_cam.sh:wait_for_creation_readiness\""
        if grep -q 'Finished execution with UUID:' "${run_log_file}"; then
          awk -v ins="${metric_line}" '
            /Finished execution with UUID:/ && !done { print ins; done=1 }
            { print }
          ' "${run_log_file}" > "${run_log_file}.tmp" && mv "${run_log_file}.tmp" "${run_log_file}"
        else
          echo "${metric_line}" >> "${run_log_file}"
        fi
      fi
      echo "create-progress criterion=${criterion} value=${current_count}/${expected_pods} readyPods=${ready_pods}/${expected_pods} observedPods=${observed_pods}/${expected_pods} codecoapps=${codecoapps} assignmentplan='${plans}'"
      rm -f "${pod_ready_values_file}"
      return 0
    fi

    elapsed=$((now - started_at))
    if [[ "${elapsed}" -ge "${WAIT_CREATE_TIMEOUT}" ]]; then
      timing_line="CreateReadinessSeconds run=${run_id} ${experiment_desc} observedReady=${observed_ready_seconds:-na}s podReady=${pod_ready_seconds:-na}s containerReady=${container_ready_seconds:-na}s expectedPods=${expected_pods} observedPods=${observed_pods} readyPods=${ready_pods} expectedContainers=${expected_containers} readyContainers=${ready_containers} status=timeout"
      echo "${timing_line}" | tee -a "${SUMMARY_FILE}"
      timing_msg="${BASE_NS}: CreateReadiness observedReady: ${observed_ready_seconds:-na}s podReady: ${pod_ready_seconds:-na}s containerReady: ${container_ready_seconds:-na}s expectedPods: ${expected_pods} observedPods: ${observed_pods} readyPods: ${ready_pods} expectedContainers: ${expected_containers} readyContainers: ${ready_containers} status: timeout"
      if [[ -n "${run_log_file}" && -f "${run_log_file}" ]]; then
        ts=$(date +"%Y-%m-%d %H:%M:%S")
        metric_line="time=\"${ts}\" level=info msg=\"${timing_msg}\" file=\"run_new_perfapp_postgres_codecoapp_cam.sh:wait_for_creation_readiness\""
        if grep -q 'Finished execution with UUID:' "${run_log_file}"; then
          awk -v ins="${metric_line}" '
            /Finished execution with UUID:/ && !done { print ins; done=1 }
            { print }
          ' "${run_log_file}" > "${run_log_file}.tmp" && mv "${run_log_file}.tmp" "${run_log_file}"
        else
          echo "${metric_line}" >> "${run_log_file}"
        fi
      fi
      echo "create-timeout criterion=${criterion} value=${current_count}/${expected_pods} readyPods=${ready_pods}/${expected_pods} observedPods=${observed_pods}/${expected_pods} codecoapps=${codecoapps} assignmentplan='${plans}' waited=${elapsed}s" >&2
      {
        echo "---- create-timeout snapshot ----"
        echo "experiment timeout in namespace=${ns}"
        kubectl get codecoapp,pods,deploy,svc,assignmentplan -n "${ns}" --ignore-not-found=true || true
        echo "Recent events:"
        kubectl get events -n "${ns}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 30 || true
        echo "--------------------------------"
      } >> "${SUMMARY_FILE}"
      rm -f "${pod_ready_values_file}"
      return 1
    fi

    echo "create-wait criterion=${criterion} value=${current_count}/${expected_pods} readyPods=${ready_pods}/${expected_pods} observedPods=${observed_pods}/${expected_pods} codecoapps=${codecoapps} assignmentplan='${plans}' elapsed=${elapsed}s"
    sleep "${WAIT_POLL_SECONDS}"
  done
}

measure_service_observed_time() {
  local experiment_desc="$1"
  local run_id="$2"
  local run_log_file="$3"
  local replicas="$4"
  local job_iters="$5"
  local creation_anchor_ts="${6:-}"
  local ns="${BASE_NS}"
  local services_per_instance=2
  local expected_services observed_services now elapsed since_anchor
  local status="ok"
  local service_seconds="na"
  local timing_line timing_msg ts metric_line
  local svc_values_file svc_stats p99_ms max_ms avg_ms sample_count
  svc_values_file=$(mktemp)

  expected_services=$((replicas * services_per_instance * job_iters))
  if [[ -z "${creation_anchor_ts}" ]]; then
    creation_anchor_ts=$(date +%s)
  fi

  local started_at
  started_at=$(date +%s)
  while true; do
    observed_services=$(kubectl get svc -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    now=$(date +%s)
    since_anchor=$((now - creation_anchor_ts))
    elapsed=$((now - started_at))

    if [[ "${observed_services}" -ge "${expected_services}" ]]; then
      service_seconds="${since_anchor}"
      break
    fi
    if [[ "${elapsed}" -ge "${WAIT_SERVICE_TIMEOUT}" ]]; then
      status="timeout"
      break
    fi
    sleep "${SERVICE_POLL_SECONDS}"
  done

  timing_line="ServiceObservedSeconds run=${run_id} ${experiment_desc} serviceObserved=${service_seconds}s expectedServices=${expected_services} observedServices=${observed_services} status=${status}"
  echo "${timing_line}" | tee -a "${SUMMARY_FILE}"

  while IFS='|' read -r svc_name create_ts; do
    [[ -z "${svc_name}" || -z "${create_ts}" ]] && continue
    create_epoch_ms=$(to_epoch_ms "${create_ts}")
    [[ -z "${create_epoch_ms}" ]] && continue
    delta_ms=$((create_epoch_ms - creation_anchor_ts * 1000))
    if [[ "${delta_ms}" -ge 0 ]]; then
      echo "${delta_ms}" >> "${svc_values_file}"
    fi
  done < <(kubectl get svc -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null | awk -F'|' '$1 ~ /^svc-/' || true)

  if [[ ! -s "${svc_values_file}" ]]; then
    kubectl get svc -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null | while IFS='|' read -r svc_name create_ts; do
      [[ -z "${svc_name}" || -z "${create_ts}" ]] && continue
      create_epoch_ms=$(to_epoch_ms "${create_ts}")
      [[ -z "${create_epoch_ms}" ]] && continue
      delta_ms=$((create_epoch_ms - creation_anchor_ts * 1000))
      if [[ "${delta_ms}" -ge 0 ]]; then
        echo "${delta_ms}" >> "${svc_values_file}"
      fi
    done
  fi

  svc_stats=$(calc_stats_from_file_ms "${svc_values_file}")
  read -r p99_ms max_ms avg_ms sample_count <<< "${svc_stats}"
  echo "ServiceLatency run=${run_id} ${experiment_desc} 99th=${p99_ms}ms max=${max_ms}ms avg=${avg_ms}ms samples=${sample_count}" | tee -a "${SUMMARY_FILE}"

  if [[ -n "${run_log_file}" && -f "${run_log_file}" ]]; then
    timing_msg="${BASE_NS}: ServiceObserved serviceReady: ${service_seconds}s expectedServices: ${expected_services} observedServices: ${observed_services} status: ${status}"
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    metric_line="time=\"${ts}\" level=info msg=\"${timing_msg}\" file=\"run_new_perfapp_postgres_codecoapp_cam.sh:measure_service_observed_time\""
    if grep -q 'Finished execution with UUID:' "${run_log_file}"; then
      awk -v ins="${metric_line}" '
        /Finished execution with UUID:/ && !done { print ins; done=1 }
        { print }
      ' "${run_log_file}" > "${run_log_file}.tmp" && mv "${run_log_file}.tmp" "${run_log_file}"
    else
      echo "${metric_line}" >> "${run_log_file}"
    fi

    metric_line="time=\"${ts}\" level=info msg=\"${BASE_NS}: ServiceLatency 99th: ${p99_ms}ms max: ${max_ms}ms avg: ${avg_ms}ms samples: ${sample_count}\" file=\"run_new_perfapp_postgres_codecoapp_cam.sh:measure_service_observed_time\""
    if grep -q 'Finished execution with UUID:' "${run_log_file}"; then
      awk -v ins="${metric_line}" '
        /Finished execution with UUID:/ && !done { print ins; done=1 }
        { print }
      ' "${run_log_file}" > "${run_log_file}.tmp" && mv "${run_log_file}.tmp" "${run_log_file}"
    else
      echo "${metric_line}" >> "${run_log_file}"
    fi
  fi
  rm -f "${svc_values_file}"
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
      {
        line=$0
        low=tolower(line)

        if (line ~ /Stopping measurement: (podLatency|serviceLatency)/) { print; next }
        if (line ~ /Deleting [0-9]+ namespaces with label: kubernetes.io\/metadata.name=kube-burner-service-latency/) { print; next }
        if (line ~ /Finished execution with UUID:/) { print; next }
        if (line ~ /👋 Exiting kube-burner/) { print; next }
        if (line ~ /file="run_new_perfapp_postgres_codecoapp_cam.sh:(capture_creation_status|measure_delete_time|wait_for_creation_readiness|measure_service_observed_time)"/) { print; next }

        # Keep latency quantiles from the full log; these can appear before "Stopping measurement"
        if (line ~ /level=info/ && (line ~ /(50th:|99th:|max:|avg:)/ || low ~ /containerready/)) { print; next }
      }
    ' "${src_log}" | sed -E '
      /file="service_latency.go:[0-9]+"/{
      s/: Ready 50th:/: ServiceLatency 50th:/g
      s/: Ready 99th:/: ServiceLatency 99th:/g
      s/: Ready max:/: ServiceLatency max:/g
      s/: Ready avg:/: ServiceLatency avg:/g
      }
      /file="base_measurement.go:[0-9]+"/{
      s/50th: ([0-9]+)/50th: \1ms/g
      s/99th: ([0-9]+)/99th: \1ms/g
      s/max: ([0-9]+)/max: \1ms/g
      s/avg: ([0-9]+)/avg: \1ms/g
      }
    ' | awk '!seen[$0]++'

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
  local pod_delete_values_file pod_delete_stats p99_ms max_ms avg_ms sample_count
  local initial_pods current_pods now_ms pod_name
  declare -A pending_pods=()
  pod_delete_values_file=$(mktemp)
  start_ts_ms=$(date +%s%3N)
  delete_started_at=$(date +%s)

  initial_pods=$(kubectl get pods -n "${ns}" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue
    pending_pods["${pod_name}"]=1
  done <<< "${initial_pods}"

  echo "delete-start namespace=${ns}"
  kubectl delete codecoapp -n "${ns}" --all --wait=false --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete deploy,svc,pod -n "${ns}" --all --wait=false --ignore-not-found=true >/dev/null 2>&1 || true

  while true; do
    current_pods=$(kubectl get pods -n "${ns}" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
    now_ms=$(date +%s%3N)
    for pod_name in "${!pending_pods[@]}"; do
      if ! grep -qx "${pod_name}" <<< "${current_pods}"; then
        echo "$((now_ms - start_ts_ms))" >> "${pod_delete_values_file}"
        unset 'pending_pods[$pod_name]'
      fi
    done

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
  pod_delete_stats=$(calc_stats_from_file_ms "${pod_delete_values_file}")
  read -r p99_ms max_ms avg_ms sample_count <<< "${pod_delete_stats}"
  echo "PodDeletionLatency run=${run_id} ${experiment_desc} 99th=${p99_ms}ms max=${max_ms}ms avg=${avg_ms}ms samples=${sample_count}" | tee -a "${SUMMARY_FILE}"

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

    metric_line="time=\"${ts}\" level=info msg=\"${BASE_NS}: PodDeletionLatency 99th: ${p99_ms}ms max: ${max_ms}ms avg: ${avg_ms}ms samples: ${sample_count}\" file=\"run_new_perfapp_postgres_codecoapp_cam.sh:measure_delete_time\""
    if grep -q 'Finished execution with UUID:' "${run_log_file}"; then
      awk -v ins="${metric_line}" '
        /Finished execution with UUID:/ && !done { print ins; done=1 }
        { print }
      ' "${run_log_file}" > "${run_log_file}.tmp" && mv "${run_log_file}.tmp" "${run_log_file}"
    else
      echo "${metric_line}" >> "${run_log_file}"
    fi
  fi
  rm -f "${pod_delete_values_file}"
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
  echo "Create wait criterion: ${WAIT_COUNTER_MODE}"
  echo "Service wait timeout: ${WAIT_SERVICE_TIMEOUT}s"
  echo "Delete waits services: ${DELETE_WAIT_INCLUDE_SERVICES}"
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

    creation_started_at=$(date +%s)
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

    wait_for_creation_readiness "${experiment}" "${run}" "${new_log_file}" "${codecoapp_replicas}" "${jobIterations}" "${creation_started_at}" || true
    measure_service_observed_time "${experiment}" "${run}" "${new_log_file}" "${codecoapp_replicas}" "${jobIterations}" "${creation_started_at}"
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
