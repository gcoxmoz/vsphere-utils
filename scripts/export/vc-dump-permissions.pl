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
# I hate clicking through the permissions tabs trying to see everything/everyone who
# has perms, looking for discrepancies.  Dump it all, so it's grep'able/sortable/scanable.
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
check_all_perms();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";


sub check_all_perms {
    my $service_instance = Vim::get_service_instance();
    my $authorizationManager_ref = $service_instance->content->authorizationManager;
    my $authorizationManager = Vim::get_view(mo_ref => $authorizationManager_ref, );
    my $roles_ref = $authorizationManager->roleList;
    my %roles = ();
    foreach my $role (@$roles_ref) {
        $roles{$role->roleId} = $role->name;
    }
    my $perms = $authorizationManager->RetrieveAllPermissions();
    foreach my $perm_ref (@{$perms}) {
        my $entity = Vim::get_view(mo_ref => $perm_ref->entity, );
        my $json = {};
        $json->{'entity_type'}        = ref($entity);
        $json->{'entity_name'}        = $entity->name;
        $json->{'isa_group'}          = $perm_ref->group;
        $json->{'principal'}          = $perm_ref->principal;
        $json->{'role_name'}          = $roles{$perm_ref->roleId};
        $json->{'propagation'}        = $perm_ref->propagate ? '' : '(NONPROPAGATING)';
        my $json_blob; %{$json_blob} = %$json;
        push @output, $json_blob;
    }

    if (Opts::get_option('json')) {
        print to_json(\@output, {utf8 => 1, pretty => 1, canonical => 1, });
    } else {
        foreach my $ref (@output) {
            print $ref->{'entity_type'} .' '. $ref->{'entity_name'} .' '. ($ref->{'isa_group'} ? 'Group=' : 'User=') . $ref->{'principal'} .' "'. $ref->{'role_name'} .'" '. $ref->{'propagation'} . "\n";
        }
    }
}
