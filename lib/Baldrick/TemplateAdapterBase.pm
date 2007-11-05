
package Baldrick::TemplateAdapterHelper;

use strict;
use Carp;
use Data::Dumper;

our @ISA = qw(Baldrick::Turnip);

sub escapeURL
{
	my ($self, $text) = @_;
    return Baldrick::Util::escapeURL($text);
}

sub escapeHTML
{
	my ($self, $text) = @_;
    return Baldrick::Util::escapeHTML($text);
}

sub round
{
	my ($self, $num, $prec) = @_;

	$prec=2 if ($prec eq '' || $prec eq undef);

	return sprintf("%.${prec}f", $num);
}

sub printf
{
	my ($self, $fmt, @args) = @_;
	return sprintf($fmt, @args);
}

sub arraycount
{
	my ($self, $foo) = @_;
	if (ref($foo) eq 'ARRAY')
	{
		return 1+ $#$foo;
	} else {
		return 0;
	}	
}

sub dumpObject
{
	my ($self, $foo) = @_;

	my $classname = ref($foo);
	$classname =~ s/:/_/g;

	my $rv =  Data::Dumper->Dump([$foo], [ "this_$classname" ]);
	$rv =~ s/\&/&amp;/g;
	$rv =~ s/</&lt;/g;
	$rv =~ s/>/&gt;/g;
	my @lines = split(/\n/, $rv);

	# get leading spaces.
	#my $pfx = $lines[1];
	#$pfx =~ s/[^\s].*//g;

	for (my $i=0; $i<=$#lines; $i++)
	{
		if ($lines[$i] =~ m/^(\s+)(.*)/)
		{
			my $spaces = $1;
			my $stuff = $2;
			$lines[$i] = (' ' x (length($spaces)/4)) . $stuff;
		} else {
		}
	}
	
	$rv = join("\n", @lines);
	return "<pre>".$rv."</pre>\n";
}

sub showObjects
{
	## die("FIX ME - this is in wrong class.");
	my ($self) = @_;
	my $objects = $self->{_objects};
	my $rv = "<ul>\n";
	foreach my $k (keys %$objects)
	{
		$rv .= "<li>$k = $objects->{$k}</li>\n";
	} 
	$rv .= "</ul>\n";
	return $rv;
}

sub makeHTMLSelector
{
	my ($self, $oldvalue, $array) = @_;

	my $rv = '';	
	foreach my $val (@$array)
	{
		my ($value, $label) = split(m/\|/, $val);
		$label = $value if (!$label);

		my $sel = ($oldvalue eq $value) ? " selected" : "";
		$rv .= qq!<option value="$value"$sel>$label</option>!;
	} 

	return $rv;
}

##############################################################################################################

package Baldrick::TemplateAdapterBase;

use Carp;
use strict;
use Baldrick::Util;
our @ISA = qw(Baldrick::Turnip);

our $DEFAULT_CONFIG = {
    classname => 'Baldrick::TemplateAdapterTT',
    'include-path' => '${MODULE_TEMPLATES};${TEMPLATE_BASE};${SCRIPT_DIR};${DOCUMENT_ROOT}'
};

sub init
{
    my ($self, %args) = @_;

    $self->SUPER::init(%args);
	$self->_initDefaultObjects();
    $self->_initIncludePath(%args);
    return $self;
}

sub finish
{
	my ($self) = @_;
}

sub DESTROY
{
	my ($self) = @_;
	$self->finish();
}

sub _initIncludePath
{
    my ($self, %args) = @_;

    my $includePath = $self->getConfig('include-path', 
        defaults => $DEFAULT_CONFIG
    );

    $self->setIncludePath($includePath, %args);
}

sub getIncludePath { return $_[0]->{_includePath} }
sub setIncludePath
{
    my ($self, $path, %args) = @_;

    my $subs = requireArg(\%args, 'substitutions');

    $self->{_include_path_string} = $path;
    my @inpaths = split(m#\s*;\s*#, $path);
    
    my @outpaths;
    foreach my $path (@inpaths)
    {
        my $outpath = $path;
        $outpath =~ s/\$\{([^\}]+)\}/defined($subs->{$1}) ? $subs->{$1} : "UNKNOWN-$1"/eg;
        $outpath =~ s#/$##;
        push (@outpaths, $outpath);
    } 

    $self->{_includePath} = \@outpaths;
    return \@outpaths;
}

sub installEngine
{
    $_[0]->{_engine} = $_[1];
}
sub getEngine
{
    return $_[0]->{_engine};
}
sub getPreferredSuffix { return $_[0]->{_filesuffix} };

sub _initDefaultObjects
# Add Date, internal, and ENV to object store.  This is generally done at the beginning of 
# App::getNextRequest(), so each user gets a clean copy of these.
{
	my ($self) = @_;

	my $internal = new Baldrick::TemplateAdapterHelper();
	
	my @lt = localtime(time());
	my %date = (
		year => $lt[5]+1900, 
		month => sprintf("%02d", $lt[4]+1), 
		day => sprintf("%02d", $lt[3]), 
		hour => sprintf("%02d", $lt[2]), 
		min => sprintf("%02d", $lt[1]), 
		sec => sprintf("%02d", $lt[0]), 
		shortdate => sprintf("%04d-%02d-%02d", $lt[5]+1900, $lt[4]+1, $lt[3]),
		date => sprintf("%04d-%02d-%02d", $lt[5]+1900, $lt[4]+1, $lt[3]),
		time => sprintf("%02d:%02d:%02d", $lt[2], $lt[1], $lt[0]),
	);
	
	$self->{_objects} = { internal => $internal, ENV => \%ENV, Date => \%date };
	$self->{_internal} = $internal;
	return $self;
}

sub getObjects
{
    my ($self) = @_;
    return $self->{_objects};
}

sub clearObjects # ()
# Discard all object references.  This is useful if a TemplateAdapter is to be reused to handle 
# multiple user requests within the same process, to avoid cross-contamination.
{
	my ($self) = @_;
	delete $self->{_objects};
	delete $self->{_internal};
	return 0;
}

sub addObject
{
	my ($self, $obj, $name) = @_;
	print "- addobject($name)<br>" if ($self->{debug});
	if ($name =~ m/\[/)
	{
		Carp::confess ("cannot use '$name' as object name in TemplateAdapter.");
	} 
	$self->getObjects()->{$name} = $obj;
}

sub removeObject
{
	my ($self, $name) = @_;
	print "- removeobject $name" if ($self->{debug});
	delete ($self->getObjects()->{$name});
}

sub putInternal
{
	my ($self, $k, $v) = @_;
	my $internal = $self->getObjects()->{internal};
	$internal->{$k} = $v;
}

sub getInternal
{
	my ($self, $k) = @_;
	my $internal = $self->getObjects()->{internal};
	return ($internal->{$k});
}

sub getObject
{
	my ($self, $name) = @_;
	return $self->getObjects()->{$name};
}

####################### STATIC #############################################
sub factoryCreateObject
{
    my (%args) = @_;

    return Baldrick::Turnip::factoryCreateObject(
        %args, 
        defaultclass => $DEFAULT_CONFIG->{classname},
        defaultconfig => $DEFAULT_CONFIG
    );
}

1;
