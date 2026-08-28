#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template — Application Health Check Engine (Hardened V1)
# ==============================================================================
# Usage:
#   APP=myapp ./scripts/health-check.sh
#   ./scripts/health-check.sh --app=myapp
#   ./scripts/health-check.sh --all
#   ./scripts/health-check.sh --app=myapp --timeout=5 --retries=3
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP_TARGET="${APP:-}"
ALL_APPS=false
TIMEOUT=5
RETRIES=3
CUSTOM_CONFIG=""

print_usage() {
  cat << EOF
Atlas Health Check Engine (V1 Hardened)

Usage:
  $(basename "$0") [options]

Options:
  -a, --app=APP_NAME      Application identifier to probe (e.g. --app=example-app)
  --all                   Probe all registered applications
  -t, --timeout=SECONDS   HTTP probe timeout in seconds (default: 5)
  -r, --retries=COUNT     Number of retry attempts before reporting failure (default: 3)
  -c, --config=PATH       Path to custom apps.yml configuration file
  -h, --help              Show this help message

Examples:
  APP=example-app ./scripts/health-check.sh
  ./scripts/health-check.sh --app=example-app --timeout=3
  ./scripts/health-check.sh --all
EOF
}

# Parse command line arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -a=*|--app=*)
      APP_TARGET="${1#*=}"
      shift
      ;;
    -a|--app)
      if [ -z "${2:-}" ]; then log_error "Option --app requires an argument"; exit 2; fi
      APP_TARGET="$2"
      shift 2
      ;;
    --all)
      ALL_APPS=true
      shift
      ;;
    -t=*|--timeout=*)
      TIMEOUT="${1#*=}"
      shift
      ;;
    -t|--timeout)
      if [ -z "${2:-}" ]; then log_error "Option --timeout requires an argument"; exit 2; fi
      TIMEOUT="$2"
      shift 2
      ;;
    -r=*|--retries=*)
      RETRIES="${1#*=}"
      shift
      ;;
    -r|--retries)
      if [ -z "${2:-}" ]; then log_error "Option --retries requires an argument"; exit 2; fi
      RETRIES="$2"
      shift 2
      ;;
    -c=*|--config=*)
      CUSTOM_CONFIG="${1#*=}"
      shift
      ;;
    -c|--config)
      if [ -z "${2:-}" ]; then log_error "Option --config requires an argument"; exit 2; fi
      CUSTOM_CONFIG="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      print_usage
      exit 2
      ;;
  esac
done

if [ -n "${CUSTOM_CONFIG}" ]; then
  export ATLAS_CONFIG_FILE="${CUSTOM_CONFIG}"
fi

# Preflight check for PyYAML
check_pyyaml_dependency

check_http_endpoint() {
  local url="$1"
  local timeout="$2"
  local retries="$3"
  
  local last_code="000"
  for attempt in $(seq 1 "${retries}"); do
    local http_code
    http_code="$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "${timeout}" --max-time "${timeout}" "${url}" 2>/dev/null || echo "000")"
    last_code="${http_code}"
    
    if [[ "${http_code}" =~ ^(200|201|204|301|302|304|307|308)$ ]]; then
      echo "${http_code}"
      return 0
    fi
    
    if [ "${attempt}" -lt "${retries}" ]; then
      sleep 1
    fi
  done
  
  echo "${last_code}"
  return 1
}

health_check_single_app() {
  local app="$1"
  local app_failures=0
  
  if ! validate_app_name "${app}"; then
    return 1
  fi
  
  printf "%b\n" "${COLOR_BOLD}=== Application: ${app} ===${COLOR_RESET}"
  
  if ! is_app_registered "${app}"; then
    log_fail_badge "Application '${app}' is not registered in apps.yml."
    return 1
  fi
  
  local config_file
  config_file="$(find_apps_config)"
  local services
  services="$(query_yaml_keys "${config_file}" "apps.${app}.services")"
  
  if [ -z "${services}" ]; then
    log_warning_badge "No services declared under 'services' for '${app}'."
  else
    for svc in ${services}; do
      local container
      container="$(get_app_property "${app}" "services.${svc}.container")"
      local healthcheck_url
      healthcheck_url="$(get_app_property "${app}" "services.${svc}.healthcheck")"
      
      # 1. Container inspection (if container name declared and Docker present)
      if [ -n "${container}" ] && [ "${container}" != "null" ]; then
        if command -v docker >/dev/null 2>&1; then
          if docker inspect "${container}" >/dev/null 2>&1; then
            local state
            state="$(docker inspect --format '{{.State.Status}}' "${container}" 2>/dev/null || echo "unknown")"
            local health_status
            health_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container}" 2>/dev/null || echo "none")"
            
            if [ "${state}" = "running" ]; then
              if [ "${health_status}" = "healthy" ]; then
                log_pass "Container '${container}' (service: ${svc}) is RUNNING & HEALTHY"
              elif [ "${health_status}" = "unhealthy" ]; then
                log_fail_badge "Container '${container}' (service: ${svc}) is UNHEALTHY"
                app_failures=$((app_failures + 1))
              else
                log_pass "Container '${container}' (service: ${svc}) is RUNNING"
              fi
            else
              log_fail_badge "Container '${container}' (service: ${svc}) is NOT RUNNING (state: ${state})"
              app_failures=$((app_failures + 1))
            fi
          else
            log_warning_badge "Container '${container}' (service: ${svc}) not found on local docker daemon"
          fi
        fi
      fi
      
      # 2. HTTP Health Probe (if URL provided)
      if [ -n "${healthcheck_url}" ] && [ "${healthcheck_url}" != "null" ]; then
        local code
        if code="$(check_http_endpoint "${healthcheck_url}" "${TIMEOUT}" "${RETRIES}")"; then
          log_pass "Endpoint '${healthcheck_url}' returned HTTP ${code}"
        else
          log_fail_badge "Endpoint '${healthcheck_url}' failed (HTTP ${code:-000} after ${RETRIES} attempts)"
          app_failures=$((app_failures + 1))
        fi
      fi
    done
  fi
  
  # 3. Database health check (if declared)
  local db_container
  db_container="$(get_app_property "${app}" "database.container")"
  if [ -n "${db_container}" ] && [ "${db_container}" != "null" ] && command -v docker >/dev/null 2>&1; then
    if docker inspect "${db_container}" >/dev/null 2>&1; then
      local db_state
      db_state="$(docker inspect --format '{{.State.Status}}' "${db_container}" 2>/dev/null || echo "unknown")"
      if [ "${db_state}" = "running" ]; then
        log_pass "Database container '${db_container}' is RUNNING"
      else
        log_fail_badge "Database container '${db_container}' is NOT RUNNING (state: ${db_state})"
        app_failures=$((app_failures + 1))
      fi
    fi
  fi
  
  if [ "${app_failures}" -eq 0 ]; then
    log_success "Application '${app}' health checks passed."
    return 0
  else
    log_error "Application '${app}' has ${app_failures} health check failure(s)."
    return 1
  fi
}

# Main execution
if [ "${ALL_APPS}" = "true" ]; then
  all_list="$(list_registered_apps)"
  if [ -z "${all_list}" ]; then
    log_error "No registered applications found."
    exit 1
  fi
  
  total_failures=0
  for single_app in ${all_list}; do
    if ! health_check_single_app "${single_app}"; then
      total_failures=$((total_failures + 1))
    fi
    printf "\n"
  done
  
  if [ "${total_failures}" -gt 0 ]; then
    log_error "Health check completed with ${total_failures} failing application(s)."
    exit 1
  fi
  log_success "All registered applications are healthy."
  exit 0
fi

if [ -z "${APP_TARGET}" ]; then
  log_error "No application specified. Use --app=APP_NAME or set APP=APP_NAME (or use --all)."
  print_usage
  exit 2
fi

health_check_single_app "${APP_TARGET}"
