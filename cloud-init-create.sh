#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/conf/cloud-init-urls.conf}"
IMAGE_DIR="${IMAGE_DIR:-${SCRIPT_DIR}/images}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

DISTRO_LIST=(
  "debian-12"
  "debian-12-docker"
  "debian-13"
  "ubuntu-noble"
  "ubuntu-noble-nvidia-runtime"
)

declare -A VMID_MAP=(
  ["debian-12"]="8000"
  ["debian-12-docker"]="8001"
  ["debian-13"]="8002"
  ["ubuntu-noble"]="8200"
  ["ubuntu-noble-nvidia-runtime"]="8201"
)

declare -A STORAGE_MAP=(
  ["debian-12"]="local-zfs"
  ["debian-12-docker"]="local-zfs"
  ["debian-13"]="local-zfs"
  ["ubuntu-noble"]="local-zfs"
  ["ubuntu-noble-nvidia-runtime"]="local-zfs"
)

declare -A IMAGE_FILE_MAP=(
  ["debian-12"]="debian-12-generic-amd64.qcow2"
  ["debian-12-docker"]="debian-12-generic-amd64+docker.qcow2"
  ["debian-13"]="debian-13-generic-amd64.qcow2"
  ["ubuntu-noble"]="noble-server-cloudimg-amd64.img"
  ["ubuntu-noble-nvidia-runtime"]="noble-server-cloudimg-amd64+nvidia.img"
)

declare -A IMAGE_URL_KEY_MAP=(
  ["debian-12"]="DEBIAN_12_IMAGE_URL"
  ["debian-12-docker"]="DEBIAN_12_IMAGE_URL"
  ["debian-13"]="DEBIAN_13_IMAGE_URL"
  ["ubuntu-noble"]="UBUNTU_NOBLE_IMAGE_URL"
  ["ubuntu-noble-nvidia-runtime"]="UBUNTU_NOBLE_IMAGE_URL"
)

declare -A IMAGE_RESIZE_MAP=(
  ["debian-12"]="8G"
  ["debian-12-docker"]="8G"
  ["debian-13"]="8G"
  ["ubuntu-noble"]="8G"
  ["ubuntu-noble-nvidia-runtime"]="8G"
)

declare -A TEMPLATE_NAME_MAP=(
  ["debian-12"]="debian-12-template"
  ["debian-12-docker"]="debian-12-template-docker"
  ["debian-13"]="debian-13-template"
  ["ubuntu-noble"]="ubuntu-noble-template"
  ["ubuntu-noble-nvidia-runtime"]="ubuntu-noble-template-nvidia-runtime"
)

declare -A CPU_ARGS_MAP=(
  ["debian-12"]="--cpu x86-64-v2-AES --cores 1 --numa 1"
  ["debian-12-docker"]="--cpu x86-64-v2-AES --cores 1 --numa 1"
  ["debian-13"]="--cpu x86-64-v2-AES --cores 1 --numa 1"
  ["ubuntu-noble"]="--cpu host --socket 1 --cores 1"
  ["ubuntu-noble-nvidia-runtime"]="--cpu host --socket 1 --cores 1"
)

declare -A NET_ARGS_MAP=(
  ["debian-12"]="--net0 virtio,bridge=vmbr0,mtu=1"
  ["debian-12-docker"]="--net0 virtio,bridge=vmbr0,mtu=1"
  ["debian-13"]="--net0 virtio,bridge=vmbr0,mtu=1"
  ["ubuntu-noble"]="--net0 virtio,bridge=vmbr0"
  ["ubuntu-noble-nvidia-runtime"]="--net0 virtio,bridge=vmbr0"
)

declare -A TAGS_MAP=(
  ["debian-12"]="debian-template,debian-12,cloudinit"
  ["debian-12-docker"]="debian-template,debian-12,cloudinit,docker"
  ["debian-13"]="debian-template,debian-13,cloudinit"
  ["ubuntu-noble"]="ubuntu-template,noble,cloudinit"
  ["ubuntu-noble-nvidia-runtime"]="ubuntu-template,noble,cloudinit,nvidia"
)

declare -A SNIPPET_FILE_MAP=(
  ["debian-12"]="debian-12.yaml"
  ["debian-12-docker"]="debian-12-docker.yaml"
  ["debian-13"]="debian-13.yaml"
  ["ubuntu-noble"]="ubuntu.yaml"
  ["ubuntu-noble-nvidia-runtime"]="ubuntu-noble-runtime.yaml"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") --distro <name> [options]

Options:
  --distro <name>   Build the template for the named distro.
  --list            List available distros.
  --help            Show this help message.

Environment:
  CONFIG_FILE       Override default URL config file location (${CONFIG_FILE}).
EOF
}

list_distros() {
  printf "%s\n" "${DISTRO_LIST[@]}"
}

validate_distro() {
  local distro="$1"
  for known in "${DISTRO_LIST[@]}"; do
    if [[ "${known}" == "${distro}" ]]; then
      return 0
    fi
  done
  echo "Unknown distro: ${distro}" >&2
  echo "Use --list to see supported distros." >&2
  exit 1
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
  local distro="$1"
  local snippet_path="$2"
  local ansible_user=$(cat <<EOF
users:
  - name: petert
    gecos: Peter T
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: users, sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHx3MgtqPEUlJPM6BQ0pJGjRSR8cRJWUuHHHqeiQLZ3J peter@tsiampas.com
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC9DsHgjgAlMQnWrKskPWxbQTY3JBFMGiLN+wKtFaNWFYi4iMkt1Ae8NLnNQw3VZi9BhaeRpgTXRYoN1RgJ6TcSUl+mFMwItQ7OWAG0v4CT3GxluyQjDLvOtT6U3noDKxa2WLFN8vczd7AERqAd7ZmgS+2PBllKeeiJWbk1p3zsodnFtzBJ7qKSJ5Quo7peLbGYqNwKhlT8qOMLMYj4FZPdUORiWps+uSDv610HPdzzur3TAkYLTrWYPSKQInfRg37mP41BYbJY7CZ/zuMZT+5XhkG2CRbSO8+Lg2Fsn1tVljcdrZBCetgDooLkeBeKNHStm0urV6QSEIIsz96pcTdaMpoanMrV1U4pioGlx8Rno8BOSsm+eoIH4mXHA0FPTyoIn6HtZA3MYtH/0O5M7PZ4SFXZTel8I5uD/HdXwqSY7i34POfjbhBeAgD6IKOreLFH0YSE5Pud8LWlssWgpFn2IvoZosuujqDCVZDi7JkHcw5BikH/BaTgAKr8oOWvsD/+FshRfNFF5x5Y/AzICj+vDUo1kbPDas8ab76zUDIag2sFdgIxOGwLB9J0taJQFGtyh7YznDqsoAd3CZIP7sZO8eb0x8y8EzDBqhkN7Rh8WEdjhKsmdesQQXXaRdpQGvJ1jrCEqqb7n923mRi5pA2/u1hnZQNAav70hgCkWWjeqw== petert@ai-desktop.lan
    passwd: $6$tm6zU8NQt6.l0m4K$GqWVjqISalcim.QAOt7c64BrBV.D/QfbsVtBnNG3ugZgoumKkrQ2UqNEQpUhhmg5oixkCDhJkg0mUYUCx9O8p/
    lock_passwd: false
  - name: ansible
    gecos: ansible user
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: users, sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFeLJ/XtaXbHknGw+76kvJ9TLtGSiNOmNbmE4iRLMTl3 awx-remote

EOF
)

  mkdir -p "$(dirname "${snippet_path}")"

  case "${distro}" in
    "debian-12"|"debian-13")
      cat <<EOF | tee "${snippet_path}" > /dev/null
#cloud-config
${ansible_user}
runcmd:
    - apt-get update
    - apt-get install -y qemu-guest-agent
    - reboot
# Taken from ${FORUM_REFERENCE_URL}
EOF
      ;;
    "debian-12-docker")
      cat <<EOF | tee "${snippet_path}" > /dev/null
#cloud-config
${ansible_user}
runcmd:
    - apt-get update
    - apt-get install -y qemu-guest-agent gnupg
    - install -m 0755 -d /etc/apt/keyrings
    - curl -fsSL ${DOCKER_GPG_KEY_URL} | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    - chmod a+r /etc/apt/keyrings/docker.gpg
    - echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_APT_REPO_URL} \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    - apt-get update
    - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    - reboot
# Taken from ${FORUM_REFERENCE_URL}
EOF
      ;;
    "ubuntu-noble")
      cat <<EOF | tee "${snippet_path}" > /dev/null
#cloud-config
${ansible_user}
runcmd:
    - apt-get update
    - apt-get install -y qemu-guest-agent
    - systemctl enable ssh
    - reboot

EOF
      ;;
    "ubuntu-noble-nvidia-runtime")
      cat <<EOF | tee "${snippet_path}" > /dev/null
#cloud-config
${ansible_user}
runcmd:
    - curl -fsSL ${NVIDIA_GPG_KEY_URL} | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    - curl -s -L ${NVIDIA_TOOLKIT_LIST_URL} | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    - apt-get update
    - apt-get install -y qemu-guest-agent nvidia-dkms-550-server nvidia-utils-550-server nvidia-container-runtime
    - systemctl enable ssh
    - reboot
# Taken from ${FORUM_REFERENCE_URL}
EOF
      ;;
    *)
      echo "No snippet template defined for ${distro}" >&2
      exit 1
      ;;
  esac
}

run_qm() {
  local cmd="$1"
  shift
  echo "+ qm ${cmd} $*"
  qm "${cmd}" "$@"
}

destroy_vm_if_exists() {
  local vmid="$1"
  if qm status "${vmid}" &> /dev/null; then
    run_qm destroy "${vmid}"
  fi
}

main() {
  local distro=""

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

  if [[ -z "${distro}" ]]; then
    usage
    exit 1
  fi

  validate_distro "${distro}"

  local vmid="${VMID_MAP[${distro}]}"
  local storage="${STORAGE_MAP[${distro}]}"
  local image_file="${IMAGE_DIR}/${IMAGE_FILE_MAP[${distro}]}"
  local image_url_key="${IMAGE_URL_KEY_MAP[${distro}]}"
  local image_url
  image_url="$(lookup_url "${image_url_key}")"
  local resize_size="${IMAGE_RESIZE_MAP[${distro}]}"
  local template_name="${TEMPLATE_NAME_MAP[${distro}]}"
  local snippet_file="${SNIPPET_FILE_MAP[${distro}]}"
  local snippet_path="/var/lib/vz/snippets/${snippet_file}"

  local cpu_args_string="${CPU_ARGS_MAP[${distro}]}"
  local net_args_string="${NET_ARGS_MAP[${distro}]}"

  destroy_vm_if_exists "${vmid}"

  rm -f "${image_file}"
  echo "+ wget ${image_url} -O ${image_file}"
  wget -q "${image_url}" -O "${image_file}"
  echo "+ qemu-img resize ${image_file} ${resize_size}"
  qemu-img resize "${image_file}" "${resize_size}"

  local -a cpu_args=()
  local -a net_args=()
  local -a create_args=()

  read -r -a cpu_args <<< "${cpu_args_string}"
  read -r -a net_args <<< "${net_args_string}"

  create_args=(
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

  create_args+=("${cpu_args[@]}")
  create_args+=("${net_args[@]}")

  run_qm create "${create_args[@]}"

  run_qm importdisk "${vmid}" "${image_file}" "${storage}"
  run_qm set "${vmid}" --scsihw virtio-scsi-pci --virtio0 "${storage}:vm-${vmid}-disk-1,discard=on"
  run_qm set "${vmid}" --boot order=virtio0
  run_qm set "${vmid}" --scsi1 "${storage}:cloudinit"

  write_snippet "${distro}" "${snippet_path}"

  run_qm set "${vmid}" --cicustom "user=local:snippets/${snippet_file}"
  run_qm set "${vmid}" --tags "${TAGS_MAP[${distro}]}"
  ## No longer needed because the cicustom has been updated to add the users.
  ## It also means that I can't adjust the users later.
  #run_qm set "${vmid}" --ciuser "${USER}"
  #run_qm set "${vmid}" --sshkeys "${HOME}/.ssh/authorized_keys"
  run_qm set "${vmid}" --ipconfig0 ip=dhcp
  run_qm template "${vmid}"
}

main "$@"
