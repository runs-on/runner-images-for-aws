retry_command() {
    local retries=$1
    shift
    echo "Retrying command for $retries times..."
    local count=0
    until ( "$@" 2>&1 | grep -v 'E:' ) || [[ $count -eq $retries ]]; do
        echo "Unable to execute command. Retrying later..." >&2
        count=$((count+1))
        sleep 30
    done
    return $?
}