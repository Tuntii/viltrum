#!/usr/bin/env bash
# Generate a self-signed dev certificate for examples/https_hello and examples/wss_echo.
# Dev only — do not use in production.
set -euo pipefail

OUT_DIR="${1:-certs}"
DAYS="${DAYS:-825}"
CN="${CN:-localhost}"

mkdir -p "${OUT_DIR}"
CERT="${OUT_DIR}/dev.crt"
KEY="${OUT_DIR}/dev.key"

if [[ -f "${CERT}" && -f "${KEY}" ]]; then
	echo "already exists: ${CERT} ${KEY}"
	exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
	echo "openssl not found; install openssl to generate a dev cert" >&2
	exit 1
fi

openssl req -x509 -newkey rsa:2048 \
	-keyout "${KEY}" \
	-out "${CERT}" \
	-days "${DAYS}" \
	-nodes \
	-subj "/CN=${CN}" \
	-addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
	2>/dev/null || openssl req -x509 -newkey rsa:2048 \
	-keyout "${KEY}" \
	-out "${CERT}" \
	-days "${DAYS}" \
	-nodes \
	-subj "/CN=${CN}"

chmod 600 "${KEY}"
echo "wrote ${CERT}"
echo "wrote ${KEY}"
echo "try: v run examples/https_hello"
