package AnyEvent::IProto::Server::Req;

use strict;
use AnyEvent::IProto::Kit ':weaken';

sub new {
	my $pk = shift;
	my $self = bless {
		@_,
	}, $pk;
	return $self;
}

sub id   { $_[0]{id}   }
sub type { $_[0]{type} }
sub data { @{ $_[0]{data} } }

sub reply {
	my $self = shift;
	$self->{s} or croak "Can't call reply without connection";
	my $buf = pack('VVV', $self->{type}, length($_[0]), $self->{id} ).$_[0];
	$self->{s}->write($self->{idx},\$buf);
	( delete $self->{s} )->requests(-1);
}

sub DESTROY {
	my $self = shift;
	return %$self = () unless $self->{s};
	$self->reply(pack("V V/a*",-1, "Request not handled") );
	return;
}

1;
