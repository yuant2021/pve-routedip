package PVE::RoutedIP::Config;

# Configuration of routed IPs, stored in the cluster file system:
#
#   /etc/pve/routedip/cluster.cfg   cluster wide options (fake gateway, tap MAC)
#   /etc/pve/routedip/<vmid>.cfg    routed NICs of one guest, one line per NIC:
#
#     net0: cidr=203.0.113.7/32;2001:db8:7::/64,tap-only=1
#
# Everything in here is pure configuration handling, see PVE::RoutedIP::Runtime
# for the kernel side.

use strict;
use warnings;

use Digest::SHA;
use Socket qw(AF_INET AF_INET6 inet_ntop inet_pton);

use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema;
use PVE::Tools;

our $CFG_DIR = '/etc/pve/routedip';
our $CLUSTER_CFG = "$CFG_DIR/cluster.cfg";

# Kernel protocol number of all routes and addresses we install. Named
# 'routedip' in /etc/iproute2/rt_protos.d/pve-routedip.conf, filter on it in
# bird with 'krt_source = 150'.
our $PROTO = 150;

my $default_options = {
    gateway4 => '169.254.0.1',
    gateway6 => 'fe80::1',
    'gateway-mac' => 'fe:ff:ff:ff:ff:ff',
};

sub default_options {
    return {%$default_options};
}

## CIDR handling (pure perl, used for validation and canonicalization)

my sub mask_packed {
    my ($packed, $len) = @_;

    my $bits = unpack('B*', $packed);
    substr($bits, $len) =~ tr/1/0/ if $len < length($bits);
    return pack('B*', $bits);
}

# Parse an IPv4/IPv6 address or network with any prefix length (a plain address
# is a host route). Host bits are cleared, so the result is canonical:
#   { family => 4|6, len => N, net => packed, cidr => '2001:db8::/64' }
sub parse_cidr {
    my ($text) = @_;

    die "missing CIDR\n" if !defined($text) || $text eq '';

    my ($ip, $len) = $text =~ m!^\s*([0-9A-Fa-f:.]+)(?:/(\d{1,3}))?\s*$!
        or die "invalid CIDR '$text'\n";

    my ($family, $af, $maxlen);
    if ($ip =~ m/:/) {
        ($family, $af, $maxlen) = (6, AF_INET6, 128);
    } else {
        ($family, $af, $maxlen) = (4, AF_INET, 32);
        die "invalid IPv4 address '$ip'\n" if $ip !~ m/^\d{1,3}(?:\.\d{1,3}){3}$/;
    }

    my $packed = inet_pton($af, $ip);
    die "invalid IPv$family address '$ip'\n" if !defined($packed);

    $len //= $maxlen;
    die "invalid prefix length /$len for IPv$family (0-$maxlen)\n" if $len > $maxlen;

    my $net = mask_packed($packed, $len);
    my $cidr = inet_ntop($af, $net) . "/$len";

    # inet_ntop output only contains these characters, safe to untaint
    ($cidr) = $cidr =~ m!^([0-9a-f:.]+/\d+)$! or die "internal error: bad CIDR '$cidr'\n";

    return { family => $family, len => $len + 0, net => $net, cidr => $cidr };
}

sub canonical_cidr {
    my ($text) = @_;
    return parse_cidr($text)->{cidr};
}

# canonical (and untainted) form of a single address
sub canonical_ip {
    my ($ip) = @_;
    my ($res) = canonical_cidr($ip) =~ m!^(.*)/\d+$!;
    return $res;
}

sub cidr_family {
    my ($cidr) = @_;
    return $cidr =~ m/:/ ? 6 : 4;
}

sub cidr_overlap {
    my ($a, $b) = @_;

    $a = parse_cidr($a) if !ref($a);
    $b = parse_cidr($b) if !ref($b);

    return 0 if $a->{family} != $b->{family};

    my $len = $a->{len} < $b->{len} ? $a->{len} : $b->{len};
    return mask_packed($a->{net}, $len) eq mask_packed($b->{net}, $len);
}

# A list of CIDR strings (separated by ';', ',' or whitespace), canonicalized,
# exact duplicates removed, order preserved.
sub parse_cidr_list {
    my ($value) = @_;

    my ($res, $seen) = ([], {});
    for my $item (PVE::Tools::split_list($value // '')) {
        my $cidr = canonical_cidr($item);
        push @$res, $cidr if !$seen->{$cidr}++;
    }
    return $res;
}

sub is_ipv6_link_local {
    my ($ip) = @_;
    return cidr_overlap("$ip/128", 'fe80::/10');
}

PVE::JSONSchema::register_format('pve-routedip-cidr', \&verify_cidr_format);

sub verify_cidr_format {
    my ($value, $noerr) = @_;

    eval { parse_cidr($value) };
    if (my $err = $@) {
        return undef if $noerr;
        die $err;
    }
    return $value;
}

PVE::JSONSchema::register_format('pve-routedip-gateway4', \&verify_gateway4);

sub verify_gateway4 {
    my ($value, $noerr) = @_;

    my $ok = PVE::JSONSchema::pve_verify_ipv4($value, 1)
        && !cidr_overlap("$value/32", '0.0.0.0/8')
        && !cidr_overlap("$value/32", '224.0.0.0/3');

    return $value if $ok;
    return undef if $noerr;
    die "value is not a usable unicast IPv4 address\n";
}

PVE::JSONSchema::register_format('pve-routedip-gateway6', \&verify_gateway6);

sub verify_gateway6 {
    my ($value, $noerr) = @_;

    my $ok = PVE::JSONSchema::pve_verify_ipv6($value, 1)
        && !cidr_overlap("$value/128", '::/127')
        && !cidr_overlap("$value/128", 'ff00::/8');

    return $value if $ok;
    return undef if $noerr;
    die "value is not a usable unicast IPv6 address\n";
}

## schema

my $nic_properties = {
    cidr => {
        type => 'string',
        format => 'pve-routedip-cidr-list',
        format_description => 'CIDR[;CIDR...]',
        description => "IPv4 and IPv6 addresses or networks (any prefix length) routed to"
            . " this network device. A plain address is a host route (/32 or /128).",
        optional => 1,
    },
    'tap-only' => {
        type => 'boolean',
        description => "Do not insert the tap device into the bridge. Routes and the gateway"
            . " addresses are configured directly on the tap device.",
        default => 0,
        optional => 1,
    },
    gateway4 => {
        type => 'string',
        format => 'pve-routedip-gateway4',
        description => "Override the host side IPv4 gateway address for this network device.",
        optional => 1,
    },
    gateway6 => {
        type => 'string',
        format => 'pve-routedip-gateway6',
        description => "Override the host side IPv6 gateway address for this network device.",
        optional => 1,
    },
};

sub nic_properties {
    return { map { $_ => {$nic_properties->{$_}->%*} } keys %$nic_properties };
}

my $option_properties = {
    gateway4 => {
        type => 'string',
        format => 'pve-routedip-gateway4',
        description => "IPv4 address the host uses as gateway towards routed guests.",
        default => $default_options->{gateway4},
        optional => 1,
    },
    gateway6 => {
        type => 'string',
        format => 'pve-routedip-gateway6',
        description => "IPv6 address the host uses as gateway towards routed guests. Link-local"
            . " addresses are configured as /64, global ones as /128.",
        default => $default_options->{gateway6},
        optional => 1,
    },
    'gateway-mac' => {
        type => 'string',
        format => 'mac-addr',
        description => "MAC address of tap-only tap devices. It is identical on all nodes, so"
            . " the guest's neighbor cache entry of the gateway stays valid across migration.",
        default => $default_options->{'gateway-mac'},
        optional => 1,
    },
};

sub option_properties {
    return { map { $_ => {$option_properties->{$_}->%*} } keys %$option_properties };
}

## parsing / writing

# Parse a NIC property string. Dies on invalid input.
sub parse_nic {
    my ($value) = @_;

    my $nic = PVE::JSONSchema::parse_property_string($nic_properties, $value);

    $nic->{cidr} = parse_cidr_list($nic->{cidr});
    $nic->{'tap-only'} = $nic->{'tap-only'} ? 1 : 0;
    for my $gw (qw(gateway4 gateway6)) {
        $nic->{$gw} = canonical_ip($nic->{$gw}) if defined($nic->{$gw});
    }

    return $nic;
}

sub print_nic {
    my ($nic) = @_;

    my $data = {%$nic};
    if (scalar($nic->{cidr}->@*)) {
        $data->{cidr} = join(';', $nic->{cidr}->@*);
    } else {
        delete $data->{cidr};
    }
    delete $data->{'tap-only'} if !$data->{'tap-only'};

    return PVE::JSONSchema::print_property_string($data, $nic_properties);
}

# the key: value config format shared by both files
my sub parse_lines {
    my ($filename, $raw, $handler) = @_;

    for my $line (split(/\n/, $raw // '')) {
        next if $line =~ m/^\s*(?:#.*)?$/;
        if ($line =~ m/^([a-z][a-z0-9\-]*):\s*(\S.*?)\s*$/) {
            my ($key, $value) = ($1, $2);
            eval { $handler->($key, $value) };
            warn "$filename: ignoring '$key' - $@" if $@;
        } else {
            warn "$filename: ignoring invalid line '$line'\n";
        }
    }
}

sub parse_vm_config {
    my ($filename, $raw) = @_;

    my $conf = { nics => {}, digest => Digest::SHA::sha1_hex($raw // '') };

    parse_lines(
        $filename,
        $raw,
        sub {
            my ($key, $value) = @_;
            die "unknown key\n" if $key !~ m/^net\d+$/;
            $conf->{nics}->{$key} = parse_nic($value);
        },
    );

    return $conf;
}

sub write_vm_config_string {
    my ($conf) = @_;

    my $raw = '';
    for my $netid (sort { ($a =~ s/^net//r) <=> ($b =~ s/^net//r) } keys $conf->{nics}->%*) {
        my $value = print_nic($conf->{nics}->{$netid});
        $raw .= "$netid: $value\n" if $value ne ''; # nothing set means not routed
    }
    return $raw;
}

sub parse_options {
    my ($filename, $raw) = @_;

    my $opts = { digest => Digest::SHA::sha1_hex($raw // '') };

    parse_lines(
        $filename,
        $raw,
        sub {
            my ($key, $value) = @_;
            my $schema = $option_properties->{$key} or die "unknown option\n";
            PVE::JSONSchema::check_format($schema->{format}, $value);
            if ($key eq 'gateway-mac') {
                ($opts->{$key}) = lc($value) =~ m/^([0-9a-f:]{17})$/;
            } else {
                $opts->{$key} = canonical_ip($value);
            }
        },
    );

    return $opts;
}

sub write_options_string {
    my ($opts) = @_;

    my $raw = '';
    for my $key (sort keys %$option_properties) {
        $raw .= "$key: $opts->{$key}\n" if defined($opts->{$key});
    }
    return $raw;
}

## file access

sub vm_config_path {
    my ($vmid) = @_;
    ($vmid) = $vmid =~ m/^(\d+)$/ or die "invalid VMID\n";
    return "$CFG_DIR/$vmid.cfg";
}

my sub read_file {
    my ($path) = @_;
    return undef if !-f $path;
    return PVE::Tools::file_get_contents($path);
}

sub has_vm_config {
    my ($vmid) = @_;
    return -f vm_config_path($vmid);
}

sub load_vm_config {
    my ($vmid) = @_;

    my $path = vm_config_path($vmid);
    return parse_vm_config($path, read_file($path));
}

sub write_vm_config {
    my ($vmid, $conf) = @_;

    my $path = vm_config_path($vmid);
    my $raw = write_vm_config_string($conf);

    if ($raw eq '') {
        unlink($path) or $!{ENOENT} or die "unable to delete '$path' - $!\n";
    } else {
        mkdir($CFG_DIR) if !-d $CFG_DIR;
        PVE::Tools::file_set_contents($path, $raw);
    }
}

sub delete_vm_config {
    my ($vmid) = @_;
    my $path = vm_config_path($vmid);
    unlink($path) or $!{ENOENT} or die "unable to delete '$path' - $!\n";
}

sub configured_vmids {
    my $res = [];
    return $res if !-d $CFG_DIR;
    PVE::Tools::dir_glob_foreach($CFG_DIR, '(\d+)\.cfg', sub { push @$res, $_[1] + 0 });
    return [sort { $a <=> $b } @$res];
}

sub load_all_vm_configs {
    my $res = {};
    for my $vmid (configured_vmids()->@*) {
        $res->{$vmid} = eval { load_vm_config($vmid) };
        warn $@ if $@;
    }
    return $res;
}

sub load_options {
    return parse_options($CLUSTER_CFG, read_file($CLUSTER_CFG));
}

sub write_options {
    my ($opts) = @_;
    mkdir($CFG_DIR) if !-d $CFG_DIR;
    PVE::Tools::file_set_contents($CLUSTER_CFG, write_options_string($opts));
}

# options with defaults applied
sub effective_options {
    my ($opts) = @_;

    $opts //= load_options();
    my $res = default_options();
    for my $key (keys %$option_properties) {
        $res->{$key} = $opts->{$key} if defined($opts->{$key});
    }
    return $res;
}

# cluster wide lock for all writes, also protects the overlap check
sub lock_config {
    my ($code, @param) = @_;

    require PVE::Cluster;
    my $res = PVE::Cluster::cfs_lock_domain('routedip', 10, $code, @param);
    die $@ if $@;
    return $res;
}

sub assert_digest {
    my ($conf, $digest) = @_;
    PVE::Tools::assert_if_modified($conf->{digest}, $digest) if $digest;
}

## validation helpers

# The gateway addresses a NIC needs, as [ip, prefix length] pairs. A family only
# gets a gateway if the NIC has routes of that family.
sub nic_gateways {
    my ($opts, $nic) = @_;

    my ($has4, $has6) = (0, 0);
    for my $cidr ($nic->{cidr}->@*) {
        if (cidr_family($cidr) == 4) { $has4 = 1 } else { $has6 = 1 }
    }

    my $res = [];
    push @$res, [canonical_ip($nic->{gateway4} // $opts->{gateway4}), 32] if $has4;
    if ($has6) {
        my $gw6 = canonical_ip($nic->{gateway6} // $opts->{gateway6});
        push @$res, [$gw6, is_ipv6_link_local($gw6) ? 64 : 128];
    }
    return $res;
}

# Die with a parameter exception if the CIDRs of (vmid, netid) overlap with each
# other or with any other routed NIC in the cluster. Entries of guests that do
# not exist anymore ($vmlist) are ignored.
sub check_cidr_conflicts {
    my ($vmid, $netid, $cidrs, $all_configs, $vmlist) = @_;

    my @mine = map { parse_cidr($_) } @$cidrs;
    for my $i (0 .. $#mine) {
        for my $j ($i + 1 .. $#mine) {
            raise_param_exc({
                cidr => "$mine[$i]->{cidr} overlaps with $mine[$j]->{cidr}",
            })
                if cidr_overlap($mine[$i], $mine[$j]);
        }
    }

    for my $other_vmid (sort { $a <=> $b } keys %$all_configs) {
        next if $vmlist && !$vmlist->{ids}->{$other_vmid};
        my $conf = $all_configs->{$other_vmid} or next;
        for my $other_net (sort keys $conf->{nics}->%*) {
            next if $other_vmid == $vmid && $other_net eq $netid;
            for my $other ($conf->{nics}->{$other_net}->{cidr}->@*) {
                my $parsed = parse_cidr($other);
                for my $cidr (@mine) {
                    raise_param_exc({
                        cidr => "$cidr->{cidr} overlaps with $other routed to VM"
                            . " $other_vmid ($other_net)",
                    })
                        if cidr_overlap($cidr, $parsed);
                }
            }
        }
    }
}

## guest NIC helpers (qemu-server)

sub parse_qemu_net {
    my ($value) = @_;

    return undef if !defined($value);

    if (eval { require PVE::QemuServer::Network; 1 }) {
        return PVE::QemuServer::Network::parse_net($value, 1);
    }
    require PVE::QemuServer;
    return PVE::QemuServer::parse_net($value, 1);
}

sub load_qemu_config {
    my ($vmid, $node) = @_;

    require PVE::QemuConfig;
    return PVE::QemuConfig->load_config($vmid, $node);
}

1;
