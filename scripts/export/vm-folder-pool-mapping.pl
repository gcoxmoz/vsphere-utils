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
# For the most part we keep our VM Folders named the same as Resource Pools.
# This script goes through and, for each VM, finds ones where their pool name != folder name
# This is just an OCD lint checker.
#

use JSON;
my %opts = (
    'json'        => { type => '',   help => 'Export listing as JSON', required => 0},
    'audit'       => { type => '',   help => 'Print all mappings', required => 0},
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
my @output = ();
check_all_folders();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";
sub check_from_folder($);


sub check_from_folder ($) {
    my $folder = shift;
    my $thisfolder = $folder->name;
    #print $thisfolder."\n";
    my $vms = Vim::get_views(mo_ref_array => $folder->childEntity, view_type => 'VirtualMachine', properties => ['name','config.template','resourcePool'] );
    foreach my $vmref (@$vms) {
        # Skip templates.
        next if ($vmref->get_property('config.template') eq 'true');
        my $respool = Vim::get_view(mo_ref => $vmref->resourcePool, properties => ['name', ] );
        my $thispool = $respool->name;
        if (Opts::get_option('audit') || ($thispool ne $thisfolder)) {
            push @output, { 'VM' => $vmref->name, 'resourcePool' => $thispool, 'Folder' => $thisfolder, };
        }
    }
}


sub check_all_folders {
    my $folders = Vim::find_entity_views(view_type => 'Folder', );
    if (!$folders) { print "Search for Folders failed.\n"; return (); }
    if (!(scalar @{$folders})) { print "Found no Folders.\n"; return (); }
    foreach my $folder (@{$folders}) {
        my %childtypes = map { $_ => 1 } @{$folder->childType};
        next unless ($childtypes{'VirtualMachine'});  # Only work on folders that can hold VMs
        check_from_folder($folder);
    }
    if (Opts::get_option('json')) {
        print to_json(\@output, {utf8 => 1, pretty => 1, canonical => 1, });
    } else {
        foreach my $ref (@output) {
            print 'VM: "' .$ref->{'VM'} . '" resourcePool: "'. $ref->{'resourcePool'} . '" Folder: "' . $ref->{'Folder'} . '"' . "\n";
        }
    }
}
