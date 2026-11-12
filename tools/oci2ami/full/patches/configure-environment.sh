# /etc/hosts is a bind mount during the build: edit the copy the converter installs.
edit "s#' /etc/hosts\$#' /etc/oci2ami/hosts#" "' /etc/oci2ami/hosts"
# The root is overlayfs here; the converter writes the ext4 root (and its rootflags).
edit 's/^if \[\[ "\$root_fs_type" != "ext4" \]\]; then$/if false; then # oci: the converter writes an ext4 root/' 'if false; then # oci'
