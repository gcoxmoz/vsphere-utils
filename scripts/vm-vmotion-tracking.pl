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
# This script was born from a slow hardware failure (correctable ECC errors)
# where VMs on a certain host were experiencing undue slowness.  But,
# we didn't have a good way (after the hardware issue was discovered)
# to know which VMs were potentially affected, and when.
#
# This script creates a (somewhat expensive) timeline of events from
# "a day ago" (or whatever you specify) through NOW.  Then it whittles
# that down to a timeframe you ask for, and shows you a choice of
#
# * what happened around a particular VM
# * where every VM was and where it moved
# * what happened around a particular host
#
# That last one is what you probably want most.  So a sample execution
# that's interested in a particular host would be called with:
# --server vc1 --onehost node4 --starttime 2015-10-21T16:28:00 --endtime 2015-10-21T16:30:00
#
# You might notice a lot of similarities to LucD's work in:
#     http://www.lucd.info/2013/03/31/get-the-vmotionsvmotion-history/
# I used that as a reference guide in culling the events, but I added
# in more events (relocation at power-on time) and more output modes
# to suit my needs.
#
#
# GOTCHA: If the host you're running on and the VMware environment have
# different timezones, you may have some 'fun' with timestamps here.
# But you were planning to set everything to UTC anyway, weren't you?
#

use DateTime;

my %opts = (
  # "dump everything you know": mostly helpful in debugging the script.  Does nothing to limit the time beyond what the search limits are.
  'dump'           => { type => '',   help => 'Dump the contents of the VM moves', default => undef, required => 0},
  # track all VMs across a span of time.  This is close to 'dump' but with more filtering for time within the script
  'allvms'         => { type => '',   help => 'Track all VMs\' moves',             default => undef, required => 0},
  # track one VM from timeX to timeY:  Not very exciting, it's the same as reading the VM's event log but without awful scrolling.
  'onevm'          => { type => "=s", help => 'Track one VM\'s moves',             default => undef, required => 0},
  # track one host from timeX to timeY:  Who came/left/stayed during a critical phase.  This is probably the most interesting setting.
  'onehost'        => { type => "=s", help => 'Track VMs\' moves on one host',     default => undef, required => 0},

  'starttime'      => { type => "=s", help => 'Start Time, use YYYY-MM-DDTHH:MM:SS  (defaults to 1-day-ago)',    required => 0},
  'endtime'        => { type => "=s", help => 'End Time,   use YYYY-MM-DDTHH:MM:SS  (defaults to NOW)',          required => 0},
  'no-gaps'        => { type => '',   help => 'Don\'t call out gaps in --onehost timelines', default => undef, required => 0},
  'no-lies'        => { type => '',   help => 'Never edit times for simple reading: always tell exact truth', default => undef, required => 0},

  );

# read/validate options and connect to the server
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $dump    = Opts::get_option('dump')    ? 1 : 0;
my $allvms  = Opts::get_option('allvms')  ? 1 : 0;
my $onevm   = Opts::get_option('onevm')   || 0;
my $onehost = Opts::get_option('onehost') || 0;
my $no_gaps = Opts::get_option('no-gaps') || 0;
my $no_lies = Opts::get_option('no-lies') || 0;
if (
    (!$dump && !$allvms && !$onevm && !$onehost) ||
    ((($dump && 1) + ($allvms && 1) + ($onevm && 1) + ($onehost && 1)) > 1 )
   ) {
    print "You must choose one option from --onevm / --onehost / --allvms / --dump\n";
    exit;
}

my $starttime;
if (Opts::option_is_set ('starttime')) {
    my $st = Opts::get_option('starttime');
    if ($st !~ m#^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$#) {
        print "use YYYY-MM-DDTHH:MM:SS on your timestamps.\n";
        exit 1;
    }
    my ($sy,$smon,$sd,$sh,$smin,$ss,) = ($1, $2, $3, $4, $5, $6, );
    $starttime = DateTime->new( year => $sy, month => $smon, day => $sd, hour => $sh, minute => $smin, second => $ss, );
} else {
    $starttime = DateTime->now->subtract( days => 1, );
}
my $endtime;
if (Opts::option_is_set ('endtime')) {
    if ($dump) {
        print "--dump is for seeing the timeline through 'now', and thus is incompatible with --endtime.\n";
        print "You probably wanted to run this with --allvms.\n";
        exit 1;
    }
    my $et = Opts::get_option('endtime');
    if ($et !~ m#^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$#) {
        print "use YYYY-MM-DDTHH:MM:SS on your timestamps.\n";
        exit 1;
    }
    my ($ey,$emon,$ed,$eh,$emin,$es,) = ($1, $2, $3, $4, $5, $6, );
    $endtime = DateTime->new( year => $ey, month => $emon, day => $ed, hour => $eh, minute => $emin, second => $es, );
} else {
    $endtime = DateTime->now;
}
my $internal_search_starttime = $starttime->clone;
   $internal_search_starttime->subtract( minutes => 5 ) unless ($no_lies || $dump);
my $internal_search_endtime   = DateTime->now;

if ($endtime->epoch < $starttime->epoch) {
    print "Start time must be before end time.\n";
    exit 1;
} elsif ($endtime->epoch > $internal_search_endtime->epoch) {
    # Keep it below 88, Marty.
    print "End time can not be in the future.\n";
    exit 1;
}

# connect to the server
Util::connect(); #print "Server Connected\n";
follow_vms();
# disconnect from the server
Util::disconnect(); #print "Server Disconnected\n";

use constant MINTIME => 0;
use constant MAXTIME => 2**31 - 1;   # Y2038!!!!   (OK, no, really, this just has to be some future date)

sub datetime_to_epoch ($) {
    my $datetime_string_in = shift;
    my ($y, $mon, $d, $h, $min, $s) = ($datetime_string_in =~ m#^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})#);
    my $dt = DateTime->new(
        year   => $y,
        month  => $mon,
        day    => $d,
        hour   => $h,
        minute => $min,
        second => $s,
    );
    return $dt->epoch;
}

sub timeprint ($) {
    my $epochtime_in = shift;
    if ($epochtime_in == MINTIME) {
        return 'previous';
    } elsif ($epochtime_in == MAXTIME) {
        return 'ongoing';
    } else {
        return scalar(localtime($epochtime_in));
    }
}


sub follow_vms {
    # get all vms and hosts
    my %vm_current_host;
    my $all_vms = Vim::find_entity_views(view_type => 'VirtualMachine', properties => ['name', 'config.template', 'runtime.host', ], filter => $onevm ? { 'name' => $onevm } : {} );
    if (!$all_vms) { print "Search for VMs failed.\n"; exit; }
    if (!(scalar @{$all_vms})) { print "Found no VMs".($onevm ? ' named '.$onevm : '').".\n"; exit; }
    foreach my $vm (@{$all_vms}) {
        next if ($vm->get_property('config.template') eq 'true');
        my $host_ref = $vm->{'runtime.host'};
        my $host = Vim::get_view(mo_ref => $host_ref, properties => ['name', ], );
        $vm_current_host{$vm->name} = $host->name;
    }

    # GOTCHA - you have to think 4th-dimensionally here.
    # You have the state of VM locations NOW... but that NOW is floating a bit, we're now 5-or-so seconds ahead of
    # the start of the script.  So what we're going to do is tell the task search to filter by time to stop at the
    # 'now' that was at the start of the script, to try to reduce the gap in the longer-running cases.

    my %target_tasks = map { $_ => 1 } qw( VirtualMachine.migrate VirtualMachine.relocate Drm.ExecuteVMotionLRO VirtualMachine.powerOn );
    # migrate is dragging-dropping; relocate is rightclick-migrate; Drm is DRS-initiated VMO; poweron is assignment at power-on
    my $servicecontent = Vim::get_service_content();
    my $taskManager = Vim::get_view( mo_ref => $servicecontent->taskManager );
    my $eventManager = Vim::get_view( mo_ref => $servicecontent->eventManager );

    my $taskFilter;
    if ($onevm) {
        my $entity = Vim::find_entity_view(view_type => 'VirtualMachine', filter => { 'name' => $onevm } );
        $taskFilter = TaskFilterSpec->new(entity => TaskFilterSpecByEntity->new(
                                                    recursion => TaskFilterSpecRecursionOption->new('self'),
                                                    entity => $entity,
                                          ) );
    } else {
        $taskFilter = TaskFilterSpec->new(time => TaskFilterSpecByTime->new(
                                                  timeType => TaskFilterSpecTimeOption->new('startedTime'),
                                                  beginTime => $internal_search_starttime,
                                                  endTime => $internal_search_endtime,
                                                  # DO NOT be tempted to filter by requested times -here-.
                                                  # We know the location of the VM -now-, but not necessarily at $endtime
                                                  # We have to construct the timeline from the anchor point of -now-
                                                  # and we can lop off pieces later, based on $endtime.
                                                  # As for start, hedge a little early: let's say an average vmotion
                                                  # is about 15 seconds.  The task fires at the beginning, but if
                                                  # that's our start time, we'll miss some.  So hedge early and
                                                  # pick things up, then process them later.
                                           ) );
    }
    my $taskCollector = Vim::get_view(mo_ref => $taskManager->CreateCollectorForTasks(filter => $taskFilter), );
    $taskCollector->RewindCollector;
    my %events;
    TASKWHILE: while (my $tasks = $taskCollector->ReadNextTasks(maxCount => 500)) {
        last TASKWHILE if (!(@$tasks));
        TASKFOR: foreach my $task (@$tasks) {
            my $task_description_id = $task->descriptionId;
            next TASKFOR unless ($target_tasks{$task_description_id});
            my $eventFilter = EventFilterSpec->new(eventChainId => $task->eventChainId);
            my $eventCollector = Vim::get_view(mo_ref => $eventManager->CreateCollectorForEvents(filter => $eventFilter));
            $eventCollector->RewindCollector;
            EVENTWHILE: while (my $events = $eventCollector->ReadNextEvents(maxCount => 100)) {
                last EVENTWHILE if (!(@$events));
                EVENTFOR: foreach my $event (@$events) {
                    next EVENTFOR unless ($event->isa('VmBeingHotMigratedEvent') || $event->isa('VmBeingRelocatedEvent'));
                    my $vm_name = $task->entityName;
                    next EVENTFOR if ($onevm && ($vm_name ne $onevm));
                    my $event_start_time = datetime_to_epoch($task->startTime);
                    my $event_end_time   = defined($task->completeTime) ? datetime_to_epoch($task->completeTime) : MAXTIME;
                    # These times can be undef, particularly in mid-vmotion.  Since that means it is ongoing,
                    # here I tag it as 'going forever'
                    my $host1 = $event->host->name;
                    my $host2 = $event->destHost->name;
                    my $movemethod;   # If you're capturing new tasks, add to this switch:
                       if ($task_description_id eq 'Drm.ExecuteVMotionLRO' )  { $movemethod = '[DRS]';     }
                    elsif ($task_description_id eq 'VirtualMachine.powerOn')  { $movemethod = '[POWERON]'; }
                    elsif ($task_description_id eq 'VirtualMachine.relocate') { $movemethod = '[MANUAL]';  }
                    elsif ($task_description_id eq 'VirtualMachine.migrate')  { $movemethod = '[MANUAL]';  }
                    else  { $movemethod = '[UPDATE-THE-SCRIPT]';  }

                    $events{$event_start_time}{$vm_name}  = {
                                        time1  => $event_start_time,
                                        time2  => $event_end_time,
                                        host1  => $host1,
                                        host2  => $host2,
                                        movemethod => $movemethod,
                                        #result => $task->state,
                                        #user = $task->reason->userName,
                                       };
                }
            }
            # Kill the collector when you finish; you can only have so many open.
            # If you miss this step, the loop will bow out quietly and confusingly.
            $eventCollector->DestroyCollector;
        }
    }
    $taskCollector->DestroyCollector;

    # Pivot the events into a new hash that has is sorted by time and focuses on the VM
    my %vm_moves;
    foreach my $event_start_time (sort keys %events) {
        foreach my $vm (keys %{$events{$event_start_time}}) {
            push @{$vm_moves{$vm}}, $events{$event_start_time}{$vm};
        }
    }

    # Now, merge the two main hashes into one timeline.
    my %timeline;
    foreach my $vm (keys %vm_current_host) {
        next if ($onevm && ($vm ne $onevm));
        my @moves = $vm_moves{$vm} ? @{$vm_moves{$vm}} : ();
        if (!@moves) {
            # Nobody moved.  Pretend this was here for all time
            my $item = { time1 => MINTIME, time2 => MAXTIME, moving => 0, host => $vm_current_host{$vm} };
            push @{$timeline{$vm}}, $item;
        } else {
            # Something moved.  Construct a timeline based on data.
            my $firstmove = $moves[0];
            my $item0 = { time1 => MINTIME, time2 => $firstmove->{'time1'}, moving => 0, host => $firstmove->{'host1'} };
            push @{$timeline{$vm}}, $item0;
            foreach my $i (0..$#moves) {
                my $move = $moves[$i];
                my $item1 = { time1 => $move->{'time1'}, time2 => $move->{'time2'}, moving => 1, movemethod => $move->{'movemethod'}, host1 => $move->{'host1'}, host2 => $move->{'host2'}, };
                push @{$timeline{$vm}}, $item1;
                if ($i < $#moves) {
                    my $nextmove = $moves[$i+1];
                    my $item2 = { time1 => $move->{'time2'}, time2 => $nextmove->{'time1'}, moving => 0, host => $move->{'host2'}, };
                    push @{$timeline{$vm}}, $item2;
                } else {
                    print "CHECK: $vm had a final move to ".$move->{'host2'}." but it's currently on ".$vm_current_host{$vm}."\n" if ($vm_current_host{$vm} ne $move->{'host2'});
                    # ^ This is usually indicative of a VMO that kicked in the seconds between "where is everyone now?"
                    # and "track down the tasks that I need to analyze."  But, since this is all about tracking, call it out.
                    my $itemN = { time1 => $move->{'time2'}, time2 => MAXTIME, moving => 0, host => $vm_current_host{$vm} };
                    push @{$timeline{$vm}}, $itemN;
                }
            }
        }
    }

    # At this point, you could JSON-dump %timeline and have a scannable version.
    # But I'm not going to require a one-off module like this for an obscure use case.
    # use JSON;
    # print(to_json(\%timeline, {utf8 => 1, pretty => 1})."\n");  # for humans
    # print(encode_json(\%timeline)."\n");                        # for parsers
    if ($dump) {
        printf "Timestamps: %s - %s\n", timeprint($starttime->epoch), timeprint($endtime->epoch);
        foreach my $vm (sort keys %timeline) {
            print "$vm\n";
            foreach my $chunk (@{$timeline{$vm}}) {
                my $hostline = $chunk->{'moving'} ? 'Moved from '.$chunk->{'host1'}.' to '.$chunk->{'host2'}.' '.$chunk->{'movemethod'} : $chunk->{'host'};
                printf '  %25s %-25s %s'."\n", timeprint($chunk->{'time1'}), timeprint($chunk->{'time2'}), $hostline;
            }
        }
        exit;
    }


    # So from here on, we don't need to consider the dump case
    # This is effectively applying the 'endtime' timefilter here
    foreach my $vm (keys %timeline) {
        my @newtimechunks = ();
        my $startflag = 1;
        foreach my $chunk (@{$timeline{$vm}}) {
            if ($startflag) {
                if (($chunk->{'time1'} <= $starttime->epoch) && ($starttime->epoch < $chunk->{'time2'})) {
                    # If a VM is at rest, set it to the beginning of time because we don't care how long it's been there
                    # But if it was in the middle of a move, tell the truth.
                    $chunk->{'time1'} = MINTIME if (!$chunk->{'moving'} && !$no_lies);
                    push @newtimechunks, $chunk;
                    $startflag = 0;
                }
            } else {
                last if ($endtime->epoch <= $chunk->{'time1'});
                if ($endtime->epoch < $chunk->{'time2'}) {
                    $chunk->{'time2'} = MAXTIME if (!$chunk->{'moving'} && !$no_lies);
                }
                push @newtimechunks, $chunk;
            }
        }
        $timeline{$vm} = \@newtimechunks;
    }

    if ($onehost) {
        # This exists to filter down to events related specifically to a particular host
        # onevm and allvms don't need this because they don't filter by hosts, duh.
        foreach my $vm (keys %timeline) {
            my @newtimechunks = ();
            my $gap = {};
            foreach my $chunk (@{$timeline{$vm}}) {

                if (( $chunk->{'moving'} && ($chunk->{'host1'} =~ m#$onehost# || $chunk->{'host2'} =~ m#$onehost#) ) ||
                    (!$chunk->{'moving'} && ($chunk->{'host'} =~ m#$onehost#)                                      ))  {
                    # If your VM matches the host during the timeline...
                    if (scalar keys %$gap) {
                        # Skip if we're not in the middle of a gap already.  If we are, the fact that
                        # we just matched means it's time to close off the end time of the gap
                        # Mark gap's end as the beginning time of this chunk, and then push the gap
                        $gap->{'time2'} = $chunk->{'time1'};
                        push(@newtimechunks, $gap) unless ($no_gaps);
                    }
                    # reset the gap.  Either we have a garbage one early in the run, or we
                    # just pushed one, or it was already empty.
                    $gap = {};
                    push(@newtimechunks, $chunk);
                } elsif (scalar @newtimechunks && !(scalar keys %$gap)) {
                    # start counting a gap only once we have a timeline we care about.
                    $gap = { time1 => $chunk->{'time1'}, moving => 0, host => '*elsewhere*' };
                }

            }
            if (@newtimechunks) {
                $timeline{$vm} = \@newtimechunks;
            } else {
                delete $timeline{$vm};
            }
        }
    }

    # So at this point, we have the timeline.  Time (HAH!) to do something with it.
    my %analysis;
    foreach my $vm (keys %timeline) {
        my @chunks = @{$timeline{$vm}};
        if (scalar(@chunks) == 1) {
            my $chunk = $chunks[0];
            $analysis{'stayed'}{$vm} = $chunk->{'moving'} ? $chunk->{'host1'}.' -> '.$chunk->{'host2'}.' '.$chunk->{'movemethod'} : $chunk->{'host'};
            # Highly unlikely, but nonzero, that a VM could be moving for the whole duration.
        } elsif ($onehost && ($chunks[0]->{'time1'} == MINTIME)) {
            $analysis{'left'}{$vm} = 1;
        } elsif ($onehost && ($chunks[$#chunks]->{'time2'} == MAXTIME)) {
            $analysis{'arrived'}{$vm} = 1;
        } else {
            $analysis{'pogoed'}{$vm} = 1;
        }
    }

    printf "Timestamps: %s - %s\n", timeprint($starttime->epoch), timeprint($endtime->epoch);
    foreach my $action ('stayed') {
        next if (scalar(keys(%{$analysis{$action}})) == 0);
        print "These VMs did not move:\n";
        foreach my $vm (sort keys %{$analysis{$action}}) {
            printf "  %s  %s\n", $analysis{$action}{$vm}, $vm, ;
        }
    }
    foreach my $action ('left', 'arrived', 'pogoed',) {
        next if (scalar(keys(%{$analysis{$action}})) == 0);
        print "These VMs $action:\n";
        foreach my $vm (sort keys %{$analysis{$action}}) {
            print "$vm\n";
            foreach my $chunk (@{$timeline{$vm}}) {
                printf '    %25s %-25s %s'."\n", timeprint($chunk->{'time1'}), timeprint($chunk->{'time2'}), $chunk->{'moving'} ? $chunk->{'host1'}.' -> '.$chunk->{'host2'}.' '.$chunk->{'movemethod'} : $chunk->{'host'};
            }
        }
    }
    

}
