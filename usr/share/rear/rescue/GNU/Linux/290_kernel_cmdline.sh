# purpose of the script is to detect some important KERNEL CMDLINE options on the current system
# we should also use in rescue mode (automatically update KERNEL_CMDLINE array variable).

# Scanning current kernel cmdline option to look for important option to include in KERNEL_CMDLINE
for current_kernel_option in $( cat /proc/cmdline ); do
    # If user use options to force or disable biosdevname (persistant inet naming)
    # we need to have this option in the rescue image in order to properly configure / migrate
    # the network configuration.

    if [ "${current_kernel_option%=*}" == "net.ifnames" ] || [ "${current_kernel_option%=*}" == "biosdevname" ] ; then
        new_kernel_options_to_add=( "${new_kernel_options_to_add[@]}" "$current_kernel_option" )
    fi
done

# Verify if the kernel option we want to add to KERNEL_CMDLINE are not already set/force by the user in the rear configuration.
# If yes, the parameter set in the configuration file have the priority and superseed the current kernel option.
for new_kernel_option in "${new_kernel_options_to_add[@]}" ; do

    kernel_option_superseeded=0

    for rear_kernel_option in $KERNEL_CMDLINE; do
        # Check if a kernel option key without value parameter (everything before =) is not already present in rear KERNEL_CMDLINE array.
        if [ "${new_kernel_option%=*}" == "${rear_kernel_option%=*}" ]; then
            Log "Current kernel option [$new_kernel_option] supperseeded by [$rear_kernel_option] in your rear configuration: (KERNEL_CMDLINE)"
            kernel_option_superseeded=1
            break
        fi
    done

    if test "$kernel_option_superseeded" -eq 1; then
        continue
    else
        LogPrint "Adding $new_kernel_option to KERNEL_CMDLINE"
        KERNEL_CMDLINE="$KERNEL_CMDLINE $new_kernel_option"
    fi
done
