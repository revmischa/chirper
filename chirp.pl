#!/usr/bin/perl
# dev notes: /dev/ttyS0, 19200, 8N1

use strict;
use warnings;

use lib 'lib';

use Device::Chirper;
use Getopt::Long;

my $cmd = shift @ARGV || '';

my $chirp = Device::Chirper->new(port => "/dev/ttyACM0");
$chirp->set_callback(Device::Chirper::CONNECTED, \&on_connect) if $cmd eq 'init';
$chirp->connect;

if ($cmd eq 'init') {
    if ($chirp->init) {
        debug("Initialized");
        $chirp->set_audio_out("speaker");
        $chirp->set_volume(1);
    } else {
        debug("Error initializing");
    }
} elsif ($cmd eq 'dial') {
    my $num = shift @ARGV or die "No number specified.\n";
    if ($chirp->dial($num) || 1) {
        interactive();
    }
} elsif ($cmd eq 'hangup') {
    my $res = $chirp->hangup;
    if ($res) {
        debug("Hung up = $res");
    } else {
        debug("Hung up");
    }
} elsif ($cmd eq 'chirp-mode') {
    # go into chirp mode
    $chirp->set_mode("chirp");
} elsif ($cmd eq 'alert-mode') {
    # go into chirp mode
    $chirp->set_mode("alert");
} elsif ($cmd eq 'voice-mode') {
    # go into chirp mode
    $chirp->set_mode("voice");
} elsif ($cmd eq 'reset') {
    # go into chirp mode
    $chirp->m->reset;
    debug("Reset");
} elsif ($cmd eq 'charp') {
    $chirp->play_chirp_outgoing;
} elsif ($cmd eq 'chirp') {
    $chirp->play_chirp_incoming;
} else {
    die "Unknown command: $cmd\n";
}

# sit and read from modem
sub interactive {
    while (1) {
        my $line = $chirp->answer(undef, 5);
        debug("<< $line") if $line;
    }
}

sub on_connect {
    my $self = shift;
    my @res;

    my %numbers = $self->get_msisdns;

    debug("Connected\n\nSubscriber numbers:");

    while ( my ($num, $type) = each %numbers ) {
        debug("$num -> $type");
    }
    debug("");
}

sub debug {
    my ($msg) = @_;
    print STDERR "$msg\n";
}
