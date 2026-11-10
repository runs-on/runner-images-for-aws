# /etc/resolv.conf is a bind mount during the build: leave the link for the converter.
edit 's#^rm -f /etc/resolv.conf$#mkdir -p /etc/oci2ami#' 'mkdir -p /etc/oci2ami'
edit 's#^ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf$#ln -sfn ../run/systemd/resolve/stub-resolv.conf /etc/oci2ami/resolv.conf#' '/etc/oci2ami/resolv.conf'
