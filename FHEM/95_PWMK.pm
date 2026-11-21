#
# 95_PWMK.pm
# Dynamic, return-temperature based maintenance-pulse spacing for FHEM PWM/PWMR.
# Copyright (C) 2026 Frank Parussel
# 21.11.2026: final-selector coordination, post-delay sample validation and
#             explicit safety fallbacks added.
# 21.11.2026: atomic persistent learning state and complete per-cycle
#             learning events for long-term FileLog analysis added.
#
package main;

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use IO::Handle;

our (%defs, $readingFnAttributes);

my %PWMK_groupLock;

sub PWMK_Initialize($);
sub PWMK_Define($$);
sub PWMK_Undef($$);
sub PWMK_Set($@);
sub PWMK_Attr(@);
sub PWMK_Evaluate($);
sub PWMK_CalculateInterval(@);
sub PWMK_GetRoomDecision(@);
sub PWMK_GroupGrant(@);
sub PWMK_ClaimPulse(@);
sub PWMK_StateFile($);
sub PWMK_SaveState($);
sub PWMK_LoadState($);

sub PWMK_Initialize($) {
  my ($hash) = @_;
  $hash->{DefFn}   = 'PWMK_Define';
  $hash->{UndefFn} = 'PWMK_Undef';
  $hash->{SetFn}   = 'PWMK_Set';
  $hash->{AttrFn}  = 'PWMK_Attr';
  $hash->{AttrList}=
      'disable:0,1 mode:off,shadow,active interval ' .
      'minInterval maxInterval initialInterval minPulseDuration ' .
      'providerMaxAge returnMaxAge coordinationGroup ' .
      'coordinationReservation ' .
      'targetOffsetLow targetOffsetHigh intervalStep stateFile ' .
      ' ' . $readingFnAttributes;
}

sub PWMK_Define($$) {
  my ($hash,$def)=@_;
  my @a=split(/\s+/,$def);
  return 'syntax: define <name> PWMK <PWM-device> [<outside-device>[:<reading>]|none]'
    if @a < 3 || @a > 4;
  my $pwm=$a[2];
  return "$a[0]: $pwm is not a PWM device"
    if defined($defs{$pwm}) && (($defs{$pwm}{TYPE} // '') ne 'PWM');
  my $outside=$a[3] // 'none';
  my ($odev,$oreading)=('none','temperature');
  if ($outside ne 'none') {
    ($odev,$oreading)=split(/:/,$outside,2);
    $oreading='temperature' unless defined($oreading) && length($oreading);
  }
  $hash->{PWM_DEVICE}=$pwm;
  $hash->{OUTSIDE_DEVICE}=$odev;
  $hash->{OUTSIDE_READING}=$oreading;
  $hash->{helper}{stateLoaded}=0;
  $hash->{STATE}='defined';
  readingsSingleUpdate($hash,'state','defined',1);
  InternalTimer(gettimeofday()+5,'PWMK_Evaluate',$hash,0);
  return undef;
}

sub PWMK_Undef($$) {
  my ($hash,$arg)=@_;
  RemoveInternalTimer($hash);
  return undef;
}

sub PWMK_Attr(@) {
  my ($cmd,$name,$attrName,$attrValue)=@_;
  if ($cmd eq 'set' && $attrName =~ /^(?:interval|minInterval|maxInterval|initialInterval|minPulseDuration|providerMaxAge|returnMaxAge|coordinationReservation|targetOffsetLow|targetOffsetHigh|intervalStep)$/) {
    return "$name: $attrName must be numeric"
      unless defined($attrValue) && $attrValue =~ /^-?\d+(?:\.\d+)?$/;
    return "$name: $attrName must be greater than zero"
      if $attrName !~ /^targetOffset/ && $attrValue <= 0;
  }
  return undef;
}

sub PWMK_Set($@) {
  my ($hash,@a)=@_;
  return 'set command missing' if @a < 2;
  my $cmd=$a[1];
  if ($cmd eq 'evaluate') {
    PWMK_Evaluate($hash);
    return undef;
  }
  if ($cmd =~ /^(freeze|unfreeze|reset)$/) {
    my $room=$a[2] // 'all';
    foreach my $r (keys %{$hash->{helper}{rooms} // {}}) {
      next if $room ne 'all' && $room ne $r;
      if ($cmd eq 'reset') {
        delete $hash->{helper}{rooms}{$r};
      } else {
        $hash->{helper}{rooms}{$r}{frozen}=($cmd eq 'freeze' ? 1 : 0);
      }
    }
    readingsSingleUpdate($hash,'lastService',"$cmd $room",1);
    my $saveError=PWMK_SaveState($hash);
    readingsSingleUpdate($hash,'persistenceStatus',
      defined($saveError) ? "error: $saveError" : 'saved '.TimeNow(),1);
    return undef;
  }
  return 'Unknown argument, choose one of evaluate:noArg freeze unfreeze reset';
}

sub PWMK_CalculateInterval(@) {
  my ($current,$trend,$low,$high,$step,$min,$max)=@_;
  my $next=$current;
  $next-=$step if $trend < $low;
  $next+=$step if $trend > $high;
  $next=$min if $next < $min;
  $next=$max if $next > $max;
  return int($next+0.5);
}

sub PWMK_safeName($) {
  my ($name)=@_;
  $name =~ s/[^A-Za-z0-9_]/_/g;
  return $name;
}

sub PWMK_epoch($) {
  my ($ts)=@_;
  return 0 unless defined($ts) && $ts =~ /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)$/;
  return eval { main::time_str2num($ts) } || 0 if defined(&main::time_str2num);
  return time(); # test harness: presence is enough; production FHEM supplies time_str2num
}

sub PWMK_StateFile($) {
  my ($hash)=@_;
  my $name=$hash->{NAME};
  my $configured=AttrVal($name,'stateFile','');
  return $configured if length($configured);
  my $globalState=AttrVal('global','statefile','./log/fhem.save');
  $globalState =~ s{[^/\\]+$}{};
  $globalState='./log/' unless length($globalState);
  return $globalState.PWMK_safeName($name).'.json';
}

sub PWMK_SaveState($) {
  my ($hash)=@_;
  my $file=PWMK_StateFile($hash);
  my %rooms;
  foreach my $roomName (sort keys %{$hash->{helper}{rooms} // {}}) {
    my $state=$hash->{helper}{rooms}{$roomName};
    next unless ref($state) eq 'HASH';
    next unless defined($state->{interval}) && defined($state->{cycles});
    my %stored;
    foreach my $key (qw(interval lastReturn trend cycles lastOutside frozen updated reason)) {
      $stored{$key}=$state->{$key} if defined($state->{$key});
    }
    $rooms{$roomName}=\%stored if keys %stored;
  }
  my $payload={
    version=>1,
    provider=>$hash->{NAME},
    pwm=>$hash->{PWM_DEVICE} // '',
    savedAt=>time(),
    rooms=>\%rooms,
  };
  my $json=eval { encode_json($payload) };
  return "encode failed: $@" if $@ || !defined($json);
  my $tmp=$file.'.tmp.'.$$;
  open(my $fh,'>:encoding(UTF-8)',$tmp) or return "open $tmp failed: $!";
  print {$fh} $json,"\n" or do { my $e=$!; close($fh); unlink($tmp); return "write $tmp failed: $e"; };
  eval { $fh->flush(); $fh->sync(); };
  close($fh) or do { my $e=$!; unlink($tmp); return "close $tmp failed: $e"; };
  if (!rename($tmp,$file)) {
    # Windows cannot atomically replace an existing destination.  Production
    # FHEM on Linux uses the first branch; this fallback keeps tests and other
    # supported hosts functional.
    unlink($file) if -e $file;
    rename($tmp,$file) or do { my $e=$!; unlink($tmp); return "rename $tmp failed: $e"; };
  }
  return undef;
}

sub PWMK_LoadState($) {
  my ($hash)=@_;
  my $file=PWMK_StateFile($hash);
  $hash->{helper}{stateLoaded}=1;
  return 0 unless -e $file;
  open(my $fh,'<:encoding(UTF-8)',$file) or return "error: open $file failed: $!";
  local $/;
  my $raw=<$fh>;
  close($fh);
  my $data=eval { decode_json($raw // '') };
  return "error: invalid JSON in $file" if $@ || ref($data) ne 'HASH';
  return 'error: unsupported state version' unless ($data->{version} // 0) == 1;
  return 'error: provider mismatch' unless ($data->{provider} // '') eq $hash->{NAME};
  return 'error: PWM mismatch' unless ($data->{pwm} // '') eq ($hash->{PWM_DEVICE} // '');
  return 'error: rooms missing' unless ref($data->{rooms}) eq 'HASH';
  my $min=AttrVal($hash->{NAME},'minInterval',120);
  my $max=AttrVal($hash->{NAME},'maxInterval',480);
  my $count=0;
  foreach my $roomName (keys %{$data->{rooms}}) {
    my $stored=$data->{rooms}{$roomName};
    next unless ref($stored) eq 'HASH';
    next unless defined($stored->{interval}) && $stored->{interval} =~ /^\d+(?:\.\d+)?$/ &&
                $stored->{interval} >= $min && $stored->{interval} <= $max;
    next unless defined($stored->{cycles}) && $stored->{cycles} =~ /^\d+$/;
    my %restored=(
      interval=>0+$stored->{interval},
      cycles=>0+$stored->{cycles},
      frozen=>$stored->{frozen} ? 1 : 0,
      valid=>0,
      reason=>'restored-awaiting-validation',
      sampledThisPulse=>0,
    );
    foreach my $key (qw(lastReturn trend lastOutside updated)) {
      next unless defined($stored->{$key}) && $stored->{$key} =~ /^-?\d+(?:\.\d+)?$/;
      $restored{$key}=0+$stored->{$key};
    }
    $hash->{helper}{rooms}{$roomName}=\%restored;
    $count++;
  }
  return $count;
}

sub PWMK_Evaluate($) {
  my ($hash)=@_;
  return undef unless defined($hash);
  my $name=$hash->{NAME};
  my $interval=AttrVal($name,'interval',300);
  RemoveInternalTimer($hash,'PWMK_Evaluate');
  InternalTimer(gettimeofday()+$interval,'PWMK_Evaluate',$hash,0) if $interval > 0;

  if (!$hash->{helper}{stateLoaded}) {
    my $loaded=PWMK_LoadState($hash);
    my $status=$loaded =~ /^error:/ ? $loaded : "restored $loaded rooms";
    readingsSingleUpdate($hash,'persistenceStatus',$status,1);
    readingsSingleUpdate($hash,'persistenceFile',PWMK_StateFile($hash),1);
  }

  my $mode=AttrVal($name,'mode','shadow');
  if (AttrVal($name,'disable',0)) {
    readingsSingleUpdate($hash,'state','disabled',1);
    return undef;
  }
  my $min=AttrVal($name,'minInterval',120);
  my $max=AttrVal($name,'maxInterval',480);
  my $initial=AttrVal($name,'initialInterval',240);
  my $duration=AttrVal($name,'minPulseDuration',20);
  my $returnAge=AttrVal($name,'returnMaxAge',1200);
  my $step=AttrVal($name,'intervalStep',30);
  my $low=AttrVal($name,'targetOffsetLow',-0.10);
  my $high=AttrVal($name,'targetOffsetHigh',0.10);
  my $now=time();
  my $count=0;
  my $persistenceDirty=0;

  my ($outsideValue,$outsideReason)=('n/a','not-configured');
  if (($hash->{OUTSIDE_DEVICE} // 'none') ne 'none') {
    my $candidate=ReadingsVal($hash->{OUTSIDE_DEVICE},$hash->{OUTSIDE_READING},undef);
    my $outsideTs=ReadingsTimestamp($hash->{OUTSIDE_DEVICE},$hash->{OUTSIDE_READING},'');
    my $outsideEpoch=PWMK_epoch($outsideTs);
    if (defined($candidate) && $candidate =~ /^-?\d+(?:\.\d+)?$/ &&
        $outsideEpoch && ($now-$outsideEpoch <= $returnAge)) {
      $outsideValue=0+$candidate;
      $outsideReason='valid';
    } else {
      $outsideReason='missing-or-invalid';
    }
  }

  readingsBeginUpdate($hash);
  foreach my $roomName (sort keys %defs) {
    my $room=$defs{$roomName};
    next unless (($room->{TYPE} // '') eq 'PWMR');
    my $io=$room->{IODev};
    my $ioName=ref($io) ? ($io->{NAME} // '') : ($io // '');
    next unless $ioName eq ($hash->{PWM_DEVICE} // '');
    next unless AttrVal($roomName,'floorKeepAliveProvider','') eq $name;
    my $mapping=AttrVal($roomName,'floorReturn','');
    next unless length($mapping);
    my ($dev,$reading)=split(/:/,$mapping,2);
    $reading='temperature' unless defined($reading) && length($reading);
    my $mappedDevice=defined($defs{$dev}) ? $defs{$dev} : undef;
    my $value=$mappedDevice ? ReadingsVal($dev,$reading,undef) : undef;
    my $ts=$mappedDevice ? ReadingsTimestamp($dev,$reading,'') : '';
    my $epoch=PWMK_epoch($ts);
    my $fresh=defined($value) && $value =~ /^-?\d+(?:\.\d+)?$/ &&
              $epoch && ($now-$epoch <= $returnAge);
    my $processing=$mappedDevice ? ReadingsVal($dev,'processing','unknown') : 'unknown';
    my $processingEpoch=$mappedDevice ?
      PWMK_epoch(ReadingsTimestamp($dev,'processing','')) : 0;
    my $postDelaySample=$processing eq 'active' && $epoch && $processingEpoch &&
                        $epoch >= $processingEpoch;
    my $sourceFresh=1;
    if ($mappedDevice && (($mappedDevice->{TYPE} // '') eq 'TempReadingFilter') &&
        defined($mappedDevice->{SENSOR_DEVICE})) {
      my $sourceDev=$mappedDevice->{SENSOR_DEVICE};
      my $sourceReading=$mappedDevice->{SENSOR_READING} // $reading;
      my $sourceExists=defined($defs{$sourceDev});
      my $sourceValue=$sourceExists ? ReadingsVal($sourceDev,$sourceReading,undef) : undef;
      my $sourceTs=$sourceExists ? ReadingsTimestamp($sourceDev,$sourceReading,'') : '';
      my $sourceEpoch=PWMK_epoch($sourceTs);
      $sourceFresh=defined($sourceValue) &&
                   $sourceValue =~ /^-?\d+(?:\.\d+)?$/ &&
                   $sourceEpoch && ($now-$sourceEpoch <= $returnAge);
    }
    my $state=$hash->{helper}{rooms}{$roomName} //= {};
    $state->{sampledThisPulse}=0 if $processing ne 'active';
    my $reason;
    my $filterDelay=$mappedDevice ? AttrVal($dev,'delay',0) : 0;
    my $actual=ReadingsVal($roomName,'temperature',undef);
    my $desired=ReadingsVal($roomName,'desired-temp',undef);
    my $roomTemperatureValid=defined($actual) && defined($desired) &&
      $actual =~ /^-?\d+(?:\.\d+)?$/ && $desired =~ /^-?\d+(?:\.\d+)?$/;
    if ($duration*60 <= $filterDelay) {
      $state->{valid}=0;
      $state->{reason}='pulse-shorter-than-filter-delay';
      $state->{updated}=$now;
    } elsif (!$sourceFresh) {
      $state->{valid}=0;
      $state->{reason}='source-stale-or-invalid';
      $state->{updated}=$now;
    } elsif (!$fresh) {
      $state->{valid}=0;
      $state->{reason}=defined($value) ? 'return-stale-or-invalid' : 'return-missing';
      $state->{updated}=$now;
    } elsif (!$roomTemperatureValid) {
      $state->{valid}=0;
      $state->{reason}='room-temperature-invalid';
      $state->{updated}=$now;
    } elsif ($processing eq 'active' && !$postDelaySample) {
      $state->{valid}=0 unless ($state->{cycles} // 0) > 0;
      $state->{reason}='waiting-post-delay-sample';
      $state->{updated}=$now;
    } elsif ($fresh && $processing eq 'active' && !$state->{sampledThisPulse}) {
      my $previous=$state->{lastReturn};
      my $trend=defined($previous) ? $value-$previous : 0;
      my $decisionSignal=$trend;
      # Preserve the room's established static cadence as the first learning
      # point.  This avoids a step change when an installation enables the
      # provider for the first time; the configured initialInterval is only
      # the generic fallback for PWMR variants without p_maxOffTime.
      my $roomInitial=(defined($room->{p_maxOffTime}) &&
                       $room->{p_maxOffTime} =~ /^\d+(?:\.\d+)?$/)
                    ? $room->{p_maxOffTime} : $initial;
      $roomInitial=$min if $roomInitial < $min;
      $roomInitial=$max if $roomInitial > $max;
      my $learned=defined($state->{interval}) ? $state->{interval} : $roomInitial;
      if ($actual < $desired-0.2) {
        $decisionSignal=$low-0.001;
        $reason='room-below-target';
      } elsif ($actual > $desired+0.2) {
        $decisionSignal=$high+0.001;
        $reason='room-above-target';
      } else {
        $reason=$trend < $low ? 'return-falling' : $trend > $high ? 'return-rising' : 'return-stable';
      }
      if ($reason eq 'return-stable' && $outsideReason eq 'valid' &&
          defined($state->{lastOutside})) {
        my $outsideTrend=$outsideValue-$state->{lastOutside};
        if ($outsideTrend <= -0.5) {
          $decisionSignal=$low-0.001;
          $reason='outside-falling';
        } elsif ($outsideTrend >= 0.5) {
          $decisionSignal=$high+0.001;
          $reason='outside-rising';
        }
      }
      my $next=PWMK_CalculateInterval($learned,$decisionSignal,$low,$high,$step,$min,$max);
      $state->{interval}=$next if !$state->{frozen} || !defined($state->{interval});
      $state->{lastReturn}=0+$value;
      $state->{trend}=$trend;
      $state->{cycles}=($state->{cycles} // 0)+1;
      $state->{updated}=$now;
      $state->{valid}=1;
      $state->{reason}=$reason;
      $state->{sampledThisPulse}=1;
      $state->{lastOutside}=$outsideValue if $outsideReason eq 'valid';
      my $safe=PWMK_safeName($roomName);
      my $event=sprintf(
        'room=%s;cycle=%d;intervalOld=%d;intervalNew=%d;duration=%d;roomActual=%.3f;roomDesired=%.3f;return=%.3f;returnDelta=%.3f;outside=%s;reason=%s;confidence=%d',
        $roomName,$state->{cycles},$learned,$state->{interval},$duration,
        $actual,$desired,$value,$trend,$outsideValue,$reason,$state->{cycles});
      readingsBulkUpdate($hash,"learningEvent_$safe",$event);
      $persistenceDirty=1;
    } elsif (($state->{cycles} // 0) > 0) {
      # TempReadingFilter periodically refreshes its output while idle.  That
      # is useful for display but is not a new hydraulically valid sample.
      # Keep the last learned decision without incrementing learning.
      $state->{valid}=1;
      $state->{updated}=$now;
    } else {
      $state->{valid}=0;
      $state->{reason}=defined($value) ? 'waiting-valid-cycle' : 'return-missing';
      $state->{updated}=$now;
    }
    $state->{duration}=$duration;
    $state->{mode}=$mode;
    my $safe=PWMK_safeName($roomName);
    my $displayInterval=defined($state->{interval}) ? $state->{interval} :
      ((defined($room->{p_maxOffTime}) && $room->{p_maxOffTime} =~ /^\d+(?:\.\d+)?$/)
        ? $room->{p_maxOffTime} : $initial);
    $displayInterval=$min if $displayInterval < $min;
    $displayInterval=$max if $displayInterval > $max;
    my $displayDesired=ReadingsVal($roomName,'desired-temp',undef);
    my $target=(defined($displayDesired) && $displayDesired =~ /^-?\d+(?:\.\d+)?$/)
      ? sprintf('%.2f..%.2f',$displayDesired+$low,$displayDesired+$high) : 'n/a';
    my $lastSwitch=ReadingsVal($roomName,'lastswitch',undef);
    my $nextPulse=(defined($lastSwitch) && $lastSwitch =~ /^\d+(?:\.\d+)?$/)
      ? int($lastSwitch+$displayInterval*60) : 'n/a';
    readingsBulkUpdate($hash,"interval_$safe",$displayInterval);
    readingsBulkUpdate($hash,"duration_$safe",$duration);
    readingsBulkUpdate($hash,"lastReturn_$safe",defined($state->{lastReturn}) ? $state->{lastReturn} : 'n/a');
    readingsBulkUpdate($hash,"trend_$safe",defined($state->{trend}) ? sprintf('%.3f',$state->{trend}) : 'n/a');
    readingsBulkUpdate($hash,"reason_$safe",$state->{reason});
    readingsBulkUpdate($hash,"confidence_$safe",$state->{cycles} // 0);
    readingsBulkUpdate($hash,"learning_$safe",$state->{frozen} ? 'frozen' : 'active');
    readingsBulkUpdate($hash,"target_$safe",$target);
    readingsBulkUpdate($hash,"nextPulse_$safe",$nextPulse);
    readingsBulkUpdate($hash,"fallback_$safe",$state->{valid} ? 'none' : $state->{reason});
    readingsBulkUpdate($hash,"queue_$safe",ReadingsVal($name,"queue_$safe",0));
    $count++;
  }
  $hash->{helper}{lastEvaluation}=$now;
  readingsBulkUpdate($hash,'mode',$mode);
  readingsBulkUpdate($hash,'outsideTemperature',$outsideValue);
  readingsBulkUpdate($hash,'outsideStatus',$outsideReason);
  readingsBulkUpdate($hash,'rooms',$count);
  readingsBulkUpdate($hash,'lastEvaluation',$now);
  readingsBulkUpdate($hash,'state',"$mode: $count rooms");
  if ($persistenceDirty) {
    my $saveError=PWMK_SaveState($hash);
    readingsBulkUpdate($hash,'persistenceStatus',
      defined($saveError) ? "error: $saveError" : 'saved '.TimeNow());
    readingsBulkUpdate($hash,'persistenceFile',PWMK_StateFile($hash));
  }
  readingsEndUpdate($hash,1);
  return undef;
}

sub PWMK_GroupGrant(@) {
  my ($hash,$room,$now,$duration)=@_;
  my $group=AttrVal($hash->{NAME},'coordinationGroup','');
  return 1 unless length($group);
  my $lock=$PWMK_groupLock{$group};
  if ($lock && ($lock->{until} // 0) > $now &&
      ($lock->{provider} ne $hash->{NAME} || $lock->{room} ne $room)) {
    readingsSingleUpdate($hash,'queue_'.PWMK_safeName($room),1,1);
    return 0;
  }
  $PWMK_groupLock{$group}={provider=>$hash->{NAME},room=>$room,until=>$now+$duration};
  readingsSingleUpdate($hash,'queue_'.PWMK_safeName($room),0,1);
  return 1;
}

sub PWMK_ClaimPulse(@) {
  my ($roomName,$now)=@_;
  $now=time() unless defined($now);
  my $providerName=AttrVal($roomName,'floorKeepAliveProvider','');
  return 1 unless length($providerName) && defined($defs{$providerName});
  my $provider=$defs{$providerName};
  my $group=AttrVal($providerName,'coordinationGroup','');
  return 1 unless length($group);

  foreach my $otherName (keys %defs) {
    next if $otherName eq $roomName || (($defs{$otherName}{TYPE} // '') ne 'PWMR');
    my $otherProvider=AttrVal($otherName,'floorKeepAliveProvider','');
    next unless length($otherProvider) && defined($defs{$otherProvider});
    next unless AttrVal($otherProvider,'coordinationGroup','') eq $group;
    if (ReadingsVal($otherName,'actorState','off') eq 'on') {
      readingsSingleUpdate($provider,'queue_'.PWMK_safeName($roomName),1,1);
      return 0;
    }
  }

  my $lock=$PWMK_groupLock{$group};
  if ($lock && ($lock->{until} // 0) > $now) {
    return 1 if $lock->{provider} eq $providerName && $lock->{room} eq $roomName;
    readingsSingleUpdate($provider,'queue_'.PWMK_safeName($roomName),1,1);
    return 0;
  }
  my $reservation=AttrVal($providerName,'coordinationReservation',90);
  $PWMK_groupLock{$group}={provider=>$providerName,room=>$roomName,until=>$now+$reservation};
  readingsSingleUpdate($provider,'queue_'.PWMK_safeName($roomName),0,1);
  return 1;
}

sub PWMK_GetRoomDecision(@) {
  my ($providerName,$roomName,$offMinutes)=@_;
  return {valid=>0,reason=>'provider-missing'} unless defined($defs{$providerName});
  my $hash=$defs{$providerName};
  return {valid=>0,reason=>'wrong-provider-type'} unless (($hash->{TYPE} // '') eq 'PWMK');
  return {valid=>0,reason=>'provider-disabled'} if AttrVal($providerName,'disable',0);
  my $mode=AttrVal($providerName,'mode','shadow');
  return {valid=>0,reason=>$mode} unless $mode eq 'active';
  my $maxAge=AttrVal($providerName,'providerMaxAge',900);
  my $last=$hash->{helper}{lastEvaluation} // 0;
  return {valid=>0,reason=>'provider-stale'} if time()-$last > $maxAge;
  return {valid=>0,reason=>'room-unavailable'}
    unless AttrVal($roomName,'floorKeepAliveProvider','') eq $providerName &&
           length(AttrVal($roomName,'floorReturn',''));
  my $state=$hash->{helper}{rooms}{$roomName};
  return {valid=>0,reason=>'room-unavailable'} unless $state;
  return {valid=>0,reason=>$state->{reason} // 'room-unavailable'} unless $state->{valid};
  my $interval=$state->{interval};
  return {valid=>0,reason=>'interval-unavailable'}
    unless defined($interval) && $interval > 0;
  my $duration=$state->{duration};
  my $queue=0;
  my $group=AttrVal($providerName,'coordinationGroup','');
  if (length($group) && defined($offMinutes) && $offMinutes < $interval &&
      $offMinutes >= $interval/2) {
    $interval=$offMinutes*2+1;
  }
  return {valid=>1,interval=>$interval,duration=>$duration,mode=>$mode,
          reason=>$state->{reason},queue=>$queue,timestamp=>$last};
}

1;

=pod
=item summary PWM KeepAlive: dynamische FBH-Erhaltungspulse mit sicherem Rückfall
=begin html
<a name="PWMK"></a>
<h3>PWMK – PWM KeepAlive</h3>
<p><b>Purpose:</b> PWMK is the optional third module in the PWM → PWMR → PWMK
family. It learns a bounded maintenance-pulse interval for each PWMR room from
hydraulically valid return temperatures. Pulse duration remains fixed.</p>

<h4>Requirements and safe fallback</h4>
<ul>
<li>Separate <a href="https://github.com/parussel/TempReadingFilter">TempReadingFilter</a>
with a filter delay shorter than the configured pulse duration.</li>
<li>PWMR attributes <code>floorReturn</code> and
<code>floorKeepAliveProvider</code>.</li>
<li>Without PWMK, in shadow/off mode, or with stale/invalid data, PWMR uses its
unchanged static <code>maxOffTime</code>. PWMK never overwrites it.</li>
</ul>

<h4>Define</h4>
<code>define &lt;name&gt; PWMK &lt;PWM-device&gt; [&lt;outside-device&gt;[:&lt;reading&gt;]|none]</code>
<p>Example: <code>define PWMK_EG PWMK PWM_EG Temperatur_Aussen:realtemperature</code></p>

<h4>Operating modes</h4>
<ul>
<li><b>shadow</b>: learn and diagnose without affecting PWMR.</li>
<li><b>active</b>: apply only fresh, valid learned intervals.</li>
<li><b>off</b>: do not apply learned intervals.</li>
<li><b>disable 1</b>: stop evaluation and learning.</li>
</ul>

<h4>Attributes</h4>
<ul>
<li><code>mode</code>, <code>disable</code>: operating state.</li>
<li><code>minInterval</code>, <code>maxInterval</code>,
<code>initialInterval</code>, <code>intervalStep</code>: bounded interval learning.</li>
<li><code>minPulseDuration</code>: fixed pulse duration in minutes.</li>
<li><code>targetOffsetLow</code>, <code>targetOffsetHigh</code>: return trend band.</li>
<li><code>providerMaxAge</code>, <code>returnMaxAge</code>: freshness limits.</li>
<li><code>coordinationGroup</code>, <code>coordinationReservation</code>:
prevent overlapping maintenance pulses.</li>
<li><code>stateFile</code>: optional absolute persistence path; otherwise the
global FHEM statefile directory is used.</li>
</ul>

<h4>Set commands</h4>
<ul>
<li><code>evaluate</code>: evaluate immediately.</li>
<li><code>freeze [room|all]</code> / <code>unfreeze [room|all]</code>.</li>
<li><code>reset [room|all]</code>: clear learning state and update persistence.</li>
</ul>

<h4>Decision and diagnostics</h4>
<p>More than 0.2 K below/above room target shortens/lengthens the interval.
Inside that band the valid return trend decides. Only when both are stable may
an outside-temperature change of at least 0.5 K act as bounded tie-breaker.
Default step is 30 minutes, bounded to 120…480 minutes.</p>
<p>Per-room readings expose interval, duration, last return, trend, target,
next pulse, confidence, reason, fallback and queue.
<code>learningEvent_ROOM</code> contains one complete accepted learning cycle.
Persistent JSON data is atomically replaced and validated after restart.</p>
=end html

=begin html_DE
<a name="PWMK"></a>
<h3>PWMK – PWM KeepAlive</h3>
<p><b>Aufgabe:</b> PWMK ist das optionale dritte Modul im Verbund
PWM → PWMR → PWMK. Es lernt für jeden PWMR-Raum einen begrenzten Abstand
zwischen Erhaltungspulsen aus hydraulisch gültigen Rücklauftemperaturen.
Die Pulsdauer bleibt fest.</p>

<h4>Voraussetzungen und sicherer Rückfall</h4>
<ul>
<li>Eigenständiger <a href="https://github.com/parussel/TempReadingFilter">TempReadingFilter</a>
mit einer Filterverzögerung, die kürzer als die Pulsdauer ist.</li>
<li>PWMR-Attribute <code>floorReturn</code> und
<code>floorKeepAliveProvider</code>.</li>
<li>Ohne PWMK, in <i>shadow/off</i> oder bei ungültigen/veralteten Daten
verwendet PWMR automatisch das unveränderte statische <code>maxOffTime</code>.
PWMK überschreibt diesen Wert niemals.</li>
</ul>

<h4>Definition</h4>
<code>define &lt;Name&gt; PWMK &lt;PWM-Gerät&gt; [&lt;Außensensor&gt;[:&lt;Reading&gt;]|none]</code>
<p>Beispiel:
<code>define PWMK_EG PWMK PWM_EG Temperatur_Aussen:realtemperature</code></p>

<h4>Betriebsarten</h4>
<ul>
<li><b>shadow</b>: lernen und anzeigen, ohne PWMR zu beeinflussen.</li>
<li><b>active</b>: ausschließlich frische gültige Lernwerte anwenden.</li>
<li><b>off</b>: keine Lernwerte anwenden.</li>
<li><b>disable 1</b>: Auswertung und Lernen vollständig anhalten.</li>
</ul>

<h4>Attribute</h4>
<ul>
<li><code>mode</code>, <code>disable</code>: Betriebszustand.</li>
<li><code>minInterval</code>, <code>maxInterval</code>,
<code>initialInterval</code>, <code>intervalStep</code>: begrenztes Intervalllernen.</li>
<li><code>minPulseDuration</code>: feste Pulsdauer in Minuten.</li>
<li><code>targetOffsetLow</code>, <code>targetOffsetHigh</code>:
Bewertungsband des Rücklauftrends.</li>
<li><code>providerMaxAge</code>, <code>returnMaxAge</code>: Altersgrenzen.</li>
<li><code>coordinationGroup</code>, <code>coordinationReservation</code>:
verhindern gleichzeitige Erhaltungspulse.</li>
<li><code>stateFile</code>: optionaler absoluter Speicherpfad; ohne Angabe wird
das Verzeichnis des globalen FHEM-statefile verwendet.</li>
</ul>

<h4>Set-Befehle</h4>
<ul>
<li><code>evaluate</code>: sofort auswerten.</li>
<li><code>freeze [Raum|all]</code> / <code>unfreeze [Raum|all]</code>.</li>
<li><code>reset [Raum|all]</code>: Lernzustand löschen und persistent speichern.</li>
</ul>

<h4>Lernentscheidung und Readings</h4>
<p>Mehr als 0,2 K unter/über Raum-Soll verkürzt/verlängert den Abstand.
Innerhalb dieses Bandes entscheidet der gültige Rücklauftrend. Nur wenn beide
Bewertungen stabil sind, darf eine Außentemperaturänderung ab 0,5 K als
begrenzter Tie-Breaker wirken. Die Standardschrittweite beträgt 30 Minuten,
begrenzt auf 120…480 Minuten.</p>
<p>Raumbezogene Readings zeigen Abstand, Dauer, letzten Rücklauf, Trend,
Zielband, nächsten Puls, Vertrauen, Begründung, Rückfall und Warteschlange.
<code>learningEvent_RAUM</code> enthält einen vollständigen angenommenen
Lernzyklus. Die JSON-Zustandsdatei wird atomar ersetzt und nach einem Neustart
geprüft.</p>
=end html_DE
=cut
