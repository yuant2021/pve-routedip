package PVE::RoutedIP::Hooks;

# Hooks into PVE::Network, installed by the PVE::Network wrapper module that
# pve-routedip puts in place of the original (see debian/pve-routedip.preinst).
#
# All guest NIC (un)plugging funnels through PVE::Network, no matter if it was
# triggered by QEMU (pve-bridge), a hot config change (pvedaemon, qm), SDN or
# a live migration:
#
#   tap_plug        tap-only NICs never get inserted into a bridge
#   tap_unplug      remove the NIC's routes (guest stop, NIC change)
#   add_bridge_fdb  called right before a guest is resumed: install routes,
#                   which makes them follow a live migration to the target
#   del_bridge_fdb  called on the migration source right before the target
#                   is resumed: remove routes
#
# This module must stay cheap to load, everything else is loaded lazily and only
# for taps of guests with a routed IP config.

use strict;
use warnings;

our $BYPASS = 0; # set (local) while pve-routedip itself (un)plugs taps
our %ORIG;

my $CFG_DIR = '/etc/pve/routedip';
my $MARKER_DIR = '/run/pve-routedip/tap-only';

my sub routed_tap {
    my ($iface) = @_;

    return if $BYPASS || !defined($iface);
    return if $iface !~ m/^tap(\d+)i(\d+)$/;
    my ($vmid, $idx) = ($1, $2);

    my $has_cfg = -f "$CFG_DIR/$vmid.cfg";
    my $has_marker = -e "$MARKER_DIR/tap${vmid}i$idx";
    return if !$has_cfg && !$has_marker;

    require PVE::RoutedIP::Runtime;

    my $nic;
    if ($has_cfg) {
        $nic = eval { PVE::RoutedIP::Runtime::routed_nic($vmid, $idx) };
        PVE::RoutedIP::Runtime::log_err("VM $vmid net$idx: $@") if $@;
    }

    return ($vmid + 0, $idx + 0, $nic, $has_marker);
}

my sub run_logged {
    my ($vmid, $idx, $code) = @_;
    eval { $code->() };
    PVE::RoutedIP::Runtime::log_err("VM $vmid net$idx: $@") if $@;
}

sub hook_tap_plug {
    my ($orig, @args) = @_;

    my ($iface, $bridge, $tag, $firewall, $trunks, $rate) = @args;
    my ($vmid, $idx, $nic, $has_marker) = routed_tap($iface);
    return $orig->(@args) if !defined($vmid);

    if ($nic && $nic->{'tap-only'}) {
        # never insert into the bridge, even if our setup fails
        run_logged($vmid, $idx, sub { PVE::RoutedIP::Runtime::hook_taponly_plug($vmid, $idx, $nic, $rate) });
        return;
    }

    if ($has_marker) {
        run_logged($vmid, $idx, sub {
            PVE::RoutedIP::Runtime::with_lock(sub { PVE::RoutedIP::Runtime::taponly_revert($iface) });
        });
    }

    my @res = $orig->(@args);

    if ($nic) {
        run_logged($vmid, $idx, sub {
            PVE::RoutedIP::Runtime::hook_bridged_plug($vmid, $idx, $nic, $bridge, $tag);
        });
    }

    return @res;
}

sub hook_tap_unplug {
    my ($orig, @args) = @_;

    my @res = $orig->(@args);

    my ($vmid, $idx, $nic) = routed_tap($args[0]);
    if (defined($vmid) && $nic) {
        run_logged($vmid, $idx, sub { PVE::RoutedIP::Runtime::hook_remove_routes($vmid, $idx, $nic) });
    }

    return @res;
}

sub hook_add_bridge_fdb {
    my ($orig, @args) = @_;

    my @res = $orig->(@args);

    my ($vmid, $idx, $nic) = routed_tap($args[0]);
    if (defined($vmid) && $nic) {
        run_logged($vmid, $idx, sub { PVE::RoutedIP::Runtime::hook_resume($vmid, $idx, $nic) });
    }

    return @res;
}

sub hook_del_bridge_fdb {
    my ($orig, @args) = @_;

    my @res = $orig->(@args);

    my ($vmid, $idx, $nic) = routed_tap($args[0]);
    if (defined($vmid) && $nic) {
        run_logged($vmid, $idx, sub { PVE::RoutedIP::Runtime::hook_remove_routes($vmid, $idx, $nic) });
    }

    return @res;
}

my $installed;

sub install {
    return if $installed;
    $installed = 1;

    no strict 'refs'; ## no critic (ProhibitNoStrict)
    no warnings 'redefine';

    for my $name (qw(tap_plug tap_unplug add_bridge_fdb del_bridge_fdb)) {
        my $fqname = "PVE::Network::$name";
        if (!defined(&{$fqname})) {
            warn "pve-routedip: $fqname not found, hook not installed\n";
            next;
        }
        my $orig = $ORIG{$name} = \&{$fqname};
        my $hook = \&{"hook_$name"};
        *{$fqname} = sub { return $hook->($orig, @_) };
    }
}

1;
