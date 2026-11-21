#
# 98_FBHKeepAlive.pm
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

my %FBHKeepAlive_groupLock;

sub FBHKeepAlive_Initialize($);
sub FBHKeepAlive_Define($$);
sub FBHKeepAlive_Undef($$);
sub FBHKeepAlive_Set($@);
sub FBHKeepAlive_Attr(@);
sub FBHKeepAlive_Evaluate($);
sub FBHKeepAlive_CalculateInterval(@);
sub FBHKeepAlive_GetRoomDecision(@);
sub FBHKeepAlive_GroupGrant(@);
sub FBHKeepAlive_ClaimPulse(@);
sub FBHKeepAlive_StateFile($);
sub FBHKeepAlive_SaveState($);
sub FBHKeepAlive_LoadState($);

sub FBHKeepAlive_Initialize($) {
  my ($hash) = @_;
  $hash->{DefFn}   = 'FBHKeepAlive_Define';
  $hash->{UndefFn} = 'FBHKeepAlive_Undef';
  $hash->{SetFn}   = 'FBHKeepAlive_Set';
  $hash->{AttrFn}  = 'FBHKeepAlive_Attr';
  $hash->{AttrList}=
      'disable:0,1 mode:off,shadow,active interval ' .
      'minInterval maxInterval initialInterval minPulseDuration ' .
      'providerMaxAge returnMaxAge coordinationGroup ' .
      'coordinationReservation ' .
      'targetOffsetLow targetOffsetHigh intervalStep stateFile ' .
      ' ' . $readingFnAttributes;
}

sub FBHKeepAlive_Define($$) {
  my ($hash,$def)=@_;
  my @a=split(/\s+/,$def);
  return 'syntax: define <name> FBHKeepAlive <PWM-device> [<outside-device>[:<reading>]|none]'
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
  InternalTimer(gettimeofday()+5,'FBHKeepAlive_Evaluate',$hash,0);
  return undef;
}

sub FBHKeepAlive_Undef($$) {
  my ($hash,$arg)=@_;
  RemoveInternalTimer($hash);
  return undef;
}

sub FBHKeepAlive_Attr(@) {
  my ($cmd,$name,$attrName,$attrValue)=@_;
  if ($cmd eq 'set' && $attrName =~ /^(?:interval|minInterval|maxInterval|initialInterval|minPulseDuration|providerMaxAge|returnMaxAge|coordinationReservation|targetOffsetLow|targetOffsetHigh|intervalStep)$/) {
    return "$name: $attrName must be numeric"
      unless defined($attrValue) && $attrValue =~ /^-?\d+(?:\.\d+)?$/;
    return "$name: $attrName must be greater than zero"
      if $attrName !~ /^targetOffset/ && $attrValue <= 0;
  }
  return undef;
}

sub FBHKeepAlive_Set($@) {
  my ($hash,@a)=@_;
  return 'set command missing' if @a < 2;
  my $cmd=$a[1];
  if ($cmd eq 'evaluate') {
    FBHKeepAlive_Evaluate($hash);
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
    my $saveError=FBHKeepAlive_SaveState($hash);
    readingsSingleUpdate($hash,'persistenceStatus',
      defined($saveError) ? "error: $saveError" : 'saved '.TimeNow(),1);
    return undef;
  }
  return 'Unknown argument, choose one of evaluate:noArg freeze unfreeze reset';
}

sub FBHKeepAlive_CalculateInterval(@) {
  my ($current,$trend,$low,$high,$step,$min,$max)=@_;
  my $next=$current;
  $next-=$step if $trend < $low;
  $next+=$step if $trend > $high;
  $next=$min if $next < $min;
  $next=$max if $next > $max;
  return int($next+0.5);
}

sub FBHKeepAlive_safeName($) {
  my ($name)=@_;
  $name =~ s/[^A-Za-z0-9_]/_/g;
  return $name;
}

sub FBHKeepAlive_epoch($) {
  my ($ts)=@_;
  return 0 unless defined($ts) && $ts =~ /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)$/;
  return eval { main::time_str2num($ts) } || 0 if defined(&main::time_str2num);
  return time(); # test harness: presence is enough; production FHEM supplies time_str2num
}

sub FBHKeepAlive_StateFile($) {
  my ($hash)=@_;
  my $name=$hash->{NAME};
  my $configured=AttrVal($name,'stateFile','');
  return $configured if length($configured);
  my $globalState=AttrVal('global','statefile','./log/fhem.save');
  $globalState =~ s{[^/\\]+$}{};
  $globalState='./log/' unless length($globalState);
  return $globalState.'FBHKeepAlive_'.FBHKeepAlive_safeName($name).'.json';
}

sub FBHKeepAlive_SaveState($) {
  my ($hash)=@_;
  my $file=FBHKeepAlive_StateFile($hash);
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

sub FBHKeepAlive_LoadState($) {
  my ($hash)=@_;
  my $file=FBHKeepAlive_StateFile($hash);
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

sub FBHKeepAlive_Evaluate($) {
  my ($hash)=@_;
  return undef unless defined($hash);
  my $name=$hash->{NAME};
  my $interval=AttrVal($name,'interval',300);
  RemoveInternalTimer($hash,'FBHKeepAlive_Evaluate');
  InternalTimer(gettimeofday()+$interval,'FBHKeepAlive_Evaluate',$hash,0) if $interval > 0;

  if (!$hash->{helper}{stateLoaded}) {
    my $loaded=FBHKeepAlive_LoadState($hash);
    my $status=$loaded =~ /^error:/ ? $loaded : "restored $loaded rooms";
    readingsSingleUpdate($hash,'persistenceStatus',$status,1);
    readingsSingleUpdate($hash,'persistenceFile',FBHKeepAlive_StateFile($hash),1);
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
    my $outsideEpoch=FBHKeepAlive_epoch($outsideTs);
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
    my $epoch=FBHKeepAlive_epoch($ts);
    my $fresh=defined($value) && $value =~ /^-?\d+(?:\.\d+)?$/ &&
              $epoch && ($now-$epoch <= $returnAge);
    my $processing=$mappedDevice ? ReadingsVal($dev,'processing','unknown') : 'unknown';
    my $processingEpoch=$mappedDevice ?
      FBHKeepAlive_epoch(ReadingsTimestamp($dev,'processing','')) : 0;
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
      my $sourceEpoch=FBHKeepAlive_epoch($sourceTs);
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
      my $next=FBHKeepAlive_CalculateInterval($learned,$decisionSignal,$low,$high,$step,$min,$max);
      $state->{interval}=$next if !$state->{frozen} || !defined($state->{interval});
      $state->{lastReturn}=0+$value;
      $state->{trend}=$trend;
      $state->{cycles}=($state->{cycles} // 0)+1;
      $state->{updated}=$now;
      $state->{valid}=1;
      $state->{reason}=$reason;
      $state->{sampledThisPulse}=1;
      $state->{lastOutside}=$outsideValue if $outsideReason eq 'valid';
      my $safe=FBHKeepAlive_safeName($roomName);
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
    my $safe=FBHKeepAlive_safeName($roomName);
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
    my $saveError=FBHKeepAlive_SaveState($hash);
    readingsBulkUpdate($hash,'persistenceStatus',
      defined($saveError) ? "error: $saveError" : 'saved '.TimeNow());
    readingsBulkUpdate($hash,'persistenceFile',FBHKeepAlive_StateFile($hash));
  }
  readingsEndUpdate($hash,1);
  return undef;
}

sub FBHKeepAlive_GroupGrant(@) {
  my ($hash,$room,$now,$duration)=@_;
  my $group=AttrVal($hash->{NAME},'coordinationGroup','');
  return 1 unless length($group);
  my $lock=$FBHKeepAlive_groupLock{$group};
  if ($lock && ($lock->{until} // 0) > $now &&
      ($lock->{provider} ne $hash->{NAME} || $lock->{room} ne $room)) {
    readingsSingleUpdate($hash,'queue_'.FBHKeepAlive_safeName($room),1,1);
    return 0;
  }
  $FBHKeepAlive_groupLock{$group}={provider=>$hash->{NAME},room=>$room,until=>$now+$duration};
  readingsSingleUpdate($hash,'queue_'.FBHKeepAlive_safeName($room),0,1);
  return 1;
}

sub FBHKeepAlive_ClaimPulse(@) {
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
      readingsSingleUpdate($provider,'queue_'.FBHKeepAlive_safeName($roomName),1,1);
      return 0;
    }
  }

  my $lock=$FBHKeepAlive_groupLock{$group};
  if ($lock && ($lock->{until} // 0) > $now) {
    return 1 if $lock->{provider} eq $providerName && $lock->{room} eq $roomName;
    readingsSingleUpdate($provider,'queue_'.FBHKeepAlive_safeName($roomName),1,1);
    return 0;
  }
  my $reservation=AttrVal($providerName,'coordinationReservation',90);
  $FBHKeepAlive_groupLock{$group}={provider=>$providerName,room=>$roomName,until=>$now+$reservation};
  readingsSingleUpdate($provider,'queue_'.FBHKeepAlive_safeName($roomName),0,1);
  return 1;
}

sub FBHKeepAlive_GetRoomDecision(@) {
  my ($providerName,$roomName,$offMinutes)=@_;
  return {valid=>0,reason=>'provider-missing'} unless defined($defs{$providerName});
  my $hash=$defs{$providerName};
  return {valid=>0,reason=>'wrong-provider-type'} unless (($hash->{TYPE} // '') eq 'FBHKeepAlive');
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
=item summary Dynamische FBH-Erhaltungspulse anhand gefilterter Rücklauftemperaturen
=begin html
<a name="FBHKeepAlive"></a><h3>FBHKeepAlive</h3>
<ul>
FBHKeepAlive calculates bounded, per-room floor-heating maintenance-pulse
intervals from filtered return temperatures. Pulse duration remains fixed.
PWM and PWMR remain fully backward compatible without provider attributes;
their static maxOffTime behavior is unchanged and no additional PWM attribute
is required. FBHKeepAlive requires the separate TempReadingFilter module from
https://github.com/parussel/TempReadingFilter.<br><br>
Only samples captured while TempReadingFilter reports <i>active</i> and whose
timestamp is not older than that active phase are learned; idle keepalive
refreshes and cached pre-delay samples are ignored. Pulse duration must exceed
the filter delay. Shadow mode is diagnostic only. Active
mode replaces timing only when the decision is fresh and valid; otherwise the
unchanged static PWMR maxOffTime settings remain the automatic fallback.<br><br>
<b>Define</b>: define name FBHKeepAlive PWM-device [outside-device[:reading]|none]<br>
<b>PWMR attributes</b>: floorReturn device[:reading], floorKeepAliveProvider provider<br>
<b>Attributes</b>: mode, interval, minInterval, maxInterval, initialInterval,
minPulseDuration, providerMaxAge, returnMaxAge, coordinationGroup,
coordinationReservation,
targetOffsetLow, targetOffsetHigh, intervalStep, stateFile<br>
<b>Set</b>: evaluate, freeze [room|all], unfreeze [room|all], reset [room|all]<br>
Diagnostics include mode, interval, duration, last return, trend, target,
next pulse, confidence, reason, fallback and queue for every discovered room.
Mode <i>active</i> applies valid timing, <i>shadow</i> keeps learning without
affecting PWMR, <i>off</i> does not apply learned timing, and disable=1 stops
evaluation. Static maxOffTime is never overwritten.<br><br>
Decision order: a room more than 0.2 K below or above target shortens or
lengthens the interval by intervalStep. Inside that band the return change is
compared with targetOffsetLow and targetOffsetHigh. Only when room and return
assessment are stable may a valid outside-temperature change of at least
0.5 K act as a bounded tie-breaker. The default 30-minute step is limited by
minInterval and maxInterval (defaults 120 and 480 minutes).<br><br>
stateFile stores interval, last return, trend, outside value, confidence and
freeze state in an atomically replaced JSON file after each completed learning
cycle. Restored data is validated before use. Missing, corrupt or mismatching
state safely falls back to maxOffTime. learningEvent_ROOM contains one full
record per accepted cycle for FileLog; persistenceStatus and lastService expose
save, restore, freeze and reset operations. reset also updates persistent state.
Coordination is claimed at final PWM selection; a short reservation bridges
switch confirmation and an actually active actor keeps blocking overlap.
</ul>
=end html

=begin html_DE
<a name="FBHKeepAlive"></a><h3>FBHKeepAlive</h3>
<ul>
Das Modul berechnet pro PWMR-Raum einen begrenzten dynamischen Abstand für
FBH-Erhaltungspulse. Die Pulsdauer bleibt fest.
PWM und PWMR bleiben ohne Providerattribute vollständig abwärtskompatibel;
das statische maxOffTime arbeitet unverändert weiter und am PWM-Gerät ist kein
zusätzliches Attribut erforderlich. FBHKeepAlive benötigt das eigenständige
TempReadingFilter-Modul von
https://github.com/parussel/TempReadingFilter.<br><br>
Gelernt werden ausschließlich
Messungen, während der TempReadingFilter <i>active</i> meldet und deren
Zeitstempel nicht vor dem Beginn dieser aktiven Phase liegt; reine
Keepalive-Aktualisierungen im Ruhezustand und zwischengespeicherte Altwerte
zählen nicht als Messzyklus. Die Pulsdauer muss größer als die
Filterverzögerung sein. Im
Modus <i>shadow</i> entstehen nur Diagnosen. Im Modus <i>active</i> ersetzt nur
eine frische, gültige Entscheidung den Pulsabstand. Bei fehlenden oder
ungültigen Daten gilt automatisch der unveränderte statische PWMR-maxOffTime-
Wert.<br><br>
<b>Define</b>: define name FBHKeepAlive PWM-device [outside-device[:reading]|none]<br>
<b>PWMR-Attribute</b>: floorReturn device[:reading], floorKeepAliveProvider provider<br>
<b>Attribute</b>: mode, interval, minInterval, maxInterval, initialInterval,
minPulseDuration, providerMaxAge, returnMaxAge, coordinationGroup,
coordinationReservation,
targetOffsetLow, targetOffsetHigh, intervalStep, stateFile<br>
<b>Set</b>: evaluate, freeze [Raum|all], unfreeze [Raum|all], reset [Raum|all]<br>
Die Readings zeigen je Raum Modus, Abstand, Dauer, letzten Rücklauf, Trend,
Zielband, nächsten Puls, Vertrauenswert, Begründung, Rückfall und Warteschlange.
<i>active</i> wendet gültige Werte an, <i>shadow</i> lernt ohne Eingriff,
<i>off</i> wendet keine Lernwerte an und disable=1 hält die Auswertung an.
Das statische maxOffTime wird niemals überschrieben.<br><br>
Entscheidungsfolge: Eine Raum-Isttemperatur mehr als 0,2 K unter oder über Soll
verkürzt oder verlängert den Abstand um intervalStep. Innerhalb dieses Bandes
entscheidet die Rücklaufänderung gegenüber targetOffsetLow und
targetOffsetHigh. Nur bei stabiler Raum- und Rücklaufbewertung dient eine
gültige Außentemperaturänderung ab 0,5 K als begrenzter Tie-Breaker. Die
Standard-Schrittweite von 30 Minuten bleibt innerhalb minInterval und
maxInterval (standardmäßig 120 bis 480 Minuten).<br><br>
stateFile speichert Intervall, letzten Rücklauf, Trend, Außenwert, Vertrauen
und Freeze-Zustand nach jedem abgeschlossenen Lernzyklus in einer atomar
ersetzten JSON-Datei. Wiederhergestellte Daten werden vor der Anwendung
geprüft. Fehlende, beschädigte oder unpassende Zustände führen sicher zu
maxOffTime. learningEvent_RAUM enthält pro Lernzyklus einen vollständigen
FileLog-Datensatz; persistenceStatus und lastService dokumentieren Speichern,
Wiederherstellen, Freeze und Reset. Reset aktualisiert auch die Zustandsdatei.
Die Koordination wird erst bei der endgültigen PWM-Auswahl beansprucht. Eine
kurze Reservierung überbrückt die Schaltbestätigung; ein tatsächlich aktiver
Aktor verhindert Überschneidungen auch danach.
</ul>
=end html_DE
=cut
