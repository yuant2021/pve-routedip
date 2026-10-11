package PVE::CLI::pve_routedip;

use strict;
use warnings;

use PVE::CLIFormatter;
use PVE::CLIHandler;
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::API2::RoutedIP;
use PVE::API2::RoutedIP::VM;
use PVE::RoutedIP::Config;
use PVE::RoutedIP::Runtime;

use base qw(PVE::CLIHandler);

my $nodename = PVE::INotify::nodename();

sub setup_environment {
    PVE::RPCEnvironment->setup_default_cli_env();
}

__PACKAGE__->register_method({
    name => 'status',
    path => 'status',
    method => 'GET',
    description => "Show the routes, gateway addresses and tap-only devices pve-routedip manages"
        . " on this node.",
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                type => { type => 'string', enum => ['route', 'address', 'tap-only'] },
                value => { type => 'string' },
                device => { type => 'string' },
            },
        },
    },
    code => sub {
        my $res = [];

        my $routes = PVE::RoutedIP::Runtime::kernel_routes();
        for my $cidr (sort keys %$routes) {
            push @$res, { type => 'route', value => $cidr, device => $_ } for $routes->{$cidr}->@*;
        }
        my $addrs = PVE::RoutedIP::Runtime::kernel_addrs();
        for my $key (sort keys %$addrs) {
            my $addr = $addrs->{$key};
            push @$res, { type => 'address', value => "$addr->{ip}/$addr->{len}", device => $addr->{dev} };
        }
        for my $tap (sort keys PVE::RoutedIP::Runtime::list_markers()->%*) {
            my $master = PVE::RoutedIP::Runtime::iface_master($tap);
            push @$res, {
                type => 'tap-only',
                value => $master ? "ERROR: plugged into $master" : 'not bridged',
                device => $tap,
            };
        }

        my $fwd = PVE::RoutedIP::Runtime::forwarding_status();
        warn "WARNING: IPv4 forwarding is disabled (net.ipv4.ip_forward)\n" if !$fwd->{ipv4};
        warn "WARNING: IPv6 forwarding is disabled (net.ipv6.conf.all.forwarding)\n"
            if !$fwd->{ipv6};

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'apply',
    path => 'apply',
    method => 'POST',
    description => "Bring the kernel state of this node in line with the configuration now"
        . " (pve-routedipd does this continuously).",
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => { type => 'null' },
    code => sub {
        my $errors = PVE::RoutedIP::Runtime::reconcile(1);
        die join('', @$errors) if @$errors;
        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'cleanup',
    path => 'cleanup',
    method => 'POST',
    description => "Remove all routes and gateway addresses installed by pve-routedip on this"
        . " node and plug tap-only devices back into their bridges. Used when uninstalling;"
        . " stop pve-routedipd first, or it will set everything up again.",
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => { type => 'null' },
    code => sub {
        my $errors = PVE::RoutedIP::Runtime::cleanup_all();
        die "cleanup finished with errors\n" if @$errors;
        return undef;
    },
});

my $print_status = sub {
    my ($data, $schema, $options) = @_;
    PVE::CLIFormatter::print_api_result($data, $schema, ['type', 'device', 'value'], $options);
};

my $print_list = sub {
    my ($data, $schema, $options) = @_;
    PVE::CLIFormatter::print_api_result(
        $data, $schema, ['vmid', 'net', 'node', 'tap-only', 'cidr', 'gateway4', 'gateway6'], $options,
    );
};

my $print_vm = sub {
    my ($data, $schema, $options) = @_;
    my $routed = [grep { $_->{routed} } @$data];
    PVE::CLIFormatter::print_api_result(
        $routed, $schema, ['net', 'bridge', 'tap-only', 'cidr', 'gateways', 'device', 'state', 'error'],
        $options,
    );
};

my $print_options = sub {
    my ($data, $schema, $options) = @_;
    my $effective = PVE::RoutedIP::Config::effective_options($data);
    PVE::CLIFormatter::print_api_result($effective, $schema, undef, $options);
};

our $cmddef = {
    status => [__PACKAGE__, 'status', [], {}, $print_status, $PVE::RESTHandler::standard_output_options],
    apply => [__PACKAGE__, 'apply', []],
    cleanup => [__PACKAGE__, 'cleanup', []],
    list => ['PVE::API2::RoutedIP', 'list_vms', [], {}, $print_list, $PVE::RESTHandler::standard_output_options],
    show => ['PVE::API2::RoutedIP::VM', 'index', ['vmid'], { node => $nodename }, $print_vm, $PVE::RESTHandler::standard_output_options],
    set => ['PVE::API2::RoutedIP::VM', 'update_nic', ['vmid', 'net'], { node => $nodename }],
    delete => ['PVE::API2::RoutedIP::VM', 'delete_nic', ['vmid', 'net'], { node => $nodename }],
    options => {
        get => ['PVE::API2::RoutedIP', 'get_options', [], {}, $print_options, $PVE::RESTHandler::standard_output_options],
        set => ['PVE::API2::RoutedIP', 'set_options', []],
    },
};

1;
