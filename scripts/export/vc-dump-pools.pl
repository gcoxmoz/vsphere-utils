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
# This script goes through and shows a nested list of your resource pools
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
        if (($folder_ref->config->cpuAllocation->limit != -1) &&
            ($folder_ref->config->cpuAllocation->reservation != 0)) {
            $json_blob->{'config.cpuAllocation.expandableReservation'}    = $folder_ref->config->cpuAllocation->expandableReservation;
            $json_blob->{'config.cpuAllocation.limit'}                    = $folder_ref->config->cpuAllocation->limit;
            $json_blob->{'config.cpuAllocation.overheadLimit'}            = $folder_ref->config->cpuAllocation->overheadLimit;
            $json_blob->{'config.cpuAllocation.reservation'}              = $folder_ref->config->cpuAllocation->reservation;
        }
        if ($folder_ref->config->cpuAllocation->shares->level->val ne 'normal') {
            $json_blob->{'config.cpuAllocation.shares.shares'}            = $folder_ref->config->cpuAllocation->shares->shares;
            $json_blob->{'config.cpuAllocation.shares.level.val'}         = $folder_ref->config->cpuAllocation->shares->level->val;
        }
        if (($folder_ref->config->memoryAllocation->limit != -1) &&
            ($folder_ref->config->memoryAllocation->reservation != 0)) {
            $json_blob->{'config.memoryAllocation.expandableReservation'} = $folder_ref->config->memoryAllocation->expandableReservation;
            $json_blob->{'config.memoryAllocation.limit'}                 = $folder_ref->config->memoryAllocation->limit;
            $json_blob->{'config.memoryAllocation.overheadLimit'}         = $folder_ref->config->memoryAllocation->overheadLimit;
            $json_blob->{'config.memoryAllocation.reservation'}           = $folder_ref->config->memoryAllocation->reservation;
        }
        if ($folder_ref->config->memoryAllocation->shares->level->val ne 'normal') {
            $json_blob->{'config.memoryAllocation.shares.shares'}         = $folder_ref->config->memoryAllocation->shares->shares;
            $json_blob->{'config.memoryAllocation.shares.level.val'}      = $folder_ref->config->memoryAllocation->shares->level->val;
        }
        push @output, $json_blob;
    } else {
        my $whoami = $parentage_ref->{'datacenter'}.'/'.$parentage_ref->{'cluster'}.'/'.$parentage_ref->{'parentage'}.'/'.$folder_ref->name;
        print "$whoami\n";
    }
    my $blob; %{$blob} = %$parentage_ref;
    $blob->{'parentage'} = $parentage_ref->{'parentage'}.'/'.$folder_ref->name;
    my $subfolders = Vim::get_views( mo_ref_array => $folder_ref->resourcePool, view_type => 'ResourcePool', );
    if (!$subfolders) { print "Search for ComputeResource failed.\n"; return; }
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
        next unless ($dc->hostFolder);
        my $folder  = Vim::get_view( mo_ref => $dc->hostFolder, );
        my $clusters = Vim::get_views( mo_ref_array => $folder->childEntity, view_type => 'ComputeResource', );
        foreach my $cluster (sort {$a->name cmp $b->name} @{$clusters}) {
            my $tlrespool = Vim::get_view( mo_ref => $cluster->resourcePool, );
            search_from_folder({ 'datacenter' => $dcname, 'cluster' => $cluster->name, 'parentage' => '', }, $tlrespool);
        }
    }
    if (Opts::get_option('json')) {
        print to_json(\@output, {utf8 => 1, pretty => 1, canonical => 1, });
    }
}
