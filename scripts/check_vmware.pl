#!/usr/bin/perl -w
#
# gcox@mozilla
#
# Check for vCenter alarms at the root
# If nothing at the root, deepdive for ones that didn't propagate
# 
# CAUTION!  This script assumes that you are at least ping-monitoring individual
# ESX hosts.  Thus, IT SUPPRESSES ALARMS for powered-off hosts (reported
# verbally in the status, but not flagged as critical) so as to avoid needing
# to file 2 downtimes, and thus suppressing potentially valid alarms that occur
# during maintenance work.
#

use strict;
use warnings;
use VMware::VIRuntime;
my $deep_dive_for_alarms_flag = 1;
my $condensed_status_count    = 3;

$SIG{__DIE__} = sub{Util::disconnect()};
$Util::script_version = '1.0';

my %opts = (
  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $servicecontent;
my $statuscode = 0;
my $condensed_status_flag = Opts::get_option('verbose') ? 0 : 1;
# by default, we're going to try to brief up the status line when it's obnoxiously long.
# However, we allow for --verbose, OR the code deciding no squishing is allowed.

my %status_words = (
  0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN',
);

sub set_final_status ($) {
    # Input - some return code (1 = warning, 2 = critical)
    # Output - nothing
    # side effect - $statuscode global is changed.
    # Set the return code to the worst-case-status
    my ($in, ) = @_;
    $statuscode = 1 if ($statuscode < 1 && $in == 1);
    $statuscode = 2 if ($statuscode < 2 && $in == 2);
}


sub analyze_one_entity ($$) {
    my($type, $entity) = @_;
    my @alarms = ();
    my $tas = $entity->triggeredAlarmState;  # doesn't have to exist
    if ($tas) {
        foreach my $aref (@$tas) {
            my $rv_ref = undef;
            my $color = $aref->overallStatus->val;
            if ($color =~ m#^(?:red|yellow)$#) {
                my $aentity = Vim::get_view(mo_ref=>$aref->entity);
                my $alarm   = Vim::get_view(mo_ref=>$aref->alarm );
                my $alarmname  = $alarm->info->name;
                if (($aentity->isa('HostSystem')) &&
                    ($alarmname eq 'Host connection and power state') &&
                    ($color     eq 'red')
                    ) {
                    # We will SHOW this message (because saying 'no errors' when there ARE errors is
                    # slimy), but do not raise the error level.  These are acceptable errors.
                    # This is us accepting the risk of "I know the blade is down, the host check will catch this."
                    1;  #  deliberate NOOP statement to make Perl happy
                } else {
                    set_final_status(1) if ($color eq 'yellow');
                    set_final_status(2) if ($color eq 'red');
                }
                $rv_ref = [$type, $aentity->name, $alarmname, $color, ];
            }
            push(@alarms, $rv_ref) if ($rv_ref);
        }
    }
    return (\@alarms);
}


sub check_simple_alarms () {
    my $rootfolder = Vim::get_view( mo_ref=>$servicecontent->rootFolder );
    if (!$rootfolder) { print("UNKNOWN: Unable to obtain root folder.\n"); exit 3;  }
    my ($rv_ref) = analyze_one_entity('Folder', $rootfolder);
    return ($rv_ref);
}

sub check_deep_alarms () {
    my @alarms    = ();
    foreach my $type ('VirtualMachine', 'HostSystem', ) {
        # We only search VM and Host here.  This is an expensive, gratuitous check of alarms
        # We've seen VMs not propagate, and Hosts are vital.  We COULD check a lot more entities
        # but this is an expensive timesink here, and at some point we have to believe that vCenter
        # will get things right, or will explode badly enough that SOME alarm will propagate.
        my $entities = Vim::find_entity_views(view_type => $type, properties => ['name', 'triggeredAlarmState', ], );
        if (!$entities) {
            #Util::trace(0, "No $entity found '\n");
        } else {
            foreach my $entity (sort { $a->name cmp $b->name } @$entities) {
                my ($rv_ref) = analyze_one_entity($type, $entity);
                push(@alarms, @$rv_ref) if (scalar @$rv_ref);
            }
        }
    }
    return (\@alarms);
}


sub generate_final_message ($) {
    # Input = arrayref
    # Output = string
    #
    # Input members can be:
    # String (print as-is, in order)
    # arrayrefs of [type of thing alarming, name of thing alarming, alarm, coloe] that can be consilidated/compressed
    my ($ref, ) = @_;
    my $message = '';
    if (scalar @{$ref} ) {
        my %alarm_analysis = ();
        if ($condensed_status_flag) {
            # Let's analyze the alarms and see if there's anything we can do to trim this down.
            # This is the general case
            foreach my $item (@{$ref}) {
                # Count the alarms by type
                next unless (ref($item) eq 'ARRAY'); # skip strings
                $alarm_analysis{$item->[0]}{$item->[2]}++;
            }
            foreach my $type (sort keys %alarm_analysis) {
                foreach my $alarm (sort keys %{$alarm_analysis{$type}}) {
                    if ($alarm_analysis{$type}{$alarm} < $condensed_status_count) {
                        # Less than N, tell us the actuality
                        delete $alarm_analysis{$type}{$alarm};
                    } else {
                        # N or more, add a summary line ala "'N * 'alarmname'" or "N VMs throwing 'alarmname'"
                        # If it's a folder, it came from the root, and we don't know what entitytype threw it.
                        # If we're in deepdive mode, we can report on what type of object misbehaved.
                        my $action = ($type eq 'Folder') ? '*' : $type.'s throwing';
                        push(@{$ref}, $alarm_analysis{$type}{$alarm} . ' ' .$action . " '" . $alarm . "'");
                    }
                }
            }
        }
        my @bundle = ();
        foreach my $item (@{$ref}) {
            if (ref($item) eq '') {
                # string, pass-through
                push @bundle, $item;
            } elsif (ref($item) eq 'ARRAY') {
                # If the alarm is in alarm_analysis, we have N instances of one alarm type.
                # Skip the individual alarm, as we've reported it in a rollup line above.
                next if ($alarm_analysis{$item->[0]}{$item->[2]});
                # Otherwise, low alarm count, tell the truth.
                my $str = '['.$item->[1].'] '.$item->[2];
                push @bundle, $str;
            } else {
                print 'UNKNOWN: Bad reference pass-though: '.ref($item)."\n";
                exit 3;
            }
        }
        $message = $status_words{$statuscode} .': '. join("\n", @bundle);  # Here we blindly hope this doesn't go over 4k.
    } else {
        $message = 'OK: No alarms found.';
    }
    return $message;
}


####################################################################################
Util::connect(); #print "Server Connected\n";
   $servicecontent = Vim::get_service_content();

my ($alarms_ref) = check_simple_alarms();
if ($deep_dive_for_alarms_flag) {
    if (!$statuscode && !(scalar @{$alarms_ref})) {
        # If you're here, statuscode is 0/OK and alarmsref is empty:
        # you didn't find any errors up at the root.  dig for more.
        #
        # Hidden gotcha: Having status=0/OK and alarms=existing is a valid/declared OK
        # return from the root, because we might skip known alarms (like a host being
        # powered off).  This condition means you won't get in here: you found AN alarm,
        # just that it's one the code says "it's cool to ignore".  This deep check 
        # is mostly redundant and can get expensive (at a time when processing matters)
        # if things are really down and alarming at the root.
        # In that case, skip this: Fight the fire you know.
        #
        ($alarms_ref) = check_deep_alarms();
        if (scalar @{$alarms_ref}) {
            # Here, we've found an alarm that didn't get caught by the normal process
            # and didn't propagate to the root folder.  This is bad.  Call it out as a
            # critical, put it at the top line of all alerts, and force verbosity
            # because the alarm, by definition, is hidden at a place you wouldn't see
            # in the normal top-level alarm panel.
            set_final_status(2);
            unshift(@{$alarms_ref}, "Nonpropagating alarms found.");
            $condensed_status_flag = 0;
        }
    }
}

# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

my $message = generate_final_message($alarms_ref);
print $message."\n";
exit $statuscode;
