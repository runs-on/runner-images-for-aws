retry_command() {
    local retries=$1
    shift
    local count=0
    until "$@" || [[ $count -eq $retries ]]; do
        echo "!!!!! Unable to execute command. Retrying in 5s..." >&2
        count=$((count+1))
        sleep 5
    done
    return $?
}