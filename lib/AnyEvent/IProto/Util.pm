package AnyEvent::IProto::Util;

use AnyEvent::IProto::Kit;
use parent 'Exporter';

our @EXPORT = our @EXPORT_OK = qw(packet_dump);

sub pint32($$) {
	printf "%s<%s>=%d ", $_[0],join(' ', unpack '(H2)*', pack('V',$_[1]) ), $_[1];
}
sub pvint($$) {
	printf "%s<%s>=%d ", $_[0],join(' ', unpack '(H2)*', pack('w',$_[1]) ), $_[1];
}
sub pdata($$) {
	printf "%s<%s> [%s]", $_[0], join(' ', unpack '(H2)*',$_[1]),
		join('', map { ord() < 127 && ord() < 32 ? '.' : $_ } $_[1] =~ /(.)/sg);
}

sub packet_dump {
	my $raw = shift;
	 Encode::_utf8_off($raw);
	my @names = qw( set add and xor or str del ins );
	my %pk;
	my $LS = "# ";
	( @pk{ qw(type len id) }, $raw) = unpack 'V3 a*', $raw;
	print $LS;
	printf "type<%s>=%d ", join(' ', unpack '(H2)*', pack('V',$pk{type}) ), $pk{type};
	printf "len<%s>=%d ", join(' ', unpack '(H2)*', pack('V',$pk{len}) ), $pk{len};
	printf "id<%s>=%d ", join(' ', unpack '(H2)*', pack('V',$pk{id}) ), $pk{id};
	if ($pk{type} == 17) {
		print " [SELECT:$pk{type}]\n";
		( @pk{ qw( space index offset limit count ) }, $raw) = unpack 'V5 a*', $raw;
		
		print $LS;
		pint32( $_ => $pk{$_} ) for qw(space index offset limit count);
		print "\n";
		my $d;
		for (1..$pk{count}) {
			
			my $count;
			($count,$raw) = unpack 'V a*', $raw;
			
			print "$LS\t";
			pint32( tuplesize => $count );
			print "\n";
		
			for (1..$count) {
				print "$LS\t\t";
				my ($s) = unpack 'w', $raw;
				pvint( len => $s );
				($d,$raw) = unpack 'w/a* a*', $raw;
				pdata( data => $d );
				print "\n";
			}
		}
	}
	elsif ($pk{type} == 13) {
		print " [INSERT:$pk{type}]\n";
		( @pk{ qw( space flags ) }, $raw) = unpack 'V2 a*', $raw;
		my @tuple = unpack 'V/(w/a*) a*', $raw;
		$raw = pop @tuple;
		map $_ = "$_:s", @tuple;
		$pk{tuple} = \@tuple;
	}
	elsif ($pk{type} == 21) {
		print " [DELETE:$pk{type}]\n";
		( @pk{ qw( space flags ) }, $raw) = unpack 'V2 a*', $raw;
		my @tuple = unpack 'V/(w/a*) a*', $raw;
		$raw = pop @tuple;
		map $_ = "$_:s", @tuple;
		$pk{tuple} = \@tuple;
	}
	elsif ($pk{type} == 19) {
		print " [UPDATE:$pk{type}]\n";
		( @pk{ qw( space flags ) }, $raw) = unpack 'V2 a*', $raw;
		print $LS;
		pint32( space => $pk{space} );
		pint32( flags => $pk{flags} );
		print "\n";
		
		print $LS;
		
		my ($size,$data,$d);
		($size,$raw) = unpack 'V a*', $raw;
		pint32( tuple => $size );
		print "\n";
		for (1..$size) {
			print "$LS\t";
			my ($s) = unpack 'w', $raw;
			pvint( len => $s );
			($d,$raw) = unpack 'w/a* a*', $raw;
			pdata( data => $d );
			print "\n";
		}
		my $count;
		($count,$raw) = unpack 'V a*', $raw;
		
		print $LS;
		pint32( opcount => $count );
		print "\n";
		
		for (1..$count) {
			no warnings;
			print "$LS\t";
			my ($fn,$op,$fl);
			return warn("Truncated packet") if length $raw < 6;
			($fn,$op,$fl,$raw) = unpack 'V C w a*', $raw;
			pint32( field => $fn );
			printf "op<%02x>=%d [%3s]  ", $op, $op, $names[$op];
			pvint( field_len => $fl );
			
			#pvint( field => $fn );
			my $field = substr($raw, 0, $fl,'');
			pdata( data => $field );
			if ($op == 5) {
				print "\n";
				
				print "$LS\t\t";
				($fl,$field) = unpack 'w a*', $field;
				pvint( off_len => $fl );
				if ($fl == 4) {
					($fn, $field) = unpack 'V a*', $field;
					pint32( offset => $fn);
				} else {
					pdata( data => substr($field, 0, $fl,'') );
				}
				print "\n";
				
				print "$LS\t\t";
				($fl,$field) = unpack 'w a*', $field;
				pvint( len_len => $fl );
				if ($fl == 4) {
					($fn, $field) = unpack 'V a*', $field;
					pint32( length => $fn);
				} else {
					pdata( data => substr($field, 0, $fl,'') );
				}
				print "\n";
				
				print "$LS\t\t";
				($fl,$field) = unpack 'w a*', $field;
				pvint( str_len => $fl );
				pdata( string => substr($field, 0, $fl,'') );
			}
			print "\n";
		}
	}
	elsif ($pk{type} == 22) {
		print " [CALL:$pk{type}]\n";
		( @pk{ qw( flags proc ) }, $raw) = unpack 'V w/a* a*', $raw;
		my @tuple = unpack 'V/(w/a*) a*', $raw;
		$raw = pop @tuple;
		map $_ = "$_:s", @tuple;
		$pk{tuple} = \@tuple;
	}
	$pk{trash} = $raw;
	return \%pk;
}

1;
