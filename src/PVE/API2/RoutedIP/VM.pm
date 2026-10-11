package PVE::API2::RoutedIP::VM;

# /nodes/{node}/qemu/{vmid}/routedip: routed IPs of one guest, per NIC

use strict;
use warnings;

use PVE::Cluster;
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::Tools qw(extract_param);

use PVE::RoutedIP::Config;
use PVE::RoutedIP::Runtime;

use base qw(PVE::RESTHandler);

my $net_param = {
    type => 'string',
    pattern => 'net\d+',
    description => "Network device of the guest (netX).",
};

my $sort_nets = sub {
    return sort { ($a =~ s/^net//r) <=> ($b =~ s/^net//r) } @_;
};

# config of a QEMU guest, wherever in the cluster it currently lives
my sub load_guest {
    my ($vmid) = @_;

    my $guest = (PVE::Cluster::get_vmlist()->{ids} // {})->{$vmid}
        or die "VM $vmid does not exist\n";
    die "VM $vmid is not a QEMU virtual machine\n" if $guest->{type} ne 'qemu';

    return PVE::RoutedIP::Config::load_qemu_config($vmid, $guest->{node});
}

my sub apply_now {
    eval { PVE::RoutedIP::Runtime::reconcile() };
    warn "applying routed IP config failed - $@" if $@;
}

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "List the network devices of a guest with their routed IP configuration and"
        . " their state on the node.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                net => { type => 'string', description => "Network device." },
                bridge => { type => 'string', optional => 1 },
                tag => { type => 'integer', optional => 1 },
                macaddr => { type => 'string', optional => 1 },
                routed => { type => 'boolean', optional => 1 },
                missing => {
                    type => 'boolean',
                    optional => 1,
                    description => "Routed IP config exists, but the guest has no such NIC.",
                },
                gateways => {
                    type => 'string',
                    optional => 1,
                    description => "Effective host side gateway addresses.",
                },
                state => {
                    type => 'string',
                    enum => ['active', 'stopped', 'migrating', 'error'],
                    optional => 1,
                },
                device => {
                    type => 'string',
                    optional => 1,
                    description => "Device the routes point to.",
                },
                error => { type => 'string', optional => 1 },
                digest => get_standard_option('pve-config-digest'),
                PVE::RoutedIP::Config::nic_properties()->%*,
            },
        },
        links => [{ rel => 'child', href => "{net}" }],
    },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};
        my $qconf = load_guest($vmid);
        my $rconf = PVE::RoutedIP::Config::load_vm_config($vmid);
        my $opts = PVE::RoutedIP::Config::effective_options();

        my $status = eval { PVE::RoutedIP::Runtime::vm_status($vmid, $rconf, $qconf) } // {};
        my $status_err = $@;

        my %nets = map { $_ => 1 } grep { m/^net\d+$/ } keys %$qconf;
        $nets{$_} = 1 for keys $rconf->{nics}->%*;

        my $res = [];
        for my $netid ($sort_nets->(keys %nets)) {
            my $entry = { net => $netid, digest => $rconf->{digest} };

            if (my $net = PVE::RoutedIP::Config::parse_qemu_net($qconf->{$netid})) {
                $entry->{$_} = $net->{$_} for grep { defined($net->{$_}) } qw(bridge tag macaddr);
            } else {
                $entry->{missing} = 1;
            }

            if (my $nic = $rconf->{nics}->{$netid}) {
                $entry->{routed} = 1;
                $entry->{cidr} = join(';', $nic->{cidr}->@*);
                $entry->{'tap-only'} = $nic->{'tap-only'};
                $entry->{$_} = $nic->{$_} for grep { defined($nic->{$_}) } qw(gateway4 gateway6);
                $entry->{gateways} = join(
                    ' ', map { "$_->[0]/$_->[1]" } PVE::RoutedIP::Config::nic_gateways($opts, $nic)->@*,
                );

                my $st = $status->{$netid} // {};
                $entry->{$_} = $st->{$_} for grep { defined($st->{$_}) } qw(state device error);
                if ($status_err) {
                    $entry->{state} = 'error';
                    $entry->{error} = $status_err =~ s/\s+$//r;
                }
            }

            push @$res, $entry;
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'read_nic',
    path => '{net}',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "Get the routed IP configuration of a network device.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            net => $net_param,
        },
    },
    returns => {
        type => 'object',
        properties => {
            PVE::RoutedIP::Config::nic_properties()->%*,
            digest => get_standard_option('pve-config-digest'),
        },
    },
    code => sub {
        my ($param) = @_;

        my $rconf = PVE::RoutedIP::Config::load_vm_config($param->{vmid});
        my $res = { digest => $rconf->{digest} };

        if (my $nic = $rconf->{nics}->{ $param->{net} }) {
            $res->{cidr} = join(';', $nic->{cidr}->@*);
            $res->{'tap-only'} = $nic->{'tap-only'};
            $res->{$_} = $nic->{$_} for grep { defined($nic->{$_}) } qw(gateway4 gateway6);
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'update_nic',
    path => '{net}',
    method => 'PUT',
    protected => 1,
    proxyto => 'node',
    description => "Create or update the routed IP configuration of a network device. Changes are"
        . " applied to the running guest right away.",
    permissions => {
        description => "Routes are a host level resource, so 'Sys.Modify' on '/' is required"
            . " in addition to 'VM.Config.Network' on the guest.",
        check => [
            'and',
            ['perm', '/vms/{vmid}', ['VM.Config.Network']],
            ['perm', '/', ['Sys.Modify']],
        ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            net => $net_param,
            PVE::RoutedIP::Config::nic_properties()->%*,
            delete => {
                type => 'string',
                format => 'pve-configid-list',
                description => "A list of settings you want to delete.",
                optional => 1,
            },
            digest => get_standard_option('pve-config-digest'),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $vmid = extract_param($param, 'vmid');
        my $netid = extract_param($param, 'net');
        my $digest = extract_param($param, 'digest');
        my $delete = extract_param($param, 'delete');
        extract_param($param, 'node');

        my $known = PVE::RoutedIP::Config::nic_properties();

        PVE::RoutedIP::Config::lock_config(sub {
            my $qconf = load_guest($vmid);
            my $net = PVE::RoutedIP::Config::parse_qemu_net($qconf->{$netid});
            raise_param_exc({ net => "VM $vmid has no network device '$netid'" }) if !$net;
            raise_param_exc({ net => "'$netid' is not attached to a bridge, so it has no tap device" })
                if !$net->{bridge};

            my $rconf = PVE::RoutedIP::Config::load_vm_config($vmid);
            PVE::RoutedIP::Config::assert_digest($rconf, $digest);

            my $nic = $rconf->{nics}->{$netid} // { cidr => [], 'tap-only' => 0 };

            for my $key (PVE::Tools::split_list($delete)) {
                raise_param_exc({ delete => "unknown option '$key'" }) if !$known->{$key};
                raise_param_exc({ $key => "cannot set and delete at the same time" })
                    if defined($param->{$key});
                if ($key eq 'cidr') {
                    $nic->{cidr} = [];
                } elsif ($key eq 'tap-only') {
                    $nic->{'tap-only'} = 0;
                } else {
                    delete $nic->{$key};
                }
            }

            if (defined($param->{cidr})) {
                $nic->{cidr} = eval { PVE::RoutedIP::Config::parse_cidr_list($param->{cidr}) };
                raise_param_exc({ cidr => $@ }) if $@;
            }
            $nic->{'tap-only'} = $param->{'tap-only'} ? 1 : 0 if defined($param->{'tap-only'});
            for my $key (qw(gateway4 gateway6)) {
                $nic->{$key} = PVE::RoutedIP::Config::canonical_ip($param->{$key})
                    if defined($param->{$key});
            }

            PVE::RoutedIP::Config::check_cidr_conflicts(
                $vmid,
                $netid,
                $nic->{cidr},
                PVE::RoutedIP::Config::load_all_vm_configs(),
                PVE::Cluster::get_vmlist(),
            );

            $rconf->{nics}->{$netid} = $nic;
            PVE::RoutedIP::Config::write_vm_config($vmid, $rconf);
        });

        apply_now();

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'delete_nic',
    path => '{net}',
    method => 'DELETE',
    protected => 1,
    proxyto => 'node',
    description => "Remove the routed IP configuration of a network device. The change is applied"
        . " to the running guest right away.",
    permissions => {
        check => [
            'and',
            ['perm', '/vms/{vmid}', ['VM.Config.Network']],
            ['perm', '/', ['Sys.Modify']],
        ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            net => $net_param,
            digest => get_standard_option('pve-config-digest'),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my ($vmid, $netid) = $param->@{qw(vmid net)};

        PVE::RoutedIP::Config::lock_config(sub {
            my $rconf = PVE::RoutedIP::Config::load_vm_config($vmid);
            PVE::RoutedIP::Config::assert_digest($rconf, $param->{digest});
            die "no routed IP configuration for '$netid'\n" if !$rconf->{nics}->{$netid};
            delete $rconf->{nics}->{$netid};
            PVE::RoutedIP::Config::write_vm_config($vmid, $rconf);
        });

        apply_now();

        return undef;
    },
});

1;
