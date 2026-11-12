# A build never generated SSH host keys.
edit 's#^shred -u /etc/ssh/\*_key /etc/ssh/\*_key.pub$#& || true#' '*_key.pub || true'
