#!/usr/bin/env perl

use lib::abs '../lib';
use uni::perl ':dumper';
use EV;
use AnyEvent::IProto::Server;

{
	package MyPacket;
	use parent -norequire => 'AnyEvent::IProto::Server::Req';
	sub email {
		(shift->data)[0];
	}
	package MyPacket3;
	use parent -norequire => 'AnyEvent::IProto::Server::Req';
	sub email {
		"email = ".(shift->data)[0];
	}
}

my $sig;$sig = AE::signal INT => sub { warn "Exiting"; EV::unloop; };

my $s = AnyEvent::IProto::Server->new(
	#port => '34567',
);

sub on_packet {
	my $r = shift;
	#warn "req $r";
	$r->reply("\1".("X"x1000));
}

$s->register(
	1 => [ 'V/a*', \&on_packet, 'MyPacket' ],
	2 => [ 'V/a*', \&on_packet, 'MyPacket' ],
	3 => [ sub { unpack 'V/a*', ${ $_[1] } }, \&on_packet, 'MyPacket3' ],
	# default also may be defined as 
	# '' => [ format, callback, req_class ]
);

$s->default([
	undef, sub {
		warn "unhandled: @_";
	}
]);

$s->start;

EV::loop;