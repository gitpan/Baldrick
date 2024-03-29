
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

sub splitTextLines  # (text, width)
{
    my ($self, $text, $width) = @_;
    return Baldrick::Util::wordsplit($text, $width || 72);
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

sub random
{
    my ($self, $lim) = @_;

    $lim ||= 10000;
    return ( int( rand($lim)));
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

##############################################################################

package Baldrick::TemplateAdapter;

use Carp;
use strict;
use Baldrick::Util;

our @ISA = qw(Baldrick::Turnip);

our $DEFAULT_CONFIG = {
    classname => 'Baldrick::TemplateAdapter::TemplateToolkit',
    'include-path' => '${MODULE_TEMPLATES};${TEMPLATE_BASE};${TEMPLATE_BASE}/${MODULE_TEMPLATES};${SCRIPT_DIR};${DOCUMENT_ROOT}'
};

sub init
{
    my ($self, %args) = @_;

    $self->SUPER::init(%args,
        copyRequired => [ 'config' ]
    );

    $self->{_filesuffix} = $self->getConfig('filesuffix', defaultvalue => $args{default_suffix} );
    $self->{_engineStartup} = $self->getConfig('engine-startup-options', 
        defaultvalue => $args{default_startup_opts} || {}
    );

	$self->_initDefaultObjects();
    $self->_initIncludePath(%args);

    return $self;
}

sub getEngineStartupOptions
{
    return ($_[0]->{_engineStartup} || {});
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

sub makeObjectList
{
    my ($self) = @_;

    my $obj = $self->getObjects();
    my @okeys = sort (keys (%$obj));
    $obj->{internal}->{OBJECT_LIST} = join(" ", @okeys);
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
        $outpath =~ s/\$\{([^\}]+)\}/defined($subs->{$1}) ? $subs->{$1} : next/eg;

        $outpath =~ s#/$##;
        $self->mutter("adding template path: $outpath");

        if (-d $outpath || -f $outpath)
        {
            push (@outpaths, $outpath);
        } elsif ($self->getConfig("dont-check-paths")) {
            push (@outpaths, $outpath);
        } else {
            $self->mutter("WARNING: output path $outpath doesn't appear to exist");
        } 
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
# Add Date, internal, and ENV to object store.  
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
		shortdate => sprintf("%02d%02d%02d", $lt[5]%100, $lt[4]+1, $lt[3]),
		date => sprintf("%04d-%02d-%02d", $lt[5]+1900, $lt[4]+1, $lt[3]),
		time => sprintf("%02d:%02d:%02d", $lt[2], $lt[1], $lt[0]),
	);
	
	$self->{_objects} = { internal => $internal, ENV => \%ENV, Date => \%date };
	$self->{_internal} = $internal;
	return $self;
}

sub getObjects
{
    my ($self, %args) = @_;
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

sub findTemplate
# Moved from Baldrick::Dogsbody 2008/02/22
{
	my ($self, $filename, %args) = @_;
	
    my $ext = $args{suffix} || $self->getPreferredSuffix();
    my $paths = $self->getIncludePath();
   
    my @badpaths; 
    foreach my $p (@$paths)
    {
        my $fullpath = "$p/$filename.$ext";
        return $fullpath if (-f $fullpath);
        
        $fullpath = "$p/$filename";
        return $fullpath if (-f $fullpath);

        push (@badpaths, $fullpath);
    } 

    # current directory searched last.
    return $filename if (-f $filename);

    $self->{_PATHS_SEARCHED} = \@badpaths;
    $self->setError("no template found matching $filename / $filename.$ext; searched paths "
        . join(";", @badpaths), uplevel => 1);

    return 0;
}

####################### STATIC #############################################
sub factoryCreateObject
{
    my (%args) = @_;

    return Baldrick::Turnip::factoryCreateObject(
        defaultclass => $DEFAULT_CONFIG->{classname},
        defaultconfig => $DEFAULT_CONFIG,
        %args
    );
}

1;
