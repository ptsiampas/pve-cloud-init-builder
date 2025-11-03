#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/conf/cloud-init-urls.conf}"
IMAGE_DIR="${IMAGE_DIR:-${SCRIPT_DIR}/images}"
CONFIG_DIR="${SCRIPT_DIR}/conf"
DISTRO_CONFIG_ROOT="${CONFIG_DIR}"
USERS_CONFIG_FILE="${CONFIG_DIR}/users-config.yaml"
SNIPPET_DIR="${SNIPPET_DIR:-/var/lib/vz/snippets}"

DRY_RUN=0
TEST_OUTPUT=0
TEST_OUTPUT_DIR="${SCRIPT_DIR}/test-output"
EXECUTE_QM_COMMANDS=1
EXECUTE_COMMANDS=1

declare -a DISTRO_LIST=()
declare -A DISTRO_CONFIG_FILES=()
declare -a QM_COMMANDS=()

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

load_distro_metadata() {
  local config_root="${DISTRO_CONFIG_ROOT}"
  local file base distro

  DISTRO_LIST=()
  DISTRO_CONFIG_FILES=()

  while IFS= read -r -d '' file; do
    if [[ "$file" == "$CONFIG_FILE" ]]; then
      continue
    fi

    base="$(basename "$file")"
    if [[ ! "$base" =~ ^[0-9].*\.conf$ ]]; then
      continue
    fi

    distro="$(
      set -euo pipefail
      source "$file"
      if [[ -n ${DISTRO:-} ]]; then
        printf '%s' "${DISTRO}"
      else
        base_no_ext="${base%.conf}"
        printf '%s' "${base_no_ext#*-}"
      fi
    )"

    if [[ -z "$distro" ]]; then
      echo "Failed to determine distro name from ${file}" >&2
      exit 1
    fi

    DISTRO_CONFIG_FILES["$distro"]="$file"
    DISTRO_LIST+=("$distro")
  done < <(find "${config_root}" -type f -name "*.conf" -print0)

  if ((${#DISTRO_LIST[@]} == 0)); then
    echo "No distro configuration files found under ${config_root}" >&2
    exit 1
  fi

  IFS=$'\n' DISTRO_LIST=($(printf '%s\n' "${DISTRO_LIST[@]}" | sort))
  unset IFS
}

load_distro_config() {
  local distro="$1"
  local -n out_ref="$2"
  local config_file="${DISTRO_CONFIG_FILES[${distro}]:-}"

  if [[ -z "${config_file}" ]]; then
    echo "No configuration file registered for distro ${distro}" >&2
    exit 1
  fi

  local -a keys=()
  mapfile -t keys < <(
    grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "${config_file}" \
      | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\1/' \
      | sort -u
  )

  out_ref=()

  local key value
  while IFS='=' read -r key value; do
    out_ref["$key"]="$value"
  done < <(
    set -euo pipefail
    source "${config_file}"
    for key in "${keys[@]}"; do
      value="${!key-}"
      printf '%s=%s\n' "$key" "$value"
    done
  )
}

build_cpu_args() {
  local -n config_ref="$1"
  local -n cpu_args_ref="$2"
  local value

  cpu_args_ref=()

  value="${config_ref[CPU]:-}"
  if [[ -n "${value}" ]]; then
    cpu_args_ref+=("--cpu" "${value}")
  fi

  value="${config_ref[CPU_CORES]:-}"
  if [[ -n "${value}" ]]; then
    cpu_args_ref+=("--cores" "${value}")
  fi

  value="${config_ref[CPU_SOCKET]:-${config_ref[CPU_SOCKETS]:-}}"
  if [[ -n "${value}" ]]; then
    cpu_args_ref+=("--socket" "${value}")
  fi

  value="${config_ref[CPU_NUMA]:-${config_ref[CPU_NUM]:-}}"
  if [[ -n "${value}" ]]; then
    cpu_args_ref+=("--numa" "${value}")
  fi
}

build_net_args() {
  local -n config_ref="$1"
  local -n net_args_ref="$2"
  local bridge mtu net_arg

  bridge="${config_ref[BRIDGE]:-}"
  mtu="${config_ref[MTU]:-}"

  net_arg="virtio"
  if [[ -n "${bridge}" ]]; then
    net_arg+=",bridge=${bridge}"
  fi
  if [[ -n "${mtu}" ]]; then
    net_arg+=",mtu=${mtu}"
  fi

  net_args_ref=(--net0 "${net_arg}")
}

collect_runcmd_entries() {
  local file="$1"
  local -n dest_ref="$2"
  local line in_section=0

  [[ -f "${file}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    if (( in_section == 0 )); then
      if [[ "${line}" =~ ^[[:space:]]*runcmd:[[:space:]]*$ ]]; then
        in_section=1
      fi
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]*-[[:space:]](.*)$ ]]; then
      dest_ref+=("${BASH_REMATCH[1]}")
      continue
    fi

    if [[ -z "${line// }" ]]; then
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ ! "${line}" =~ ^[[:space:]] ]]; then
      break
    fi
  done < "${file}"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") --distro <name> [options]

Options:
  --distro <name>   Build the template for the named distro.
  --list            List available distros.
  --dry-run         Print qm commands without executing them.
  --test-output, -to
                    Generate outputs under test-output and skip qm execution.
  --help            Show this help message.

Environment:
  CONFIG_FILE       Override default URL config file location (${CONFIG_FILE}).
EOF
}

list_distros() {
  if ((${#DISTRO_LIST[@]} == 0)); then
    load_distro_metadata
  fi
  printf "%s\n" "${DISTRO_LIST[@]}"
}

validate_distro() {
  local distro="$1"
  if [[ -z "${DISTRO_CONFIG_FILES[${distro}]:-}" ]]; then
    echo "Unknown distro: ${distro}" >&2
    echo "Use --list to see supported distros." >&2
    exit 1
  fi
}

lookup_url() {
  local key="$1"
  local value="${!key:-}"
  if [[ -z "${value}" ]]; then
    echo "Missing URL configuration for ${key} in ${CONFIG_FILE}" >&2
    exit 1
  fi
  printf "%s" "${value}"
}

write_snippet() {
  local snippet_path="$1"
  local base_snippet="$2"
  local reference_comment="$3"
  shift 3
  local -a fragment_files=("$@")
  local -a runcmd_commands=()
  local fragment

  if (( DRY_RUN && ! TEST_OUTPUT )); then
    echo "Dry run mode: skipping snippet generation for ${snippet_path}"
    return 0
  fi

  if [[ -n "${base_snippet}" && "${base_snippet}" != /* ]]; then
    base_snippet="${CONFIG_DIR}/${base_snippet}"
  fi

  if [[ -n "${base_snippet}" ]]; then
    if [[ ! -f "${base_snippet}" ]]; then
      echo "Base cloud-init snippet not found: ${base_snippet}" >&2
      exit 1
    fi
    collect_runcmd_entries "${base_snippet}" runcmd_commands
  fi

  for fragment in "${fragment_files[@]}"; do
    if [[ -f "${fragment}" ]]; then
      collect_runcmd_entries "${fragment}" runcmd_commands
    fi
  done

  mkdir -p "$(dirname "${snippet_path}")"

  {
    echo "#cloud-config"
    if [[ -f "${USERS_CONFIG_FILE}" ]]; then
      cat "${USERS_CONFIG_FILE}"
    else
      echo "users: []"
    fi

    echo

    if (( ${#runcmd_commands[@]} > 0 )); then
      echo "runcmd:"
      for fragment in "${runcmd_commands[@]}"; do
        printf "    - %s\n" "${fragment}"
      done
    fi

    if [[ "${reference_comment}" == "true" && -n "${FORUM_REFERENCE_URL:-}" ]]; then
      echo "# Taken from ${FORUM_REFERENCE_URL}"
    fi
  } | tee "${snippet_path}" > /dev/null
}

format_qm_command() {
  local -a command_parts=("qm" "$@")
  local formatted=""
  printf -v formatted '%q ' "${command_parts[@]}"
  formatted="${formatted% }"
  printf '%s' "${formatted}"
}

format_command() {
  local formatted=""
  printf -v formatted '%q ' "$@"
  formatted="${formatted% }"
  printf '%s' "${formatted}"
}

run_command() {
  local formatted
  formatted="$(format_command "$@")"
  echo "+ ${formatted}"
  if (( EXECUTE_COMMANDS )); then
    "$@"
  fi
}

record_qm_command() {
  local formatted
  formatted="$(format_qm_command "$@")"
  echo "+ ${formatted}"
  QM_COMMANDS+=("${formatted}")
}

run_qm() {
  local cmd="$1"
  shift
  record_qm_command "${cmd}" "$@"
  if (( EXECUTE_QM_COMMANDS )); then
    qm "${cmd}" "$@"
  else
    return 0
  fi
}

destroy_vm_if_exists() {
  local vmid="$1"
  record_qm_command status "${vmid}"
  if (( EXECUTE_QM_COMMANDS )); then
    if qm status "${vmid}" &> /dev/null; then
      run_qm destroy "${vmid}"
    fi
  else
    run_qm destroy "${vmid}"
  fi
}

main() {
  local distro=""

  load_distro_metadata

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --distro|-d)
        distro="$2"
        shift 2
        ;;
      --list|-l)
        list_distros
        exit 0
        ;;
      --dry-run)
        DRY_RUN=1
        EXECUTE_QM_COMMANDS=0
        EXECUTE_COMMANDS=0
        shift
        ;;
      --test-output|-to)
        TEST_OUTPUT=1
        DRY_RUN=1
        EXECUTE_QM_COMMANDS=0
        EXECUTE_COMMANDS=0
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if (( DRY_RUN )); then
    echo "Dry run mode: qm commands will not be executed."
  fi
  if (( TEST_OUTPUT )); then
    echo "Test output mode: outputs will be written to ${TEST_OUTPUT_DIR}"
    if [[ -d "${TEST_OUTPUT_DIR}" ]]; then
      find "${TEST_OUTPUT_DIR}" -mindepth 1 -delete
    fi
    mkdir -p "${TEST_OUTPUT_DIR}"
  fi

  if [[ -z "${distro}" ]]; then
    usage
    exit 1
  fi

  validate_distro "${distro}"

  declare -A distro_cfg=()
  load_distro_config "${distro}" distro_cfg

  local config_file="${DISTRO_CONFIG_FILES[${distro}]}"
  local config_dir
  config_dir="$(dirname "${config_file}")"
  local prefix
  prefix="$(basename "${config_file}" .conf)"

  if [[ -n "${distro_cfg[DISTRO]:-}" && "${distro_cfg[DISTRO]}" != "${distro}" ]]; then
    echo "Configured distro name mismatch for ${distro}: ${distro_cfg[DISTRO]} in ${config_file}" >&2
    exit 1
  fi

  local vmid="${distro_cfg[VMID]:-}"
  local storage="${distro_cfg[STORAGE]:-}"
  local image_name="${distro_cfg[LOCAL_IMAGE_FILE_NAME]:-}"
  local resize_size="${distro_cfg[IMAGE_RESIZE]:-}"
  local template_name="${distro_cfg[TEMPLATE_NAME]:-}"
  local snippet_file="${distro_cfg[SNIPPET_FILE]:-}"
  local base_snippet="${distro_cfg[BASE_SNIPPET_FILE]:-}"
  local reference_comment="${distro_cfg[REFERENCE_URL_COMMENT]:-false}"
  local image_url="${distro_cfg[IMAGE_URL]:-}"
  local image_url_key="${distro_cfg[IMAGE_URL_KEY]:-}"
  local tags="${distro_cfg[TAGS]:-}"

  if [[ -z "${vmid}" || -z "${storage}" || -z "${image_name}" || -z "${resize_size}" || -z "${template_name}" || -z "${snippet_file}" ]]; then
    echo "Incomplete configuration for ${distro}. Check ${config_file}" >&2
    exit 1
  fi

  if [[ -z "${image_url}" && -n "${image_url_key}" ]]; then
    image_url="$(lookup_url "${image_url_key}")"
  fi

  if [[ -z "${image_url}" ]]; then
    echo "Missing IMAGE_URL (or IMAGE_URL_KEY) for ${distro} in ${config_file}" >&2
    exit 1
  fi

  local image_file="${IMAGE_DIR}/${image_name}"
  local snippet_output_dir="${SNIPPET_DIR}"
  if (( TEST_OUTPUT )); then
    snippet_output_dir="${TEST_OUTPUT_DIR}"
  fi
  local snippet_path="${snippet_output_dir}/${snippet_file}"

  local -a snippet_fragments=()
  local yaml_file nullglob_was_set=0
  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob
  for yaml_file in "${config_dir}/${prefix}"*.yaml; do
    snippet_fragments+=("${yaml_file}")
  done
  if (( nullglob_was_set == 0 )); then
    shopt -u nullglob
  fi

  destroy_vm_if_exists "${vmid}"

  run_command mkdir -p "${IMAGE_DIR}"
  run_command rm -f "${image_file}"
  run_command wget -q "${image_url}" -O "${image_file}"
  run_command qemu-img resize "${image_file}" "${resize_size}"

  local -a cpu_args=()
  build_cpu_args distro_cfg cpu_args

  local -a net_args=()
  build_net_args distro_cfg net_args

  local -a create_args=(
    "${vmid}"
    --name "${template_name}"
    --ostype l26
    --memory 1024
    --balloon 0
    --agent 1
    --bios ovmf
    --machine q35
    --efidisk0 "${storage}:0,pre-enrolled-keys=0"
    --vga serial0
    --serial0 socket
  )

  if ((${#cpu_args[@]} > 0)); then
    create_args+=("${cpu_args[@]}")
  fi
  if ((${#net_args[@]} > 0)); then
    create_args+=("${net_args[@]}")
  fi

  run_qm create "${create_args[@]}"

  run_qm importdisk "${vmid}" "${image_file}" "${storage}"
  run_qm set "${vmid}" --scsihw virtio-scsi-pci --virtio0 "${storage}:vm-${vmid}-disk-1,discard=on"
  run_qm set "${vmid}" --boot order=virtio0
  run_qm set "${vmid}" --scsi1 "${storage}:cloudinit"

  write_snippet "${snippet_path}" "${base_snippet}" "${reference_comment}" "${snippet_fragments[@]}"

  run_qm set "${vmid}" --cicustom "user=local:snippets/${snippet_file}"
  if [[ -n "${tags}" ]]; then
    run_qm set "${vmid}" --tags "${tags}"
  fi
  ## No longer needed because the cicustom has been updated to add the users.
  ## It also means that I can't adjust the users later.
  #run_qm set "${vmid}" --ciuser "${USER}"
  #run_qm set "${vmid}" --sshkeys "${HOME}/.ssh/authorized_keys"
  run_qm set "${vmid}" --ipconfig0 ip=dhcp
  run_qm template "${vmid}"

  if (( TEST_OUTPUT )); then
    mkdir -p "${TEST_OUTPUT_DIR}"
    local commands_file="${TEST_OUTPUT_DIR}/proxmox-commands.txt"
    if ((${#QM_COMMANDS[@]} > 0)); then
      printf "%s\n" "${QM_COMMANDS[@]}" > "${commands_file}"
    else
      : > "${commands_file}"
    fi
    echo "Proxmox command list written to ${commands_file}"
    echo "Cloud-init snippet written to ${snippet_path}"
  fi
}

main "$@"
