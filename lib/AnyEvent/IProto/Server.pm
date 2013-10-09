package AnyEvent::IProto::Server;

require AnyEvent::IProto; our $VERSION = $AnyEvent::IProto::VERSION;

use 5.008008;
use AnyEvent::IProto::Kit ':weaken', ':refaddr';
use AnyEvent::IProto::Server::Req;
use AnyEvent::Socket;

use Errno qw(EAGAIN EINTR);
use AnyEvent::Util qw(WSAEWOULDBLOCK guard AF_INET6 fh_nonblocking);
use Socket qw(AF_INET AF_UNIX SOCK_STREAM SOCK_DGRAM SOL_SOCKET SO_REUSEADDR IPPROTO_TCP TCP_NODELAY);

sub MAX_READ_SIZE () { 128 * 1024 }
our $SEQ = 1;

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
	croak "Use listen/accept instead";
}

sub listen:method {
	my $self = shift;
	my $host = $self->{host};
	my $service = $self->{port};
	$host = $AnyEvent::PROTOCOL{ipv4} < $AnyEvent::PROTOCOL{ipv6} && AF_INET6 ? "::" : "0" unless defined $host;
	
	my $ipn = parse_address $host
		or Carp::croak "$self.listen: cannot parse '$host' as host address";
	
	my $af = address_family $ipn;
	
	# win32 perl is too stupid to get this right :/
	Carp::croak "listen/socket: address family not supported"
		if AnyEvent::WIN32 && $af == AF_UNIX;
	
	socket my $fh, $af, SOCK_STREAM, 0 or Carp::croak "listen/socket: $!";
	
	if ($af == AF_INET || $af == AF_INET6) {
		setsockopt $fh, SOL_SOCKET, SO_REUSEADDR, 1
			or Carp::croak "listen/so_reuseaddr: $!"
				unless AnyEvent::WIN32; # work around windows bug
		
		unless ($service =~ /^\d*$/) {
			$service = (getservbyname $service, "tcp")[2]
				or Carp::croak "tcp_listen: $service: service unknown"
		}
	} elsif ($af == AF_UNIX) {
		unlink $service;
	}
	
	bind $fh, AnyEvent::Socket::pack_sockaddr( $service, $ipn )
		or Carp::croak "listen/bind: $!";
	
	fh_nonblocking $fh, 1;
	
	$self->{fh} = $fh;
	
	$self->prepare();
	
	listen $self->{fh}, $self->{backlog}
		or Carp::croak "listen/listen: $!";
	
	return wantarray ? do {
		my ($service, $host) = AnyEvent::Socket::unpack_sockaddr( getsockname $self->{fh} );
		(format_address $host, $service);
	} : ();
}

sub prepare {}

sub accept:method {
	weaken( my $self = shift );
	$self->{aw} = AE::io $self->{fh}, 0, sub {
		while ($self->{fh} and (my $peer = accept my $fh, $self->{fh})) {
			AnyEvent::Util::fh_nonblocking $fh, 1; # POSIX requires inheritance, the outside world does not
			setsockopt($fh, IPPROTO_TCP, TCP_NODELAY, 1) or die "setsockopt(TCP_NODELAY) failed:$!";
			binmode $fh, ':raw';
			if ($self->{want_peer}) {
				my ($service, $host) = AnyEvent::Socket::unpack_sockaddr $peer;
				$self->incoming($fh, AnyEvent::Socket::format_address $host, $service);
			} else {
				$self->incoming($fh);
			}
		}
	};
	return;
}

sub write :method {
	my ($self,$id,$buf) = @_;
	exists $self->{$id} or return;# $self->{debug} && warn "No client $id for response packet";
	#warn "write after shutdown" if $self->{graceful};
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

sub incoming {
	my ( $self, $fh, $host, $port ) = @_;
	#my ( $self, $fh ) = @_;
	#my $id = fileno($fh).':'.refaddr( $fh );
	my $id = fileno($fh).':'.$SEQ;
	
	warn "client connected ($id)" if $self->{debug};
	$self->{active_connections}++;
	$self->{$id}{fh} = $fh;
	$self->{$id}{rw} = AE::io $fh, 0, sub {
		#warn "rw.io.$id";
		my $buf = $self->{$id}{rbuf};
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
				last if ( length($buf)-$ix < 12 );
				my ($type,$l,$seq) = unpack 'VVV', substr($buf,$ix,12);
				#warn "got $type + $l + $seq $ix -> ".length $buf;
				if ( length($buf) - $ix >= 12 + $l ) {
					$ix += 12;
					
					my $ref = \( substr($buf,$ix,$l) );
					
					$self->requests(+1);
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
								defined $host ? (
									host => $host,
									port => $port,
								) : (),
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
								defined $host ? (
									host => $host,
									port => $port,
								) : (),
							);
						};
						$map->[1]( $req );
					
					} else {
						warn "Unhandled request packet (seq:$seq) of type $type with body size $l received from $host:$port\n";
						my $body = pack("V V/a*", -1, "Request not handled");
						my $buf = pack('VVV', $type, length($body), $seq ).$body;
						$self->write($id,\$buf);
						$self->requests(-1);
					}
					
					$ix += $l;
				}
				else {
					warn "wait for +".( 12 + $l - ( length($buf) - $ix ) )." more data" if $self->{debug};
					last;
				}
				
			}
			$buf = substr($buf,$ix);# if length $buf > $ix;
		}
		return unless $self;
		$self->{$id}{rbuf} = $buf;
		
		if (defined $len) {
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

sub requests {
	my ( $self, $delta ) = @_;
	$self->{requests_total} -= $delta if $delta < 0;
	$self->{requests} += $delta;
	if ( $self->{graceful} and $self->{requests} == 0 ) {
		$self->cleanup;
	};
}

sub drop {
	my $self = shift;
	my $id = shift;
	exists $self->{$id} or return;
	$self->{active_connections}--;
	%{ delete $self->{$id} } = ();
	warn "client $id disconnected @_" if $self->{debug};
	if ( $self->{graceful} and $self->{requests} == 0 ) {
		$self->cleanup;
	};
}

sub cleanup {
	my $self = shift;
	delete $self->{gracetimer};
	for my $id (keys %$self) {
		ref $self->{$id} eq 'HASH' and exists $self->{$id}{fh} or next; # other key
		close( $self->{$id}{fh} );
		%{ delete $self->{$id} } = ();
	}
	( delete $self->{graceful} )->() if $self->{graceful};
	return;
}

sub graceful {
	my $self = shift;
	my $cb = pop;
	my $timeout = @_ ? shift : 3;
	delete $self->{aw};
	close $self->{fh};
	for my $id (keys %$self) {
		ref $self->{$id} eq 'HASH' and exists $self->{$id}{fh} or next; # other key
		#shutdown $self->{$id}{fh}, 0 or warn "shutdown for $id failed: $!";
	}
	$self->{gracetimer} = AE::timer $timeout,0,sub {
		$self->cleanup;
	};
	if ($self->{requests} == 0 or $self->{active_connections} == 0) {
		warn "close immediately";
		$self->cleanup;
		$cb->();
	} else {
		warn "have $self->{requests} active requests over $self->{active_connections} connections";
		$self->{graceful} = $cb;
	}
}
BEGIN{ *stop = \&graceful; }

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
