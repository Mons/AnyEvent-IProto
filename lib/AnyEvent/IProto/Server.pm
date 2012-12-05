package AnyEvent::IProto::Server;

use 5.008008;
use AnyEvent::IProto::Kit ':weaken', ':refaddr';
use AnyEvent::IProto::Server::Req;
use AnyEvent::Socket;

use Errno qw(EAGAIN EINTR);
use AnyEvent::Util qw(WSAEWOULDBLOCK);

sub MAX_READ_SIZE () { 128 * 1024 }

sub new {
	my $pk = shift;
	my $self = bless {
		host      => '0.0.0.0',
		port      => '3334',
		backlog   =>  1024,
		read_size =>  4096,
		@_,
		map     => {},
		cnn     => {},
	}, $pk;
	$self->init();
	return $self;
}

sub register {
	my $self = shift;
	while (my ($type, $hdl) = splice @_,0,2) {
		$hdl->[2] ||= 'AnyEvent::IProto::Server::Req';
		exists $self->{map}{$type} and warn "Packet type $type already registered";
		$self->{map}{$type} = $hdl;
	}
	return;
}

sub default {
	my $self = shift;
	my $hdl = @_ == 1 ? shift : [@_];
	$hdl->[2] ||= 'AnyEvent::IProto::Server::Req';
	$self->{map}{''} = $hdl;
}

sub init {}
sub start {
	weaken(my $self = shift);
	$self->{server} =
		tcp_server $self->{host}, $self->{port},
		sub { $self or return; unshift @_,$self; goto &{ $self->can('accept') }; },
		#sub { $self->{backlog} },
	;
	return;
}

sub stop {
	my ($self,$cb) = @_;
	delete $self->{server};
	if ($self->{requests} > 0) {
		warn "Waiting for $self->{requests} requests to finish";
		$self->{stop} = $cb;
	} else {
		warn "No requests";
		$cb->();
	}
}

sub write :method {
	my ($self,$id,$buf) = @_;
	exists $self->{$id} or return warn "unknown id $id";
	if ( $self->{$id}{wbuf} ) {
		${ $self->{$id}{wbuf} } .= $$buf;
		return;
	}
	my $fh = $self->{$id}{fh};
	my $w = syswrite( $fh, $$buf );
	if ($w == length $$buf) {
		# ok;
	}
	elsif (defined $w) {
		substr($$buf,0,$w,'');
		$self->{$id}{wbuf} = $buf;
		$self->{$id}{ww} = AE::io $fh, 1, sub {
			#warn "ww.io.$id";
			$w = syswrite( $fh, ${ $self->{$id}{wbuf} } );
			if ($w == length ${ $self->{$id}{wbuf} }) {
				delete $self->{$id}{wbuf};
				delete $self->{$id}{ww};
			}
			elsif (defined $w) {
				substr( ${ $self->{$id}{wbuf} }, 0, $w, '');
			}
			else {
				#warn "disconnect: $!";
				#delete $self->{$id};
				$self->drop($id);
			}
		};
	}
	else {
		#warn "disconnect: $!";
		#delete $self->{$id};
		$self->drop($id);
	}
	
}

sub accept :method {
	my ( $self, $fh, $host, $port ) = @_;
	my $id = refaddr( $fh );
	
	#warn "client connected ($id) @_";
	
	$self->{requests}++;
	$self->{$id}{fh} = $fh;
	$self->{$id}{rw} = AE::io $fh, 0, sub {
		#warn "rw.io.$id";
		my $buf = $self->{rbuf};
		my $len;
		my $lsr;
		while ( $self and ( $len = sysread( $fh, $buf, $self->{read_size}, length $buf) ) ) {
			$self->{_activity} = $self->{_ractivity} = AE::now;
			$lsr = $len;
			if ($len == $self->{read_size} and $self->{read_size} < $self->{max_read_size}) {
				$self->{read_size} *= 2;
				$self->{read_size} = $self->{max_read_size} || MAX_READ_SIZE
					if $self->{read_size} > ($self->{max_read_size} || MAX_READ_SIZE);
			}
			
			my $ix = 0;
			while () {
				last if length $buf < 12;
				my ($type,$l,$seq) = unpack 'VVV', substr($buf,$ix,12);
				if ( length($buf) - $ix >= 12 + $l ) {
					$ix += 12;
					
					my $ref = \( substr($buf,$ix,$l) );
					
					if( my $map = exists $self->{map}{$type} ? $self->{map}{$type} : exists $self->{map}{''} ? $self->{map}{''} : undef ) {
						
						my $req;
						eval {
							my @rv;
							if (ref $map->[0] ) {
								@rv = $map->[0]( $type, $ref );
							}
							elsif ( length $map->[0] ) {
								@rv = unpack $map->[0], $$ref;
							}
							else {
								@rv = ($ref);
							}
							$req = $map->[2]->new(
								type => $type,
								id   => $seq,
								data => \@rv,
								s    => $self,
								idx  => $id,
							);
							weaken( $req->{s} );
						1} or do {
							warn "Failed fo capture packet type $type [seq $seq] body length $l: $@";
							$req = $map->[2]->new(
								type  => $type,
								id    => $seq,
								error => "$@",
								data  => ["$$ref"],
								s     => $self,
								idx   => $id,
							);
						};
						$map->[1]( $req );
					
					} else {
						warn "Unhandled request packet (seq:$seq) of type $type with body size $l\n";
						my $body = pack("V V/a*", 255, "Request not handled");
						my $buf = pack('VVV', $type, length($body), $seq ).$body;
						$self->write($id,\$buf);
					}
					
					$ix += $l;
				}
				else {
					last;
				}
				
			}
			$buf = substr($buf,$ix);# if length $buf > $ix;
		}
		return unless $self;
		$self->{rbuf} = $buf;
		
		if (defined $len) {
			#warn "EOF from client ($len)";
			$! = Errno::EPIPE;
		} else {
			if ($! == EAGAIN or $! == EINTR or $! == WSAEWOULDBLOCK) {
				return;
			} else {
				#warn "Client gone: $!";
				#$! = Errno::EPIPE;
			}
		}
		$self->drop($id);
		
	};
	return;
}

sub drop {
	my ($self,$id) = @_;
	$self->{requests}--;
	%{ delete $self->{$id} } = ();
	if ( $self->{stop} and $self->{requests} == 0 ) {
		$self->{stop}();
	}
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

AnyEvent::IProto - Perl extension for blah blah blah

=head1 SYNOPSIS

  use AnyEvent::IProto::Server;
  blah blah blah

=head1 AUTHOR

Mons Anderson <mons@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2012 Mons Anderson, Mail.ru Group

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself


=cut
