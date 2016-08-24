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
# DVswitches are great, but they are annoying to click around and security audit.
# Our opsec folks hate promiscuous mode, but sometimes you need it (nested hypervisors)
# This lint script goes through and tells us where we have security openings.
# If we're lucky, it's just on portgroups where we expect it.
#

my %opts = (
  'clusterName' => { type => '=s', help => 'Cluster name', required => 0},
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
my @vms = check_all_DVSes();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub check_all_DVSes {
    my $dvses = Vim::find_entity_views(view_type => 'VmwareDistributedVirtualSwitch', properties => ['name', 'portgroup', ], );
    if (!$dvses) { print "Search for VmwareDistributedVirtualSwitch failed.\n"; return (); }
    if (!(scalar @{$dvses})) { print "Found no VmwareDistributedVirtualSwitch.\n"; return (); }
    foreach my $dvs (@{$dvses}) {
      print $dvs->get_property('name')."\n";

      my $pg_refs = $dvs->get_property('portgroup');
      if (!(scalar @{$pg_refs})) { print "Found no portgroups in this VmwareDistributedVirtualSwitch.\n"; next; }
      my $pgs = Vim::get_views(mo_ref_array => $pg_refs, );
      foreach my $pg_ref (sort { lc($a->name) cmp lc($b->name) } @{$pgs}) {
          print '  '. $pg_ref->name;
          my $config = $pg_ref->config;  # DVPortgroupConfigInfo
          #print '  '. $config->portNameFormat .  '  '. $config->numPorts .  '  '. $config->key .  "\n";
          my $secpol = $config->defaultPortConfig->securityPolicy;
          if ($secpol->allowPromiscuous->value) { print ' (promiscuous)'; }
          if ($secpol->forgedTransmits->value)  { print ' (forged-xmits)'; }
          if ($secpol->macChanges->value)       { print ' (MACchanges)'; }
          print "\n";
      }

    }
    return @vms;
}
