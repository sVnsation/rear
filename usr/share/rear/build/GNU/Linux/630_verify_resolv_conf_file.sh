# Try to verify that the /etc/resolv.conf file in the ReaR recovery system
# contains content that is actually usable within the recovery system.
#
# We do not want to replicate in the recovery system
# whatever complicated DNS setup there is on the original system
# (e.g. a local name server or a stub resolver like systemd-resolved).
# In the recovery system a plain traditional /etc/resolv.conf file
# with a remote name server that the resolver should query should be sufficient, cf.
# https://github.com/rear/rear/issues/2015#issuecomment-454749972
# By default things cannot work when only loopback nameservers are specified
# or when there is no nameserver entry in /etc/resolv.conf in the recovery system
# so that we error out in this case.
# For non-default cases the user must specify what he wants via USE_RESOLV_CONF
# (e.g. to use a local name server that he manually starts in the recovery system):

# Use what the user specified for /etc/resolv.conf in the recovery system:
if test "$USE_RESOLV_CONF" ; then
    rm -f $ROOTFS_DIR/etc/resolv.conf
    # No /etc/resolv.conf in the recovery system when USE_RESOLV_CONF is false:
    is_false "$USE_RESOLV_CONF" && return
    # Copy a file if USE_RESOLV_CONF specifies an existing non-empty file:
    if test -s "$USE_RESOLV_CONF" ; then
        cp $v "$USE_RESOLV_CONF" $ROOTFS_DIR/etc/resolv.conf
        return
    fi
    # Otherwise USE_RESOLV_CONF specifies the lines for /etc/resolv.conf in the recovery system:
    local resolv_conf_line
    for resolv_conf_line in "${USE_RESOLV_CONF[@]}" ; do
        echo "$resolv_conf_line" >>$ROOTFS_DIR/etc/resolv.conf
    done
    return
fi

# Ensure /etc/resolv.conf in the recovery system contains actual content.
# Because of the issues
# https://github.com/rear/rear/issues/520
# https://github.com/rear/rear/issues/1200
# https://github.com/rear/rear/issues/2015
# where on Ubuntu /etc/resol.conf is linked to /run/resolvconf/resolv.conf
# and since Ubuntu 18.x /etc/resol.conf is linked to /lib/systemd/resolv.conf
# so that we need to remove the link and have the actual content in /etc/resolv.conf
if test -h $ROOTFS_DIR/etc/resolv.conf ; then
    rm -f $ROOTFS_DIR/etc/resolv.conf
    if [[ -f /run/systemd/resolve/resolv.conf ]] ; then
        # For Ubuntu 18.x use a real resolv.conf file: quick hack on #2018
        # See https://github.com/rear/rear/pull/2101#issuecomment-478496081
        # for an example what the symlink target /etc/resolv.conf and the files
        # /lib/systemd/resolv.conf and /run/systemd/resolve/resolv.conf contain.
        # Basically /etc/resolv.conf and /lib/systemd/resolv.conf contain only
        # the systemd-resolved stub resolver "nameserver 127.0.0.53" and
        # only /run/systemd/resolve/resolv.conf contains a real nameserver:
        cp $v /run/systemd/resolve/resolv.conf $ROOTFS_DIR/etc/resolv.conf
    else
        cp $v /etc/resolv.conf $ROOTFS_DIR/etc/resolv.conf
    fi
fi

# Check that the content in /etc/resolv.conf in the recovery system
# seems to be actually usable within the recovery system
# (i.e. that there is at least one remote nameserver IP address).
# On Ubuntu 18.x versions /etc/resol.conf is linked to /lib/systemd/resolv.conf
# where its actual content is only the following single line
#   nameserver 127.0.0.53
# cf. https://github.com/rear/rear/issues/2015#issuecomment-454082087
# but a loopback IP address for the nameserver cannot work
# because neither a local name server nor systemd-resolved
# is running within the recovery system.
# According to "man resolv.conf"
#   ... the keyword (e.g., nameserver) must start the line.
#   The value follows the keyword, separated by white space.
local valid_nameserver="no"
local nameserver_keyword nameserver_value junk
while read nameserver_keyword nameserver_value junk ; do
    test "$nameserver_value" || continue
    # One non-empty/non-loopback nameserver IP address is considered to be valid
    # (i.e. we do not verify here if a nameserver does actually work).
    # TODO: Do we also have to check for IPv6 loopback addresses like '::1' ?
    if grep -q '^127\.' <<<"$nameserver_value" ; then
        Log "Useless loopback nameserver '$nameserver_value' in $ROOTFS_DIR/etc/resolv.conf"
    else
        valid_nameserver="yes"
        Log "Supposedly valid nameserver '$nameserver_value' in $ROOTFS_DIR/etc/resolv.conf"
        # We may no 'break' here if we like to 'Log' all supposedly valid nameserver values:
        break
    fi
done < <( grep '^nameserver[[:space:]]' $ROOTFS_DIR/etc/resolv.conf )
# When there is no '^nameserver ' line in /etc/resolv.conf in the recovery system
# the 'while' loop is not run so that valid_nameserver="no" would be still set:
is_true "$valid_nameserver" && return 0

# In case of static networking setup it would not work when /etc/resolv.conf
# in the recovery system contains only loopback IP addresses or when there is
# no nameserver entry so that "rear mkrescue/mkbackup" errors out in this case
# unless USE_DHCLIENT is true (and USE_STATIC_NETWORKING is not also set to true).
# USE_DHCLIENT is automatically true when a known 'dhclient' process is running
# on the original system and then networking setup in the recovery system also
# happens via DHCP (for details see see prep/GNU/Linux/210_include_dhclient.sh)
# cf. https://github.com/rear/rear/pull/2076#issuecomment-471540880
# In this case during recovery system startup /etc/resolv.conf will be
# generated by /bin/dhclient-script regardless what its content was before
# cf. https://github.com/rear/rear/pull/2018#issuecomment-470968951
# We do not error out when USE_DHCLIENT is true and USE_STATIC_NETWORKING is not true
# but we inform the user when he runs ReaR in verbose mode (no LogPrintError needed):
if is_true "$USE_DHCLIENT" ; then
    if ! is_true "$USE_STATIC_NETWORKING" ; then
        LogPrint "No nameserver or only loopback addresses in $ROOTFS_DIR/etc/resolv.conf should not matter because USE_DHCLIENT is true"
        return 0
    fi
fi
Error "No nameserver or only loopback addresses in $ROOTFS_DIR/etc/resolv.conf, specify a real nameserver via USE_RESOLV_CONF"
