package PVE::API2;

# Installed by pve-routedip. The PVE::API2 module of pve-manager is diverted
# (dpkg-divert) to the path below; load it unchanged and register the
# pve-routedip API paths. Removing pve-routedip restores the original.

use strict;
use warnings;

BEGIN {
    my $orig = '/usr/share/perl5/PVE/API2.pm.pve-routedip-orig';
    my $res = do $orig;
    die "unable to load $orig - $@" if $@;
    die "unable to load $orig - $!\n" if !defined($res);
}

eval {
    require PVE::API2::RoutedIP;
    PVE::API2::RoutedIP::register_api();
};
warn "pve-routedip: unable to register API - $@" if $@;

1;
