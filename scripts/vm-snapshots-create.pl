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
# When you need to snapshot an environment's worth of VMs all at once
#

use POSIX qw(strftime);
my $now_string = strftime "%Y%m%d-%H%M%S", gmtime;

my %opts = (
  'snapname' => { type => '=s', help => 'Snapshot name', required => 0},
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my %target_vms = map { $_ => 1 } @ARGV;
my %found_vms  = ();

my $default_snap_name = $ENV{USER}.'-'.$now_string;
my $snap_name = Opts::get_option('snapname') || $default_snap_name;


sub snap_vms() {
    my $vms = Vim::find_entity_views(view_type => 'VirtualMachine', properties => ['name', 'config.template', ], );
    if (!$vms) { Util::trace(0, "No vms found.'\n"); return; }
    foreach my $vm (@$vms) {
      next if ($vm->get_property('config.template') eq 'true');
      my $vm_name = $vm->name;
      next unless ($target_vms{$vm_name});
      $found_vms{$vm_name} = $vm;
    }

    my %temp1 = %target_vms;
    foreach my $k (keys %found_vms) { delete $temp1{$k}; }
    if (scalar keys %temp1) {
      print "Requested VMs not found in VM list: " . join(' ', sort keys %temp1) ."\n";
      print "Aborting.\n";
      exit 1;
    }
    my %temp2 = %found_vms;
    foreach my $k (keys %target_vms) { delete $temp2{$k}; }
    if (scalar keys %temp2) {
      print "I found more VMs than you asked for: " . join(' ', sort keys %temp2) ."\n";
      print "That's a neat trick.  Aborting.\n";
      exit 1;
    }

    foreach my $vm_name (sort keys %found_vms) {
      print "Found $vm_name\n";
      my $vm = $found_vms{$vm_name};
      $vm->CreateSnapshot_Task(name => $snap_name, memory => 'true', quiesce => 'true', );
    }
}


# connect to the server
Util::connect(); #print "Server Connected\n";
snap_vms();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";
