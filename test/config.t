#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use PVE::RoutedIP::Config;

my sub parse_error {
    my ($text) = @_;
    eval { PVE::RoutedIP::Config::parse_cidr($text) };
    return $@;
}

subtest 'any prefix length, canonical form' => sub {
    my $cases = [
        ['203.0.113.7', '203.0.113.7/32'],
        ['203.0.113.7/32', '203.0.113.7/32'],
        ['203.0.113.7/29', '203.0.113.0/29'],
        ['198.51.100.200/25', '198.51.100.128/25'],
        ['10.1.2.3/7', '10.0.0.0/7'],
        ['10.1.2.3/1', '0.0.0.0/1'],
        ['0.0.0.0/0', '0.0.0.0/0'],
        ['2001:DB8::1', '2001:db8::1/128'],
        ['2001:db8:0:0:1::5/64', '2001:db8::/64'],
        ['2001:db8:abcd:1234::/48', '2001:db8:abcd::/48'],
        ['2001:db8::1/127', '2001:db8::/127'],
        ['2001:db8::/3', '2000::/3'],
        ['::/0', '::/0'],
    ];
    for my $case (@$cases) {
        my ($in, $out) = @$case;
        is(PVE::RoutedIP::Config::canonical_cidr($in), $out, "$in -> $out");
    }
};

subtest 'invalid CIDRs' => sub {
    for my $bad (
        '203.0.113.7/33', '2001:db8::/129', '203.0.113', '203.0.113.256', '1.2.3.4/',
        '2001:db8:::1', 'example.com', '1.2.3.4/24/1', '',
    ) {
        ok(parse_error($bad), "'$bad' rejected");
    }
};

subtest 'overlap' => sub {
    my $overlap = \&PVE::RoutedIP::Config::cidr_overlap;
    ok($overlap->('203.0.113.0/29', '203.0.113.5/32'), 'network contains host');
    ok($overlap->('203.0.113.5/32', '203.0.113.0/29'), 'host inside network');
    ok($overlap->('0.0.0.0/0', '198.51.100.1/32'), 'default route contains all');
    ok(!$overlap->('203.0.113.0/29', '203.0.113.8/29'), 'adjacent networks');
    ok(!$overlap->('203.0.113.0/29', '2001:db8::/32'), 'different families');
    ok($overlap->('2001:db8::/32', '2001:db8:1::/48'), 'IPv6 containment');
    ok(!$overlap->('2001:db8::/48', '2001:db8:1::/48'), 'IPv6 disjoint');
};

subtest 'NIC property string' => sub {
    my $nic = PVE::RoutedIP::Config::parse_nic(
        'cidr=203.0.113.9/24;2001:db8::9/64;203.0.113.0/24,tap-only=1,rp-filter=1,gateway6=FE80::0001',
    );
    is_deeply($nic->{cidr}, ['203.0.113.0/24', '2001:db8::/64'], 'canonicalized, deduplicated');
    is($nic->{'tap-only'}, 1, 'tap-only');
    is($nic->{'rp-filter'}, 1, 'rp-filter');
    is($nic->{gateway6}, 'fe80::1', 'gateway canonicalized');

    my $raw = PVE::RoutedIP::Config::write_vm_config_string({
        nics => {
            net10 => $nic,
            net2 => { cidr => ['198.51.100.1/32'], 'tap-only' => 0, 'rp-filter' => 0 },
            net3 => { cidr => [], 'tap-only' => 0 },
        },
    });
    is(
        $raw,
        "net2: cidr=198.51.100.1/32\n"
            . "net10: cidr=203.0.113.0/24;2001:db8::/64,gateway6=fe80::1,rp-filter=1,tap-only=1\n",
        'written sorted by index, disabled flags and empty NIC dropped',
    );

    my $conf = PVE::RoutedIP::Config::parse_vm_config('test', $raw);
    is_deeply([sort keys $conf->{nics}->%*], ['net10', 'net2'], 'read back');
    is_deeply($conf->{nics}->{net10}, $nic, 'roundtrip');
    is($conf->{nics}->{net2}->{'rp-filter'}, 0, 'flag defaults to off');

    eval { PVE::RoutedIP::Config::parse_nic('cidr=203.0.113.1/40') };
    ok($@, 'invalid CIDR in NIC rejected');
};

subtest 'gateways' => sub {
    my $opts = PVE::RoutedIP::Config::effective_options({});
    my $gws = \&PVE::RoutedIP::Config::nic_gateways;

    is_deeply($gws->($opts, { cidr => ['203.0.113.1/32'] }), [['169.254.0.1', 32]], 'IPv4 only');
    is_deeply($gws->($opts, { cidr => ['2001:db8::/64'] }), [['fe80::1', 64]], 'IPv6 link-local /64');
    is_deeply(
        $gws->($opts, { cidr => ['2001:db8::/64'], gateway6 => '2001:db8:ffff::1' }),
        [['2001:db8:ffff::1', 128]],
        'global IPv6 override is a /128',
    );
    is_deeply(
        $gws->({ %$opts, gateway4 => '100.64.0.1' }, { cidr => ['203.0.113.1/32', '2001:db8::/64'] }),
        [['100.64.0.1', 32], ['fe80::1', 64]],
        'cluster option, both families',
    );
    is_deeply($gws->($opts, { cidr => [] }), [], 'no routes, no gateway');
};

subtest 'options' => sub {
    my $opts = PVE::RoutedIP::Config::parse_options(
        'test', "gateway6: FE80:0:0::0001\ngateway-mac: FE:00:00:00:00:01\n",
    );
    is($opts->{gateway6}, 'fe80::1', 'gateway6 canonicalized');
    is($opts->{'gateway-mac'}, 'fe:00:00:00:00:01', 'MAC lower case');

    my $effective = PVE::RoutedIP::Config::effective_options($opts);
    is($effective->{gateway4}, '169.254.0.1', 'default applied');

    for my $bad (
        'gateway4: 224.0.0.1', 'gateway4: 169.254.000.001', 'gateway6: ff02::1',
        'gateway-mac: 01:00:5e:00:00:01',
    ) {
        local $SIG{__WARN__} = sub { };
        my $parsed = PVE::RoutedIP::Config::parse_options('test', "$bad\n");
        my ($key) = $bad =~ m/^(\S+):/;
        ok(!defined($parsed->{$key}), "'$bad' rejected");
    }
};

subtest 'conflicts' => sub {
    my $all = {
        100 => PVE::RoutedIP::Config::parse_vm_config(
            '100', "net0: cidr=203.0.113.0/29;2001:db8:100::/48\n",
        ),
        101 => PVE::RoutedIP::Config::parse_vm_config('101', "net0: cidr=198.51.100.7\n"),
    };
    my $vmlist = { ids => { 100 => {}, 102 => {} } }; # 101 got destroyed
    my $check = sub {
        my ($vmid, $net, @cidrs) = @_;
        eval {
            PVE::RoutedIP::Config::check_cidr_conflicts($vmid, $net, [@cidrs], $all, $vmlist);
        };
        return $@;
    };

    ok(!$check->(100, 'net0', '203.0.113.0/29', '203.0.113.8/32'), 're-saving own NIC is fine');
    like($check->(102, 'net0', '203.0.113.5/32'), qr/overlaps with 203\.0\.113\.0\/29/, 'other VM');
    like($check->(100, 'net1', '2001:db8:100:5::/64'), qr/VM 100 \(net0\)/, 'other NIC, same VM');
    ok(!$check->(102, 'net0', '198.51.100.7/32'), 'config of destroyed VM ignored');
    like(
        $check->(102, 'net0', '192.0.2.0/24', '192.0.2.128/25'),
        qr/overlaps/,
        'overlap within one NIC',
    );
};

done_testing();
