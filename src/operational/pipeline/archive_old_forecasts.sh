#!/usr/bin/env bash
# Archive old forecast directories in S3, keeping only the 2 most recent.
#
# Required env vars:
#   S3_BUCKET_PATH  - e.g. s3://firecachedata
#   ECOREGION       - e.g. middle_rockies
#
# Optional:
#   DRY_RUN=true    - print what would be moved without doing it

set -euo pipefail

if [ -z "${S3_BUCKET_PATH:-}" ] || [ -z "${ECOREGION:-}" ]; then
  echo "ERROR: S3_BUCKET_PATH and ECOREGION must be set" >&2
  exit 1
fi

KEEP=2
S3_PREFIX="${S3_BUCKET_PATH}/out/forecasts/${ECOREGION}/"
ARCHIVE_PREFIX="${S3_BUCKET_PATH}/archive/forecasts/${ECOREGION}/"
DRY_RUN="${DRY_RUN:-false}"

echo "Listing forecast directories in ${S3_PREFIX} ..."

# List date directories (YYYY-MM-DD/) and sort
DATE_DIRS=$(aws s3 ls "${S3_PREFIX}" | grep -oP '\d{4}-\d{2}-\d{2}/' | sort)

if [ -z "$DATE_DIRS" ]; then
  echo "No date directories found. Nothing to archive."
  exit 0
fi

TOTAL=$(echo "$DATE_DIRS" | wc -l)
echo "Found ${TOTAL} date directories."

if [ "$TOTAL" -le "$KEEP" ]; then
  echo "Keeping all ${TOTAL} directories (threshold: ${KEEP}). Nothing to archive."
  exit 0
fi

# Directories to archive (all but the last KEEP)
ARCHIVE_DIRS=$(echo "$DATE_DIRS" | head -n -"${KEEP}")
KEEP_DIRS=$(echo "$DATE_DIRS" | tail -n "${KEEP}")

echo "Keeping: $(echo "$KEEP_DIRS" | tr '\n' ' ')"
echo "Archiving: $(echo "$ARCHIVE_DIRS" | tr '\n' ' ')"

for DIR in $ARCHIVE_DIRS; do
  DATE="${DIR%/}"
  SRC="${S3_PREFIX}${DATE}/"
  DST="${ARCHIVE_PREFIX}${DATE}/"

  if [[ "${DRY_RUN}" =~ ^[Tt][Rr][Uu][Ee]$ ]]; then
    echo "[DRY RUN] Would move ${SRC} -> ${DST}"
  else
    echo "Archiving ${DATE} ..."
    if ! aws s3 mv "${SRC}" "${DST}" --recursive --acl public-read --copy-props none; then
      echo "WARNING: Failed to archive ${DATE}, continuing..." >&2
    fi
  fi
done

echo "Archival complete."
