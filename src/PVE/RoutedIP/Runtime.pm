package PVE::RoutedIP::Runtime;

# Kernel side of pve-routedip: tap-only setup, gateway addresses and routes.
#
# Everything we install is tagged with protocol $PVE::RoutedIP::Config::PROTO
# (routes and addresses), so the kernel itself is the state database: whatever
# carries our protocol and is not wanted anymore gets removed.
#
# Ownership rule for a guest NIC tap<vmid>i<n> on this node:
#  - tap exists and the guest config lives on this node: active
#  - tap exists but the config lives elsewhere: migration in flight, hands off
#  - no tap: nothing may remain

use strict;
use warnings;

use Fcntl qw(:flock);
use JSON;

use PVE::INotify;
use PVE::Network;
use PVE::SafeSyslog;
use PVE::Tools;

use PVE::RoutedIP::Config;

my $IP = '/sbin/ip';
my $PROTO = $PVE::RoutedIP::Config::PROTO;

our $STATE_DIR = '/run/pve-routedip';
our $MARKER_DIR = "$STATE_DIR/tap-only";
our $LOCK_FILE = '/run/lock/pve-routedip.lck';

# also print errors to STDERR (task logs), the daemon only uses syslog
our $LOG_STDERR = 1;

## helpers

sub log_err {
    my ($msg) = @_;
    chomp($msg);
    syslog('err', '%s', $msg);
    warn "pve-routedip: $msg\n" if $LOG_STDERR;
}

sub log_info {
    my ($msg) = @_;
    chomp($msg);
    syslog('info', '%s', $msg);
}

our $LOCK_DEPTH = 0;

# Node local lock, re-entrant within one process. Unlike PVE::Tools::lock_file
# it does not print anything when waiting, this runs inside 'qm start' & co.
sub with_lock {
    my ($code) = @_;

    return $code->() if $LOCK_DEPTH;

    mkdir('/run/lock');
    open(my $fh, '>>', $LOCK_FILE) or die "unable to open '$LOCK_FILE' - $!\n";
    eval { PVE::Tools::run_with_timeout(30, sub { flock($fh, LOCK_EX) or die "$!\n" }) };
    die "unable to lock '$LOCK_FILE' - $@" if $@;

    local $LOCK_DEPTH = 1;
    my $res = eval { $code->() };
    my $err = $@;
    close($fh);
    die $err if $err;

    return $res;
}

# run code without our PVE::Network hooks, used for internal (un)plugging
sub without_hooks {
    my ($code) = @_;
    no warnings 'once';
    local $PVE::RoutedIP::Hooks::BYPASS = 1;
    return $code->();
}

sub parse_tap {
    my ($iface) = @_;
    return if !defined($iface) || $iface !~ m/^tap(\d+)i(\d+)$/;
    return ($1 + 0, $2 + 0);
}

sub untaint_dev {
    my ($dev) = @_;
    my ($res) = ($dev // '') =~ m/^([A-Za-z0-9_.\-:@]{1,15})$/;
    die "invalid interface name '" . ($dev // '') . "'\n" if !defined($res);
    return $res;
}

sub iface_exists {
    my ($dev) = @_;
    return -d "/sys/class/net/$dev";
}

sub iface_is_up {
    my ($dev) = @_;
    my $flags = PVE::Tools::file_read_firstline("/sys/class/net/$dev/flags") // return 0;
    return hex($flags) & 0x1; # IFF_UP
}

sub iface_master {
    my ($dev) = @_;
    my $link = readlink("/sys/class/net/$dev/master") // return undef;
    my ($master) = $link =~ m!/([^/]+)$!;
    return $master ? untaint_dev($master) : undef;
}

sub iface_attr {
    my ($dev, $attr) = @_;
    return PVE::Tools::file_read_firstline("/sys/class/net/$dev/$attr");
}

my sub ip_cmd {
    my (@args) = @_;

    my ($out, $err) = ('', '');
    eval {
        PVE::Tools::run_command(
            [$IP, @args],
            outfunc => sub { $out .= "$_[0]\n" },
            errfunc => sub { $err .= "$_[0]\n" },
        );
    };
    if (my $cmd_err = $@) {
        chomp($err);
        die "ip " . join(' ', @args) . ": " . ($err || $cmd_err) . "\n";
    }
    return $out;
}

my sub ip_json {
    my (@args) = @_;
    my $out = ip_cmd('-j', @args);
    return [] if $out !~ m/\S/;
    return decode_json($out);
}

sub ip_link_set {
    my ($dev, @opts) = @_;
    ip_cmd('link', 'set', 'dev', $dev, @opts);
}

sub sysctl_set {
    my ($family, $dev, $key, $value) = @_;

    my $path = "/proc/sys/net/ipv$family/conf/$dev/$key";
    return if !-e $path;
    my $cur = PVE::Tools::file_read_firstline($path);
    return if defined($cur) && $cur eq $value;

    open(my $fh, '>', $path) or die "unable to open '$path' - $!\n";
    print {$fh} "$value\n" or die "unable to write '$path' - $!\n";
    close($fh) or die "unable to write '$path' - $!\n";
}

sub random_mac {
    my @bytes = map { int(rand(256)) } 1 .. 6;
    $bytes[0] = ($bytes[0] & 0xfe) | 0x02; # unicast, locally administered
    return join(':', map { sprintf('%02x', $_) } @bytes);
}

sub local_taps {
    my $res = {};
    opendir(my $dh, '/sys/class/net') or return $res;
    while (defined(my $name = readdir($dh))) {
        next if $name !~ m/^tap(\d+)i(\d+)$/;
        $res->{"tap$1i$2"} = { vmid => $1 + 0, idx => $2 + 0 };
    }
    closedir($dh);
    return $res;
}

## markers for taps we took out of their bridge

sub marker_path {
    my ($tap) = @_;
    return "$MARKER_DIR/" . untaint_dev($tap);
}

sub make_state_dir {
    for my $dir ($STATE_DIR, $MARKER_DIR) {
        mkdir($dir, 0755) or $!{EEXIST} or die "unable to create '$dir' - $!\n";
    }
}

sub marker_set {
    my ($tap) = @_;
    my $path = marker_path($tap);
    return if -e $path;
    make_state_dir();
    PVE::Tools::file_set_contents($path, "");
}

sub marker_exists {
    my ($tap) = @_;
    return -e marker_path($tap);
}

sub marker_clear {
    my ($tap) = @_;
    my $path = marker_path($tap);
    unlink($path) or $!{ENOENT} or die "unable to remove '$path' - $!\n";
}

sub list_markers {
    my $res = {};
    opendir(my $dh, $MARKER_DIR) or return $res;
    while (defined(my $name = readdir($dh))) {
        $res->{"tap$1i$2"} = 1 if $name =~ m/^tap(\d+)i(\d+)$/;
    }
    closedir($dh);
    return $res;
}

## kernel state

sub proto_is_ours {
    my ($proto) = @_;
    return 0 if !defined($proto);
    return 1 if $proto eq 'routedip';
    $proto = hex($proto) if $proto =~ m/^0x[0-9a-f]+$/i;
    return $proto =~ m/^\d+$/ && $proto == $PROTO;
}

# our routes in the main table: { cidr => [dev, ...] }
sub kernel_routes {
    my $res = {};
    for my $family (4, 6) {
        my $routes = ip_json("-$family", 'route', 'show', 'table', 'main', 'proto', $PROTO);
        for my $route (@$routes) {
            my ($dst, $dev) = $route->@{qw(dst dev)};
            next if !defined($dst) || !defined($dev);
            $dst = $family == 4 ? '0.0.0.0/0' : '::/0' if $dst eq 'default';
            my $cidr = eval { PVE::RoutedIP::Config::canonical_cidr($dst) } // next;
            push $res->{$cidr}->@*, untaint_dev($dev);
        }
    }
    return $res;
}

# our addresses: { "ip/len dev" => { ip, len, dev } }
sub kernel_addrs {
    my $res = {};
    for my $link (ip_json('addr', 'show')->@*) {
        my $dev = eval { untaint_dev($link->{ifname}) } // next;
        for my $addr (($link->{addr_info} // [])->@*) {
            next if !proto_is_ours($addr->{protocol});
            my $ip = eval { PVE::RoutedIP::Config::canonical_ip($addr->{local}) } // next;
            my ($len) = ($addr->{prefixlen} // '') =~ m/^(\d+)$/ or next;
            $res->{"$ip/$len $dev"} = { ip => $ip, len => $len, dev => $dev };
        }
    }
    return $res;
}

sub addr_add {
    my ($ip, $len, $dev, $nodad) = @_;
    my @flags = $nodad && $ip =~ m/:/ ? ('nodad') : ();
    eval { ip_cmd('addr', 'add', "$ip/$len", 'dev', $dev, @flags, 'proto', $PROTO) };
    if (my $err = $@) {
        # the very same address configured by the admin is fine, we just don't own it
        die $err if $err !~ m/File exists/;
    }
}

sub addr_del {
    my ($ip, $len, $dev) = @_;
    eval { ip_cmd('addr', 'del', "$ip/$len", 'dev', $dev) };
    if (my $err = $@) {
        die $err if $err !~ m/Cannot assign requested address|Cannot find device/;
    }
}

# make $cidr point to $dev, $cur is the list of devices our routes for $cidr use now
sub route_set {
    my ($cidr, $dev, $cur) = @_;

    $cur //= [];
    return if grep { $_ eq $dev } @$cur;

    if (scalar(@$cur)) {
        ip_cmd('route', 'replace', $cidr, 'dev', $dev, 'proto', $PROTO);
        return;
    }

    eval { ip_cmd('route', 'add', $cidr, 'dev', $dev, 'proto', $PROTO) };
    if (my $err = $@) {
        die "a route for $cidr not managed by pve-routedip exists, refusing to replace it\n"
            if $err =~ m/File exists/;
        die $err;
    }
}

sub route_del {
    my ($cidr, $dev) = @_;
    eval { ip_cmd('route', 'del', $cidr, 'dev', $dev, 'proto', $PROTO) };
    if (my $err = $@) {
        die $err if $err !~ m/No such process|Cannot find device/;
    }
}

## tap-only handling

sub bridged_route_device {
    my ($bridge, $tag) = @_;

    die "network device is not attached to a bridge\n" if !$bridge;
    $bridge = untaint_dev($bridge);

    if (!defined($tag) || $tag eq '') {
        die "bridge '$bridge' does not exist\n" if !iface_exists($bridge);
        return $bridge;
    }

    my ($vlan) = $tag =~ m/^(\d+)$/ or die "invalid VLAN tag '$tag'\n";
    my $vlan_aware = iface_attr($bridge, 'bridge/vlan_filtering');
    my $dev = untaint_dev($vlan_aware ? "$bridge.$vlan" : "${bridge}v$vlan");
    die "route device '$dev' for VLAN $vlan on bridge '$bridge' does not exist\n"
        if !iface_exists($dev);
    return $dev;
}

# Compute what a routed NIC needs: device for routes and gateway addresses and,
# for tap-only, the tap settings. $net is the parsed qemu-server NIC (may be
# undef for tap-only when the guest config is not readable).
sub nic_plan {
    my ($vmid, $idx, $nic, $net, $opts) = @_;

    my $tap = "tap${vmid}i$idx";
    my $plan = {
        vmid => $vmid,
        netid => "net$idx",
        tap => $tap,
        taponly => $nic->{'tap-only'} ? 1 : 0,
        cidrs => [$nic->{cidr}->@*],
        gateways => PVE::RoutedIP::Config::nic_gateways($opts, $nic),
    };

    if ($plan->{taponly}) {
        $plan->{dev} = $tap;
        $plan->{mac} = $opts->{'gateway-mac'};
        my $mtu = $net ? $net->{mtu} : undef;
        ($plan->{mtu}) = ($mtu // '') =~ m/^(\d+)$/ if $mtu && $mtu > 1;
        $plan->{v6} = (grep { PVE::RoutedIP::Config::cidr_family($_) == 6 } $nic->{cidr}->@*)
            ? 1
            : 0;
    } else {
        $plan->{dev} = bridged_route_device($net->{bridge}, $net->{tag});
    }

    return $plan;
}

# Turn the tap into a standalone L3 interface. Never plugs anything into a bridge.
sub taponly_setup {
    my ($plan) = @_;

    my $tap = $plan->{tap};
    die "tap device '$tap' does not exist\n" if !iface_exists($tap);

    if (my $master = iface_master($tap)) {
        without_hooks(sub { PVE::Network::tap_unplug($tap) });
        die "unable to remove '$tap' from '$master'\n" if iface_master($tap);
        log_info("tap-only: removed $tap from $master");
    }

    ip_link_set($tap, 'address', $plan->{mac})
        if lc(iface_attr($tap, 'address') // '') ne $plan->{mac};

    ip_link_set($tap, 'mtu', $plan->{mtu})
        if $plan->{mtu} && (iface_attr($tap, 'mtu') // 0) != $plan->{mtu};

    if ($plan->{v6}) {
        # no SLAAC/RA and no EUI-64 link-local, the gateway address is all we want
        sysctl_set(6, $tap, 'addr_gen_mode', 1);
        sysctl_set(6, $tap, 'accept_ra', 0);
        sysctl_set(6, $tap, 'autoconf', 0);
        sysctl_set(6, $tap, 'disable_ipv6', 0);
    } else {
        PVE::Network::disable_ipv6($tap);
    }

    marker_set($tap);
}

# Undo taponly_setup (addresses, routes, MAC, IPv6) without plugging the tap.
sub taponly_revert {
    my ($tap) = @_;

    return marker_clear($tap) if !iface_exists($tap);

    my $addrs = kernel_addrs();
    for my $addr (values %$addrs) {
        addr_del($addr->@{qw(ip len dev)}) if $addr->{dev} eq $tap;
    }
    my $routes = kernel_routes();
    for my $cidr (keys %$routes) {
        route_del($cidr, $tap) if grep { $_ eq $tap } $routes->{$cidr}->@*;
    }

    PVE::Network::disable_ipv6($tap);
    ip_link_set($tap, 'address', random_mac());
    marker_clear($tap);
}

# Undo tap-only and plug the tap into its configured bridge, like pve-bridge does.
sub taponly_revert_and_plug {
    my ($tap, $net) = @_;

    taponly_revert($tap);
    return if !iface_exists($tap) || iface_master($tap);
    die "no bridge configured for '$tap'\n" if !$net || !$net->{bridge};

    my ($bridge, $tag, $firewall, $trunks, $rate) = $net->@{qw(bridge tag firewall trunks rate)};

    my $mtu = eval { PVE::Network::read_bridge_mtu($bridge) };
    ip_link_set($tap, 'mtu', $mtu) if $mtu;

    without_hooks(sub {
        if (eval { require PVE::QemuServer::Network; 1 }
            && PVE::QemuServer::Network->can('tap_plug')
        ) {
            PVE::QemuServer::Network::tap_plug($tap, $bridge, $tag, $firewall, $trunks, $rate);
        } elsif (eval { require PVE::Network::SDN::Zones; 1 }) {
            PVE::Network::SDN::Zones::tap_plug($tap, $bridge, $tag, $firewall, $trunks, $rate);
        } else {
            PVE::Network::tap_plug($tap, $bridge, $tag, $firewall, $trunks, $rate);
        }

        if (my $mac = $net->{macaddr}) {
            if (eval { require PVE::Network::SDN::Zones; 1 }) {
                PVE::Network::SDN::Zones::add_bridge_fdb($tap, $mac, $bridge);
            } else {
                PVE::Network::add_bridge_fdb($tap, $mac);
            }
        }
    });

    log_info("tap-only disabled: plugged $tap into $bridge");
}

## per NIC operations, used by the PVE::Network hooks

sub nodename {
    return PVE::INotify::nodename();
}

sub guest_config_is_local {
    my ($vmid) = @_;
    my $node = nodename();
    return -f "/etc/pve/nodes/$node/qemu-server/$vmid.conf";
}

# The routed NIC config for a tap, or undef. Cheap for unrouted guests.
sub routed_nic {
    my ($vmid, $idx) = @_;
    return undef if !PVE::RoutedIP::Config::has_vm_config($vmid);
    my $conf = PVE::RoutedIP::Config::load_vm_config($vmid);
    return $conf->{nics}->{"net$idx"};
}

# Parsed qemu-server NIC of a guest, wherever its config currently lives.
sub guest_net {
    my ($vmid, $idx) = @_;

    my $node;
    if (!guest_config_is_local($vmid)) {
        require PVE::Cluster;
        PVE::Cluster::cfs_update();
        $node = PVE::Cluster::get_vmlist()->{ids}->{$vmid}->{node}
            or die "unable to find config of VM $vmid\n";
    }
    my $conf = PVE::RoutedIP::Config::load_qemu_config($vmid, $node);
    return PVE::RoutedIP::Config::parse_qemu_net($conf->{"net$idx"});
}

# Configure gateway addresses and, if requested, routes of one NIC. Additive
# except on tap-only taps, which belong to us completely.
sub nic_apply {
    my ($plan, $with_routes) = @_;

    my @errors;
    my $try = sub {
        my ($code) = @_;
        eval { $code->() };
        push @errors, $@ if $@;
    };

    my $dev = $plan->{dev};
    my $cur_addrs = kernel_addrs();
    my %want_addrs;
    for my $gw ($plan->{gateways}->@*) {
        my ($ip, $len) = @$gw;
        $want_addrs{"$ip/$len $dev"} = 1;
        next if $cur_addrs->{"$ip/$len $dev"};
        $try->(sub { addr_add($ip, $len, $dev, $plan->{taponly}) });
    }
    if ($plan->{taponly}) {
        for my $key (sort keys %$cur_addrs) {
            my $addr = $cur_addrs->{$key};
            next if $addr->{dev} ne $dev || $want_addrs{$key};
            $try->(sub { addr_del($addr->@{qw(ip len dev)}) });
        }
    }

    if ($with_routes) {
        my $cur_routes = kernel_routes();
        my %want = map { $_ => 1 } $plan->{cidrs}->@*;
        for my $cidr ($plan->{cidrs}->@*) {
            $try->(sub { route_set($cidr, $dev, $cur_routes->{$cidr}) });
        }
        if ($plan->{taponly}) {
            for my $cidr (sort keys %$cur_routes) {
                next if $want{$cidr} || !grep { $_ eq $dev } $cur_routes->{$cidr}->@*;
                $try->(sub { route_del($cidr, $dev) });
            }
        }
    }

    die join('', @errors) if @errors;
}

# Remove the routes of one NIC (gateway addresses on shared bridges stay, the
# reconcile loop cleans them up once unused).
sub nic_remove_routes {
    my ($vmid, $idx, $nic) = @_;

    my $tap = "tap${vmid}i$idx";
    my %mine = map { $_ => 1 } ($nic ? $nic->{cidr}->@* : ());

    my @errors;
    my $routes = kernel_routes();
    for my $cidr (sort keys %$routes) {
        for my $dev ($routes->{$cidr}->@*) {
            next if $dev ne $tap && !$mine{$cidr};
            eval { route_del($cidr, $dev) };
            push @errors, $@ if $@;
        }
    }
    die join('', @errors) if @errors;
}

## entry points for PVE::RoutedIP::Hooks

# tap_plug() of a tap-only NIC: set up the tap instead of plugging it. Routes
# only if the guest config is here, an incoming live migration gets them
# right before the guest is resumed (hook_resume).
sub hook_taponly_plug {
    my ($vmid, $idx, $nic, $rate) = @_;

    with_lock(sub {
        my $opts = PVE::RoutedIP::Config::effective_options();
        my $net = eval { guest_net($vmid, $idx) }; # only needed for the MTU
        my $plan = nic_plan($vmid, $idx, $nic, $net, $opts);

        taponly_setup($plan);
        PVE::Network::tap_rate_limit($plan->{tap}, $rate);
        nic_apply($plan, guest_config_is_local($vmid));
    });
    log_info("tap-only: tap${vmid}i$idx configured without bridge");
}

# tap_plug() of a bridged routed NIC, after the tap got plugged
sub hook_bridged_plug {
    my ($vmid, $idx, $nic, $bridge, $tag) = @_;

    with_lock(sub {
        my $opts = PVE::RoutedIP::Config::effective_options();
        my $plan = nic_plan($vmid, $idx, $nic, { bridge => $bridge, tag => $tag }, $opts);
        nic_apply($plan, guest_config_is_local($vmid));
    });
}

# add_bridge_fdb(): the guest is about to run here (start or resume, also on
# the target of a live migration, where the config might not be moved yet)
sub hook_resume {
    my ($vmid, $idx, $nic) = @_;

    with_lock(sub {
        my $opts = PVE::RoutedIP::Config::effective_options();
        my $net = eval { guest_net($vmid, $idx) };
        die "unable to read guest config - $@" if !$net && !$nic->{'tap-only'};
        my $plan = nic_plan($vmid, $idx, $nic, $net, $opts);

        taponly_setup($plan) if $plan->{taponly};
        nic_apply($plan, 1);
    });
}

# tap_unplug() / del_bridge_fdb(): the NIC goes away or the guest is about to
# continue on another node
sub hook_remove_routes {
    my ($vmid, $idx, $nic) = @_;

    with_lock(sub { nic_remove_routes($vmid, $idx, $nic) });
}

## full reconcile

# Bring the whole node in line with the configuration. Returns the list of
# errors, which are also logged unless $quiet is set.
sub reconcile {
    my ($quiet) = @_;

    my $errors = [];
    with_lock(sub { reconcile_locked($errors) });
    if (!$quiet) {
        log_err($_) for @$errors;
    }
    return $errors;
}

sub reconcile_locked {
    my ($errors) = @_;

    require PVE::Cluster;
    PVE::Cluster::cfs_update(1);
    my $vmlist = PVE::Cluster::get_vmlist();
    die "unable to read guest list from pmxcfs\n" if !$vmlist || !defined($vmlist->{version});
    my $guests = $vmlist->{ids} // {};

    my $node = nodename();
    my $opts = PVE::RoutedIP::Config::effective_options();
    my $taps = local_taps();
    my $markers = list_markers();

    for my $tap (keys %$markers) {
        eval { marker_clear($tap) } if !$taps->{$tap};
    }

    my (%want_routes, %want_addrs, %protect_dev, %protect_cidr, %protect_addr, %rcfg, %qcfg);

    my $protect = sub {
        my ($tap, $nic) = @_;
        $protect_dev{$tap} = 1;
        $protect_cidr{$_} = 1 for ($nic ? $nic->{cidr}->@* : ());
    };

    for my $tap (sort keys %$taps) {
        my ($vmid, $idx) = $taps->{$tap}->@{qw(vmid idx)};
        my $netid = "net$idx";

        my $rconf = $rcfg{$vmid} //= eval { PVE::RoutedIP::Config::load_vm_config($vmid) };
        if (!$rconf) {
            push @$errors, "VM $vmid: unable to read routed IP config - $@";
            $protect->($tap);
            next;
        }
        my $nic = $rconf->{nics}->{$netid};

        if (!iface_is_up($tap)) {
            # QEMU just created it, pve-bridge (our tap_plug hook) did not run yet
            $protect->($tap, $nic);
            next;
        }

        my $entry = $guests->{$vmid};
        if (!$entry || ($entry->{node} // '') ne $node) {
            # config not here (yet/anymore): live migration in progress, hands off
            $protect->($tap, $nic);
            if ($nic && $entry) {
                # also the gateway addresses the hooks put on a shared bridge
                my $plan = eval {
                    my $qconf = PVE::RoutedIP::Config::load_qemu_config($vmid, $entry->{node});
                    my $net = PVE::RoutedIP::Config::parse_qemu_net($qconf->{$netid});
                    nic_plan($vmid, $idx, $nic, $net, $opts);
                };
                if ($plan) {
                    $protect_addr{"$_->[0]/$_->[1] $plan->{dev}"} = 1 for $plan->{gateways}->@*;
                }
            }
            next;
        }

        my $qconf = $qcfg{$vmid} //= eval { PVE::RoutedIP::Config::load_qemu_config($vmid) };
        my $net = $qconf ? PVE::RoutedIP::Config::parse_qemu_net($qconf->{$netid}) : undef;
        if (!$net) {
            push @$errors, "VM $vmid: unable to read $netid of guest config - "
                . ($@ || "no such network device\n")
                if $nic;
            $protect->($tap, $nic);
            next;
        }

        if (!$nic) {
            if ($markers->{$tap}) {
                eval { taponly_revert_and_plug($tap, $net) };
                push @$errors, "VM $vmid $netid: $@" if $@;
            }
            next;
        }

        my $plan = eval { nic_plan($vmid, $idx, $nic, $net, $opts) };
        if (!$plan) {
            push @$errors, "VM $vmid $netid: $@";
            $protect->($tap, $nic);
            next;
        }

        eval {
            if ($plan->{taponly}) {
                taponly_setup($plan);
            } elsif ($markers->{$tap}) {
                taponly_revert_and_plug($tap, $net);
            }
        };
        if (my $err = $@) {
            push @$errors, "VM $vmid $netid: $err";
            $protect->($tap, $nic);
            next;
        }

        for my $gw ($plan->{gateways}->@*) {
            my ($ip, $len) = @$gw;
            $want_addrs{"$ip/$len $plan->{dev}"} //= {
                ip => $ip,
                len => $len,
                dev => $plan->{dev},
                nodad => $plan->{taponly},
            };
        }
        for my $cidr ($plan->{cidrs}->@*) {
            if (my $other = $want_routes{$cidr}) {
                push @$errors, "VM $vmid $netid: $cidr is already routed to $other->{owner}\n";
                next;
            }
            $want_routes{$cidr} = { dev => $plan->{dev}, owner => "VM $vmid $netid" };
        }
    }

    # Add new gateway addresses before removing old ones: the kernel flushes all
    # IPv4 routes of a device once its last IPv4 address is gone.
    my $cur_addrs = kernel_addrs();

    for my $key (sort keys %want_addrs) {
        next if $cur_addrs->{$key};
        my $addr = $want_addrs{$key};
        eval { addr_add($addr->@{qw(ip len dev nodad)}) };
        push @$errors, $@ if $@;
    }

    for my $key (sort keys %$cur_addrs) {
        my $addr = $cur_addrs->{$key};
        next if $want_addrs{$key} || $protect_addr{$key} || $protect_dev{ $addr->{dev} };
        eval { addr_del($addr->@{qw(ip len dev)}) };
        push @$errors, $@ if $@;
    }

    my $cur_routes = kernel_routes();

    for my $cidr (sort keys %$cur_routes) {
        next if $protect_cidr{$cidr} || $want_routes{$cidr}; # wanted ones get replaced below
        for my $dev ($cur_routes->{$cidr}->@*) {
            next if $protect_dev{$dev};
            eval { route_del($cidr, $dev) };
            push @$errors, $@ if $@;
        }
    }

    for my $cidr (sort keys %want_routes) {
        my $want = $want_routes{$cidr};
        eval { route_set($cidr, $want->{dev}, $cur_routes->{$cidr}) };
        push @$errors, "$want->{owner}: $@" if $@;
    }
}

## uninstall

# Revert everything: plug tap-only taps back into their bridges and remove all
# routes and addresses we installed.
sub cleanup_all {
    my $errors = [];

    with_lock(sub {
        my $markers = list_markers();
        for my $tap (sort keys %$markers) {
            my ($vmid, $idx) = parse_tap($tap);
            eval {
                if (iface_exists($tap) && guest_config_is_local($vmid)) {
                    taponly_revert_and_plug($tap, guest_net($vmid, $idx));
                } else {
                    taponly_revert($tap);
                }
            };
            push @$errors, "$tap: $@" if $@;
        }

        my $routes = kernel_routes();
        for my $cidr (sort keys %$routes) {
            for my $dev ($routes->{$cidr}->@*) {
                eval { route_del($cidr, $dev) };
                push @$errors, $@ if $@;
            }
        }
        for my $addr (values kernel_addrs()->%*) {
            eval { addr_del($addr->@{qw(ip len dev)}) };
            push @$errors, $@ if $@;
        }
    });

    log_err($_) for @$errors;
    return $errors;
}

## status

sub forwarding_status {
    my $res = {};
    $res->{ipv4} = PVE::Tools::file_read_firstline('/proc/sys/net/ipv4/ip_forward') // 0;
    $res->{ipv6} = PVE::Tools::file_read_firstline('/proc/sys/net/ipv6/conf/all/forwarding') // 0;
    return $res;
}

# Runtime state of the routed NICs of one guest on this node.
sub vm_status {
    my ($vmid, $rconf, $qconf) = @_;

    my $opts = PVE::RoutedIP::Config::effective_options();
    my $routes = kernel_routes();
    my $local = guest_config_is_local($vmid);
    my $res = {};

    for my $netid (keys $rconf->{nics}->%*) {
        my ($idx) = $netid =~ m/^net(\d+)$/;
        my $nic = $rconf->{nics}->{$netid};
        my $tap = "tap${vmid}i$idx";
        my $st = { tap => iface_exists($tap) ? 1 : 0 };
        $res->{$netid} = $st;

        my $net = $qconf ? PVE::RoutedIP::Config::parse_qemu_net($qconf->{$netid}) : undef;
        if (!$net || !$net->{bridge}) {
            $st->{state} = 'error';
            $st->{error} = "guest has no bridged network device $netid";
            next;
        }

        my $plan = eval { nic_plan($vmid, $idx, $nic, $net, $opts) };
        if (!$plan) {
            $st->{state} = 'error';
            $st->{error} = $@ =~ s/\s+$//r;
            next;
        }
        $st->{device} = $plan->{dev};

        if (!$st->{tap}) {
            $st->{state} = 'stopped';
            next;
        }
        if (!$local) {
            $st->{state} = 'migrating';
            next;
        }

        $st->{master} = iface_master($tap) if $plan->{taponly};
        my @missing = grep {
            my $cidr = $_;
            !grep { $_ eq $plan->{dev} } ($routes->{$cidr} // [])->@*
        } $plan->{cidrs}->@*;

        if ($st->{master}) {
            $st->{state} = 'error';
            $st->{error} = "tap device is still plugged into $st->{master}";
        } elsif (@missing) {
            $st->{state} = 'error';
            $st->{error} = "missing routes: " . join(', ', @missing);
        } else {
            $st->{state} = 'active';
        }
    }

    return $res;
}

1;
