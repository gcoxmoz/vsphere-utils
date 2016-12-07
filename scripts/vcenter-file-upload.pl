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
# This script uploads a file directly to the datastores.
#
# H/T: http://www.virtuallyghetto.com/2014/06/how-to-efficiently-transfer-files-to-datastore-in-vcenter-using-the-vsphere-api.html
# I went away from vghetto's recommendations in a few ways:
# 1) I did the 'inefficient' way, because, frankly, the code is much cleaner, and if your
#    vCenter is so bogged down that it can't handle a file passthrough, you have bigger problems.
# 2) I eliminated 'datacenter' as a mandatory option.  If the script can find the datastore
#    uniquely, it learns the datacenter on its own.
#
# Also, that page doesn't speak about roles and permissions.
# The permission needed is Datastore/Low-level file operations, attached to the vCenter, NOT the datastore.
# Since it's writing to the VC, not the DS, that's where it goes; it's kind of a DUH item that took me
# a little too long to realize.
#
use URI::URL;
use URI::Escape;
#
# ^ These are pretty much freebies/needed for the SDK itself.
#

my %opts = (
    'sourcefile' => { type => '=s', help => 'Path to file to upload',     required => 1, },
    'destfile'   => { type => '=s', help => 'Destination file path/name', required => 1, },
    'datastore'  => { type => '=s', help => 'Name of vSphere Datastore to upload file to', required => 1, },
    'datacenter' => { type => '=s', help => 'Name of vSphere Datacenter to upload file to', required => 0, },
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $sourcefile = Opts::get_option('sourcefile');
my $destfile   = Opts::get_option('destfile');
my $datastore  = Opts::get_option('datastore');
my $datacenter = Opts::get_option('datacenter');

if ((! -e $sourcefile) || (! -f $sourcefile)) {
    Util::trace(0, "No file named $sourcefile found.\n"); exit;
} elsif (! -r $sourcefile) {
    Util::trace(0, "File $sourcefile is not readable.\n"); exit;
}

Util::connect();

## Verification step to go and find the datacenter by name
my $datacenter_refs = Vim::find_entity_views(view_type => 'Datacenter', filter => $datacenter ? { 'name' => $datacenter, } : {}, properties => ['name', 'datastore', ], );
my @dc_morefs;
foreach my $dc (@$datacenter_refs) {
    foreach my $ds_ref (@{$dc->datastore}) {
        my $ds    = Vim::get_view( view_type => 'Datastore', mo_ref => $ds_ref, filter => { 'name' => $datastore, }, properties => ['name', ], );
        next if ($datastore ne $ds->name);
        push(@dc_morefs, $dc);
    }
}

if (scalar(@dc_morefs) < 1) {
    Util::trace(0, "No Datastores named $datastore found.\n"); exit;
} elsif (scalar(@dc_morefs) > 1) {
    Util::trace(0, "Found multiple Datastores named $datastore, add a --datacenter option.\n"); exit;
}
my $dc = $dc_morefs[0];

my $service     = Vim::get_vim_service();
# ^ This is a not-well-exposed call in VICommon.
my $user_agent  = $service->{vim_soap}->{user_agent};

my $service_url = URI::URL->new($service->{vim_soap}->{url});
   $service_url =~ s#/sdk/.*$##g;
my $url_string = $service_url . '/folder/' . $destfile;
utf8::downgrade($url_string);
my $url = URI::URL->new($url_string);
   $url->query_form('dcPath' => $dc->name, 'dsName' => $datastore, );
my $request = HTTP::Request->new('PUT', $url);
   $request->header('Content-Type', 'application/octet-stream');
   $request->header('Content-Length', -s $sourcefile);

my $buffer;
open(CONTENT, '< :raw', $sourcefile);
my $num_read = read(CONTENT, $buffer, 102400);
close(CONTENT);
$buffer = '' if ($num_read == 0);
$request->content($buffer);
my $response = $user_agent->request($request);
print $response->message."\n" unless ($response->is_success);

Util::disconnect();
