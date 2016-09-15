#!/usr/bin/env perl

use lib '.';
{
package Local::Client;

use parent 'AnyEvent::IProto::Client';
use Scalar::Util qw(weaken);

sub request {
	weaken( my $self = shift );
	my $cb = pop;

	my $timeout = $self->{request_timeout} || 5;
	my $timeout_reached = q{};

	my $w;
	$w = AnyEvent->timer(
		after => $timeout,
		cb    => sub {
			undef $w;
			$timeout_reached = 1;
			$cb->( undef, 'timeout reached' );
			undef $cb;
		}
	);

	my $cb_with_timeout = sub {
		undef $w;
		$cb->(@_) unless $timeout_reached;
	};

	$self->SUPER::request( @_, $cb_with_timeout );
}

}

use strict;
use 5.010;
use AnyEvent::IProto::Server;
use AnyEvent::IProto::Client;
use EV;
use Scalar::Util qw(weaken);
use DDP;

my $s;
my $srv;$srv = sub {
	if ($s) {
		warn "s: destroy";
		$s->cleanup;
		%$s = ();
		undef $s;
	}
	$s = AnyEvent::IProto::Server->new(
		port => 12345,
	);
	$s->register(
		1 => ['a*', sub {
			my $req = shift;
			#warn "s: $req->{id}:ok";
			$req->reply("ok");
		} ],
	);
	$s->listen;
	$s->accept;
};
#$srv->();
my $t;$t = AE::timer 0,0.01, sub {
	$srv->();
};

my $c = Local::Client->new(
	host => '127.0.0.1',
	port => 12345,
	reconnect => 1,
	request_timeout => 0.005,
	connected => sub {
		my $c = shift;
		my $N;
		my $do;$do = sub {
			my $do = $do;
			#$srv->();
			$c->request(1,'test',sub {
				++$N;
				if (my $res = shift) {
					#warn $res->{data}[0];
					if ($res->{data} and ${ $res->{data}[0] } eq 'ok') {
						AE::postpone{ $do->(); }
					}
					elsif ($res->{error}) {
						warn "C:$c->{state} $res->{id}: $res->{error} ($N success)";
					}
					else{
						p $res;
						p @_;
					}
				} else {
					p @_;
				}
			});
			#AE::postpone { $srv->() };
		};$do->() for 1..2;weaken($do);
	}
);
$c->connect;


EV::loop;
