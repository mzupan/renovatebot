#!/bin/bash
set -euo pipefail

# Parse arguments
INPUT_DIR="."
OUTPUT_DIR="."
PATTERN="scan_results_.*\.json"

while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--directory)
      INPUT_DIR="$2"
      shift 2
      ;;
    -o|--output-directory)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -r|--regex)
      PATTERN="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Initialize all_criticals.csv
> "$OUTPUT_DIR/all_criticals.csv"

# Remove any existing critical_found marker
rm -f "$OUTPUT_DIR/critical_found"

# Process each JSON file matching the pattern
find "$INPUT_DIR" -maxdepth 1 -type f -name "scan_results_*.json" | while read -r filepath; do
  filename=$(basename "$filepath")
  echo "Processing: $filename"

  # Extract image name from JSON
  IMAGE_NAME=$(jq -r '.scanOriginResource.name' "$filepath")
  echo "Image: $IMAGE_NAME"

  # Sanitize image name for filename (replace / and : with _)
  SAFE_NAME=$(echo "$IMAGE_NAME" | sed 's/[\/:]/_/g')
  COMMENT_FILE="$OUTPUT_DIR/pr_comment_${SAFE_NAME}.md"

  # Start markdown comment
  cat > "$COMMENT_FILE" <<EOF
## Wiz Scan $IMAGE_NAME

### Summary
EOF

  # Extract vulnerability counts
  CRITICAL_COUNT=$(jq -r '.result.analytics.vulnerabilities.criticalCount // 0' "$filepath")
  HIGH_COUNT=$(jq -r '.result.analytics.vulnerabilities.highCount // 0' "$filepath")
  MEDIUM_COUNT=$(jq -r '.result.analytics.vulnerabilities.mediumCount // 0' "$filepath")
  LOW_COUNT=$(jq -r '.result.analytics.vulnerabilities.lowCount // 0' "$filepath")

  # Write summary table
  cat >> "$COMMENT_FILE" <<EOF
| Severity | Count |
| --- | --- |
| 🔴 Critical | $CRITICAL_COUNT |
| 🟠 High | $HIGH_COUNT |
| 🟡 Medium | $MEDIUM_COUNT |
| 🟢 Low | $LOW_COUNT |

<details><summary>Detailed Findings (Critical and High only)</summary>

| Type | Package | Version | Vulnerability | Severity | Score | Fixed Version |
| --- | --- | --- | --- | --- | --- | --- |
EOF

  # Create temporary files for critical and high findings
  CRITICAL_TEMP=$(mktemp)
  HIGH_TEMP=$(mktemp)

  # Process each section: osPackages, containerPackages, cpe
  for SECTION in "osPackages:OS" "containerPackages:Container" "cpe:CPE"; do
    SECTION_KEY="${SECTION%%:*}"
    SECTION_LABEL="${SECTION##*:}"

    echo "Processing section: $SECTION_KEY"

    # Check if section exists and has data
    if jq -e ".result.$SECTION_KEY // empty" "$filepath" > /dev/null 2>&1; then
      # Process each package in this section
      jq -c ".result.$SECTION_KEY[]? // empty" "$filepath" | while read -r package; do
        PACKAGE_NAME=$(echo "$package" | jq -r '.name')
        PACKAGE_VERSION=$(echo "$package" | jq -r '.version')

        # Process each vulnerability in the package
        echo "$package" | jq -c '.vulnerabilities[]? // empty' | while read -r vuln; do
          VULN_NAME=$(echo "$vuln" | jq -r '.name')
          SEVERITY=$(echo "$vuln" | jq -r '.severity')
          SCORE=$(echo "$vuln" | jq -r '.score')
          FIXED_VERSION=$(echo "$vuln" | jq -r '.fixedVersion // "N/A"')

          # Only process CRITICAL and HIGH
          if [[ "$SEVERITY" == "CRITICAL" ]]; then
            EMOJI="🔴"
            LINE="| $SECTION_LABEL | $PACKAGE_NAME | $PACKAGE_VERSION | $VULN_NAME | ${EMOJI}${SEVERITY} | $SCORE | $FIXED_VERSION |"
            echo "$LINE" >> "$CRITICAL_TEMP"

            # Add to all_criticals.csv
            echo "$IMAGE_NAME,$VULN_NAME,$SEVERITY" >> "$OUTPUT_DIR/all_criticals.csv"

            # Create marker file
            touch "$OUTPUT_DIR/critical_found"

          elif [[ "$SEVERITY" == "HIGH" ]]; then
            EMOJI="🟠"
            LINE="| $SECTION_LABEL | $PACKAGE_NAME | $PACKAGE_VERSION | $VULN_NAME | ${EMOJI}${SEVERITY} | $SCORE | $FIXED_VERSION |"
            echo "$LINE" >> "$HIGH_TEMP"
          fi
        done
      done
    fi
  done

  # Write findings to comment file (criticals first, then high)
  if [[ -f "$CRITICAL_TEMP" ]]; then
    cat "$CRITICAL_TEMP" >> "$COMMENT_FILE"
  fi
  if [[ -f "$HIGH_TEMP" ]]; then
    cat "$HIGH_TEMP" >> "$COMMENT_FILE"
  fi

  # Close details section
  echo "</details>" >> "$COMMENT_FILE"

  # Cleanup temp files
  rm -f "$CRITICAL_TEMP" "$HIGH_TEMP"

  echo "Created comment file: $COMMENT_FILE"
done

echo "Processing complete"
