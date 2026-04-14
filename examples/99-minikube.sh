#!/bin/bash -x
echo $@
IFACE=$(virsh -q -l /dev/null domiflist minikube | grep mk-minikube | awk '{print $1}')
BRIDGE=$(virsh -q -l /dev/null net-info mk-minikube | grep Bridge | awk '{print $2}')
MINIKUBE_IP=""

if [ "$1" == "$IFACE" ] && [ "$2" == "up" ]; then
    while [ "$MINIKUBE_IP" == "" ]; do
         sleep 3
         MINIKUBE_IP=$(virsh -q -l /dev/null net-dhcp-leases mk-minikube | awk '{print $5}' | cut -d/ -f1)
    done
    resolvectl domain "$BRIDGE" ~minikube.home
    resolvectl dns "$BRIDGE" "$MINIKUBE_IP:30053"
elif [ "$IFACE" == "-"   ] && [ "$2" == "down" ]; then
    resolvectl revert "$BRIDGE"
fi

exit 0
