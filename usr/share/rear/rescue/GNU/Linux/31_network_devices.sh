# 31_network_devices.sh
#
# record network device configuration for Relax-and-Recover
#
#    Relax-and-Recover is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.

#    Relax-and-Recover is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.

#    You should have received a copy of the GNU General Public License
#    along with Relax-and-Recover; if not, write to the Free Software
#    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

# Notes:
# - Thanks to Markus Brylski for fixing some bugs with bonding.
# - Thanks to Gerhard Weick for coming up with a way to disable bonding if needed.

# TODO: Currently it supports only ethernet.

# Where to build networking configuration.
# When booting the rescue/recovery system
# /etc/scripts/system-setup.d/60-network-devices.sh
# is run to setup the network devices:
network_devices_setup_script=$ROOTFS_DIR/etc/scripts/system-setup.d/60-network-devices.sh

# When DHCP is used via 58-start-dhclient.sh do not mess up the existing networking setup
# here by possibly conflicting network devices setup via 60-network-devices.sh:
if test $USE_DHCLIENT -a -z $USE_STATIC_NETWORKING ; then
    Log "No network devices setup via 60-network-devices.sh because that happens via DHCP in 58-start-dhclient.sh."
    # To be on the safe side remove network_devices_setup_script if it somehow already exists:
    rm $v -f $network_devices_setup_script >&2
    return
fi

# Initialize network_devices_setup_script:
echo "# Network devices setup:" >$network_devices_setup_script

# Skip network_devices_setup_script if the kernel command line contains the 'noip' parameter:
  ( echo "# Skip network devices setup if the kernel command line parameter 'noip' is specifiled:"
    echo "grep -q '\<noip\>' /proc/cmdline && return"
  ) >>$network_devices_setup_script

# If IPADDR=1.2.3.4 has been defined at boot time via ip=1.2.3.4
# then do the network devices setup this way:
cat - <<EOT >>$network_devices_setup_script
# If IPADDR=1.2.3.4 has been defined at boot time via ip=1.2.3.4 setup network devices this way:
if [[ "\$IPADDR" ]] && [[ "\$NETMASK" ]] ; then
    device=\${NETDEV:-eth0}
    ip link set dev "\$device" up
    ip addr add "\$IPADDR"/"\$NETMASK" dev "\$device"
    if [[ "\$GATEWAY" ]] ; then
        ip route add default via "\$GATEWAY"
    fi
    return
fi
EOT

# Collect list of all physical network interface cards.
# Take all interfaces in /sys/class/net and subtract /sys/devices/virtual/net, bonding_masters:
physical_network_interfaces=""
# e.g. on SLES12 with KVM/QEMU 'ls /sys/devices/virtual/net' may result "br0 lo virbr1 virbr1-nic vnet0"
virtual_network_interfaces=$( ls /sys/devices/virtual/net )
# e.g. on SLES12 with KVM/QEMU 'ls /sys/class/net' may result "br0 eth0 lo virbr1 virbr1-nic vnet0"
network_interfaces=$( ls /sys/class/net )
# so that in this example using network_interfaces and subtracting virtual_network_interfaces
# results "eth0" as the only physical network interface.
# Note that when network_interfaces or virtual_network_interfaces is empty
# then no commands are executed in the for-loops and the return status is 0
# which is the right behaviour here (i.e. no additional "if empty" test needed) and
# because network interface names do not allow spaces they can be just used in for-loops:
for network_interface in $network_interfaces ; do
    # See https://github.com/rear/rear/issues/758 why regular expression
    # cannot be used here (because it does not work on all bash 3.x versions).
    # Additionally one cannot use simple substring search because assume
    # virtual_network_interfaces is "lo virt-eth0" and network_interfaces is "eth0 lo virt-eth0"
    # then simple substring search would find "eth0" as substring in "lo virt-eth0"
    # so that to be on the safe side a dumb traditional for-loop approach is used
    # (unitl someone implements a better solution that works on all bash 3.x versions):
    for virtual_network_interface in $virtual_network_interfaces ; do
        test "$network_interface" = "$virtual_network_interface" && network_interface=""
    done
    # bonding_masters is also no physical network interface:
    test "$network_interface" = "bonding_masters" && network_interface=""
    # Now network_interface is non-epmtry only for physical network interfaces:
    test "$network_interface" && physical_network_interfaces+=" $network_interface"
done

# Go over the physical network interfaces and record information.
# BTW, network interface names luckily do not allow spaces :-)
for physical_network_interface in $physical_network_interfaces ; do
    sysfspath=/sys/class/net/$physical_network_interface
    # Get MAC address:
    mac="$( cat $sysfspath/address )" || BugError "Could not read a MAC address from '$sysfspath/address'."
    # Skip fake interfaces without MAC address:
    test "$mac" == "00:00:00:00:00:00" && continue
    # TODO: skip bonding (and other dependent) devices from recording their MAC address in /etc/mac-addresses
    # because such devices mirror the MAC address of (usually the first) real NIC.
    # I lack experience with bonding setups to write this blindly, so please contribute better code
    #
    # Keep mac address information for rescue system:
    echo "$physical_network_interface $mac" >>$ROOTFS_DIR/etc/mac-addresses
    # Take information only from UP devices, we don't care about non-working devices:
    ip link show dev $physical_network_interface | grep -q UP || continue
    # Link is up.
    # Determine the driver to load, relevant only for non-udev environments:
    if [[ -z "$driver" && -e "$sysfspath/device/driver" ]] ; then
        # This should work for virtio_net, xennet and vmxnet on recent kernels:
        driver=$( basename $( readlink $sysfspath/device/driver ) )
        if test "$driver" -a "$driver" = vif ; then
            # xennet driver announces itself as vif :-(
            driver=xennet
        fi
    elif [[ -z "$driver" && -e "$sysfspath/driver" ]] ; then
        # This should work for virtio_net, xennet and vmxnet on older kernels (2.6.18):
        driver=$( basename $( readlink $sysfspath/driver ) )
    elif [[ -z "$driver" ]] && has_binary ethtool ; then
        driver=$( ethtool -i $physical_network_interface 2>&8 | grep driver: | cut -d: -f2 )
    fi
    if [[ "$driver" ]] ; then
        grep -q $driver /proc/modules || LogPrint "Driver '$driver' for '$physical_network_interface' not loaded - is that okay?"
        echo "$driver" >>$ROOTFS_DIR/etc/modules
    else
        LogPrint "Could not determine driver for '$physical_network_interface'. To ensure it gets loaded add it to MODULES_LOAD."
    fi
    mkdir -p $v $TMP_DIR/mappings >&2
    test -f $CONFIG_DIR/mappings/ip_addresses && read_and_strip_file $CONFIG_DIR/mappings/ip_addresses > $TMP_DIR/mappings/ip_addresses

    if test -s $TMP_DIR/mappings/ip_addresses ; then
        while read network_device ip_address junk ; do
            Log "New IP-address will be $network_device $ip_address"
              ( echo "# New IP-address will be $network_device $ip_address:"
                echo "ip addr add $ip_address dev $network_device"
                echo "ip link set dev $network_device up"
              ) >>$network_devices_setup_script
        done < $TMP_DIR/mappings/ip_addresses
    else
        for addr in $( ip a show dev $physical_network_interface scope global | grep "inet.*\ " | tr -s " " | cut -d " " -f 3 ) ; do
            echo "ip addr add $addr dev $physical_network_interface" >>$network_devices_setup_script
        done
        echo "ip link set dev $physical_network_interface up" >>$network_devices_setup_script
    fi

    # Record interface MTU:
    if test -e "$sysfspath/mtu" ; then
        mtu="$( cat $sysfspath/mtu )" || LogPrint "Could not read a MTU address from '$sysfspath/mtu'!"
        [[ "$mtu" ]] && echo "ip link set dev $physical_network_interface mtu $mtu" >>$network_devices_setup_script
    fi
done

# Extract configuration of a given VLAN interface:
already_set_up_vlans=""
function vlan_setup () {
    local network_interface=$1
    # Check if we already dealt with this interface as a dependency:
    # See https://github.com/rear/rear/issues/758 why regular expression
    # cannot be used here (because it does not work on all bash 3.x versions).
    # Additionally one cannot use simple substring search because assume
    # already_set_up_vlans is "vlan10" and network_interface is "vlan1"
    # then simple substring search would find "vlan1" as substring in "vlan10"
    # so that to be on the safe side a dumb traditional for-loop approach is used
    # (unitl someone implements a better solution that works on all bash 3.x versions):
    for already_set_up_vlan in $already_set_up_vlans ; do
        test "$network_interface" = "$already_set_up_vlan" && return
    done
    # Determine the parent interface:
    local parent_interface=$( grep "^${network_interface}" /proc/net/vlan/config | awk '{print $5}' )
    # If the VLAN is built on top of a bonding, set that up first:
    # See https://github.com/rear/rear/issues/758 why regular expression
    # cannot be used here (because it does not work on all bash 3.x versions)
    # so that to be on the safe side a dumb traditional for-loop approach is used
    # (unitl someone implements a better solution that works on all bash 3.x versions):
    for bonding_interface in ${bonding_interfaces[@]} ; do
        # it is safe to just call bond_setup because that set up an interface only once:
        test "$parent_interface" = "$bonding_interface" &&  bond_setup $parent_interface
    done
    # Determine the VLAN ID:
    local vlan_id=$( grep "^${network_interface}" /proc/net/vlan/config | awk '{print $3}' )
    # Set up network device (a.k.a. 'link'):
    echo ip link add link $parent_interface name $network_interface type vlan id $vlan_id >>$network_devices_setup_script
    # Set up IP addresses on that device:
    for ip_address in $( ip ad show dev $network_interface scope global | grep "inet.*\ " | tr -s " " | cut -d " " -f 3 ) ; do
        echo "ip addr add $ip_address dev $network_interface" >>$network_devices_setup_script
    done
    # Enable the network interface:
    echo "ip link set dev $network_interface up" >>$network_devices_setup_script
    # Remember that we already dealt with this interface:
    already_set_up_vlans+=" ${network_interface}"
}

# Extract configuration of a given bonding interface:
already_set_up_bonding_interfaces=""
function bond_setup () {
    local network_interface=$1
    # Check if we already dealt with this interface as a dependency:
    # See https://github.com/rear/rear/issues/758 why regular expression
    # cannot be used here (because it does not work on all bash 3.x versions).
    # Additionally one cannot use simple substring search because assume
    # already_set_up_bonding_interfaces is "bond10" and network_interface is "bond1"
    # then simple substring search would find "bond1" as substring in "bond10"
    # so that to be on the safe side a dumb traditional for-loop approach is used
    # (unitl someone implements a better solution that works on all bash 3.x versions):
    for already_set_up_bonding_interface in $already_set_up_bonding_interfaces ; do
        test "$network_interface" = "$already_set_up_bonding_interface" && return
    done
    # Get list of bonding group members:
    local bonding_group_members=$( cat /sys/class/net/${network_interface}/bonding/slaves )
    # If a member of the bonding group is a VLAN, set that up first:
    for bonding_group_member in $bonding_group_members ; do
        # See https://github.com/rear/rear/issues/758 why regular expression
        # cannot be used here (because it does not work on all bash 3.x versions)
        # so that to be on the safe side a dumb traditional for-loop approach is used
        # (unitl someone implements a better solution that works on all bash 3.x versions):
        for vlan_interface in ${vlan_interfaces[@]} ; do
            if test "$bonding_group_member" = "$vlan_interface" ; then
                # it is safe to just call vlan_setup because that set up an interface only once:
                vlan_setup $bonding_group_member
            else
                echo "No vlan_setup for bonding group member '$bonding_group_member' because it is not a vlan."
            fi
        done
    done
    # We first need to "up" the bonding interface, then add the slaves
    # (ifenslave complains about missing IP adresses, can be ignored),
    # and then add the IP addresses:
    echo "ip link set dev $network_interface up" >>$network_devices_setup_script
    # Enslave slave interfaces which we read from the sysfs status file:
    if command -v ifenslave >/dev/null 2>&1 ; then
        # We can use ifenslave(8) and do it all at once:
        echo "ifenslave $network_interface $bonding_group_members" >>$network_devices_setup_script
    else
        # No ifenslave(8) found, hopefully ip(8) can do it:
        for bonding_group_member in $bonding_group_members ; do
            echo "ip link set $bonding_group_member master $network_interface" >>$network_devices_setup_script
        done
    fi
    # FIXME: What is the reason why sleeping hardcoded 5 seconds is "the right thing" that makes it work?
    echo "sleep 5" >>$network_devices_setup_script
    # Set up IP addresses on that device:
    for ip_address in $( ip ad show dev $network_interface scope global | grep "inet.*\ " | tr -s " " | cut -d " " -f 3 ) ; do
        echo "ip addr add $ip_address dev $network_interface" >>$network_devices_setup_script
    done
    # Remember that we already dealt with this interface:
    already_set_up_bonding_interfaces+=" ${network_interface}"
}

# Load required modules for bonding and collect list of all up bonding interfaces:
bonding_interfaces=()
if test -d /proc/net/bonding ; then
   for bonding_interface in $( ls /proc/net/bonding ) ;	do
       if ip link show dev $bonding_interface | grep -q UP ; then
           bonding_interfaces+=($bonding_interface)
       fi
    done
    # Default bonding mode is 1 (active backup):
    bonding_mode=1
    grep -q "Bonding Mode: IEEE 802.3ad" /proc/net/bonding/${bonding_interfaces[0]} && bonding_mode=4
    # Load bonding with the correct amount of bonding devices:
    echo "modprobe bonding max_bonds=${#bonding_interfaces[@]} miimon=100 mode=$bonding_mode use_carrier=0" >>$network_devices_setup_script
    MODULES=( "${MODULES[@]}" 'bonding' )
fi

# Load required modules for VLAN and collect list of all up VLAN interfaces:
vlan_interfaces=()
if test -d /proc/net/vlan ; then
    if [[ -f /proc/net/vlan/config ]] ; then
        # Config file contains a line like "vlan163        | 163  | bond1" describing the vlan.
        # Save a copy to our recovery area.
        # We might need it if we ever want to implement VLAN Migration.
        cp /proc/net/vlan/config $VAR_DIR/recovery/vlan.config
    fi
    # Load required modules for VLAN:
    echo "modprobe 8021q" >>$network_devices_setup_script
    echo "sleep 5" >>$network_devices_setup_script
    # Collect list of all up VLAN interfaces:
    for vlan_interface in $( ls /proc/net/vlan | grep -v config ) ; do
        if ip link show dev $vlan_interface | grep -q UP ; then
            vlan_interfaces+=($vlan_interface)
        fi
    done
fi

# Set up all VLANS:
for vlan_interface in ${vlan_interfaces[@]} ; do
    vlan_setup $vlan_interface
done

# Bonding setup:
if ! test "$SIMPLIFY_BONDING" ; then
    for bonding_interface in ${bonding_interfaces[@]} ; do
        bond_setup $bonding_interface
    done
else
    # Simplified bonding setup by configuring always the first device of a bond:
    #
    # The way to simplify the bonding is to copy the IP addresses
    # from the bonding device to the *first* slave device.
    #
    # FIXME: Translate the following comment into globally comprehensible language (i.e. English!)
    # Anpassung HZD: Hat ein System bei einer SLES10 Installation zwei Bonding-Devices
    # gibt es Probleme beim Boot mit der Rear-Iso-Datei. Der Befehl modprobe -o name ...
    # funkioniert nicht. Dadurch wird nur das erste bonding-Device koniguriert.
    # Die Konfiguration des zweiten Devices schlaegt fehl und dieses laesst sich auch nicht manuell
    # nachinstallieren. Daher wurde diese script so angepasst, dass die Rear-Iso-Datei kein Bonding
    # konfiguriert, sondern die jeweiligen IP-Adressen einer Netzwerkkarte des Bondingdevices
    # zuordnet. Dadurch musste aber auch das script 35_routing.sh angepasst werden.
    #
    # Go over bondX and record information:
    bonding_interface_number=0
    # Unlimited while-loop because there is no real limit how many bonding interfaces could exist:
    while : ; do
        bonding_interface=bond$bonding_interface_number
        # Break while-loop at the first non-existent bonding interface:
        test -r /proc/net/bonding/$bonding_interface || break
        if ip link show dev $bonding_interface | grep -q UP ; then
            # Link is up:
            bonding_enslaved_interfaces=( $( cat /proc/net/bonding/$bonding_interface | grep "Slave Interface:" | cut -d : -f 2 ) )
            for addr in $( ip a show dev $bonding_interface scope global | grep "inet.*\ " | tr -s " " | cut -d " " -f 3 ) ; do
                # Use bonding_enslaved_interfaces[0] instead of bond$c
                # to copy IP address from bonding device to the first enslaved device:
                echo "ip addr add $addr dev ${bonding_enslaved_interfaces[0]}" >>$network_devices_setup_script
            done
            echo "ip link set dev ${bonding_enslaved_interfaces[0]} up" >>$network_devices_setup_script
        fi
        let bonding_interface_number++
    done
    # Fake already_set_up_bonding_interfaces, so that no recursive call tries to bring one up the not-simplified way:
    already_set_up_bonding_interfaces=${bonding_interfaces[@]}
fi

