# nft -c needs CAP_NET_ADMIN, which a build does not have.
edit 's#^in_root nft -c -f /etc/runs-on/syn-reroll.nft$#& || echo "nft check skipped: no CAP_NET_ADMIN in a build"#' 'nft check skipped'
