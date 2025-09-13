#!/bin/bash
# Mirror Sync Script - Standalone utility for Docker image mirroring
# This can be used locally or in CI/CD pipelines

set -euo pipefail

# Configuration
MIRROR_REGISTRY="${MIRROR_REGISTRY:-registry.internal.company.com}"
MIRROR_PREFIX="${MIRROR_PREFIX:-dockerhub}"
DRY_RUN="${DRY_RUN:-false}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to build mirror path
build_mirror_path() {
    local original_image="$1"
    local image_path=""
    local image_tag="latest"

    # Split image and tag
    if [[ "$original_image" == *":"* ]]; then
        image_path="${original_image%:*}"
        image_tag="${original_image#*:}"
    else
        image_path="$original_image"
    fi

    # Replace slashes with underscores for flattened structure
    # Or keep hierarchical structure based on preference
    local mirror_path="${MIRROR_REGISTRY}/${MIRROR_PREFIX}/${image_path}"
    echo "${mirror_path}:${image_tag}"
}

# Function to mirror a single image
mirror_image() {
    local original_image="$1"
    local mirror_image="$(build_mirror_path "$original_image")"

    log_info "Mirroring: $original_image -> $mirror_image"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN: Would mirror $original_image to $mirror_image"
        return 0
    fi

    # Pull original image
    if docker pull "$original_image" > /dev/null 2>&1; then
        log_info "Successfully pulled: $original_image"
    else
        log_error "Failed to pull: $original_image"
        return 1
    fi

    # Tag for mirror
    docker tag "$original_image" "$mirror_image"

    # Push to mirror registry
    if docker push "$mirror_image" > /dev/null 2>&1; then
        log_info "Successfully pushed: $mirror_image"
        # Clean up local images to save space
        docker rmi "$mirror_image" > /dev/null 2>&1 || true
        return 0
    else
        log_error "Failed to push: $mirror_image"
        return 1
    fi
}

# Function to extract images from Helm chart
extract_images_from_chart() {
    local chart_path="$1"
    local images=()

    if [[ ! -d "$chart_path" ]]; then
        log_error "Chart directory not found: $chart_path"
        return 1
    fi

    log_info "Extracting images from chart: $chart_path"

    # Update dependencies if needed
    if [[ -f "$chart_path/Chart.lock" ]]; then
        helm dependency update "$chart_path" 2>/dev/null || true
    fi

    # Run helm template and extract images
    local template_output
    template_output=$(helm template test-release "$chart_path" 2>/dev/null || echo "")

    # Extract image references
    while IFS= read -r image; do
        # Clean up the image string
        image=$(echo "$image" | sed 's/image:\s*//' | sed 's/"//g' | sed 's/\s*$//')

        # Skip empty lines and template variables
        if [[ -n "$image" ]] && [[ ! "$image" =~ \{\{ ]]; then
            # Add default tag if missing
            if [[ ! "$image" =~ : ]]; then
                image="$image:latest"
            fi
            images+=("$image")
        fi
    done < <(echo "$template_output" | grep -oE 'image:\s*"?[^"[:space:]]+' | sort -u)

    # Output unique images
    printf '%s\n' "${images[@]}" | sort -u
}

# Function to process images in parallel
process_images_parallel() {
    local -a images=("$@")
    local pids=()
    local failed=0
    local succeeded=0

    for image in "${images[@]}"; do
        # Limit parallel jobs
        while [[ ${#pids[@]} -ge $PARALLEL_JOBS ]]; do
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                    wait "${pids[$i]}"
                    local exit_code=$?
                    if [[ $exit_code -eq 0 ]]; then
                        ((succeeded++))
                    else
                        ((failed++))
                    fi
                    unset 'pids[$i]'
                fi
            done
            pids=("${pids[@]}")  # Reindex array
            sleep 0.1
        done

        # Start new mirror job
        mirror_image "$image" &
        pids+=($!)
    done

    # Wait for remaining jobs
    for pid in "${pids[@]}"; do
        wait "$pid"
        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            ((succeeded++))
        else
            ((failed++))
        fi
    done

    log_info "Mirror complete: $succeeded succeeded, $failed failed"
    return $failed
}

# Main function
main() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        mirror)
            if [[ $# -eq 0 ]]; then
                log_error "No images specified"
                exit 1
            fi
            process_images_parallel "$@"
            ;;

        extract)
            if [[ $# -eq 0 ]]; then
                log_error "No chart path specified"
                exit 1
            fi
            extract_images_from_chart "$1"
            ;;

        extract-and-mirror)
            if [[ $# -eq 0 ]]; then
                log_error "No chart path specified"
                exit 1
            fi
            local images
            images=$(extract_images_from_chart "$1")
            if [[ -n "$images" ]]; then
                readarray -t image_array <<< "$images"
                process_images_parallel "${image_array[@]}"
            else
                log_warn "No images found in chart"
            fi
            ;;

        help|*)
            cat << EOF
Usage: $0 <action> [arguments]

Actions:
  mirror <image1> <image2> ...     Mirror specified Docker images
  extract <chart-path>              Extract images from Helm chart
  extract-and-mirror <chart-path>   Extract and mirror images from chart
  help                              Show this help message

Environment Variables:
  MIRROR_REGISTRY   Target registry (default: registry.internal.company.com)
  MIRROR_PREFIX     Registry prefix (default: dockerhub)
  DRY_RUN          Dry run mode (default: false)
  PARALLEL_JOBS    Number of parallel mirror jobs (default: 4)

Examples:
  # Mirror specific images
  $0 mirror nginx:latest redis:7.0

  # Extract images from a Helm chart
  $0 extract ./charts/my-app

  # Extract and mirror all images from a chart
  $0 extract-and-mirror ./charts/my-app

  # Dry run mode
  DRY_RUN=true $0 mirror nginx:latest
EOF
            ;;
    esac
}

# Check prerequisites
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    log_warn "Helm is not installed - chart extraction features will not work"
fi

# Run main function
main "$@"