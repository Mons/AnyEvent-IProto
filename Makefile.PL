use 5.008008;
use ExtUtils::MakeMaker;
$ENV{AUTHOR} and require CPAN::Meta;

WriteMakefile(
	NAME              => 'AnyEvent::IProto',
	VERSION_FROM      => 'lib/AnyEvent/IProto.pm',
	PREREQ_PM         => {
		AnyEvent => 5,
	},
	ABSTRACT_FROM  => 'lib/AnyEvent/IProto.pm', # retrieve abstract from module
	AUTHOR         => 'Mons Anderson <mons@cpan.org>',
	LICENSE        => 'perl',
	
	PL_FILES          => {
		"Kit.pm.PL" => '$(INST_LIB)/AnyEvent/IProto/Kit.pm',
		#$AUTHOR ? (
		#	"Kit.pm.PL" => 'lib/AnyEvent/IProto/Kit.pm',
		#) : ()
	},
	
	clean             => { FILES => "Kit.pm" },
);
