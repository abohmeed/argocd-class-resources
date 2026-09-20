#!/bin/bash
# Builds the Argo CD course verification host on pve. Single k3s node.
set -e
IMG=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img
GW=192.168.126.1
N=130
pvesm set local --content iso,vztmpl,backup,import,snippets
if qm status $N >/dev/null 2>&1; then qm stop $N --timeout 30 || true; qm destroy $N --purge --destroy-unreferenced-disks 1; fi
qm create $N --name acd-lab --memory 16384 --cores 8 --cpu host --ostype l26 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --serial0 socket --vga serial0 --agent enabled=1
qm importdisk $N $IMG local-lvm >/dev/null
qm set $N --scsi0 local-lvm:vm-$N-disk-0,discard=on --boot order=scsi0 --ide2 local-lvm:cloudinit
qm disk resize $N scsi0 80G
qm set $N --ciuser ubuntu --ipconfig0 ip=192.168.126.245/24,gw=$GW \
  --nameserver 8.8.8.8 --searchdomain lab.local --cicustom user=local:snippets/acd-lab-user-data
qm start $N
qm list | grep acd-lab
