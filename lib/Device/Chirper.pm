#!/usr/bin/perl
# dev notes: /dev/ttyS0, 19200, 8N1
package Device::Chirper;
use strict;
use Device::Modem;
use Carp qw (croak);
use Data::Dumper;
use constant {
    CONNECTED => 1,
};

sub new {
    my $class = shift;
    my %opts = @_;
    my $port = $opts{port} || '/dev/ttyS0';
    my $baud = $opts{baud} || 19200;

    my $self = {
        m         => Device::Modem->new(port => $port),
        baud      => $baud,
        callbacks => {},
    };

    bless $self, $class;
    return $self;
}

sub set_callback {
    my ($self, $action, $cb) = @_;
    $self->{callbacks}->{$action} = $cb;
}

sub call_callback {
    my ($self, $action, @params) = @_;
    my $cb = $self->{callbacks}->{$action};
    return $cb->($self, @params) if $cb;
}

sub m    { $_[0]->{m} }
sub baud { $_[0]->{baud} }

sub dial {
    my ($self, $num, $timeout) = @_;
    $timeout ||= 5;
    debug("Dialing $num");

    my ($ok, $ans) = $self->m->dial($num, $timeout);
    if ($ok || $ans =~ /OK/i) {
        $self->at("AT+WVAR=1,1"); # start audio uplink
        $self->play_chirp_outgoing;
        debug($ans);
        return 1;
    } else {
        debug("Error dialing $num: $ans");
        return 0;
    }
}

sub play_chirp_outgoing {
    my $self = shift;
    $self->at("AT+CRTG=8"); # play charp
}

sub play_chirp_incoming {
    my $self = shift;
    $self->at("AT+CRTG=9"); # charp charp
}

sub at {
    my ($self, $cmd) = @_;
    debug(">> $cmd");
    $self->m->atsend($cmd . "\r\n");
    my $res = $self->m->answer();
    debug("<< $res") if $res;
    return $res;
}

sub connect {
    my $self = shift;
    return 1 if $self->is_connected;

    my $ret = $self->m->connect(baudrate => $self->baud);
    $self->{_connected} = $ret;
    $self->call_callback(CONNECTED) if $ret;
    return $ret;
}

sub is_connected {
    my $self = shift;
    return 0 unless $self->{_connected};
    return $self->m->is_active();
}

sub hangup {
    my $self = shift;
    return $self->at("ATH");
}

sub init {
    my $self = shift;

    if ($self->connect) {
        debug("Resetting...");
        #$self->m->reset;
        # send init string
        debug("Initing...");
        $self->at("Z");            # init
        $self->m->send_init_string;
        $self->at("AT+WVMODE=0");  # multiservice iDEN phone mode

        $self->at("AT+WS46=24");   # packet data services
        $self->at("AT+WS45=3");   # SLIP
        $self->at("AT+COPS=0");    # connect to iDEN system
        debug("Registering...");
        $self->at("AT+WPREG");    # connect to iDEN system

        $self->at("AT+WS46=23");
        $self->at("AT+WS45=0");    # DTE stack = transparent char stream
        $self->set_mode("chirp");
        return 1;
    } else {
        return 0;
    }
}

sub set_mode {
    my ($self, $mode) = @_;

    my $class;
    if ($mode eq 'chirp') {
        $class = 1;
    } elsif ($mode eq 'alert') {
        $class = 2;
    } elsif ($mode eq 'voice') {
        $class = 0;
    } else {
        croak "unknown mode $mode";
    }

    $self->at("AT+WVCLASS=$class");
    $self->at("AT+FCLASS=8"); # voice services

    if ($class == 1 || $class == 2) {
        $self->chirp_stax;
    } elsif ($class == 0) {
        $self->voice_stax;
    }

    debug("Now in $mode mode");
}

sub chirp_stax {
    my $self = shift;

    $self->at("AT+WVAR=2,1"); # start audio downlink
    $self->at("AT+S0=1");     # autoanswer on 1st ring
    #$self->at("AT+WVAR=3,0"); # stop audio interconnect
}

sub voice_stax {
    my $self = shift;

    $self->at("AT+WVAR=2,1"); # start audio downlink
    $self->at("AT+WVAR=3,1"); # start audio interconnect

    #$self->at("AT+WVAR=1,0"); # stop audio uplink
    #$self->at("AT+WVAR=2,0"); # start audio downlink
}

# returns hash of MSIDN -> human readable class
sub get_msisdns {
    my $self = shift;
    my $res = $self->at("AT+WVNUM");

    my %ret;
    foreach my $line (split(/\r\n/, $res)) {
        my ($num, $class) = $line =~ /\+WVNUM: .*\,?
        \"([\.\d\*]+)\"\, # MSISDN
        \d*\,             # type identifier
        \d*\,             # speed
        (\d+)             # number class
            /x;

        next unless $num && defined $class;
        next if ($num =~ /^0+$/) || ($num eq '0.0.0.0');

        my $classstr;
        if ($class == 4) {
            $classstr = 'Voice number (line 1)';
        } elsif ($class == 11) {
            $classstr = 'Voice number (line 2)';
        } elsif ($class == 6) {
            $classstr = 'Chirp number';
        } elsif ($class == 7) {
            $classstr = 'Carrier IP';
        } elsif ($class == 8) {
            $classstr = 'IP Address 1';
        } elsif ($class == 9) {
            $classstr = 'IP Address 2';
        } elsif ($class == 0) {
            $classstr = 'Fax/circuit data';
        } elsif ($class == 10) {
            $classstr = 'Chirp group';
        } else {
            $classstr = "Unknown ($class)";
        }

        $ret{$num} = $classstr;
    }

    return %ret;
}

# takes range 0-5
sub set_volume {
    my ($self, $vol) = @_;
    return unless $self->{audio_out_class};
    $self->at("AT+MAVOL=$self->{audio_out_class},$vol");
}

sub set_audio_out {
    my ($self, $out) = @_;
    my $class;
    if ($out eq 'headset') {
        $class = 3;
    } elsif ($out eq 'speaker') {
        $class = 2;
    } elsif ($out eq 'raw') {
        $class = 1;
    } else {
        croak "Invalid audio out $out";
    }

    $self->{audio_out_class} = $class;

    return $self->at("AT+MAFEAT=$class");
}

sub answer {
    my ($self, $data, $timeout) = @_;
    return join("\n", $self->m->answer($data, $timeout));
}

sub debug {
    my ($msg) = @_;
    print STDERR "$msg\n";
}

1;
