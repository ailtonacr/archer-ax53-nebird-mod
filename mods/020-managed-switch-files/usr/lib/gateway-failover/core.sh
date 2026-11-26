# POSIX shell; pure policy, no network writes.
# Arguments: phase, consecutive samples, probe, failure limit, recovery limit,
# automatic return (0/1). Output: phase count action.
fo_step() {
    phase=$1 count=$2 probe=$3 fail_limit=$4 recovery_limit=$5 auto_return=$6
    case "$phase:$probe" in
        NORMAL:healthy|SUSPECT:healthy) echo "NORMAL 0 none" ;;
        NORMAL:down|SUSPECT:down)
            count=$((count + 1))
            if [ "$count" -ge "$fail_limit" ]; then
                echo "SUSPECT $fail_limit takeover"
            else
                echo "SUSPECT $count none"
            fi ;;
        NORMAL:*|SUSPECT:*) echo "SUSPECT 0 none" ;;
        FAILOVER:healthy|RECOVERY:healthy)
            count=$((count + 1))
            if [ "$count" -ge "$recovery_limit" ]; then
                if [ "$auto_return" = 1 ]; then
                    echo "RECOVERY $recovery_limit return"
                else
                    echo "RECOVERY $recovery_limit none"
                fi
            else
                echo "RECOVERY $count none"
            fi ;;
        FAILOVER:*|RECOVERY:*) echo "FAILOVER 0 none" ;;
        *) echo "ERROR 0 none" ;;
    esac
}
