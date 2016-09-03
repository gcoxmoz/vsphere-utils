#!/usr/bin/perl -w
#
# gcox@mozilla
#
use strict;
use warnings;
use VMware::VIRuntime;
$SIG{__DIE__} = sub{Util::disconnect()};
$Util::script_version = '1.0';

#
# This script checks the existence and contents of ClusterHostGroups
# It's a little naive and Mozilla-specific, checking across clusters
# for 3 groups in each cluster:
# Do we have even numbered hosts grouped in each cluster?
# Do we have odd  numbered hosts grouped in each cluster?
# Do we have a group of the highest numbered host in the cluster?
#
# We DO NOT check that there is a rule tying to them.
# For even/odds, there does not necessarily need to be a rabbit
# or elasticsearch tie on a given cluster.
#
# You probably want to use this in conjunction with vm-drs-separation
#

my %opts = (
  'clusterName' => { type => '=s', help => 'Cluster name', required => 0},
  );

# At Mozilla, by tribal knowledge, we pin the vCenter Server on the highest numbered host
# so that in the event of a failure, we know where it's likely to be found, rather than
# having to go iterating over the farm to find it.
my $evens_group_name   = 'Even Hosts';
my $odds_group_name    = 'Odd Hosts';
my $vc_host_group_name = 'VC Hosts';

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
searchGroups();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub even_odd_hash (@) {
    my %ret = ();
    foreach my $hostname (@_) {
        my $copy_hostname = $hostname;
        $copy_hostname =~ s#\..+$##;
        $copy_hostname =~ s#\D##g;
        push(@{ $ret{($copy_hostname % 2) ? 'odd' : 'even'} }, $hostname);
    }
    return %ret;
}

sub searchGroups {
    # Find the Cluster
    my $clusterName = Opts::get_option('clusterName');
    my $clusters_ref = Vim::find_entity_views(view_type => 'ClusterComputeResource', properties => ['name', 'configurationEx'], filter => $clusterName ? { name => $clusterName } : {} );
    if (!@{$clusters_ref}) { Util::trace(0, "ComputeResource '" . $clusterName . "' not found\n"); return; }

    my $found_vc_group = 0;

    foreach my $cluster_ref (@{$clusters_ref}) {
        print '# Cluster '.  $cluster_ref->name . "\n";

        my $hosts_ref = Vim::find_entity_views(view_type => 'HostSystem', begin_entity => $cluster_ref, properties => ['name', ], );
        if (!$hosts_ref) { Util::trace(0, "No hosts found for ComputeResource '" . $cluster_ref->name . "'\n"); next; }
        my @hosts = ();
        foreach my $host (@{$hosts_ref}) {
           push(@hosts, $host);
        }
        @hosts = map { $_->name } sort { $a->name cmp $b->name } @hosts;

        my $groups = $cluster_ref->configurationEx->group;
        my @hostgroups = ();
        #my @vmgroups   = ();
        if (!$groups) {
            Util::trace(0, "Warning: No groups found for ComputeResource '" . $cluster_ref->name . "'\n");
        } else {
            foreach my $group (@{$groups}) {
                if ($group->isa('ClusterHostGroup')) {
                    push(@hostgroups, $group);
                #} elsif ($group->isa('ClusterVmGroup')) {
                #    push(@vmgroups, $group);
                }
            }
        }

        my $found_evens_group = 0;
        my $found_odds_group = 0;
        foreach my $group (sort { $a->name cmp $b->name } @hostgroups) {
            my $group_hosts_arrayref = $group->host;
            my $host_ref = Vim::get_views(view_type => 'HostSystem', mo_ref_array => $group_hosts_arrayref, properties => ['name', ], );
            my @host_names = map { $_->name } @$host_ref;
            if ($group->name eq $vc_host_group_name) {
                $found_vc_group = 1;
                my $numhosts = $group_hosts_arrayref ? scalar @{$group_hosts_arrayref} : 0;
                if ($numhosts != 1) {
                    print "### Hostgroup '$vc_host_group_name' has $numhosts hosts instead of 1.\n";
                } else {
                    print "### Found a '$vc_host_group_name' hostgroup on cluster " . $cluster_ref->name . " ...\n";
                    my $largest_cluster_host = $hosts[$#hosts];
                    my $host_name = $host_names[0];
                    if ($host_name eq $largest_cluster_host) {
                        print "### ... points correctly to host $host_name\n";
                    } else {
                        print "### ... points INCORRECTLY to host $host_name when $largest_cluster_host seems larger.\n";
                    }
                }
            } elsif ($group->name eq $evens_group_name) {
                $found_evens_group = 1;
                print "### Found a '$evens_group_name' hostgroup on cluster " . $cluster_ref->name . " ...\n";
                my %host_findings  = even_odd_hash(@hosts);
                my %group_findings = even_odd_hash(@host_names);
                if ($group_findings{'odd'}) {
                    print "### ... which INCORRECTLY contains odds: ", join(' ', sort @{$group_findings{'odd'}}), "\n";
                }
                my %known_evenhosts = map { $_ => 1 } @{$host_findings{'even'}};
                foreach my $hostname (@{$group_findings{'even'}}) {
                    delete $known_evenhosts{$hostname};
                }
                if (keys %known_evenhosts) {
                    print "### ... which INCORRECTLY missed including: ", join(' ', sort keys %known_evenhosts), "\n";
                } else {
                    print "### ... which correctly contains the found even hosts.\n";
                }
            } elsif ($group->name eq $odds_group_name) {
                $found_odds_group = 1;
                print "### Found a '$odds_group_name' hostgroup on cluster " . $cluster_ref->name . " ...\n";
                my %host_findings  = even_odd_hash(@hosts);
                my %group_findings = even_odd_hash(@host_names);
                if ($group_findings{'even'}) {
                    print "### ... which INCORRECTLY contains evens: ", join(' ', sort @{$group_findings{'even'}}), "\n";
                }
                my %known_oddhosts = map { $_ => 1 } @{$host_findings{'odd'}};
                foreach my $hostname (@{$group_findings{'odd'}}) {
                    delete $known_oddhosts{$hostname};
                }
                if (keys %known_oddhosts) {
                    print "### ... which INCORRECTLY missed including: ", join(' ', sort keys %known_oddhosts), "\n";
                } else {
                    print "### ... which correctly contains the found odd hosts.\n";
                }
            } else {
                print "### Found a hostgroup of '".$group->name."'\n";
            }
        }
        if (!$found_evens_group) {
            print "### Did not find a '$evens_group_name' group on cluster ". $cluster_ref->name .".\n";
        }
        if (!$found_odds_group) {
            print "### Did not find a '$odds_group_name' group on cluster ". $cluster_ref->name .".\n";
        }
    }

    if (!$found_vc_group) {
        print "### Did not find a '$vc_host_group_name' group on any cluster.\n";
    }

}
