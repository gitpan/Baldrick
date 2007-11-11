
package Baldrick::TemplateAdapter::TemplateToolkit;

use Template;
use Baldrick::Util;

use strict;

our @ISA=qw(Baldrick::TemplateAdapter Baldrick::Turnip);

sub init
{
    my ($self, %args) = @_;

    $self->SUPER::init(
        default_suffix => 'tt',
        default_startup_opts => {
	        ABSOLUTE    => 1, 
    		RELATIVE    => 1, 
            POST_CHOMP  => 1,               	# cleanup whitespace
            EVAL_PERL   => 1,               	# evaluate Perl code blocks
            # INTERPOLATE  => 1,               	# expand "$var" in plain text
            # PRE_PROCESS  => 'header',       	# prefix each template
        },
        %args
    );

    my $opts = $self->getEngineStartupOptions();
    $self->installEngine(
        Template->new(
    	    INCLUDE_PATH => $self->getIncludePath(),
            %$opts
        )
    ); 

    return $self;
}

sub processString
{
	my ($self, $text, %args) = @_;
	my $tt = $self->getEngine();

	my $output='';
	if (! $tt->process(\$text, $self->getObjects(), \$output))
	{
		my $err = $tt->error();
		$self->abort($err) unless ($args{softfail});
	}
	return $output;
}

sub processFile # ($file) return REFERENCE
# return a reference to a string containing the processed text.
{
	my ($self, $file, %args) = @_;

	print "- processfile $file<br>\n" if ($self->{debug});
	my $tt = $self->getEngine();

    $self->makeObjectList();

	my $out;
	if (! $tt->process($file, $self->getObjects(), \$out))
	{
		my $err = $tt->error();
		$self->abort($err) unless ($args{softfail});
	}
	return \$out;
}

1;
