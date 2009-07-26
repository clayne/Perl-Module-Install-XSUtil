package Module::Install::XSUtil;

use 5.005_03;

$VERSION = '0.01';
@ISA     = qw(Module::Install::Base);

use strict;
use Module::Install::Base;

use Config;

use File::Spec;
use File::Find;

use constant _VERBOSE => $ENV{MI_VERBOSE} ? 1 : 0;

my %BuildRequires = (
	'ExtUtils::ParseXS' => 2.20,
	'XSLoader'          => 0.08,
);

my %ToInstall;

sub _verbose{
	print STDERR q{# }, @_, "\n";
}

sub _xs_initialize{
	my($self) = @_;

	unless($self->{xsu_initialized}){

		$self->requires_external_cc();
		$self->build_requires(%BuildRequires);
		$self->makemaker_args(OBJECT => '$(O_FILES)');

		$self->{xsu_initialized} = 1;
	}
	return;
}

sub use_ppport{
	my($self, $dppp_version) = @_;

	$self->_xs_initialize();

	my $filename = 'ppport.h';

	$dppp_version ||= 0;
	$self->configure_requires('Devel::PPPort' => $dppp_version);

	print "Writing $filename\n";

	eval qq{
		use Devel::PPPort;
		Devel::PPPort::WriteFile(q{$filename});
		1;
	} or warn("Cannot write $filename: $@");

	$self->clean_files($filename);
	$self->cc_append_to_ccflags('-DUSE_PPPORT');
	$self->cc_append_to_inc('.');

	return;
}

sub cc_warnings{
	my($self) = @_;

	$self->_xs_initialize();

	if($Config{gccversion}){
		$self->cc_append_to_ccflags(qw(-Wall -Wextra));
	}
	elsif($Config{cc} =~ /\A cl \b /xmsi){
		# Microsoft Visual C++ Compiler
		$self->cc_append_to_ccflags('-Wall');
	}
	else{
		# TODO: support other compilers
	}

	return;
}

sub cc_append_to_inc{
	my($self, @dirs) = @_;

	$self->_xs_initialize();

	for my $dir(@dirs){
		unless(-d $dir){
			warn("'$dir' not found: $!\n");
			exit;
		}

		_verbose "inc: -I$dir" if _VERBOSE;
	}

	my $mm    = $self->makemaker_args;
	my $paths = join q{ }, map{ qq{"-I$_"} } @dirs;

	if($mm->{INC}){
		$mm->{INC} .=  q{ } . $paths;
	}
	else{
		$mm->{INC}  = $paths;
	}
	return;
}

sub cc_append_to_libs{
	my($self, @libs) = @_;

	$self->_xs_initialize();

	my $mm = $self->makemaker_args;

	my $libs = join q{ }, map{
		my($file, $dir) = ref($_) eq 'ARRAY' ? @{$_} : ($_, undef);
		$file =~ s/ \. \w+ \z //xms; # remove suffix

		$dir = qq{-L$dir } if defined $dir;
		_verbose "libs: $dir-l$file" if _VERBOSE;
		$dir . qq{-l$file};
	} @libs;

	if($mm->{LIBS}){
		$mm->{LIBS} .= q{ } . $libs;
	}
	else{
		$mm->{LIBS} = $libs;
	}

	return;
}

sub cc_append_to_ccflags{
	my($self, @ccflags) = @_;

	$self->_xs_initialize();

	my $mm    = $self->makemaker_args;
	my $flags = join q{ }, @ccflags;

	if($mm->{CCFLAGS}){
		$mm->{CCFLAGS} .=  q{ } . $flags;
	}
	else{
		$mm->{CCFLAGS}  = $flags;
	}
	return;
}

sub requires_xs{
	my $self  = shift;

	return $self->requires() unless @_;

	$self->_xs_initialize();

	my %added = $self->requires(@_);

	while(my $module = each %added){
		my $dir = File::Spec->join(split /::/, $module);

		SCAN_INC: foreach my $inc_dir(@INC){
			my $packlist = File::Spec->join($inc_dir, 'auto', $dir, '.packlist');
			if(-e $packlist){

				my @files = do{
					local *IN;
					open IN, "< $packlist" or die("Cannot open '$packlist' for reading: $!\n");
					map{ chomp; $_ } <IN>;
				};

				if(my @header_files = grep{ / \.h \z/xmsi } @files){
					$self->cc_append_to_inc(map{
						my($vol, $dir, $file) = File::Spec->splitpath($_);
						$dir;
					} @header_files);
				}

				if(my @lib_files = grep{ / \. (?: lib | dll ) \z/xmsio } @files){
					$self->cc_append_to_libs(map{
						my($vol, $dir, $file) = File::Spec->splitpath($_);
						[$file, $dir]
					} @lib_files);
				}


				last SCAN_INC;
			}
		}
	}

	return %added;
}

sub cc_src_paths{
	my($self, @dirs) = @_;

	$self->_xs_initialize();

	my $mm     = $self->makemaker_args;

	my $XS_ref = $mm->{XS} ||= {};
	my $C_ref  = $mm->{C}  ||= [];

	my $_obj   = $Config{_o};

	my @src_files;
	find(sub{
		if(/ \. (?: xs | c (?: c | pp | xx )? ) \z/xmsi){ # *.{xs, c, cc, cpp, cxx}
			push @src_files, $File::Find::name;
		}
	}, @dirs);

	foreach my $src_file(@src_files){
		my $c = $src_file;
		if($c =~ s/ \.xs \z/.c/xms){
			$XS_ref->{$src_file} = $c;

			_verbose "xs: $src_file" if _VERBOSE;
		}
		else{
			_verbose "c: $c" if _VERBOSE;
		}

		push @{$C_ref}, $c;
	}

	$self->cc_append_to_inc('.');

	return;
}

sub cc_include_paths{
	my($self, @dirs) = @_;

	$self->_xs_initialize();

	push @{ $self->{xsu_include_paths} ||= []}, @dirs;

	my $h_map = $self->{xsu_header_map} ||= {};

    foreach my $dir(@dirs){
		my $prefix = quotemeta( File::Spec->catfile($dir, '') );
		find(sub{
			return unless / \.h \z/xms;

			(my $h_file = $File::Find::name) =~ s/ \A $prefix //xms;
			$h_map->{$h_file} = $File::Find::name;
		}, $dir);
	}

	$self->cc_append_to_inc(@dirs);

	return;
}

sub install_headers{
	my $self    = shift;
	my $h_files;
	if(@_ == 0){
		$h_files = $self->{xsu_header_map} or die "install_headers: cc_include_paths not specified.\n";
	}
	elsif(@_ == 1 && ref($_[0]) eq 'HASH'){
		$h_files = $_[0];
	}
	else{
		$h_files = +{ map{ $_ => undef } @_ };
	}

	$self->_xs_initialize();

	my @not_found;
	my $h_map = $self->{xsu_header_map} || {};

	while(my($ident, $path) = each %{$h_files}){
		$path ||= $h_map->{$ident} || File::Spec->join('.', $ident);

		unless($path && -e $path){
			push @not_found, $ident;
			next;
		}

		$ToInstall{$path} = File::Spec->join('$(INST_LIBDIR)', $path);

		$self->provides($ident => { file => $path });

		_verbose "install: $ident ($path)" if _VERBOSE;
		$self->_extract_functions_from_header_file($path);
	}

	if(@not_found){
		die "Header file(s) not found: @not_found\n";
	}

	return;
}


# NOTE:
# This function tries to extract C functions from header files.
# Using heuristic methods, not a smart parser.
sub _extract_functions_from_header_file{
	my($self, $h_file) = @_;

	my @functions;

	my $contents = do {
		local *IN;
		local $/;
		open IN, "< $h_file" or die "Cannot open $h_file: $!";
		scalar <IN>;
	};

	# remove C comments
	$contents =~ s{ /\* .*? \*/ }{}xmsg;

	# remove cpp directives
	$contents =~ s{
		\# \s* \w+
			(?: [^\n]* \\ [\n])*
			[^\n]* [\n]
	}{}xmsg;

	# register keywords
	my %skip;
	@skip{qw(if while for int void unsignd float double bool char)} = ();


	while($contents =~ m{
			([^\\;\s]+                # type
			\s+
			([a-zA-Z_][a-zA-Z0-9_]*)  # function name
			\s*
			\( [^;#]* \)              # argument list
			[^;]*                     # attributes or something
			;)                        # end of declaration
		}xmsg){
			my $decl = $1;
			my $name = $2;

			next if exists $skip{$name};
			next if $name eq uc($name);  # maybe macros

			next if $decl =~ /\b typedef \b/xmsi;

			next if $decl =~ /\b [0-9]+ \b/xmsi; # integer literals
			next if $decl =~ / ["'] /xmsi;       # string/char literals

			push @functions, $name;

			_verbose "function: $name" if _VERBOSE;
	}

	$self->cc_append_to_funclist(@functions) if @functions;
	return;
}


sub cc_append_to_funclist{
	my($self, @functions) = @_;

	$self->_xs_initialize();

	my $mm = $self->makemaker_args;

	push @{$mm->{FUNCLIST} ||= []}, @functions;

	return;
}


package
	MY;

use Config;

# XXX: We must append to PM inside ExtUtils::MakeMaker->new().
sub init_PM{
	my $self = shift;

	$self->SUPER::init_PM(@_);

	while(my($k, $v) = each %ToInstall){
		$self->{PM}{$k} = $v;
	}
	return;
}

# append object file names to CCCMD
sub const_cccmd {
	my $self = shift;

	my $cccmd  = $self->SUPER::const_cccmd(@_);
	return q{} unless $cccmd;

	if ($Config{cc} =~ /\A cl \b /xmsi){
		# Microsoft Visual C++ Compiler
		$cccmd .= ' -Fo$@';
	}
	else {
		$cccmd .= ' -o $@';
	}

	return $cccmd
}

1;
__END__

=for stopwords gfx API

=head1 NAME

Module::Install::XSUtil - Utility functions for XS modules

=head1 VERSION

This document describes Module::Install::XSUtil version 0.01.

=head1 SYNOPSIS

	# in Makefile.PL
	use inc::Module::Install;

	# No need to include ppport.h. It's created here.
	use_ppport 3.19;

	# Enables C compiler warnings, e.g. -Wall -Wextra
	cc_warnings;

	# This is a special version of requires().
	# If XS::SomeFeature provides header files,
	# this will add its include paths into INC
	requies_xs 'XS::SomeFeature';

	# Sets paths for header files
	cc_include_paths 'include'; # all the header files are in include/

	# Sets paths for source files
	cc_src_paths 'src'; # all the XS and C source files are in src/

	# Installs header files
	install_headers; # all the header files are in @cc_include_paths


=head1 DESCRIPTION

Module::Install::XSUtil provides a set of utilities to setup distributions
which include XS module.

=head1 FUNCTIONS

=head2 requires_xs $module => ?$version

Does C<requires()> and setup B<include paths> and B<libraries>
for what I<$module> provides.

=head2 use_ppport ?$version

Create F<ppport.h> using C<Devel::PPPort::WriteFile()>.

This command calls C<< configure_requires 'Devel::PPPort' => $version >>
and adds C<-DUSE_PPPORT> to B<ccflags>.

=head2 cc_warnings

Enables C compiler warnings.

=head2 cc_src_paths @source_paths

Sets source file directories which include F<*.xs> or F<*.c>.

=head2 cc_include_paths @include_paths

Sets include paths for a C compiler.

=head2 install_headers ?@header_files

Declares providing header files.

If I<@header_files> are omitted, all the header files in B<include paths> will
be installed.

This information are added to F<META.yml>.

=head2 cc_append_to_inc @include_paths

Low level API.

=head2 cc_append_to_libs @libraries

Low level API.

=head2 cc_append_to_ccflags @ccflags

Low level API.

=head2 cc_append_to_funclist @funclist

Low level API.

=head1 DEPENDENCIES

Perl 5.5.3 or later.

=head1 BUGS

No bugs have been reported.

Please report any bugs or feature requests to the author.

=head1 AUTHOR

Goro Fuji (gfx) E<lt>gfuji(at)cpan.orgE<gt>.

=head1 SEE ALSO

L<ExtUtils::Depends>.

L<Module::Install>.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009, Goro Fuji (gfx). Some rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut