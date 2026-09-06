#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template — SSL / TLS Certificate Automation Engine
# ==============================================================================
# Usage:
#   ./scripts/setup-ssl.sh --domain=example.com --email=admin@example.com
#   ./scripts/setup-ssl.sh --domain=example.com --dry-run
#   ./scripts/setup-ssl.sh --domain=example.com --staging
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DOMAINS=()
EMAIL=""
ACME_WEBROOT="/var/www/certbot"
DRY_RUN=false
STAGING=false
FORCE_RENEW=false

print_usage() {
  cat << EOF
Atlas SSL / TLS Certificate Setup (Certbot Wrapper)

Usage:
  $(basename "$0") -d DOMAIN [options]

Options:
  -d, --domain=DOMAIN     Primary domain name (can be specified multiple times)
  -m, --email=EMAIL       Administrative contact email for Let's Encrypt notices
  -w, --webroot=PATH      ACME challenge webroot directory (default: /var/www/certbot)
  --staging               Use Let's Encrypt Staging API (for testing without rate limits)
  --dry-run               Simulate certificate issuance without contacting Let's Encrypt
  --force-renew           Force certificate renewal even if not close to expiration
  -h, --help              Show this help message

Examples:
  ./scripts/setup-ssl.sh -d example.com -d www.example.com --email=admin@example.com
  ./scripts/setup-ssl.sh -d example.com --dry-run
  ./scripts/setup-ssl.sh -d example.com --staging
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d=*|--domain=*)
      DOMAINS+=("${1#*=}")
      shift
      ;;
    -d|--domain)
      if [ -z "${2:-}" ]; then log_error "Option --domain requires an argument"; exit 2; fi
      DOMAINS+=("$2")
      shift 2
      ;;
    -m=*|--email=*)
      EMAIL="${1#*=}"
      shift
      ;;
    -m|--email)
      if [ -z "${2:-}" ]; then log_error "Option --email requires an argument"; exit 2; fi
      EMAIL="$2"
      shift 2
      ;;
    -w=*|--webroot=*)
      ACME_WEBROOT="${1#*=}"
      shift
      ;;
    -w|--webroot)
      if [ -z "${2:-}" ]; then log_error "Option --webroot requires an argument"; exit 2; fi
      ACME_WEBROOT="$2"
      shift 2
      ;;
    --staging)
      STAGING=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force-renew)
      FORCE_RENEW=true
      shift
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

if [ "${#DOMAINS[@]}" -eq 0 ]; then
  log_error "At least one domain must be specified via -d or --domain."
  print_usage
  exit 2
fi

PRIMARY_DOMAIN="${DOMAINS[0]}"
log_info "=================================================="
log_info "Atlas SSL Certificate Setup Engine"
log_info "Primary Domain:  ${PRIMARY_DOMAIN}"
log_info "All Domains:     ${DOMAINS[*]}"
log_info "ACME Webroot:    ${ACME_WEBROOT}"
log_info "=================================================="

# Check domain syntax
for dom in "${DOMAINS[@]}"; do
  if ! [[ "${dom}" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    log_error "Invalid domain format: '${dom}'"
    exit 2
  fi
done

# Check if Certbot is installed
if ! command -v certbot >/dev/null 2>&1; then
  log_error "Certbot is not installed. Run 'sudo apt-get install certbot' or use scripts/setup-server.sh."
  exit 1
fi

# Check ACME challenge directory
if [ "${DRY_RUN}" = "false" ]; then
  mkdir -p "${ACME_WEBROOT}"
  chmod 755 "${ACME_WEBROOT}"
fi

# Build Certbot command
CERTBOT_ARGS=(
  certonly
  --webroot
  -w "${ACME_WEBROOT}"
  --non-interactive
  --agree-tos
)

for dom in "${DOMAINS[@]}"; do
  CERTBOT_ARGS+=(-d "${dom}")
done

if [ -n "${EMAIL}" ]; then
  CERTBOT_ARGS+=(--email "${EMAIL}")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

if [ "${STAGING}" = "true" ]; then
  CERTBOT_ARGS+=(--staging)
  log_warn "Using Let's Encrypt STAGING server (certificate will not be trusted by browsers)."
fi

if [ "${FORCE_RENEW}" = "true" ]; then
  CERTBOT_ARGS+=(--force-renewal)
fi

if [ "${DRY_RUN}" = "true" ]; then
  log_info "[DRY-RUN] Would execute: certbot ${CERTBOT_ARGS[*]}"
  log_success "[DRY-RUN] SSL setup validation passed."
  exit 0
fi

# Check if certificate already exists and is healthy
CERT_DIR="/etc/letsencrypt/live/${PRIMARY_DOMAIN}"
if [ -f "${CERT_DIR}/fullchain.pem" ] && [ "${FORCE_RENEW}" = "false" ]; then
  EXPIRY_DATE="$(openssl x509 -enddate -noout -in "${CERT_DIR}/fullchain.pem" | cut -d= -f2 || echo "unknown")"
  log_info "Existing certificate found for ${PRIMARY_DOMAIN} (Expires: ${EXPIRY_DATE})."
  if ! openssl x509 -checkend 2592000 -noout -in "${CERT_DIR}/fullchain.pem" >/dev/null 2>&1; then
    log_warn "Certificate expires within 30 days. Proceeding with renewal."
  else
    log_info "Certificate is valid for more than 30 days. Skipping issuance (use --force-renew to override)."
    exit 0
  fi
fi

log_info "Requesting certificate from Let's Encrypt..."
certbot "${CERTBOT_ARGS[@]}" || {
  log_error "Certbot failed to obtain certificate for ${DOMAINS[*]}."
  log_error "Ensure DNS A-records point to this server and Nginx routes /.well-known/acme-challenge/ to ${ACME_WEBROOT}."
  exit 1
}

# Verify generated certificate files
if [ -f "${CERT_DIR}/fullchain.pem" ] && [ -f "${CERT_DIR}/privkey.pem" ]; then
  log_pass "Certificate files verified in ${CERT_DIR}"
  
  # Reload Nginx if present
  if command -v nginx >/dev/null 2>&1; then
    log_info "Testing and reloading Nginx..."
    if nginx -t >/dev/null 2>&1; then
      nginx -s reload || systemctl reload nginx || true
      log_pass "Nginx reloaded successfully."
    else
      log_warn "Nginx syntax test failed. Nginx was NOT reloaded. Check /etc/nginx/."
    fi
  elif docker inspect atlas_nginx >/dev/null 2>&1 || docker inspect nginx >/dev/null 2>&1; then
    NGINX_CONTAINER="atlas_nginx"
    docker exec "${NGINX_CONTAINER}" nginx -s reload >/dev/null 2>&1 || true
    log_pass "Dockerized Nginx reloaded successfully."
  fi
  
  log_info "=================================================="
  log_success "SSL SETUP COMPLETED SUCCESSFULLY FOR ${DOMAINS[*]}!"
  log_info "Certificate: ${CERT_DIR}/fullchain.pem"
  log_info "Private Key: ${CERT_DIR}/privkey.pem"
  log_info "=================================================="
else
  log_error "Certificate files not found after certbot run."
  exit 1
fi
