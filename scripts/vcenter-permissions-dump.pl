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

my %opts = (
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# connect to the server
Util::connect(); #print "Server Connected\n";
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
        $roles{$role->roleId} = ($role->system ? 'systemdefined-' : '').'"'. $role->name .'"';
    }
    my $perms = $authorizationManager->RetrieveAllPermissions();
    foreach my $perm_ref (@{$perms}) {
        my $entity = Vim::get_view(mo_ref => $perm_ref->entity, );
        my $entity_type = ref($entity);
        my $entity_name = $entity->name;
        my $group  = $perm_ref->group ? 'Group=' : 'User=';
        my $role   = $roles{$perm_ref->roleId} || 'UNDEF_ROLE';
        my $propagation = $perm_ref->propagate ? '' : ' (NONPROPAGATING)';
        print  $entity_type .' '. $entity_name .' '. $group . $perm_ref->principal .' '. $role . $propagation . "\n";
    }
}
