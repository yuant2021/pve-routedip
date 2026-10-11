package PVE::Network;

# Installed by pve-routedip. The PVE::Network module of libpve-common-perl is
# diverted (dpkg-divert) to the path below; load it unchanged and add the
# pve-routedip tap hooks on top. Removing pve-routedip restores the original.

use strict;
use warnings;

BEGIN {
    my $orig = '/usr/share/perl5/PVE/Network.pm.pve-routedip-orig';
    my $res = do $orig;
    die "unable to load $orig - $@" if $@;
    die "unable to load $orig - $!\n" if !defined($res);
}

eval {
    require PVE::RoutedIP::Hooks;
    PVE::RoutedIP::Hooks::install();
};
warn "pve-routedip: unable to install network hooks - $@" if $@;

1;
