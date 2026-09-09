# NODE_OS_FAMILY groups the distributions we build by package family, so that
# package-installs.yaml `when:` clauses and the finalisers can say "every EL
# rebuild" instead of naming Rocky Linux and AlmaLinux one by one. `when:` can
# only test one variable for equality, and a YAML key cannot repeat, so a
# second distribution cannot be added as a second `when:` line.
#
# Numbered after DIB's own 10-* files, which set DISTRO_NAME.
case "${DISTRO_NAME:-}" in
    rocky|almalinux|centos|rhel|fedora|openeuler) export NODE_OS_FAMILY=redhat ;;
    debian|ubuntu)                                export NODE_OS_FAMILY=debian ;;
    *)                                            export NODE_OS_FAMILY=other ;;
esac
