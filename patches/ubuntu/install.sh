retry_command() {
    local retries=$1
    shift
    echo "Retrying command for $retries times..."
    local count=0
    until "$@" || [[ $count -eq $retries ]]; do
        echo "Unable to execute command. Retrying later..." >&2
        count=$((count+1))
        sleep 10
    done
    return $?
}