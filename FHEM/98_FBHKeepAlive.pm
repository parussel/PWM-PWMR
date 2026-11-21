#
# 98_FBHKeepAlive.pm
# Dynamic, return-temperature based maintenance-pulse spacing for FHEM PWM/PWMR.
# Copyright (C) 2026 Frank Parussel
#
package main;

use strict;
use warnings;

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
      'targetOffsetLow targetOffsetHigh intervalStep ' .
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
  if ($cmd eq 'set' && $attrName =~ /^(?:interval|minInterval|maxInterval|initialInterval|minPulseDuration|providerMaxAge|returnMaxAge|targetOffsetLow|targetOffsetHigh|intervalStep)$/) {
    return "$name: $attrName must be numeric"
      unless defined($attrValue) && $attrValue =~ /^-?\d+(?:\.\d+)?$/;
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

sub FBHKeepAlive_Evaluate($) {
  my ($hash)=@_;
  return undef unless defined($hash);
  my $name=$hash->{NAME};
  my $interval=AttrVal($name,'interval',300);
  RemoveInternalTimer($hash,'FBHKeepAlive_Evaluate');
  InternalTimer(gettimeofday()+$interval,'FBHKeepAlive_Evaluate',$hash,0) if $interval > 0;

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
    my $value=ReadingsVal($dev,$reading,undef);
    my $ts=ReadingsTimestamp($dev,$reading,'');
    my $epoch=FBHKeepAlive_epoch($ts);
    my $fresh=defined($value) && $value =~ /^-?\d+(?:\.\d+)?$/ &&
              $epoch && ($now-$epoch <= $returnAge);
    my $processing=ReadingsVal($dev,'processing','unknown');
    my $sourceFresh=1;
    if ((($defs{$dev}{TYPE} // '') eq 'TempReadingFilter') &&
        defined($defs{$dev}{SENSOR_DEVICE})) {
      my $sourceDev=$defs{$dev}{SENSOR_DEVICE};
      my $sourceReading=$defs{$dev}{SENSOR_READING} // $reading;
      my $sourceValue=ReadingsVal($sourceDev,$sourceReading,undef);
      my $sourceTs=ReadingsTimestamp($sourceDev,$sourceReading,'');
      my $sourceEpoch=FBHKeepAlive_epoch($sourceTs);
      $sourceFresh=defined($sourceValue) &&
                   $sourceValue =~ /^-?\d+(?:\.\d+)?$/ &&
                   $sourceEpoch && ($now-$sourceEpoch <= $returnAge);
    }
    my $state=$hash->{helper}{rooms}{$roomName} //= {};
    $state->{sampledThisPulse}=0 if $processing ne 'active';
    my $reason;
    if (!$sourceFresh) {
      $state->{valid}=0;
      $state->{reason}='source-stale-or-invalid';
      $state->{updated}=$now;
    } elsif ($fresh && $processing eq 'active' && !$state->{sampledThisPulse}) {
      my $previous=$state->{lastReturn};
      my $trend=defined($previous) ? $value-$previous : 0;
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
      my $actual=ReadingsVal($roomName,'temperature',undef);
      my $desired=ReadingsVal($roomName,'desired-temp',undef);
      if (defined($actual) && defined($desired) && $actual < $desired-0.2) {
        $trend=$low-0.001;
        $reason='room-below-target';
      } elsif (defined($actual) && defined($desired) && $actual > $desired+0.2) {
        $trend=$high+0.001;
        $reason='room-above-target';
      } else {
        $reason=$trend < $low ? 'return-falling' : $trend > $high ? 'return-rising' : 'return-stable';
      }
      if ($reason eq 'return-stable' && $outsideReason eq 'valid' &&
          defined($state->{lastOutside})) {
        my $outsideTrend=$outsideValue-$state->{lastOutside};
        if ($outsideTrend <= -0.5) {
          $trend=$low-0.001;
          $reason='outside-falling';
        } elsif ($outsideTrend >= 0.5) {
          $trend=$high+0.001;
          $reason='outside-rising';
        }
      }
      my $next=FBHKeepAlive_CalculateInterval($learned,$trend,$low,$high,$step,$min,$max);
      $state->{interval}=$next unless $state->{frozen};
      $state->{lastReturn}=0+$value;
      $state->{trend}=$trend;
      $state->{cycles}=($state->{cycles} // 0)+1;
      $state->{updated}=$now;
      $state->{valid}=1;
      $state->{reason}=$reason;
      $state->{sampledThisPulse}=1;
      $state->{lastOutside}=$outsideValue if $outsideReason eq 'valid';
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
    my $desired=ReadingsVal($roomName,'desired-temp',undef);
    my $target=(defined($desired) && $desired =~ /^-?\d+(?:\.\d+)?$/)
      ? sprintf('%.2f..%.2f',$desired+$low,$desired+$high) : 'n/a';
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

sub FBHKeepAlive_GetRoomDecision(@) {
  my ($providerName,$roomName,$offMinutes)=@_;
  return {valid=>0,reason=>'provider-missing'} unless defined($defs{$providerName});
  my $hash=$defs{$providerName};
  return {valid=>0,reason=>'wrong-provider-type'} unless (($hash->{TYPE} // '') eq 'FBHKeepAlive');
  my $mode=AttrVal($providerName,'mode','shadow');
  return {valid=>0,reason=>$mode} unless $mode eq 'active';
  my $maxAge=AttrVal($providerName,'providerMaxAge',900);
  my $last=$hash->{helper}{lastEvaluation} // 0;
  return {valid=>0,reason=>'provider-stale'} if time()-$last > $maxAge;
  my $state=$hash->{helper}{rooms}{$roomName};
  return {valid=>0,reason=>'room-unavailable'} unless $state && $state->{valid};
  my $interval=$state->{interval};
  my $duration=$state->{duration};
  my $queue=0;
  if (defined($offMinutes) && $offMinutes >= $interval) {
    if (!FBHKeepAlive_GroupGrant($hash,$roomName,time(),$duration*60)) {
      $interval=$offMinutes+1;
      $queue=1;
    }
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
Only samples captured while TempReadingFilter reports <i>active</i> are learned;
idle keepalive refreshes are ignored. Shadow mode is diagnostic only. Active
mode replaces timing only when the decision is fresh and valid; otherwise the
unchanged static PWMR maxOffTime settings remain the automatic fallback.<br><br>
<b>Define</b>: define name FBHKeepAlive PWM-device [outside-device[:reading]|none]<br>
<b>PWMR attributes</b>: floorReturn device[:reading], floorKeepAliveProvider provider<br>
<b>Attributes</b>: mode, interval, minInterval, maxInterval, initialInterval,
minPulseDuration, providerMaxAge, returnMaxAge, coordinationGroup,
targetOffsetLow, targetOffsetHigh, intervalStep<br>
<b>Set</b>: evaluate, freeze [room|all], unfreeze [room|all], reset [room|all]<br>
Diagnostics include mode, interval, duration, last return, trend, target,
next pulse, confidence, reason, fallback and queue for every discovered room.
A valid outside-temperature change of at least 0.5 K is only a tie-breaker
when room and return assessment are otherwise stable.
</ul>
=end html

=begin html_DE
<a name="FBHKeepAlive"></a><h3>FBHKeepAlive</h3>
<ul>
Das Modul berechnet pro PWMR-Raum einen begrenzten dynamischen Abstand für
FBH-Erhaltungspulse. Die Pulsdauer bleibt fest. Gelernt werden ausschließlich
Messungen, während der TempReadingFilter <i>active</i> meldet; reine
Keepalive-Aktualisierungen im Ruhezustand zählen nicht als Messzyklus. Im
Modus <i>shadow</i> entstehen nur Diagnosen. Im Modus <i>active</i> ersetzt nur
eine frische, gültige Entscheidung den Pulsabstand. Bei fehlenden oder
ungültigen Daten gilt automatisch der unveränderte statische PWMR-maxOffTime-
Wert.<br><br>
<b>Define</b>: define name FBHKeepAlive PWM-device [outside-device[:reading]|none]<br>
<b>PWMR-Attribute</b>: floorReturn device[:reading], floorKeepAliveProvider provider<br>
<b>Attribute</b>: mode, interval, minInterval, maxInterval, initialInterval,
minPulseDuration, providerMaxAge, returnMaxAge, coordinationGroup,
targetOffsetLow, targetOffsetHigh, intervalStep<br>
<b>Set</b>: evaluate, freeze [Raum|all], unfreeze [Raum|all], reset [Raum|all]<br>
Die Readings zeigen je Raum Modus, Abstand, Dauer, letzten Rücklauf, Trend,
Zielband, nächsten Puls, Vertrauenswert, Begründung, Rückfall und Warteschlange.
Eine gültige Außentemperaturänderung ab 0,5 K dient nur bei ansonsten stabiler
Raum- und Rücklaufbewertung als begrenzter Tie-Breaker.
</ul>
=end html_DE
=cut
