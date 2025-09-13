#!/bin/bash
# Extract Docker images from Helm charts
# This script processes Helm charts and extracts all Docker image references

set -euo pipefail

# Enable bash debugging if BASH_DEBUG is set
if [[ "${BASH_DEBUG:-false}" == "true" ]]; then
    set -x
fi

# Default values
MIRROR_REGISTRY="${MIRROR_REGISTRY:-registry.internal.company.com}"
MIRROR_PREFIX="${MIRROR_PREFIX:-dockerhub}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-json}"  # json or text
DEBUG="${DEBUG:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Debug logging
debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

# Info logging
info() {
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

# Warning logging
warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

# Error logging
error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Function to extract images from a single chart
extract_from_chart() {
    local chart_path="$1"
    local images=()

    if [[ ! -d "$chart_path" ]]; then
        error "Chart directory not found: $chart_path"
        return 1
    fi

    info "Processing chart: $chart_path"

    # Update dependencies if needed
    if [[ -f "$chart_path/Chart.yaml" ]]; then
        # Check if chart has dependencies
        if grep -q "dependencies:" "$chart_path/Chart.yaml"; then
            debug "Chart has dependencies, building them..."
            if helm dependency build "$chart_path" >/dev/null 2>&1; then
                debug "Successfully built dependencies for $chart_path"
            else
                warn "Failed to build dependencies for $chart_path, trying update instead..."
                helm dependency update "$chart_path" 2>/dev/null || warn "Failed to update dependencies for $chart_path"
            fi
        fi
    fi

    # Run helm template to get all manifests
    local template_output
    if template_output=$(helm template test-release "$chart_path" 2>/dev/null); then
        debug "Successfully templated chart: $chart_path"
    else
        warn "Failed to template chart: $chart_path"
        template_output=""
    fi

    # Extract images from templated output
    # Look for image: fields in YAML (handle both quoted and unquoted)
    while IFS= read -r line; do
        # Extract image value - handle various formats
        local image=$(echo "$line" | sed 's/^[[:space:]]*-*[[:space:]]*image:[[:space:]]*//' | sed 's/"//g' | sed "s/'//g" | sed 's/[[:space:]]*$//')

        # Skip empty lines and template variables
        if [[ -n "$image" ]] && [[ ! "$image" =~ \{\{ ]]; then
            debug "Found image from template: $image"
            images+=("$image")
        fi
    done < <(echo "$template_output" | grep -E 'image:' || true)

    # Also look for container specs with image fields
    # This catches cases where image might be in a containers array
    while IFS= read -r line; do
        local image=$(echo "$line" | awk '{print $2}' | sed 's/"//g' | sed "s/'//g")
        if [[ -n "$image" ]] && [[ ! "$image" =~ \{\{ ]] && [[ "$image" =~ / ]]; then
            debug "Found container image: $image"
            images+=("$image")
        fi
    done < <(echo "$template_output" | grep -E 'containers:' -A 20 | grep -E 'image:' || true)

    # Check values.yaml for image definitions
    if [[ -f "$chart_path/values.yaml" ]]; then
        debug "Checking values.yaml for image definitions"

        # Extract repository and tag combinations
        local repos=$(grep -E '^\s*repository:' "$chart_path/values.yaml" 2>/dev/null | sed 's/.*repository:[[:space:]]*//' | sed 's/"//g' || true)
        local tags=$(grep -E '^\s*tag:' "$chart_path/values.yaml" 2>/dev/null | sed 's/.*tag:[[:space:]]*//' | sed 's/"//g' || true)

        # Try to combine repository and tag
        if [[ -n "$repos" ]]; then
            while IFS= read -r repo; do
                if [[ -n "$repo" ]] && [[ ! "$repo" =~ \{\{ ]]; then
                    # Add with latest tag if no tag found
                    images+=("$repo:latest")
                    debug "Found repository in values: $repo"
                fi
            done <<< "$repos"
        fi

        # Also look for complete image references
        while IFS= read -r line; do
            local image=$(echo "$line" | sed 's/.*image:[[:space:]]*//' | sed 's/"//g' | sed 's/[[:space:]]*$//' | sed 's/#.*//')
            if [[ -n "$image" ]] && [[ ! "$image" =~ \{\{ ]] && [[ "$image" =~ / ]]; then
                debug "Found complete image in values: $image"
                images+=("$image")
            fi
        done < <(grep -E '\bimage:' "$chart_path/values.yaml" 2>/dev/null || true)
    else
        debug "No values.yaml found in $chart_path - this is normal for charts with dependencies"
    fi

    # Return unique images (handle case where no images found)
    if [[ ${#images[@]} -gt 0 ]]; then
        printf '%s\n' "${images[@]}" | sort -u
    else
        debug "No images found in chart: $chart_path"
        # Return nothing (empty output) which is valid
    fi
}

# Function to process an image and add metadata
process_image() {
    local image="$1"
    local chart="$2"

    # Ensure image has a tag
    if [[ ! "$image" =~ : ]]; then
        image="$image:latest"
    fi

    # Build mirror path
    local mirror_path="${MIRROR_REGISTRY}/${MIRROR_PREFIX}/$(echo "$image" | sed 's|/|_|g')"

    echo "$image|$mirror_path|$chart"
}

# Main function
main() {
    local charts="$*"
    local all_images=()
    local processed_images=()
    local charts_processed=0
    local charts_skipped=0

    if [[ -z "$charts" ]]; then
        error "No charts specified"
        echo "Usage: $0 <chart-path> [chart-path...]" >&2
        exit 1
    fi

    # Process each chart
    for chart in $charts; do
        # Clean up chart path
        chart=$(echo "$chart" | sed 's|/$||')

        # Try to handle relative and absolute paths
        if [[ ! -d "$chart" ]]; then
            # Try with ./ prefix if not found
            if [[ -d "./$chart" ]]; then
                chart="./$chart"
                debug "Using relative path: $chart"
            else
                warn "Skipping non-existent directory: $chart (pwd: $(pwd))"
                ((charts_skipped++))
                continue
            fi
        fi

        ((charts_processed++))

        # Extract images from this chart
        local chart_images
        chart_images=$(extract_from_chart "$chart")

        if [[ -n "$chart_images" ]]; then
            while IFS= read -r img; do
                if [[ -n "$img" ]]; then
                    processed_images+=("$(process_image "$img" "$chart")")
                fi
            done <<< "$chart_images"
        fi
    done

    # Check if all charts were skipped
    if [[ $charts_processed -eq 0 ]]; then
        warn "All specified charts were skipped or not found"
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            echo "[]"
        fi
        info "Charts processed: $charts_processed, Charts skipped: $charts_skipped"
        # Don't fail - just return empty results
        return 0
    fi

    # Remove duplicates and format output
    local unique_images=""
    if [[ ${#processed_images[@]} -gt 0 ]]; then
        unique_images=$(printf '%s\n' "${processed_images[@]}" | sort -u)
    fi

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        # Output as JSON array
        echo "["
        local first=true
        while IFS='|' read -r original mirror chart; do
            if [[ -n "$original" ]]; then
                if [[ "$first" != "true" ]]; then
                    echo ","
                fi
                cat <<EOF
  {
    "original": "$original",
    "mirror": "$mirror",
    "chart": "$chart",
    "selected": false
  }
EOF
                first=false
            fi
        done <<< "$unique_images"
        echo "]"
    else
        # Output as text
        echo "# Docker Images Found"
        echo "# Format: original|mirror|chart"
        echo "$unique_images"
    fi

    # Summary to stderr
    local count=0
    if [[ -n "$unique_images" ]]; then
        count=$(echo "$unique_images" | grep -c '^[^[:space:]]' || echo 0)
    fi
    info "Found $count unique images across all charts"
}

# Check prerequisites
if ! command -v helm &> /dev/null; then
    error "Helm is not installed or not in PATH"
    exit 1
fi

# Run main function
main "$@"