
package Baldrick::TemplateAdapterTT;

use Template;
use Baldrick::Util;

use strict;

our @ISA=qw(Baldrick::TemplateAdapterBase Baldrick::Turnip);

sub init
{
    my ($self, %args) = @_;

    $self->SUPER::init(%args,
        copyDefaults => {
            config => $args{config},
        }, 
    );

	# for getPreferredSuffix().
	$self->{_filesuffix} = $self->getConfig('filesuffix', defaultvalue => 'tt');

	my $incpath = $self->getIncludePath();

    my $engineOpts = $self->getConfig('engine-startup-options', 
        defaultvalue => {
	        ABSOLUTE    => 1, 
    		RELATIVE    => 1, 
            POST_CHOMP  => 1,               	# cleanup whitespace
            EVAL_PERL   => 1,               	# evaluate Perl code blocks
            # INTERPOLATE  => 1,               	# expand "$var" in plain text
            # PRE_PROCESS  => 'header',       	# prefix each template
        }
    );

    $self->installEngine(Template->new(
    	INCLUDE_PATH => $incpath,  			# or list ref
        %$engineOpts
    )); 
    return $self;
}

sub processString
{
	my ($self, $text) = @_;
	my $tt = $self->getEngine();

	my $output;

	if (! $tt->process(\$text, $self->getObjects(), \$output))
	{
		my $err = $tt->error();
		$self->abort($err);
	}
	return $output;
}

sub processFile # ($file) return REFERENCE
# return a reference to a string containing the processed text.
{
	my ($self, $file) = @_;

	print "- processfile $file<br>\n" if ($self->{debug});
	my $tt = $self->getEngine();

    my $obj = $self->getObjects();
    my @okeys = sort (keys (%$obj));
    $obj->{internal}->{OBJECT_LIST} = join(" ", @okeys);

	my $out;
	if (! $tt->process($file, $obj, \$out))
	{
		my $err = $tt->error();
		$self->abort($err);
	}
	return \$out;
}

1;
