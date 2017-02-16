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
# This script goes through and shows a nested list of your folders
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
list_all_folders();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

sub search_from_folder {
    my ($parentage_ref, $folder_ref, ) = @_;
    if (Opts::get_option('json')) {
        my $json_blob; %{$json_blob} = %$parentage_ref;
        $json_blob->{'folder'} = $folder_ref->name;
        push @output, $json_blob;
    } else {
        my $whoami = $parentage_ref->{'datacenter'}.'/'.$parentage_ref->{'parentage'}.'/'.$folder_ref->name;
        print "$whoami\n";
    }
    my $blob; %{$blob} = %$parentage_ref;
    $blob->{'parentage'} = $parentage_ref->{'parentage'}.'/'.$folder_ref->name;
    my $subfolders = Vim::get_views( mo_ref_array => $folder_ref->childEntity, view_type => 'Folder', );
    if (!$subfolders) { print "Search for Folders failed.\n"; return; }
    if (!(scalar @{$subfolders})) { return; } # Don't print anything, coming up empty is expected on leaf nodes.
    foreach my $subfolder (sort {$a->name cmp $b->name} @{$subfolders}) {
        search_from_folder($blob, $subfolder, );
    }
}

sub list_all_folders {
    my $servicecontent = Vim::get_service_content();
    my $rootfolder     = Vim::get_view( mo_ref => $servicecontent->rootFolder, );
    my $dcs            = Vim::get_views( mo_ref_array => $rootfolder->childEntity, view_type => 'Datacenter', );
    if (!$dcs) { print "Search for Datacenters failed.\n"; return; }
    if (!(scalar @{$dcs})) { print "No Datacenters found.\n"; return; }
    foreach my $dc (sort {$a->name cmp $b->name} @{$dcs}) {
        my $dcname = $dc->name;
        next unless ($dc->vmFolder);
        my $folder  = Vim::get_view( mo_ref => $dc->vmFolder, );
        search_from_folder({ 'datacenter' => $dcname, 'parentage' => '', }, $folder);
    }
    if (Opts::get_option('json')) {
        print to_json(\@output, {utf8 => 1, pretty => 1, canonical => 1, });
    }
}
