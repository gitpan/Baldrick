
package Baldrick::TemplateAdapter::TextTemplate;

use Text::Template;
use Baldrick::Util;

use strict;

our @ISA=qw(Baldrick::TemplateAdapter Baldrick::Turnip);

sub init
{
    my ($self, %args) = @_;

    $self->SUPER::init(
        default_suffix => 'tmpl',
        default_startup_opts => {
         
        },
        %args
    );

    $self->{_default_startup_opts}->{DELIMITERS} => [ '<%', '%>' ];
    $self->{_engine} = 0;   # created by processString()/processFile() as needed.
    my $opts = $self->getEngineStartupOptions();
    if (my $dl = $self->getConfig("DELIMITERS"))
    {
        my ($a, $b) = split(/\s+/, $dl);
        if ($a && $b)
        {
            $opts->{DELIMITERS} = [ $a, $b ];
        } 
    } 

    return $self;
}

sub processString   # ($text) return string
{
	my ($self, $text, %args) = @_;

    my $opts = $self->getEngineStartupOptions();
	my $tt = Text::Template->new(
        %$opts,
        TYPE => 'STRING',
        SOURCE => $text,
    );

    my $objs = $self->_getObjectRefs();
	my $output = $tt->fill_in(HASH => $objs);
	return $output;
}

sub processFile # ($file) return REFERENCE
# return a reference to a string containing the processed text.
{
	my ($self, $file, %args) = @_;

	print "- processfile $file<br>\n" if ($self->{debug});

    my $opts = $self->getEngineStartupOptions();
	my $tt = Text::Template->new(
        %$opts,
        TYPE => 'FILE',
        SOURCE => $file
    );

    my $objs = $self->_getObjectRefs();
	my $out = $tt->fill_in(HASH => $objs);
	return \$out;   # wants text-ref
}

sub _getObjectRefs
# Text::Template doesn't like references to objects, it wants 
# references to references to objects.
# Do not override getObjects(), it must stay intact so add/remove work.
{
    my ($self) = @_;

    my $objs = $self->SUPER::getObjects();
    my $rv = { };
    foreach my $k (keys %$objs)
    {
        my $foo = $objs->{$k};
        $rv->{$k} = ref($foo) ? \$objs->{$k} : $foo;
    }
    return $rv;
}

1;
