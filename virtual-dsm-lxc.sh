#!/bin/bash

# Constants
CONFIG_DIR="/etc/pve/lxc"
TMP_DIR="/tmp"

# Function to display log messages
log() {
    echo -e "$1"
}

# Function to display error and exit
function display_error_and_exit() {
    log "Error: $1 Exiting."
    exit 1
}

# Function to display information
function display_info {
    clear
    log "This script is used to configure prerequisites to run Synology Virtual DSM"
    log "in a Docker container inside an unprivileged Proxmox LXC container."
    log "Please run this script on the Proxmox host, not inside the LXC container.\n"
}

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    display_error_and_exit "Please run this script as root."
fi

display_info

read -p "Do you want to continue? (y/n): " choice

if [[ $choice == "y" || $choice == "Y" ]]; then
    read -p "Enter the LXC Container ID (CT ID): " ct_id

    # Check if ct_id is a non-empty numeric value
    if [[ ! $ct_id =~ ^[0-9]+$ ]]; then
        display_error_and_exit "Invalid LXC Container ID. Please enter a numeric value."
    fi

    # Check if the configuration file exists
    config_file="$CONFIG_DIR/$ct_id.conf"
    if [[ ! -f "$config_file" ]]; then
        display_error_and_exit "Configuration file $config_file does not exist."
    fi

    # Check if the LXC container is running
    container_status=$(pct status $ct_id 2>&1)
    if [[ "$container_status" == *"running"* ]]; then
        log "Stopping running LXC container $ct_id..."
        pct stop $ct_id || display_error_and_exit "Failed to stop LXC container $ct_id."
    fi

    # Remove existing dev folder and tun, kvm, and vhost-net devices
    if [[ -d "/dev-$ct_id" ]]; then
        log "Removing existing /dev-$ct_id folder..."
        rm -r "/dev-$ct_id" || display_error_and_exit "Failed to remove existing /dev-$ct_id folder."
    fi

    # Function to configure devices
    function configure_device() {
        device=$1
        module=$2
        major=$3
        minor=$4

        log "Configuring $device..."
        mkdir -p "/dev-$ct_id/net" || display_error_and_exit "Failed to create /dev-$ct_id/net"
        mknod "/dev-$ct_id/$device" c $major $minor || display_error_and_exit "Failed to mknod /dev-$ct_id/$device"
        chown 100000:100000 "/dev-$ct_id/$device" || display_error_and_exit "Failed to chown /dev-$ct_id/$device"

        #log "Checking if /dev-$ct_id/$device exists..."
        if ! [[ -e "/dev-$ct_id/$device" ]]; then
            display_error_and_exit "/dev-$ct_id/$device should have been created but does not exist."
        fi
    }

    # Configure devices
    configure_device "net/tun" "tun" 10 200
    configure_device "kvm" "kvm" 10 232
    configure_device "vhost-net" "vhost-net" 10 238

    # Check and add configuration lines to /et/pve/lxc/<CT ID>.conf
    log "Checking and adding configuration to $config_file..."
    lines_to_add=(
        "lxc.mount.entry: /dev-$ct_id/net/tun dev/net/tun none bind,create=file 0 0"
        "lxc.mount.entry: /dev-$ct_id/kvm dev/kvm none bind,create=file 0 0"
        "lxc.mount.entry: /dev-$ct_id/vhost-net dev/vhost-net none bind,create=file 0 0"
    )

    # Error handling for config file changes
    for line in "${lines_to_add[@]}"; do
        if ! grep -qF "$line" "$config_file"; then
            echo "$line" >> "$config_file" || display_error_and_exit "Failed to add line '$line' to $config_file."
        fi
    done

    # Start LXC container if not running
    container_status=$(pct status $ct_id 2>&1)
    if [[ "$container_status" != *"running"* ]]; then
        log "Starting LXC container $ct_id..."
        pct start $ct_id || display_error_and_exit "Failed to start LXC container $ct_id."
    fi

    # Install git and docker, clone virtual-dsm repository, change code, and generate docker image inside the LXC container
    lxc-attach -n $ct_id -- /bin/bash -s <<'SCRIPT'
        set -e; # Exit immediately if a command exits with a non-zero status

        log() {
            echo -e "$1"
        }

        export DEBIAN_FRONTEND=noninteractive # Set noninteractive mode

        apt-get update > /dev/null 2>&1
        apt-get install -y git > /dev/null 2>&1

        # Install Docker prerequisites
        log "Installing Docker prerequisites..."
        apt-get install -y ca-certificates curl gnupg > /dev/null 2>&1
        install -m 0755 -d /etc/apt/keyrings > /dev/null 2>&1
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg > /dev/null 2>&1
        chmod a+r /etc/apt/keyrings/docker.gpg > /dev/null 2>&1

        # Add the Docker repository to Apt sources
        echo "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update > /dev/null 2>&1

        # Install Docker packages
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1

        # Git clone repository and change code to ignore mknod
        log "Cloning virtual-dsm repository..."
        rm -rf virtual-dsm > /dev/null 2>&1
        git clone https://github.com/vdsm/virtual-dsm.git > /dev/null 2>&1 && cd virtual-dsm

        log "Changing source code to bypass mknod errors..."

        # Comment out lines to replace within install.sh
        sed -i -e '/{ (cd "$TMP" && cpio -idm <"$TMP\/rd" 2>\/dev\/null); rc=$?; } || :/s/^/#/' src/install.sh
        sed -i -e '/(( rc != 0 )) && error "Failed to cpio $RDC, reason $rc" && exit 92/s/^/#/' src/install.sh
        sed -i -e '/tar xpfJ "$HDA.txz" --absolute-names -C "$MOUNT\/"$/ s/^/#/' src/install.sh

        # Add new code to bypass mknod errors within install.sh
        echo -e '\n  if (cd "$TMP" && errors=$(cpio -idm <"$TMP/rd" 2>&1 | grep -E "mknod|block" || true); [ $? -eq 0 ]); then\n    echo "Extraction successful. Continuing with the script."\n  else\n    echo "Error: Unknown error during cpio extraction. Exiting."\n    echo "Details:"\n    echo "$errors"\n    exit 1\n  fi' | sed -i -e '/^#.*(( rc != 0 )) && error "Failed to cpio $RDC, reason $rc" && exit 92/{r /dev/stdin' -e '}' src/install.sh
        echo -e '\nif (errors=$(tar xpfJ "$HDA.txz" --absolute-names -C "$MOUNT/" 2>&1 | grep -E "mknod|block" || true); [ $? -eq 0 ]); then\n  echo "Extraction successful. Continuing with the script."\nelse\n  echo "Error: Unknown error during tar extraction. Exiting."\n  echo "Details:"\n  echo "$errors"\n  exit 1\nfi' | sed -i -e '/^#tar xpfJ "$HDA.txz" --absolute-names -C "$MOUNT\/"$/ r /dev/stdin' src/install.sh

        # Comment out lines to replace within network.sh
        sed -i -e '/^  if \[\[ ! -e "${TAP_PATH}" \]\]; then/,/^  fi$/ s/^/#/' src/network.sh

        # Add new code to bypass mknod errors within network.sh
        echo -e '\n  if [[ ! -e "${TAP_PATH}" ]]; then\n      if { mknod "${TAP_PATH}" c "${MAJOR}" "${MINOR}" ; rc=$?; } 2>&1 | grep -q "Cannot mknod"; then\n          echo "Error: Cannot mknod operation. Continuing with the script."\n      else\n          echo "Error: Unknown error during mknod. Exiting."\n          exit 20\n      fi\n  fi' | sed -i -e '/^#    (( rc != 0 )) && error "Cannot mknod: ${TAP_PATH} (\$rc)" && exit 20$/{:a; n; /#  fi$/!ba; r /dev/stdin' -e '}' src/network.sh

        # Generate docker image
        log "Building Docker image (this may take a while)..."
        docker build -t virtual-dsm . > /dev/null 2>&1
SCRIPT

    log "Configuration completed successfully.\n\nStart the docker image (virtual-dsm) inside the LXC container using docker run or docker compose."
else
    clear
    log "\nScript aborted. No changes were made."
fi
