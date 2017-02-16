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
# Find a misbehaving VM when your netops people come running to you
# with a MAC address.  Dump all the addresses, and grep away.
#

use JSON;
my %opts = (
    'json' => { type => '',   help => 'Export listing as JSON', required => 0},
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
my @output = ();
searchMACs();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub searchMACs {
    my $vms = Vim::find_entity_views(view_type => 'VirtualMachine', properties => ['name', 'config.hardware.device', ], );
    if (!$vms) { Util::trace(0, "No vms found '\n"); return; }

    foreach my $vm (sort { $a->name cmp $b->name } @$vms) {
        my $vm_name = $vm->name;

        my $hwlist_ref = $vm->get_property('config.hardware.device');
        if (scalar(@{$hwlist_ref}) < 1) {
            print "### VM '$vm_name' doesn't have a network(?)\n";
            next;
        }
        foreach my $dev (@{$hwlist_ref}) {
            next unless (ref($dev)->isa('VirtualEthernetCard'));
            if (Opts::get_option('json')) {
                my $json_blob; %{$json_blob} = ();
                $json_blob->{'vm'}          = $vm_name;
                $json_blob->{'macAddress'}  = $dev->macAddress;
                $json_blob->{'addressType'} = $dev->addressType;
                push @output, $json_blob;
            } else {
                print '"'. $vm_name . '" ' . $dev->macAddress . ' ' . $dev->addressType . "\n";
            }
        }
    }

    if (Opts::get_option('json')) {
        print to_json(\@output, {utf8 => 1, pretty => 1, canonical => 1, });
    }
}
