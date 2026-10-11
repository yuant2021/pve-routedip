package PVE::API2::RoutedIP;

# /cluster/routedip: cluster wide options and an overview of all routed NICs

use strict;
use warnings;

use PVE::Cluster;
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Tools qw(extract_param);

use PVE::API2::RoutedIP::VM;
use PVE::RoutedIP::Config;
use PVE::RoutedIP::Runtime;

use base qw(PVE::RESTHandler);

my $registered;

# called by the PVE::API2 wrapper module
sub register_api {
    return if $registered;
    $registered = 1;

    require PVE::API2::Cluster;
    require PVE::API2::Qemu;

    PVE::API2::Cluster->register_method({
        subclass => 'PVE::API2::RoutedIP',
        path => 'routedip',
    });
    PVE::API2::Qemu->register_method({
        subclass => 'PVE::API2::RoutedIP::VM',
        path => '{vmid}/routedip',
    });
}

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Directory index.",
    permissions => { user => 'all' },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => { name => { type => 'string' } },
        },
        links => [{ rel => 'child', href => "{name}" }],
    },
    code => sub {
        return [{ name => 'options' }, { name => 'vms' }];
    },
});

__PACKAGE__->register_method({
    name => 'get_options',
    path => 'options',
    method => 'GET',
    description => "Get the cluster wide routed IP options.",
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'object',
        properties => {
            PVE::RoutedIP::Config::option_properties()->%*,
            digest => get_standard_option('pve-config-digest'),
        },
    },
    code => sub {
        return PVE::RoutedIP::Config::load_options();
    },
});

__PACKAGE__->register_method({
    name => 'set_options',
    path => 'options',
    method => 'PUT',
    protected => 1,
    description => "Update the cluster wide routed IP options. Changes are applied to running"
        . " guests on all nodes right away.",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            PVE::RoutedIP::Config::option_properties()->%*,
            delete => {
                type => 'string',
                format => 'pve-configid-list',
                description => "A list of settings you want to reset to their default.",
                optional => 1,
            },
            digest => get_standard_option('pve-config-digest'),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $digest = extract_param($param, 'digest');
        my $delete = extract_param($param, 'delete');
        my $known = PVE::RoutedIP::Config::option_properties();

        PVE::RoutedIP::Config::lock_config(sub {
            my $opts = PVE::RoutedIP::Config::load_options();
            PVE::RoutedIP::Config::assert_digest($opts, $digest);
            delete $opts->{digest};

            for my $key (PVE::Tools::split_list($delete)) {
                raise_param_exc({ delete => "unknown option '$key'" }) if !$known->{$key};
                raise_param_exc({ $key => "cannot set and delete at the same time" })
                    if defined($param->{$key});
                delete $opts->{$key};
            }

            for my $key (keys %$param) {
                $opts->{$key} = $key eq 'gateway-mac'
                    ? lc($param->{$key})
                    : PVE::RoutedIP::Config::canonical_ip($param->{$key});
            }

            PVE::RoutedIP::Config::write_options($opts);
        });

        # this node now, all others within a second (pve-routedipd)
        eval { PVE::RoutedIP::Runtime::reconcile() };
        warn "applying routed IP config failed - $@" if $@;

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'list_vms',
    path => 'vms',
    method => 'GET',
    description => "List the routed network devices of all guests.",
    permissions => {
        description => "Only guests with 'VM.Audit' permission are listed.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                vmid => get_standard_option('pve-vmid'),
                net => { type => 'string', description => "Network device." },
                node => {
                    type => 'string',
                    optional => 1,
                    description => "Node the guest config is on.",
                },
                orphan => {
                    type => 'boolean',
                    optional => 1,
                    description => "The guest does not exist (anymore).",
                },
                PVE::RoutedIP::Config::nic_properties()->%*,
            },
        },
    },
    code => sub {
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $guests = PVE::Cluster::get_vmlist()->{ids} // {};
        my $all = PVE::RoutedIP::Config::load_all_vm_configs();

        my $res = [];
        for my $vmid (sort { $a <=> $b } keys %$all) {
            next if !$rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit'], 1);
            my $conf = $all->{$vmid} or next;
            my $guest = $guests->{$vmid};
            for my $netid (sort { ($a =~ s/^net//r) <=> ($b =~ s/^net//r) } keys $conf->{nics}->%*) {
                my $nic = $conf->{nics}->{$netid};
                my $entry = {
                    vmid => $vmid + 0,
                    net => $netid,
                    cidr => join(';', $nic->{cidr}->@*),
                    'tap-only' => $nic->{'tap-only'},
                };
                $entry->{$_} = $nic->{$_} for grep { defined($nic->{$_}) } qw(gateway4 gateway6);
                if ($guest) {
                    $entry->{node} = $guest->{node};
                } else {
                    $entry->{orphan} = 1;
                }
                push @$res, $entry;
            }
        }

        return $res;
    },
});

1;
