package PVE::RoutedIP::Daemon;

# pve-routedipd: keeps the kernel state of this node in line with the routed
# IP configuration. The PVE::Network hooks react to guest start/stop, NIC
# changes and live migration right away; this loop covers everything else:
#
#  - configuration changes made on other nodes (cluster options, guests),
#  - the final hand-over of a live migration once pmxcfs moved the config,
#  - drift (manually removed routes, re-created bridges, crashed guests),
#  - removal of routed IP configs of guests that were destroyed.

use strict;
use warnings;

use Digest::SHA;
use Time::HiRes qw(sleep time);

use PVE::Cluster;
use PVE::INotify;
use PVE::SafeSyslog;
use PVE::Tools;

use PVE::RoutedIP::Config;
use PVE::RoutedIP::Runtime;

my $INTERVAL = 1; # seconds between checks
my $RESYNC = 30; # full reconcile at least this often
my $ORPHAN_GRACE = 60; # seconds a guest must be gone before its config is removed

# Cheap fingerprint of everything the reconcile result depends on.
sub signature {
    my ($guests) = @_;

    my $sha = Digest::SHA->new(1);
    my $add_file = sub {
        my ($path) = @_;
        my $raw = -f $path ? PVE::Tools::file_get_contents($path) : '';
        $sha->add("$path\0$raw\0");
    };

    $add_file->($PVE::RoutedIP::Config::CLUSTER_CFG);

    # sysctl reloads reset these, see PVE::RoutedIP::Runtime::rp_filter_all_update()
    $sha->add('rp_filter:' . PVE::RoutedIP::Runtime::rp_filter_value('all') . "\0");

    my $taps = PVE::RoutedIP::Runtime::local_taps();
    my %vmids;
    for my $tap (sort keys %$taps) {
        my $master = PVE::RoutedIP::Runtime::iface_master($tap) // '';
        my $up = PVE::RoutedIP::Runtime::iface_is_up($tap) ? 1 : 0;
        my $rpf = PVE::RoutedIP::Runtime::rp_filter_value($tap);
        $sha->add("$tap:$master:$up:$rpf\0");
        $vmids{ $taps->{$tap}->{vmid} } = 1;
    }

    for my $vmid (sort { $a <=> $b } keys %vmids) {
        my $entry = $guests->{$vmid} // {};
        $sha->add(join(':', $vmid, $entry->{node} // '', $entry->{version} // '') . "\0");
        $add_file->(PVE::RoutedIP::Config::vm_config_path($vmid));
    }

    $sha->add(join(',', sort keys PVE::RoutedIP::Runtime::list_markers()->%*));

    return $sha->hexdigest;
}

sub gc_orphans {
    my ($guests, $missing_since) = @_;

    return if !PVE::Cluster::check_cfs_quorum(1);

    my $now = time();
    my %configured = map { $_ => 1 } PVE::RoutedIP::Config::configured_vmids()->@*;

    for my $vmid (keys %$missing_since) {
        delete $missing_since->{$vmid} if !$configured{$vmid} || $guests->{$vmid};
    }

    for my $vmid (sort { $a <=> $b } keys %configured) {
        next if $guests->{$vmid};
        my $since = $missing_since->{$vmid} //= $now;
        next if $now - $since < $ORPHAN_GRACE;

        delete $missing_since->{$vmid};
        eval {
            PVE::RoutedIP::Config::lock_config(sub {
                # cfs_lock_domain() refreshed the guest list
                return if (PVE::Cluster::get_vmlist()->{ids} // {})->{$vmid};
                return if !PVE::RoutedIP::Config::has_vm_config($vmid);
                PVE::RoutedIP::Config::delete_vm_config($vmid);
                PVE::RoutedIP::Runtime::log_info("removed routed IP config of deleted VM $vmid");
            });
        };
        PVE::RoutedIP::Runtime::log_err("unable to remove config of deleted VM $vmid - $@") if $@;
    }
}

sub run {
    my $stop = 0;
    my $force = 1;

    local $SIG{TERM} = sub { $stop = 1 };
    local $SIG{INT} = sub { $stop = 1 };
    local $SIG{HUP} = sub { $force = 1 };

    local $PVE::RoutedIP::Runtime::LOG_STDERR = 0;

    my ($last_sig, $last_full, $last_gc, $last_errors) = ('', 0, 0, '');
    my $missing_since = {};

    PVE::RoutedIP::Runtime::log_info("pve-routedipd started");

    while (!$stop) {
        my $errors = eval {
            PVE::Cluster::cfs_update(1);
            my $vmlist = PVE::Cluster::get_vmlist();
            die "unable to read guest list from pmxcfs\n" if !defined($vmlist->{version});
            my $guests = $vmlist->{ids} // {};

            my $now = time();
            my $res;
            if ($force || $now - $last_full >= $RESYNC || signature($guests) ne $last_sig) {
                $force = 0;
                $res = PVE::RoutedIP::Runtime::reconcile(1);
                $last_full = $now;
                $last_sig = signature($guests);
            }

            if ($now - $last_gc >= 10) {
                $last_gc = $now;
                gc_orphans($guests, $missing_since);
            }

            return $res;
        };
        $errors = [$@] if $@;

        # only log changes, a persistent problem should not flood the log
        if (defined($errors)) {
            my $text = join('', @$errors);
            if ($text ne $last_errors) {
                PVE::RoutedIP::Runtime::log_err($_) for @$errors;
                PVE::RoutedIP::Runtime::log_info("all routed IP errors resolved")
                    if $text eq '' && $last_errors ne '';
                $last_errors = $text;
            }
        }

        sleep($INTERVAL) if !$stop;
    }

    PVE::RoutedIP::Runtime::log_info("pve-routedipd stopped");
}

1;
