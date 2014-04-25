package AnyEvent::IProto::Client::Res;

use strict;
use AnyEvent::IProto::Kit ':weaken';

sub new {
	my $pk = shift;
	my $self = bless {
		@_,
	}, $pk;
	#$self->init();
	return $self;
}

sub id   { $_[0]{id}   }
sub type { $_[0]{type} }
sub data { @{ $_[0]{data} || [] } }

package AnyEvent::IProto::Client;

require AnyEvent::IProto; our $VERSION = $AnyEvent::IProto::VERSION;

use 5.008008;
use AnyEvent::IProto::Kit ':weaken', ':refaddr';
use AnyEvent::Socket;

use Errno qw(EAGAIN EINTR);
use AnyEvent::Util qw(WSAEWOULDBLOCK);

use AnyEvent::DNS;
use List::Util qw(min max);

use constant {
	INIT           => 1,
	CONNECTING     => 2,
	CONNECTED      => 4,
	DISCONNECTING  => 8,
	RECONNECTING   => 16,
	RESOLVE        => 32,
};

sub xd ($;$) {
	if( eval{ require Devel::Hexdump; 1 }) {
		no strict 'refs';
		*{ caller().'::xd' } = \&Devel::Hexdump::xd;
	} else {
		no strict 'refs';
		*{ caller().'::xd' } = sub($;$) {
			my @a = unpack '(H2)*', $_[0];
			my $s = '';
			for (0..$#a/16) {
				$s .= "@a[ $_*16 .. $_*16 + 7 ]  @a[ $_*16+8 .. $_*16 + 15 ]\n";
			}
			return $s;
		};
	}
	goto &{ caller().'::xd' };
}


sub MAX_READ_SIZE () { 128 * 1024 }


sub init {
	my $self = shift;
	$self->{debug} ||= 0;
	$self->{timeout} ||= 30;
	$self->{reconnect} = 0.1 unless exists $self->{reconnect};
	if (exists $self->{server}) {
		my ($h,$p) = split ':',$self->{server},2;
		$self->{host} = $h if length $h;
		$self->{port} = $p if length $p;
	}
	$self->{server} = join ':',$self->{host},$self->{port};
}

sub new {
	my $pk = shift;
	my $self = bless {
		host      => '0.0.0.0',
		port      => '3334',
		read_size =>  4096,
		@_,
		map     => {},
		req     => {},
	}, $pk;
	$self->init();
	return $self;
}

sub register {
	my $self = shift;
	while (my ($type, $hdl) = splice @_,0,2) {
		$hdl->[2] ||= 'AnyEvent::IProto::Server::Req';
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

sub _resolve {
	weaken( my $self = shift );
	my $cb = shift;
	$self->{_}{resolve} = AnyEvent::DNS::resolver->resolve($self->{host}, 'a', sub {
		$self or return;
		if (@_) {
			my $time = time;
			my @addrs;
                        my $ttl = int($AnyEvent::VERSION) == 5 ? 3600 : 2**32;
                        for my $r (@_) {
                                if(int($AnyEvent::VERSION) == 5){
                                        #  [$name, $type, $class, @data], 
                                        push @addrs, $r->[3];
                                }
                                else {  
                                        #  [$name, $type, $class, $ttl, @data],
                                        $ttl = min( $ttl, $time + $r->[3] );
                                        push @addrs, $r->[4];
                                }       
                        }       
			$self->{addrs} = \@addrs;
			warn "Resolved $self->{host} into @addrs\n" if $self->{debug};
			$self->{addrs_ttr} = $ttl;
			$cb->(1);
		} else {
			$cb->(undef, "Not resolved `$self->{host}' ".($!? ": $!" : ""));
		}
	});
}

sub connect {
	weaken( my $self = shift );
	my $cb;$cb = pop if @_ and ref $_[-1] eq 'CODE';
	$self->{state} == CONNECTING and return;
	$self->state( CONNECTING );
	warn "Connecting to $self->{host}:$self->{port} with timeout $self->{timeout} (by @{[ (caller)[1,2] ]})...\n" if $self->{debug};
	my $addr;
	if (my $addrs = $self->{addrs}) {
		if (time > $self->{addrs_ttr}) {
			warn "TTR $self->{addrs_ttr} expired (".time.")\n" if $self->{debug} > 1;
			delete $self->{addrs};
			$self->_resolve(sub {
				warn "Resolved: @_" if $self->{debug};
				$self or return;
				if (shift) {
					$self->state( INIT );
					$self->connect($cb);
				} else {
					$self->_on_connreset(@_);
				}
			});
			return;
		}
		push @$addrs,($addr = shift @$addrs);
		warn "Have addresses: @{ $addrs }, current $addr" if $self->{debug} > 1;
	}
	else {
		if ( $self->{host} =~ /^[\.\d]+$/ and my $paddr = pack C4 => split '\.', $self->{host},4 ) {
			$self->{addrs} = [ $addr = Socket::inet_ntoa( $paddr ) ];
			$self->{addrs_ttr} = 2**32;
			warn "using ip host: $self->{host} ($addr)" if $self->{debug};
		} else {
			warn "Have no addrs, resolve $self->{host}\n" if $self->{debug};
			$self->_resolve(sub {
				warn "Resolved: @_" if $self->{debug};
				$self or return;
				if (shift) {
					$self->state( INIT );
					$self->connect($cb);
				} else {
					$self->_on_connreset(@_);
				}
			});
			return;
		}
	}
	warn "Connecting to $addr:$self->{port} with timeout $self->{timeout} (by @{[ (caller)[1,2] ]})...\n" if $self->{debug};
	$self->{_}{con} = AnyEvent::Socket::tcp_connect
		$addr,$self->{port},
		sub {
			$self or return;
			pop;
			warn "Connect: @_...\n" if $self->{debug};
			
			my ($fh,$host,$port) = @_;
			
			$self->_on_connect($fh,$host,$port,$cb);
		},
		sub {
			$self or return;
			$self->{timeout};
		};
	return;
}

sub _on_connect {
	my ($self,$fh,$host,$port,$cb) = @_;
	unless ($fh) {
		#warn "Connect failed: $!";
		if ($self->{reconnect}) {
			$self->{connfail} && $self->{connfail}->( $self,"$!" );
		} else {
			$self->{disconnected} && $self->{disconnected}->( $self,"$!" );
		}
		$self->_reconnect_after;
		return;
	}
	$self->state( CONNECTED );
	$self->{fh} = $fh;
	$self->{connected} && $self->{connected}->( $self,$host,$port );
		
	$self->{rw} = AE::io $fh,0,sub {
		#warn "on_read";
		my $buf = $self->{rbuf};
		my $len;
		while ( $self and ( $len = sysread( $fh, $buf, $self->{read_size}, length $buf) ) ) {
			#warn "read $len";
			$self->{_activity} = $self->{_ractivity} = AE::now;
			if ($len == $self->{read_size} and $self->{read_size} < $self->{max_read_size}) {
				$self->{read_size} *= 2;
				$self->{read_size} = $self->{max_read_size} || MAX_READ_SIZE
					if $self->{read_size} > ($self->{max_read_size} || MAX_READ_SIZE);
			}
			
			my $ix = 0;
			while () {
				last if length $buf < 12 + $ix;
				my ($type,$l,$seq) = unpack 'VVV', substr($buf,$ix,12);
				#warn "$type,$l,$seq";
				if ( length($buf) - $ix >= 12 + $l ) {
					$ix += 12;
					
					if (exists $self->{req}{$seq} ) {
						my ($reqt, $cb, $unp, $cls) = @{ delete $self->{req}{$seq} };
						
						my $ref = \( substr($buf,$ix,$l) );
						my $res;
						eval {
							
							my @rv;
							if (ref $unp ) {
								@rv = $unp->( $type, $ref );
							}
							elsif ( length $unp ) {
								#warn "unpacking $unp".xd($$ref);
								@rv = unpack $unp, $$ref;
							}
							else {
								@rv = ($ref);
							}
							$res = $cls->new(
								type => $type,
								id   => $seq,
								data => \@rv,
							);
						1} or do {
							$res = $cls->new(
								type  => $type,
								id    => $seq,
								error => "$@",
								data  => ["$$ref"],
							);
						};
						
						$cb->( $res );
					}
					else {
						use Data::Dumper;
						warn "Unhandled response packet (seq:$seq) of type $type with body size $l\n".Dumper($self->{req});
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
			warn "EOF from client ($len)";
			$! = Errno::EPIPE;
			$self->_on_connreset("$!");
		} else {
			if ($! == EAGAIN or $! == EINTR or $! == WSAEWOULDBLOCK) {
				return;
			} else {
				warn "Client gone: $!";
				#$! = Errno::EPIPE;
				$self->_on_connreset("$!");
			}
		}
	};
}

sub _on_connreset {
	my ($self,$error) = @_;
	while (my ($seq,$hdl) = each %{ $self->{req} } ) {
		my ($reqt, $cb, $unp, $cls) = @$hdl;
		my $res = $cls->new(
			type  => $reqt,
			id    => $seq,
			error => $error,
		);
		$cb->( $res );
	}
	%{$self->{req}} = ();
	$self->disconnect($error);
	$self->_reconnect_after;
}

sub _reconnect_after {
	weaken( my $self = shift );
	if ($self->{reconnect}) {
		# Want to reconnect
		$self->state( RECONNECTING );
		warn "Reconnecting (state=$self->{state}) to $self->{host}:$self->{port} after $self->{reconnect}...\n" if $self->{debug};
		$self->{timers}{reconnect} = AE::timer $self->{reconnect},0, sub {
			$self or return;
			$self->state(INIT);
			$self->connect;
		};
	} else {
		$self->state(INIT);
		return;
	}
}

sub reconnect {
	my $self = shift;
	$self->disconnect;
	$self->state(RECONNECTING);
	$self->connect;
}

sub disconnect {
	my $self = shift;
	$self->state(DISCONNECTING);
	warn "Disconnecting (state=$self->{state}, pstate=$self->{pstate}) by @{[ (caller)[1,2] ]}\n" if $self->{debug};
	if ( $self->{pstate} &(  CONNECTED | CONNECTING ) ) {
		delete $self->{con};
	}
	delete $self->{ww};
	delete $self->{rw};
	
	delete $self->{_};
	delete $self->{timers};
	if ( $self->{pstate} == CONNECTED ) {
			$self->{disconnected} && $self->{disconnected}->( $self,@_ );
	}
	elsif ( $self->{pstate} == CONNECTING ) {
		$self->{connfail} && $self->{connfail}->( $self,"$!" );
	}
	return;
}

sub state {
	my $self = shift;
	$self->{pstate} = $self->{state} if $self->{pstate} != $self->{state};
	$self->{state} = shift;
}

sub request {
	my $self = shift;
	my $cb   = pop;
	ref $cb eq 'CODE' or
		croak 'Usage: request( $type, [$body, [$format, [$seq, ]]] $cb )';
	my $type = shift;
	my $body = @_ ? shift : '';
	my $format;
	if (@_) {
		$format = shift;
		if (!ref $format) {
			$format = [ $format ];
		}
	} else {
		$format = $self->{map}{$type} || [];
	}
	my $seq = @_ ? shift : ++$self->{seq};
	
	if ( exists $self->{req}{$seq} ) {
		return $cb->(undef, "Duplicate request for id $seq");
	}
	$format->[1] ||= 'AnyEvent::IProto::Client::Res';
	
	$self->{state} == CONNECTED or return $cb->(undef, "Not connected");
	
	$self->{req}{$seq} = [ $type, $cb, @$format ];
	
	my $buf = pack('VVV', $type, length $body, $seq ).$body;
	
	if ( $self->{wbuf} ) {
		${ $self->{wbuf} } .= $buf;
		return;
	}
	my $w = syswrite( $self->{fh}, $buf );
	if ($w == length $buf) {
		# ok;
	}
	elsif (defined $w) {
		$self->{wbuf} = \( substr($buf,$w) );
		$self->{ww} = AE::io $self->{fh}, 1, sub {
			$w = syswrite( $self->{fh}, ${ $self->{wbuf} } );
			if ($w == length ${ $self->{wbuf} }) {
				delete $self->{wbuf};
				delete $self->{ww};
			}
			elsif (defined $w) {
				substr( ${ $self->{wbuf} }, 0, $w, '');
			}
			else {
				#warn "disconnect: $!";
				$self->_on_connreset("$!");
			}
		};
	}
	else {
		$self->_on_connreset("$!");
	}
	
}




=head1 METHODS

=over 4

=item ...()

...

=back

=cut


=head1 AUTHOR

Mons Anderson, C<< <mons@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012 Mons Anderson, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

=cut

1;
