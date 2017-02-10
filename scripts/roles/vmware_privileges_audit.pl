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
# Inspecting privileges-per-role is annoying because of the nested nature.
# What we found in our environment is that we had a lot of places where privs
# were inconsistent, missing this-or-that unexpectedly.
#
# As part of the consolidation effort, we wanted to make roles that had
# sane consistency AND did what we wanted.
#
# This script is that attempt.  We defined our roles in terms of "priv groups"
# (namely, the set of privs necessary to do certain tasks) and put that in a
# JSON file (so this script would become sharable and not muddied with privs).
# The contents of privileges.json is that first mapping - tasks to permissions.
#
# Then the roles are a flattening of the things that we want particular roles
# to do.  That mapping is roles.json, which is going to be proprietary per company.
#
# The script maps the desired permissions (from our JSON) into a list of perms,
# and checks that against the actual privileges on the vCenter.
#
# You will probably want to tweak this to your local environment.  We have
# exceptions coded in (e.g we don't care about NetApp VSC roles) that you may
# wish to cull out.
#

use JSON;
my %opts = (
   'privilegesfile' => { type => '=s', help => 'Privileges configuration file, in JSON format', required => 0},
   'rolesfile'      => { type => '=s', help => 'Roles configuration file, in JSON format', required => 0},
   'audit'          => { type => '',   help => 'Print all roles and privileges', required => 0},
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $privilegesfile = Opts::get_option('privilegesfile') || 'privileges.json';
my %privilege_groupings = ();
if (!$privilegesfile || ! -f $privilegesfile) {
    die "Privileges file not provided.\n";
} else {
    open( FH, '<'.$privilegesfile ) or die "Can't open JSON file $privilegesfile: $!\n";
    my $json_text = join '', <FH>;
    close FH;
    my $privilege_groupings_ref = from_json($json_text);
    %privilege_groupings = %$privilege_groupings_ref;
}

my $rolesfile = Opts::get_option('rolesfile') || 'roles.json';
my %role_groupings = ();
if (!$rolesfile && ! -f $rolesfile) {
    die "Roles file not provided.\n";
} else {
    open( FH, '<'.$rolesfile ) or die "Can't open JSON file $rolesfile: $!\n";
    my $json_text = join '', <FH>;
    close FH;
    my $role_groupings_ref = from_json($json_text);
    %role_groupings = %$role_groupings_ref;
}

# connect to the server
Util::connect(); #print "Server Connected\n";
check_all_perms();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";


sub check_all_perms {
    my $service_instance = Vim::get_service_instance();
    my $authorizationManager_ref = $service_instance->content->authorizationManager;
    my $authorizationManager = Vim::get_view(mo_ref => $authorizationManager_ref, );

    my $perms = $authorizationManager->RetrieveAllPermissions();
    my %roles_in_use = ();
    foreach my $perm_ref (@{$perms}) {
        $roles_in_use{$perm_ref->roleId || 'nonsense'} = 1;
    }

    my $roles_ref = $authorizationManager->roleList;
    my %roles = ();
    foreach my $role (sort { $a->name cmp $b->name } @$roles_ref) {
        # we can't change 'em so why care?
        next if ($role->system);
        # The samples are deployed from VMware.  Let's ignore.
        next if ($role->info->label =~ m#\(sample\)$#); 
        next if ($role->info->label =~ m#^InventoryService.Tagging.TaggingAdmin$#);
        # The VSC perms are created by NetApp.  Don't touch.
        next if ($role->info->label =~ m#^VSC#);
        #    print $role->name."\n";
        #    foreach my $priv (@{$role->privilege}) {
        #        print '  '.$priv."\n";
        #    }
        if (!Opts::get_option('audit')) {
            if (! $roles_in_use{$role->roleId}) {
                print '### Unused role '. $role->name ."\n";
                next;
            }
            next unless ($role->privilege); # If it's an empty privilege set, move on
        }

        my $rolegroup_ref = $role_groupings{$role->name};
        if (!defined $rolegroup_ref) {
            print $role->name." has no definition in %role_groupings.  Raw dump:\n";
            foreach my $priv (@{$role->privilege}) {
                print '  '.$priv."\n";
            }
            next;
        }
        my %privs_expected = ();
        foreach my $group (@$rolegroup_ref) {
            my $privlist_ref = $privilege_groupings{$group};
            if (! defined $privlist_ref) {
                print $role->name." is trying to use group $group, which isn't listed in \%privilege_groupings.  Aborting.\n";
                exit -1;
            } elsif (! defined $privlist_ref->{'privs'}) {
                print $role->name." is trying to use group $group, which has no privs in \%privilege_groupings.  Aborting.\n";
                exit -1;
            }
            foreach my $x (@{$privlist_ref->{'privs'}}) {
                $privs_expected{$x} = 1;
            }
        }
        my %privs_actual = map { $_ => 1, } @{$role->privilege};
        foreach my $priv (keys %privs_actual) {
            if ($privs_expected{$priv}) {
                delete $privs_expected{$priv};
                delete $privs_actual{$priv};
            }
        }
        if ((scalar(keys %privs_actual) == 0) && (scalar(keys %privs_expected) == 0)) {
            print '### '.$role->name.' has correct / expected privs'."\n";
        } elsif (scalar(keys %privs_actual) > 0) {
            print '### '.$role->name.' has extra privs:'."\n";
            foreach my $priv (sort keys %privs_actual) {
                print '  '.$priv."\n";
            }
        } elsif (scalar(keys %privs_expected) > 0) {
            print '### '.$role->name.' has missing privs:'."\n";
            foreach my $priv (sort keys %privs_expected) {
                print '  '.$priv."\n";
            }
        }
    }
}
