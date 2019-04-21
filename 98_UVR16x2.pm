############################################################################
# fhem Modul zur Ansteuerung von UVR16x2 via CAN (candump/cansend)
##############################################################################

package main;

use strict;
use warnings;

use IO::Select;

use Time::HiRes qw(time); # Required for sending can-time
use Time::Local;

my %Units = ( # Type => [Factor, Unit]
"Dimensionslos" => [1, ""],
"Dimensionslos_(.5)" => [0.5, ""],
"Dimensionslos_(.1)" => [0.1, ""],
"Arbeitszahl" => [0.01, ""],
"Temperatur_(°C)" => [0.1, "°C"],
"Globalstrahlung" => [1, "W/m²"],
"Prozent" => [0.1, "%"],
"Absolute_Feuchte" => [0.1, "g/m³"],
"Druck_bar" => [0.01, "bar"],
"Druck_mbar" => [0.1, "mbar"],
"Druck_Pascal" => [1, "Pascal"],
"Durchfluss_l/min" => [1, "l/min"],
"Durchfluss_l/h" => [1, "l/h"],
"Durchfluss_l/d" => [1, "l/d"],
"Durchfluss_m³/min" => [1, "m³/min"],
"Durchfluss_m³/h" => [1, "m³/h"],
"Durchfluss_m³/d" => [1, "m³/d"],
"Leistung" => [0.1, "kW"],
"Spannung" => [0.01, "V"],
"Stromstärke_mA" => [0.1, "mA"],
"Stromstärke_A" => [0.1, "A"],
"Widerstand" => [0.01, "kΩ"],
"Geschwindigkeit_km/h" => [1, "km/h"],
"Geschwindigkeit_m/s" => [1, "m/s"],
"Winkel_(Grad)" => [0.1, "°"],
);

#
# FHEM module intitialisation
# defines the functions to be called from FHEM
#########################################################################
sub UVR16x2_Initialize($)
{
    my ($hash) = @_;

    $hash->{ReadFn}  = "UVR16x2_Read";
	$hash->{ReadyFn}  = "UVR16x2_Ready";
    $hash->{DefFn}   = "UVR16x2_Define";
    $hash->{UndefFn} = "UVR16x2_Undef";
    $hash->{NotifyFn} = "UVR16x2_Notify";
    $hash->{GetFn}   = "UVR16x2_Get";
    $hash->{SetFn}   = "UVR16x2_Set";
    $hash->{AttrFn}  = "UVR16x2_Attr";
    $hash->{AttrList} = "SendAsNodeId ".
                        "SendInterval ".
						"SendNewTimeInterval ";
    my $units = "";
    for my $unit (keys %Units) {
        $units .= "," unless $units eq "";
        $units .= $unit
    }
    for (my $i = 1; $i < 33; $i++) {
        $hash->{AttrList} .= sprintf("GetFactorAnalog%02d", $i).":".$units." "; # Names of unit
        $hash->{AttrList} .= sprintf("SetFactorAnalog%02d", $i).":".$units." ";
    }
}

#
# Define command
#########################################################################                                   #
sub UVR16x2_Define($$)
{
    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );

    return "wrong syntax: define <name> UVR16x2 can-device(can0) node-id(of UVR)"
      if ( @a < 4 );

    my $name   = $a[0];
    my $dev    = $a[2];
    my $nodeid = $a[3];

    $hash->{DeviceName} = $dev;
    $hash->{NodeId} = $nodeid;

    my $ret = UVR16x2_InitDev($hash); # Open process and assign to FD
    return $ret;
}


sub UVR16x2_InitDev($)
{
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $dev = $hash->{DeviceName};

    $hash->{candumppid} = open(my $FD, "candump $dev |");
    $hash->{FD} = $FD; # Must be FD because of Select loop of fhem

    return "Failed to open candump" unless $hash->{candumppid};
    $selectlist{$name.$dev} = $hash; # add to loop of selects
    $hash->{STATE} = "Initialized";
	$hash->{select} = IO::Select->new([$hash->{FD}]); # Make our own select to use at Read and Ready
	
	UVR16x2_SendNewTime($hash);
	
	return undef;
}

sub UVR16x2_SendNewTime($) # Sends a time broadcast onto the can-network.
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $dev = $hash->{DeviceName};

	my $can_epoch = 441763200;

	my $time = time();
	my $diff = ($time *1000) %1000;
	my $localepochinms = (timegm(localtime($time))*1000 + $diff);
	my $ms = $localepochinms % 86400000;
	my $cmd = "cansend $dev 100#";
	for (my $x = 0; $x < 4; $x++) { # First 4 bytes of ms since 00:00
	  $cmd .= sprintf("%02x", ($ms >> ($x * 8)) & hex "FF");
	}
	
	# Then 2 bytes days since 1.1.1984 ($can_epoch)
	
	my $days = ($localepochinms - $can_epoch * 1000 - $ms) / 86400000;
	
	$cmd .= sprintf("%02x", $days & hex "FF") . sprintf("%02x", $days >> 8);
	
	Log3 $name, 4, "$name: Executing: $cmd (Current local epoch (ms): ${localepochinms}, ms since 00:00: ${ms}, days since 1.1.1984: $days";
	system($cmd);

	my $interval = AttrVal($name, "SendNewTimeInterval", undef); # If not set, DO NOT make a new timer.
	InternalTimer(gettimeofday() + $interval, "UVR16x2_SendNewTime", $hash, 0) if $interval;
}


#
# undefine command when device is deleted
#########################################################################
sub UVR16x2_Undef($$)
{
    my ( $hash, $arg ) = @_;
    UVR16x2_CloseDev($hash); # Kill process
	RemoveInternalTimer($hash, "UVR16x2_SendInputs");
	RemoveInternalTimer($hash, "UVR16x2_SendNewTime");
    return undef;
}

sub UVR16x2_Notify($$$)
{
    my ($own_hash, $dev_hash) = @_;
    my $ownName = $own_hash->{NAME}; # own name / hash

    return "" if(IsDisabled($ownName)); # Return without any further action if the module is disabled

    my $devName = $dev_hash->{NAME}; # Device that created the events

    return unless $devName eq "global"; # we need just globals for shutdown/initialized

    my $events = deviceEvents($dev_hash,1);
    return if( !$events );

    foreach my $event (@{$events}) {
        $event = "" if(!defined($event));

        if ($event eq "SHUTDOWN") {
            UVR16x2_CloseDev($own_hash); # Kill process
        } elsif ($event eq "INITIALIZED") {
            UVR16x2_SendInputs($own_hash); # Sending Inputs before initialied = DEATH
        }
    }
}

sub UVR16x2_CloseDev($) # Param: hash Called when to kill candump.
{
    my ( $hash ) = @_;
	my $name = $hash->{NAME};
	my $dev = $hash->{DeviceName}; # eg can0.
    kill "KILL", $hash->{candumppid};
    close $hash->{FD}; # Will wait for process exit, but sends no signal: kill needed
    $hash->{candumppid} = undef;
	delete($hash->{select}); # No process = Nothing to read
    delete($selectlist{$name.$dev}); # remove from select list
}

# Attr command
#########################################################################
sub
UVR16x2_Attr(@) # TODO: Check units
{
    my ($cmd,$name,$aName,$aVal) = @_;
    # $cmd can be "del" or "set"
    # $name is device name
    # aName and aVal are Attribute name and value
	
    my $hash = $defs{$name};
    Log3 $name, 4, "$name: Attr called with @_";
	
	if ($aName eq "SendInterval") {
		if ($cmd eq "set") {
			if ($aVal !~ /^\d+$/ or int($aVal) < 5 or int($aVal) > 600) {
				return "Interval not numeric or in a valid range (5-600)"
			}
		}
		RemoveInternalTimer($hash, "UVR16x2_SendInputs");
		UVR16x2_SendInputs($hash); # This will set a new Timer
	} elsif ($aName eq "SendAsNodeId") {
		if ($cmd eq "del") {
			RemoveInternalTimer($hash, "UVR16x2_SendInputs");
		} else {
			if ($aVal !~ /^\d+$/ or int($aVal) < 1 or int($aVal) > 63) {
				return "NodeId not numeric or in a valid range (1-63)"
			}
		}
	} elsif ($aName eq "SendNewTimeInterval") {
		if ($cmd eq "del") {
			RemoveInternalTimer($hash, "UVR16x2_SendNewTime");
		} elsif ($aVal !~ /^\d+$/ or int($aVal) < 5 or int($aVal) > 86400) {
			return "Interval not numeric or in a valid range (5-86400)"
		} else {
			RemoveInternalTimer($hash, "UVR16x2_SendNewTime");
			UVR16x2_SendNewTime($hash);
		}
	} elsif ($aName =~ /^(Get|Set)FactorAnalog\d\d$/) {
		my $valid = 0; # Valid unit
		my $validAttr = "";
		for my $key (keys %Units) {
			if ($aVal eq $key) {
				$valid = 1;
				last;
			} elsif ($validAttr ne "") {
				$validAttr .= ", ";
			}
			$validAttr .= $key; # Build a valid units array
		}
		return "Unknown unit $aVal, choose one of $validAttr" unless $valid;
	}
    return undef;
}

my $UVR16x2_SetVals = "SendNewTime:noArg SendInputs:noArg "; # Help
for (my $UVR16x2_SetValsI = 1; $UVR16x2_SetValsI < 33; $UVR16x2_SetValsI++) {
  $UVR16x2_SetVals .= sprintf("Analog%02d", $UVR16x2_SetValsI) . " ";
  $UVR16x2_SetVals .= sprintf("Digital%02d", $UVR16x2_SetValsI) . ":0,1 ";
}
# SET command
#########################################################################
sub UVR16x2_Set($@)
{
    my ( $hash, @a ) = @_;
	if ( @a == 2 && $a[1] =~ /(SendNewTime|SendInputs)/) {
		if ($1 eq "SendNewTime") {
			RemoveInternalTimer($hash, "UVR16x2_SendNewTime");
			UVR16x2_SendNewTime($hash);
		} else {
			RemoveInternalTimer($hash, "UVR16x2_SendInputs");
			UVR16x2_SendInputs($hash);
		}
		return undef;
	}
    return "Unknown argument ?, choose one of $UVR16x2_SetVals" if @a != 3;

    # @a is an array with DeviceName, SetName, Rest of Set Line
    my $name = shift @a;
    my $attr = shift @a;
    my $val  = shift @a;

    return "Not a valid number" unless $val =~ /^\d+$/; # TODO: Maybe allow units?

    return "Unknown argument $attr, choose one of $UVR16x2_SetVals" if ($attr !~ /^(Analog|Digital)(\d\d)$/);
    my $digital = $1 eq "Digital"; # First group of regex
    my $inputnum = int($2); # and second

    return "Unknown argument $attr, choose one of $UVR16x2_SetVals" if $inputnum < 1 or $inputnum > 32;
    return "Unknown argument $attr, choose one of $UVR16x2_SetVals" if $digital and $val ne "0" and $val ne "1";

    readingsSingleUpdate($hash, "Set$attr", $val, 1); # Store setting, as ALWAYS all digital values and all analog values are send. If we dont send the other digital vals f.e., we kill the other values to 0 again (which isnt wanted,)

    RemoveInternalTimer($hash, "UVR16x2_SendInputs"); # Kill old Timer to start a new one afterwards
    UVR16x2_SendInputs($hash);
    return undef;
}

sub UVR16x2_SendInputs($) # Called on initialized and from then every Attr: SendInterval seconds, also on set command.
{
    my ( $hash ) = @_;

	my $name = $hash->{NAME};
	
    return (Log3 $name, 2, "$name: Skipping SendInputs due to no AttrVal(SendAsNodeId) set!") unless AttrVal($name, "SendAsNodeId", undef);

    #Digital
    my $num = 0;
    for (my $i = 0; $i < 4; $i++) {
		for (my $ii = 8; $ii > 0; $ii--) {
			my $current = $i * 8 + $ii; # Input num, begins at 1
			my $bitpos = 31 - $i * 8 - 8 + $ii; # Position of bit in the 4 bytes, 31 . . . . . . 24 | 23 . . . . . . 16 | 15 . . . . . . 8 | 7 . . . . . . 0
			$num += ReadingsVal($name, sprintf("SetDigital%02d", $current), 0) << $bitpos;
			Log3 $name, 6, "$name: $i $ii ". $current . " ".$bitpos;
		}
    }

	my $cmd = "cansend $hash->{DeviceName} " . sprintf("%03x", (hex "180") + int(AttrVal($name, "SendAsNodeId", undef))) . "#" . sprintf("%08x", $num)."00000000"; # id # Digital bytes + padding/zeroes. Length must be 8 bytes
	
	Log3 $name, 4, "$name: Executing: " . $cmd;
    system($cmd); # send!

    #Analog
    my @sends = (hex "200", hex "280", hex "300", hex "380", hex "240", hex "2C0", hex "340", hex "3C0");
    for (my $i = 0; $i < 8; $i++) {
        $sends[$i] += int(AttrVal($name, "SendAsNodeId", 63));
        my $txt = ""; # Our compiled can-message
        for (my $ii = 0; $ii < 4; $ii++) { # For loop for the 4 inputs within the 8 parts.
            my $input = $i * 4 + $ii + 1; # Calculate current Input to send
            my $val = ReadingsVal($name, sprintf("SetAnalog%02d", $input), 0); # get the value
			my $factor = AttrVal($name, sprintf("SetFactorAnalog%02d", $input), undef);
            if ($factor) { # If a factor is set,
                $val = $val / $Units{$factor}[0]; # reverse it
            } else {$factor = "";}
			$val = unpack("S", pack("s", $val)); # Make signed to unsigned. Pack is confisung.... :D
            $txt .= sprintf("%02x", $val & hex "FF") . sprintf("%02x", $val >> 8); # Swichting Bytes, Low byte is first...
			Log3 $name, 6, "$name: $i * 4 + $ii + 1 = $input = $val $factor $txt";
        }
		$cmd = "cansend $hash->{DeviceName} " . sprintf("%03x", $sends[$i]) . "#$txt";
		Log3 $name, 4, "$name: Executing: " . $cmd;
        system($cmd); # send!
    }
                                                                                                    # 0 = Do not wait for Init done. 1 = wait for init done.
    InternalTimer(gettimeofday() + AttrVal($name, "SendInterval", 30), "UVR16x2_SendInputs", $hash, 0);
}

# GET command
#########################################################################
sub UVR16x2_Get($@) # TODO: Maybe manual values? like idx + subidx?
{
    my ( $hash, @a ) = @_;
    return "\"set UVR16x2\" needs at least one argument" if ( @a < 2 );

    # @a is an array with DeviceName, GetName
    my $name = shift @a;
    my $attr = shift @a;

    return undef;
}


#########################################################################
# called from the global loop, when the select for hash->{FD} reports data
sub UVR16x2_Read($)
{
    my ($hash) = @_;
    my $name = $hash->{NAME};
	my $handle = $hash->{FD};
    readingsBeginUpdate($hash);
    while ($hash->{select}->can_read(0)) { # if we just directly do <$handle>, we block fhem - unwanted.
		my $line = <$handle>;
		$line =~ s/(\r|\n)//g; # kill newlines
        my @words = split / /, $line, 10;
        my $id = hex $words[4]; # target id.
        my @bytes = split / /, $words[9]; # our hex/text bytes
		my @hbytes = []; # our numeric bytes
        for (my $i = 0; $i < scalar @bytes; $i++) {
            $hbytes[$i] = hex $bytes[$i];
        }
        next if ($id & hex "3F") != $hash->{NodeId}; # Skip if not targeted at us.
		Log3 $name, 5, "$name: $words[4] with $words[9] in space " . sprintf("%03x", $id & hex "7C0");

        my $space = $id & hex "7C0"; # which target space, e.g. Digital/Analog
        if ($space == hex "700") { # Heartbeat
            if ($hbytes[0] == hex "00") {
                readingsBulkUpdate($hash, "UVRstate", "BootUp");
            } elsif ($hbytes[0] == hex "04") {
                readingsBulkUpdate($hash, "UVRstate", "Stopped");
            } elsif ($hbytes[0] == hex "05") {
                readingsBulkUpdate($hash, "UVRstate", "Operational");
            } elsif ($hbytes[0] == hex "7F") {
                readingsBulkUpdate($hash, "UVRstate", "Pre-Operational");
            }
        } elsif ($space == hex "180") { # Digital
			for (my $i = 0; $i < 4; $i++) {
				my $byte = $hbytes[$i];
				for (my $ii = 8; $ii > 0; $ii--) {
					my $bit = ($byte >> ($ii - 1)) & 1;
					my $current = $i * 8 + $ii;
					if ($bit or ReadingsVal($name, sprintf("Digital%02d", $current), 55) != 55) { # skip updating val if never used or now used.
						readingsBulkUpdate($hash, sprintf("Digital%02d", $current), $bit); # update val
					}
				}
			}
        } elsif (($space & hex "200") == hex "200") {# Probably Analog
            my $i = -55; # Dummy.
            if ($space == hex "200") { # Offset *4
                $i = 0;
            } elsif ($space == hex "280") {
                $i = 1;
            } elsif ($space == hex "300") {
                $i = 2;
            } elsif ($space == hex "380") {
                $i = 3;
            } elsif ($space == hex "240") {
                $i = 4;
            } elsif ($space == hex "2C0") {
                $i = 5;
            } elsif ($space == hex "340") {
                $i = 6;
            } elsif ($space == hex "3C0") {
                $i = 7;
            }
            unless ($i == -55) { # Definitly Analog
                for (my $ii = 0; $ii < 4; $ii++) { # Pos + 1 in byte array.
                    my $current = $i * 4 + $ii + 1;
                    next unless my $factor = AttrVal($name, sprintf("GetFactorAnalog%02d", $current), undef); # Skip if no Factor defined
					Log3 $name, 6, "$name: " . hex($bytes[2 * $ii + 1].$bytes[2 * $ii]). " " . $bytes[2 * $ii + 1].$bytes[2 * $ii];
                    my $val = unpack("s", pack("S", hex $bytes[2 * $ii + 1].$bytes[2 * $ii])) * $Units{$factor}[0]; # Make signed value and apply factor.
                    readingsBulkUpdate($hash, sprintf("Analog%02d", $current), $val . " ".$Units{$factor}[1]); # update val
                }
            }
        }
    }
    readingsEndUpdate( $hash, 1 );
    return "";
}

sub UVR16x2_Ready($) # Dunno if select works on windows
{
    my ($hash) = @_;
    # try to reopen if state is disconnected
    return UVR16x2_InitDev($hash)
      unless ( $hash->{FD});
	  
	my $ret = $hash->{select}->can_read(0);
	Log3 $hash->{NAME}, 6, "$hash->{NAME} called ReadyB with ${ret}!";
    return $ret;
}

1; # Required!!!

=pod
=begin html

<a name="UVR16x2"></a>
<h3>UVR16x2</h3>

<ul>
    This module implements an Interface to an UVR16x2, shipped by Technische Alternative (ta.co.at), via CAN-Bus.
	When defined, this module will set the time on every UVR16x2 on the defined can-network to the raspi's one. (UVR16x2 save clock on shutdown and read on bootup, and clock will be time behind)
    <br><br>
    <b>Prerequisites</b>
    <ul>
        <br>
        <li>
            This module requires an UVR16x2. Maybe it works with an UVR1611, but there are only 16 inputs/outputs.
        </li>
    </ul>
    <br>

    <a name="UVR16x2define"></a>
    <b>Define</b>
    <ul>
        <br>
        <code>define &lt;name&gt; ArduCounter &lt;device&gt; &lt;node-id&gt;</code>
        <br>
	    &lt;device&gt; specifies the can network interface (e.g. can0) to communicate with the CAN-Network.<br>
		
        Node-Id is the CAN-Node-Id defined in the CAN-Settings of your UVR. Min. 1 max. 63.
        <br>
        Example:<br>
        <br>
        <ul><code>define UVR UVR16x2 can0 44</code></ul>
		This will create a device listening on can0 for can-outputs of node 44.
    </ul>
    <br>

    <a name="UVR16x2configuration"></a>
    <b>Configuration of UVR16x2</b><br><br>
    <ul>
        The only thing to <u>receive</u> values to do is setting an unit for the analogue outputs which are used by the UVR.
		Digital outputs are created in fhem when they are first set ON!
		
		To <u>send/set</u> values you need to specify a SendAsNodeId attribute, for every analogue output to use a unit using attribute SetFactorAnalog?? and (optionally) a SendInterval (defaults to 30).
		Then you can send values, f.e. <pre>set UVR Analog01 33.4</pre> to send a value of 33.4 to the first analogue output of the virtual UVR created by the module.
        <br><br>
        Full example:<br>
        <pre>
        define UVR UVR16x2 can0 44
        attr UVR SendAsNodeId 45
        attr UVR SendInterval 60 # Send every 60 seconds = minute ALL inputs
        attr UVR SetFactorAnalog01 Temperatur_(°C)
        attr UVR GetFactorAnalog01 Temperatur_(°C)
		set UVR Analog01 24.5 # Set first analogue output of virtual uvr to 24.5 °C
        </pre>
    </ul>
    <br>

    <a name="UVR16x2set"></a>
    <b>Set-Commands</b><br>
    <ul>
		<li><b>SendInputs</b></li>
			This command sends ALL inputs again. Useful after detecting if an UVR is back online
		<li><b>SendNewTime</b></li>
			This command sends a new Time sync to the network. Useful after detecting that an UVR is back online
        <li><b>&lt;InputName&gt;</b></li> 
            send the value to the UVR16x2. <br>
			InputName is Digital/Analog + a input number, formatted as 2 digits. e.g. Digital06<br>
			After InputName the value is required. Digital = 0 for Off, 1 for On.<br>
    </ul>
    <br>
    <!--<a name="UVR16x2get"></a>
    <b>Get-Commands</b><br>
    <ul>
        <li><b>info</b></li> 
            send the internal command <code>show</code> to the Arduino board to get current counts<br>
            this is not needed for normal operation but might be useful sometimes for debugging<br>
    </ul>-->
    <br>
    <a name="UVR16x2attr"></a>
    <b>Attributes</b><br><br>
    <ul>
        <li><b>GetFactorAnalog*</b></li> 
            Defines an unit for the incoming value. See the attr-help to get a list of supported units.<br>
        <li><b>SetFactorAnalog*</b></li> 
            Defines an unit for the outgoing value. See the attr-help to get a list of supported units.<br>
        <li><b>SendAsNodeId</b></li> 
            Defines the nodeid for the virtual UVR.<br>
        <li><b>SendInterval</b></li> 
            Defines the interval to send all outputs of the virtual UVR.<br>
        <li><b>SendNewTimeInterval</b></li> 
            Defines the interval to send a new time to the network.<br>
		<li><b>verbose</b></li>
			Defines the loglevel of module. Recommended while setting up: 4, operational: 3. EXTREM debugging: 6. <br>
			On 3, it will log just skipped inputs send.<br>
			On 4, it will also log every command executed (every can-message send)<br>
			On 5, it will also log every can-message received (coming from the real UVR)<br>
			On 6, it will log for EVERY input/output one line, just for debugging while changing the script.<br>
    </ul>
    <br>
    <b>Readings / Events</b><br>
    <ul>
        The module creates the following readings and events for each digital input and defined analogue input, and for changing the send values:
        <li><b>Analog*</b> and <b>Digital*</b></li> 
            the current value on the output of the real UVR
        <li><b>SetAnalog*</b> and <b>SetDigital*</b></li> 
            the current set value of the virtual UVR's output.
		<li><b>UVRstate</b></li>
			the current state of the real UVR. AFAIK, it always sends Operational, and never Stopped. Watch the time of this, if more than 10 secs passed, then it is probably down.
    </ul>
    <br>
</ul>

=end html
=cut

