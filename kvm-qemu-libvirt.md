# KVM/QEMU/Libvirt Setup Guide

A walkthrough for setting up KVM virtualization with a **Manjaro Linux client** managing VMs on a **remote Ubuntu server** using virt-manager over SSH. This covers server installation, bridge networking, permissions, client configuration, and VM creation workflows.

## Prerequisites

### Verify Hardware Virtualization Support

Before installing anything, confirm your CPU supports hardware virtualization:

```bash
# Check for Intel VT-x or AMD-V
lscpu | grep -i virtualization

# Alternative: look for vmx (Intel) or svm (AMD) flags
grep -E 'vmx|svm' /proc/cpuinfo | head
```

You should see `VT-x` (Intel) or `AMD-V` (AMD) in the output. If not, enable virtualization in your BIOS/UEFI settings.

### Disable Sleep/Suspend (Server)

For a dedicated virtualization server, disable sleep states so VMs aren't interrupted:

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

## Server Setup (Ubuntu)

### Install Packages

Install the full KVM/QEMU/libvirt stack along with supporting tools:

```bash
sudo apt install \
  qemu-system-x86 \
  libvirt-daemon-system \
  virtinst \
  virt-manager \
  virt-viewer \
  ovmf \
  swtpm \
  qemu-utils \
  guestfs-tools \
  libguestfs-tools \
  libosinfo-bin \
  tuned
```

| Package | Purpose |
|---------|---------|
| `qemu-system-x86` | The core hypervisor/emulator |
| `libvirt-daemon-system` | Libvirt daemon and management API |
| `virtinst` | CLI tools (`virt-install`, `virt-clone`) |
| `virt-manager` | GUI for VM management |
| `ovmf` | UEFI firmware for VMs |
| `swtpm` | Software TPM emulator |
| `qemu-utils` | Disk image utilities (`qemu-img`) |
| `guestfs-tools` / `libguestfs-tools` | Modify guest images offline (`virt-customize`) |
| `tuned` | System performance tuning profiles |

### Enable Services and Validate

```bash
sudo systemctl enable libvirtd.service
sudo systemctl enable --now tuned
```

Verify the host is properly configured for KVM:

```bash
sudo virt-host-validate qemu
```

All checks should show `PASS`. If any show `WARN` or `FAIL`, address those before proceeding.

Optionally set a tuned profile optimized for virtualization:

```bash
tuned-adm list
tuned-adm active
```

## Bridge Networking

VMs need a network bridge to appear as peers on your LAN. This uses NetworkManager's `nmcli` to create a bridge on the server.

### Install NetworkManager (if not present)

```bash
sudo apt install network-manager
sudo nmcli device status
```

### Create the Bridge

```bash
# Create the bridge interface
sudo nmcli connection add type bridge con-name bridge0 ifname bridge0

# Enslave the physical NIC (eno1) to the bridge
sudo nmcli connection add type ethernet slave-type bridge \
  con-name 'Bridge connection 1' ifname eno1 master bridge0
```

### Configure Static IP

Adjust the addresses, gateway, and DNS to match your network:

```bash
sudo nmcli connection modify bridge0 ipv4.addresses '172.16.1.37/24'
sudo nmcli connection modify bridge0 ipv4.gateway '172.16.1.1'
sudo nmcli connection modify bridge0 ipv4.dns '172.16.1.11,172.16.1.12'
sudo nmcli connection modify bridge0 ipv4.dns-search 'int.psw.io'
sudo nmcli connection modify bridge0 ipv4.method manual
```

### Bring Up the Bridge

```bash
sudo nmcli connection up bridge0
sudo nmcli connection modify bridge0 connection.autoconnect-slaves 1
sudo nmcli connection up bridge0
sudo nmcli device status
```

> **Note:** If your server uses Netplan, you may need to disable the Netplan config for the bridged interface so NetworkManager takes full control. Edit `/etc/netplan/00-installer-config.yaml` and run `sudo netplan apply` as needed.

### Define the Bridge in Libvirt

Create a file called `nwbridge.xml`:

```xml
<network>
  <name>nwbridge</name>
  <forward mode="bridge"/>
  <bridge name="bridge0"/>
</network>
```

Register it with libvirt:

```bash
sudo virsh net-define nwbridge.xml
sudo virsh net-start nwbridge
sudo virsh net-autostart nwbridge
sudo virsh net-list --all
```

## Permissions

### Add Your User to the libvirt Group

```bash
sudo usermod -aG libvirt $USER
```

Log out and back in for the group change to take effect, then verify:

```bash
virsh uri
# Should output: qemu:///system
```

### Set ACLs on the Images Directory

Grant your user read/write access to the libvirt images directory so you can manage disk images without `sudo`:

```bash
# Clear any existing ACLs
sudo setfacl -R -b /var/lib/libvirt/images

# Grant your user access (recursive + default for new files)
sudo setfacl -R -m u:$USER:rwX /var/lib/libvirt/images
sudo setfacl -m d:u:$USER:rwx /var/lib/libvirt/images

# Verify
getfacl /var/lib/libvirt/images
```

## Client Setup (Manjaro)

### Install SSH Askpass

virt-manager needs an SSH askpass helper to prompt for passphrases when connecting to the remote host:

```bash
pamac install openssh-askpass x11-ssh-askpass
```

### SSH Key Setup

Copy your SSH key to the server:

```bash
ssh-copy-id -i ~/.ssh/mykey ec
```

Add the host to your `~/.ssh/config` for convenience:

```
Host ec
  HostName 172.16.1.37
  User paulda
  IdentityFile ~/.ssh/mykey
```

### Connect with virt-manager

Launch virt-manager pointed at the remote server:

```bash
virt-manager -c 'qemu+ssh://username@hostname/system?keyfile=mykey'
```

You can also add this as a persistent connection in virt-manager's GUI via **File > Add Connection**.

## Creating VMs

### CLI: Cloud Image with virt-install

This workflow downloads an Ubuntu cloud image, customizes it with cloud-init, and launches a VM — all from the command line.

**1. Download and prepare the cloud image:**

```bash
cd /var/lib/libvirt/images/templates/
sudo wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
sudo mv noble-server-cloudimg-amd64.img ubuntu-24.04-server-cloudimg-amd64.qcow2
```

**2. Create a VM directory and copy/resize the base image:**

```bash
sudo mkdir -p /var/lib/libvirt/images/ec1/
sudo cp /var/lib/libvirt/images/templates/ubuntu-24.04-server-cloudimg-amd64.qcow2 \
  /var/lib/libvirt/images/ec1/root-disk.qcow2
sudo qemu-img resize /var/lib/libvirt/images/ec1/root-disk.qcow2 100G
```

**3. Create a cloud-init config** (`/var/lib/libvirt/images/ec1/cloud-init.cfg`):

Create your cloud-init user-data file with hostname, user accounts, SSH keys, and packages. Validate it with:

```bash
cloud-init schema --config-file /var/lib/libvirt/images/ec1/cloud-init.cfg --annotate
```

**4. Generate the cloud-init ISO:**

```bash
sudo cloud-localds \
  /var/lib/libvirt/images/ec1/cloud-init.iso \
  /var/lib/libvirt/images/ec1/cloud-init.cfg
```

**5. Launch the VM:**

```bash
sudo virt-install \
  --name ec1 \
  --memory 16384 \
  --vcpus 4 \
  --disk /var/lib/libvirt/images/ec1/root-disk.qcow2,device=disk,bus=virtio,format=qcow2 \
  --disk /var/lib/libvirt/images/ec1/cloud-init.iso,device=cdrom \
  --os-variant ubuntu24.04 \
  --virt-type kvm \
  --network network=host-bridge,model=virtio \
  --graphics spice \
  --import \
  --noautoconsole
```

Key flags:
- `--import` skips the OS installer and boots directly from the disk image
- `--noautoconsole` returns control to the terminal instead of opening a console
- `--network network=host-bridge` connects the VM to the bridge network defined earlier

### Importing Pre-built Images (Kali Example)

Some distros provide pre-built QEMU images. Here's the workflow for Kali Linux:

**1. Download and extract:**

```bash
cd ~
wget https://cdimage.kali.org/kali-2024.2/kali-linux-2024.2-qemu-amd64.7z
sudo apt install p7zip-full
7za x kali-linux-2024.2-qemu-amd64.7z
```

**2. Move the image into place:**

```bash
cp kali-linux-2024.2-qemu-amd64.qcow2 /var/lib/libvirt/images/kali.qcow2
```

**3. Customize the image** (set root password, remove cloud-init):

```bash
sudo virt-customize -a /var/lib/libvirt/images/kali.qcow2 \
  --root-password password:YourPasswordHere \
  --uninstall cloud-init
```

Then import it with `virt-install --import` or through virt-manager's GUI.

## VM Management

### Snapshots

Create snapshots before major changes to enable easy rollback:

```bash
# Create a snapshot
sudo virsh snapshot-create-as ec1 initialosinstall "before software installs" --atomic

# List snapshots
sudo virsh snapshot-list ec1
```

### Adding Storage to a Running VM

**On the host** — create and attach a new disk:

```bash
qemu-img create -f qcow2 -o preallocation=full ec-opt2.qcow2 50G
virsh attach-disk hulk /var/lib/libvirt/images/ec-opt2.qcow2 vdb --cache none --persistent
```

**On the guest** — partition and format:

```bash
sudo fdisk /dev/vdb
sudo mkfs.ext4 /dev/vdb1
```

Add it to `/etc/fstab` for persistent mounting:

```
/dev/vdb1  /opt  ext4  defaults  0  2
```

> **Tip:** You can also share host directories with guests using virtiofs. Add a filesystem entry in the VM's XML config, then mount it in the guest's fstab:
> ```
> host_home  /home/paulda/host-home  virtiofs  defaults  0  0
> ```

### Essential virsh Commands

```bash
virsh list --all              # List all VMs (running and stopped)
virsh start <vm>              # Start a VM
virsh shutdown <vm>           # Graceful shutdown
virsh destroy <vm>            # Force stop (like pulling the power)
virsh undefine <vm>           # Remove VM definition
virsh console <vm>            # Attach to serial console
virsh dominfo <vm>            # Show VM details
virsh net-list --all          # List all virtual networks
virsh snapshot-list <vm>      # List snapshots
virsh snapshot-revert <vm> <snap>  # Revert to a snapshot
```

## Resources

- [Install KVM on Linux](https://sysguides.com/install-kvm-on-linux) — comprehensive starting guide
- [Create VMs in KVM with virt-manager](https://sysguides.com/create-virtual-machines-in-kvm-virt-manager)
- [KVM Guest OS from the Command Line](https://sysguides.com/kvm-guest-os-from-the-command-line)
- [virt-manager Remote Console via QEMU+SSH](https://fabianlee.org/2019/02/16/kvm-virt-manager-to-connect-to-a-remote-console-using-qemussh/)
- [Manjaro and virt-manager Remote Connect](https://www.reddit.com/r/ManjaroLinux/comments/bprycv/manjaro_and_virtmanager_remote_connect/)
- [Kali Linux QEMU Guest VM](https://www.kali.org/docs/virtualization/install-qemu-guest-vm/)
- [virt-customize Man Page](https://manpages.ubuntu.com/manpages/xenial/man1/virt-customize.1.html)
- [How to Extract 7z Files on Linux](https://gcore.com/learning/how-to-extract-7z-files-linux/)
- [nmcli Troubleshooting](https://askubuntu.com/questions/1190504/why-is-nmcli-not-configuring-device)
