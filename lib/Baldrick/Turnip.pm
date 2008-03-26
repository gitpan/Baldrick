package Baldrick::Turnip;
# Provides functions to be used by just about every class that does anything interesting; 
# consistent ways to handle errors and options.

use strict;

use Data::Dumper;
use FileHandle;
use Baldrick::Util;

sub new # ( %args) 
{
	my ($class, %args) = @_;
    my $self = {};
	bless ($self, $class);
    if (%args)
    {
        $self->init(%args) unless ($args{no_init});
    }
    return $self;
}

sub init    # ( %args ) 
# A pseudo-constructor that may be called any number of times.
# optional args:
#   copyRequired => [ list of required arguments for _construct ]
#   copyOptional => [ list of optional arguments for _construct ]
#   copyDefaults => { hashref of defaults for copyRequired/copyOptional }
#   logHandle => handle
#   openLogFile => file-path    -- open this log file.  Usual date-words expansion is done.
#   creator => Turnip object (will call getLogHandle())
#       if creator is defined:
#       copyConfig => 0|1 -- copy creator's configRoot 
{
    my ($self, %args) = @_;

    # call _construct with copyRequired / copyOptional / copyDefaults
    my $defaults = $args{copyDefaults} || {};
    if ($args{debug})
    {
        $self->{_debug} = $args{debug};
    }

    if ($args{copyRequired})
    {
        $self->_construct(\%args, $args{copyRequired}, 
            defaults => $defaults, required => 1);
    } 

    my $optArgs  = $args{copyOptional} || [ (keys %$defaults) ]; 
    if ($#$optArgs >= 0)
    {
        $self->_construct(\%args, $optArgs, 
            defaults => $defaults, required => 0);
    } 

    my $cr = $args{creator} || 0;
    if ($cr)
    {
    	$self->setConfigRoot( $cr->getConfigRoot() ) if ($args{copyConfig});
    }
    
    unless ($self->{_logHandle})
    {
        if (my $lh = $args{logHandle})
        {
            $self->setLogHandle($lh);
        } elsif (my $olf = $args{openLogFile}) {
            $self->openLog(file => $olf);
        } elsif ($cr && $cr->can('getLogHandle') ) {
            my $lh = $cr->getLogHandle();
            $self->setLogHandle($lh) if ($lh);
        } 
    }
    
    # set default log prefix to be our class name
    $self->{_logprefix} ||= $args{logprefix} || ref($self);

    return $self;
}

sub finish
{
	my ($self) = @_;
	$self->closeLog();
    $self->{_finished} = 1;
    return 0;
}

sub isFinished
{
    return $_[0]->{_finished};
}

sub clone
{
    my ($self) = @_;

    return Baldrick::Util::cloneObject($self);
}

sub DESTROY
{
	my ($self) = @_;
	$self->finish();
}

sub _construct # ( \%source, $varlist, %opts )
# Generic constructor.  Each parameter in list is copied to member variable 
# with preceding '_'.
# If undefined, defaults to '', or $defs->{...}
# opts: 
#	required => 0 | 1
#   defaults => HASHREF
#   memberprefix => _
{
	my ($self, $parms, $varlist, %opts ) = @_;
	my $defs = $opts{defaults} || {};

    $self->abort("First argument to constructor must be hashref.")
        unless (ref($parms));

    my $mp = defined ($opts{memberprefix}) ? $opts{memberprefix} : '_'; 
	
	foreach my $word (@$varlist)
	{
        my $member = $mp . $word;

        next if (defined($self->{$member}) && (!$opts{overwrite}));

		if (defined ($parms->{$word}))
		{
			$self->{$member} = $parms->{$word};
		} elsif (defined ($defs->{$word})) {
			$self->{$member} = $defs->{$word};
		} elsif ($opts{required}) {
			$self->abort("".ref($self) . "._construct(): field '" . $word . "' is required.");
		} else {
			$self->{$member} = '';
		}
	}
	return 0;
}

sub getDebug
{
    my ($self) = @_;
    return $self->{_debug};
}

sub setDebug
{
    my ($self, $d) = @_;
    $self->{_debug} = $d;
}

sub pushDebug
{
    my ($self, $val) = @_;
    $self->{_debugLevelStack} ||= [];
    push (@{ $self->{_debugLevelStack} }, $self->getDebug());
    $self->setDebug($val);
}

sub popDebug
{
    my ($self) = @_;

    $self->{_debugLevelStack} ||= [];
    my $odb = pop (@{ $self->{_debugLevelStack} }) || 0;
    $self->setDebug($odb);
    return $odb;
}

sub dump # ( %opts ) return string
{
	my ($self, %opts) = @_;
	# return Baldrick::Util::dumpObject($self, %opts);
	my $raw = Dumper($self);
	my @lines = split(/\n/, $raw);
	for (my $i=0; $i<=$#lines; $i++)
	{
		$lines[$i] =~ s/^        //;
	} 

	my $rv = join("\n", @lines);
	if ($opts{html})
	{
		return "<pre>" . $rv . "</pre>";
	} else {
		return $rv;
	}
}

sub loadFrom # ( $source )
# For classes that represent a database row; simply copy the fields as-is.
# override it if you want something fancier.
{
	my ($self, $source, %args) = @_;
	foreach my $k (keys %$source)
	{
        next if (substr($k,0,1) eq '_');
		$self->{$k} = $source->{$k};
	}
    
	$self->analyse() unless ($args{no_analyse});
    return $self;
}

sub analyse { return $_[0]; }
# alternate spelling.
sub analyze { my ($self, @junk) = @_; return $self->analyse(@junk) };


################################## CONFIG HANDLING #######################################
# Config file settings, as distinct from compiled-in options

my $_CONFIG_SEARCHPATH = "__baldrick_config_searchpath";
my $_CONFIG_SEARCHNODES = "__baldrick_config_searchnodes";

sub getConfigRoot # ()	## Return root of the object's config tree.
{
    my ($self) = @_;
    return $self->{_config};
}

sub setConfigRoot
{
	my ($self, $root) = @_;
	$self->{_config} = $root;
	# rebuild nodelist from saved searchpath array.
	$self->setConfigSearchPath( $self->{$_CONFIG_SEARCHPATH} );
}

sub getConfigSearchPath
{
    return $_[0]->{ $_CONFIG_SEARCHPATH };
}

sub setConfigSearchPath # ( [ "/", "/foo/bar" ] ) 	## where getConfig() looks by default.
{
    my ($self, $pathlist) = @_;
    
    if (! $pathlist || ($#$pathlist<0))
    {
        delete $self->{ $_CONFIG_SEARCHPATH };
        delete $self->{ $_CONFIG_SEARCHNODES };
        return 0;
    }
    
    $self->{ $_CONFIG_SEARCHPATH } = $pathlist;	# store text version...
    $self->{ $_CONFIG_SEARCHNODES } = [];	# and compiled version.
    
    foreach my $path (@$pathlist)
    {
    	my $node = $self->_getConfigNode($self->{_config}, $path);
    	if (defined($node))
    	{
    		push (@{ $self->{$_CONFIG_SEARCHNODES}}, $node);	
    	}
    }
    return 0;
}

sub mergeConfig
{
    my ($self, $newcfg) = @_;
    my $oldcfg = $self->getConfigRoot();
    if ($oldcfg)
    {
        mergeHashTrees($oldcfg, $newcfg);
        $self->setConfigRoot($oldcfg);
    } else {
        $self->setConfigRoot($newcfg);
    } 
}

sub _getConfigNode # ($rootnode, '/path/to/node')	# return hashref or undef.
{
	my ($self, $rootnode, $path) = @_;
	
	my $loc = $rootnode;				# current location in tree
	my @labels = split(m#/#, $path);
	for (my $i=0; $i<=$#labels; $i++)
	{
		my $thislabel = $labels[$i];
		next if ($thislabel eq '');	# skip null labels.
		
		if (ref($loc) && (defined ($loc->{ $thislabel })))
		{
			$loc = $loc->{ $thislabel };
		} else {
			return undef;	
		}
	}
	return $loc;
}

sub getConfig # ($cfgkey, %opts) return string or other
#WHERE TO LOOK:
#  opt config => hashref ( else use $self->{_config} )
#  opt places => [ multiple section names to search in... ] or semicolon-separated list.
#  opt section => section-name  -- relevant to root or each searchpath node.
#HOW TO RETURN IT:
#  opt bool = 0 | 1 -- if set, return settings as true/false.
#  opt aslist => 1 	-- split at spaces and return listref instead of string.
#  opt delim => SPACE | ; | , -- delimiter for aslist
#  opt limitvalues = LISTREF - it must be one of these values, else fatal error.
#NOT FOUND? WHAT NEXT?
#  opt defaults => hashref		-- fall-back place to look for it. (default $self->{_config_defaults} )
#  opt defaultvalue => what to return if all else fails...
#  opt required => 0 | 1 -- fatal error if not defined 
#  opt nonempty => 0 | 1 -- fatal error if defined but empty
#  opt warning = 1 | message...  -- warn if not defined.
{
	my ($self, $cfgkey, %opts) = @_;

	# Find root of config tree - usually $self->{_config} unless caller overrides with config=> rootnode
	my $root = defined($opts{config}) ? $opts{config} : $self->{_config};
	$self->setError("no config object in $self", fatal => 1) if (!$root);
	
    # getConfig() (with no cfgkey name) returns the whole tree
	return $root if (!$cfgkey || $cfgkey eq '/');
	
	# Assemble a list of base nodes from rootnode and searchpath, or caller's "places"
	my @basenodes;
	if (defined ($opts{places}))
	{
	    my $placelist = ref ($opts{places}) ? $opts{places} : \split (/;/, $opts{places});
	    foreach my $place (@$placelist)
		{
			my $thisbase = $self->_getConfigNode($root, $place);
			push (@basenodes, $thisbase) if ($thisbase);
		}
	} elsif (($root == $self->{_config}) && ($self->{$_CONFIG_SEARCHNODES})) {
		foreach my $thisbase (@{ $self->{$_CONFIG_SEARCHNODES} })
		{
		    push (@basenodes, $thisbase);		    
		}
	} 
	
	# no search list; search root only - places/CONFIG_SEARCHNODES may have been empty.
	push (@basenodes, $root) if ($#basenodes < 0);
	
    # Now search for the requested section and cfgkey in each basenode.
    my $rv = undef;
    for (my $i=0; $i<=$#basenodes && (!defined($rv)); $i++)
    {
        my $thisbase = $basenodes[$i];
        my $section = $thisbase;        # look in root by default.
        if (defined ($opts{section}))
        {
            $section = $self->_getConfigNode($thisbase, $opts{section});
            next if (!defined($section) || !$section);
        }

        $rv = $self->_getConfigNode($section, $cfgkey);        
    }
    
    my $foundit = 0; 
	if (defined ($rv))
	{
        $foundit = 1;
	    if (($rv eq '') && defined ($opts{nonempty}) && $opts{nonempty})
	    {
	       return $self->setError("required configuration option '$cfgkey' has a disallowed emptiness",
                fatal => 1);
	    }
	} elsif (defined ($opts{defaultvalue})) {
		$rv= $opts{defaultvalue};
	} elsif (defined ($opts{defaults})) {
		$rv = $self->_getConfigNode($opts{defaults}, $cfgkey);
	} elsif (defined ($self->{_config_defaults}) && defined($self->{_config_defaults}->{$cfgkey})) {
	    $rv = $self->_getConfigNode($self->{_config_defaults}, $cfgkey);
	} elsif ($opts{required} || $opts{require} || $opts{nonempty}) {
		$self->setError("required configuration option '$cfgkey' not found " .
		    (defined $opts{section} ? "(section $opts{section})" : ""), 
		    fatal => 1);
		return '';
	} else {
		$rv = '';
	}

    if ($self->{_debug_getconfig})
    {
        print "getconfig( $opts{section} / $cfgkey ) return : '$rv'<br>";
    }

    # limitvalues=LISTREF: ensure that the returned value appears in this list.
    if (defined $opts{limitvalues})
    {
        my $lim = $opts{limitvalues};
        if (! grep { $rv eq $_ } @$lim)
        {
            $self->abort("Configuration option '$cfgkey' must have one of these values: " . join(", ", @$lim));
        } 
    } 

    if (!$foundit)
    {
        if ($opts{warning})
        {
            $self->writeLog("WARNING: getConfig():" . 
                (length($opts{warning})>2) ? $opts{warning} :
                "$cfgkey undefined in $opts{section}"
            );
        }
    } 

    # HOW TO RETURN IT.	
    # aslist=0|1  - if true, split at 'delim' regex & return LISTREF.
	if (defined ($opts{aslist}) && $opts{aslist})
	{
	    my $delim = defined($opts{delim}) ? $opts{delim} : '[\s\t]+';
		my @temp = split(m/$delim/, $rv);
		return \@temp;
	} elsif (defined($opts{bool}) && $opts{bool}) {
	    return seekTruth($rv);
	} else {
		return $rv;
	}
}

sub getConfigSection # ($path, %opts) return hashref
# $path: a hierarchical name such as foo/bar/baz
# opt required => 0|1 : fatal error if not found.
# opt config => hashref : use this instead of $self->{_config}
{
	my ($self, $section, %opts) = @_;
	
	my $cfg = defined $opts{config} ? $opts{config} : $self->{_config};
	$self->setError("no config object", fatal => 1) if (!$cfg);
	my @labels = split(m#/#, $section);
	
	my $loc = $cfg;	# current location in tree
	for (my $i=0; $i<=$#labels; $i++)
	{
		my $thislabel = $labels[$i];
		if (defined ($loc->{ $thislabel }))
		{
			$loc = $loc->{ $thislabel };
		} else {
			if ($opts{required})
			{
				$self->setError("config section '$section' not found", fatal => 1);
			}
			return 0;
		}
	}
	return ($loc);
}

################################## ERROR HANDLING ########################################

sub abort # ($msg, %opts)
# DEPRECATED - this name is too common, causes conflicts.  use fatalError().
{
	my ($self, $msg, %args) = @_;
	return $self->setError ($msg, %args, fatal => 1, uplevel => 1 + $args{uplevel});
} 

sub fatalError # ($msg, %opts)
{
	my ($self, $msg, %args) = @_;
	return $self->setError ($msg, %args, fatal => 1, 
        uplevel => 1 + $args{uplevel});
} 

sub whinge
{
    my ($self, $msg, %args) = @_;
    $args{uplevel} ||= 0;
    $args{uplevel}++;

    return $self->setError($msg, %args, whinge => 1);
}

sub setError    # ($msg, %args)
# $msg - PUBLIC message to show to user; logs will use 'privmsg' or $msg.
# optional args:
#   privmsg => private message for log files, won't be shown to user.
#   fatal => 0|1 -- die with this error message.
#   uplevel => 0... -- show caller info.
#   returnval => -1 what to return (default -1)
#   whinge => 0|1 -- just a bit of minor whining, don't set _error to this.
#   critical => send mail to site admin
{
    my ($self, $msg, %opts) = @_;

	chomp($msg);

	my $fullmsg = $self->annotateError($opts{privmsg} || $msg, %opts);

    $self->writeLog($fullmsg, error => 1, no_stderr => $opts{no_stderr} );
	
    unless (defined $opts{whinge})
    {		
        $self->{_error} = $msg;
        $self->{_private_error} = $opts{privmsg} ||$msg;
    }
    
    $self->mutter($fullmsg, divclass => 'error');

    if ($opts{critical})
    {
        my $addr = $opts{notify_mail};
        if (!$addr && $self->getConfigRoot())
        {
            $addr = $self->getConfig("errornotify");
        } 
        if ($addr)
        {
            sendMail(
                to => $addr,
                subject => "CRITICAL ERROR ON $ENV{SERVER_NAME}",
                text => "\nCRITICAL ERROR - SERVER $ENV{SERVER_NAME}\n\n$self->{_error}\n\n$self->{_private_error}\n$opts{extrainfo}\n\n" . ref($self) . "\n\n$ENV{REMOTE_ADDR}"
            );
        } else {
            print STDERR "CRITICAL ERROR $msg in " . ref($self) . "\n"; 
        } 
    } 

	if ($opts{fatal})
	{
    	die($msg . "\n");
	}

	return defined($opts{returnval}) ?  $opts{returnval} : -1;
}

sub annotateError # ($msg, %opts)
{
	my ($self, $msg, %opts) = @_;

	my @caller1 = caller(1 + ($opts{uplevel}||0) );
	my @caller2 = caller(2 + ($opts{uplevel}||0) );

#	print "CALLER-1: " . join("; ", @caller1) . "\n";
#	print "CALLER-2: " . join("; ", @caller2) . "\n";

	my $cinfo = "$caller2[0] $caller2[3] [$caller1[2]]";

	# get classname.
    my $ref = ref($self);
    my $prog = $0;
    $prog =~ s#.*/##;

    if ($self->{_errprefix})
    {
		return ( $self->{_errprefix} . " error: $msg ($cinfo)" );
    } elsif ($self->{_logprefix}) {
		return ( $self->{_logprefix} . " error: $msg ($cinfo)" );
    } else {
		return ( "$prog: $ref error: $msg ($cinfo)" );
    }
}

sub getError    # (%opts) return string
# opt full => 0|1 -- return message with program/class prefix.
{
    my ($self, %opts) = @_;
    my $msg = defined($self->{_error}) ? $self->{_error} : '';
    if ($opts{full})
    {
    	return $self->annotateError($msg, %opts);
    } else {
    	return ($msg);
    }
}

sub requireMember
# look in $self for a field.  if defined, return it; else abort.
{
	my ($self, $fn) = @_;
	return $self->{$fn} if (defined ($self->{$fn}));
	$self->setError("Required field '$fn' not present in '$self'",
		fatal => 1);
}

sub argOrMember
{
    my ($self, $args, $label, %opts) = @_;
   
    if ($args && ref($args) && defined ($args->{$label}))
    {
        return $args->{$label};
    } 

    my $l2 = '_' . $label;
    return $self->{$l2} if (defined ($self->{$l2}));
    
    return 0 if ($opts{softfail});
    $self->abort("'$label' not present in " . ref($self) . 
        " or function arguments.", uplevel => 1);
}

sub openLog # (file => $filename)
# the literal TODAY in filename is expanded to something like 2007-12-31
# stores handle in $self->{_logHandle}, name in $self->{_logFile}
{
	my ($self, %args) = @_;

    my $logfile = Baldrick::Util::replaceDateWords(
        requireArg(\%args, 'file'));

    if (my $fh = new FileHandle(">>$logfile"))
    {
	    $self->{_logFile} = $logfile;
	    $self->{_logHandle} = $fh;
        $self->{_isLogOwner} = 1;
        $fh->autoflush(1);
        return $fh;
    } else {
		$self->setError("cannot open log file $logfile: $!");
		return 0;
	} 
}

sub closeLog
{
	my ($self) = @_;

	my $lh = $self->{_logHandle} || return 0;

    if ($self->{_isLogOwner})
    {
        $lh->close();
        delete $self->{_isLogOwner};
    }

    delete $self->{_logHandle};
	return 0;
}


sub getLogHandle { return $_[0]->{_logHandle}; }
sub setLogHandle { my ($self, $h) = @_; $self->{_logHandle} = $h; }

sub writeLog    # $line|\@lines, [logprefix => .., 
# notice => 0|1, warning => 0|1, error => 0|1 ]
{
	my ($self, $lines_tmp, %args) = @_;

    my $isNotice = $args{notice} || $args{warning} || $args{error};
    my $fh = $self->{_logHandle};
	my $fh2 = $args{handle};

    # Require one of the above to be nonzero to proceed.
    if (!$fh && !$fh2 && !$isNotice && !$self->getDebug())
    {
        # return if we have no handle and no imperative to mutter.
        return 0;
    } 

	my @lines;
	
	if (ref($lines_tmp))
	{
		push (@lines, @$lines_tmp);
	} else {
		push (@lines, $lines_tmp);
	} 

	my $pfx = sprintf("%s %s", 
		Baldrick::Util::easydate(), Baldrick::Util::easytime()
	);

    if (defined ($args{logprefix}))
    {
	    $pfx .= ' ' . $args{logprefix};
    } elsif (defined ($self->{_logprefix})) {
	    $pfx .= ' ' . $self->{_logprefix};
    } 

	for (my $jj=0; $jj<=$#lines; $jj++)
	{
		my $line = $lines[$jj];
		chomp($line);

        $self->mutter($line) unless ($args{no_mutter});
	
        print $fh "$pfx $line\n" if ($fh); 
        print $fh2 "$pfx $line\n" if ($fh2); 

        # errors/warnings also to STDERR even if no regular log file.
        if ($isNotice && (! $args{no_stderr}) )
        {
	        print STDERR "$pfx $line\n";
        }
	} 

	return 0;
}

###### get/put Contents interface.

sub getContents
{
    my ($self) = @_;

    if (defined ($self->{_contents}))
    {
        $self->{_changed} ||= 0;
        return $self->{_contents};
    } else {
        $self->abort("getContents() called on object " . ref($self) . 
            " lacking _contents member");
    }
}

sub getContentsSubset   # ( (selectors), full_keys => 0|1) return hashref
# Return a hash containing selected key/value pairs from getContents() - only
# those with key names having a given prefix/suffix or matching a regex
# selectors:
#   regex => perl regex to match keys with; (.*) is OK; return $1$2$3$4$5 or full key
# OR 
#   prefix => string, suffix => string -- return keys that begin/end with these
{
    my ($self, %args) = @_;

    my $contents = $self->getContents() || {};
    my $regex  = $args{regex} || '';
    my $prefix = $args{prefix} || '';
    my $suffix = $args{suffix} || '';
    my $wantfull = $args{full_keys} ? 1 : 0;
    my %rv;

    foreach my $k (keys %$contents)
    {
        my $outname = '';
        if ($regex)
        {
            if ($k =~ m/$regex/)
            {
                $outname = "$1$2$3$4$5" || $k;
            } 
        } elsif ($k =~ m/$prefix(.*)$suffix/) {
            $outname = $1;
        } 
        next unless ($outname);
        $outname = $k if ($wantfull);
        $rv{$outname} = $contents->{$k};
    } 

    return \%rv;
}

sub get # ($keyname, %opts)
# optional parameters:
#   required => 0|1 - fatal error if not present
# -- what to return
#   defaultvalue => 'foo' : return this if not defined 
# -- how to return it.
#   lcase => 0|1 : force lowercase
#   ucase => 0|1 : force uppercase
#   dequote => 0|1 : escape single quotes for safer sqling
#   forcealpha => 0|1 : remove all but A-Za-z0-9_
#   firstvalue => 0|1 : chop at first \0 (used for CGI request)
{
    my ($self, $k, %args) = @_;

    my $c = $self->getContents();
    my $rv = '';

    if (defined ($c->{$k}) )
    {
        $rv = $c->{$k};
    } elsif (defined ($args{defaultvalue})) {
        $rv = $args{defaultvalue};
    } elsif ($args{required}) {
        $self->setError("Required parameter '$k' was missing.", fatal => 1);
    }

    # return early if no transformations.
    return $rv unless (%args);

    # TRANSFORMATIONS.
    $rv =~ tr/A-Z/a-z/ if ($args{lcase});
    $rv =~ tr/a-z/A-Z/ if ($args{ucase});
    $rv =~ s/'/\\'/ if ($args{dequote});
    $rv =~ s/[^a-zA-Z0-9_]//g if ($args{forcealpha});
    $rv =~ s/\0.*// if ($args{firstvalue});
    $rv =~ s/\s+$// if ($args{rtrim});
    $rv =~ s/^\s+// if ($args{ltrim});

    return $rv;
}

sub put # ($key, $value)
{
    my ($self, $k, $v) = @_;

    my $con = $self->getContents();

    if (defined ($con->{$k}) )
    {
        # Hasn't changed - drop out early without touching anything.
        return 0 if ($v eq $con->{$k});
    }

    # PUT IT IN, and increment _changed.
    $self->{_changed}++;
    $con->{$k} = $v;
    return 0;
}

sub del # ($key)
{
    my ($self, $k) = @_;
    my $con = $self->getContents();

    if (defined ($con->{$k}) )
    {
        delete $con->{$k};
        $self->{_changed}++;
    }
    return 0;
}

sub clearContents
{
    my ($self, %args) = @_;

    my $con = $self->getContents();
    my $skipkeys = $args{preserve};

    if ($skipkeys)
    {
        foreach my $k (keys %$con)
        {
            next if (grep { $_ eq $k } @$skipkeys);

            delete $con->{$k};
        } 
    } else {
        $self->{_contents} = { };
    } 
    $self->{_changed}++;
    return $self->{_contents};    
}

sub factoryCreateObject # (%args)
# Generic factory to create an object of any class from a config file.
# config => { }
# classname => 'Some::Class::Name' -- force it to this classname
# defaultclass => 'Some::Class::Name' -- fall back on this name if not config->{classname}
# init_args => \%args_for_init
# no_init => 0|1 -- don't call init at all. 
{
    my (%args) = @_;

    my $config = $args{config} || { };
    my $classname = $args{classname} || $config->{classname} || $args{defaultclass};

    my $obj = dynamicNew($classname);
    if ($args{init_args})
    {
        $obj->init( %{ $args{init_args} } );
    } elsif ($args{no_init}) {
    } else {
        $obj->init(%args);
    }
    return $obj; 
}

sub debugPrint { mutter(@_) };  # DEPRECATED.

sub mutter
{
    my ($self, $msg, %args) = @_;

    my $dbug = 0;
    if ($args{always})
    {
        $dbug = 9;
    } else {
        $dbug = $self->{_debug} || return 0;
    }

    # $self->writeLog($msg, no_mutter => 1);
    if ($dbug >= 9) 
    {
        Baldrick::Util::webhead() unless ($self->{_debug_did_webhead});
        $self->{_debug_did_webhead} = 1;

        my $cl = $args{divclass} || 'debug';
        my $rs = $args{noprefix} ? '' : '[' . ref($self) . '] ' ;
        my $msg2 = escapeHTML($msg);
        print qq|<div class="$cl">$rs$msg2</div>|;
    } else {
        print STDERR $msg . "\n";
    }
}

sub transmogrifySelf    # ($classname|$model)   # return $self
# Become another class.
{
    my ($self, $cl, %args) = @_;
    if (ref($cl))
    {
        $cl = ref($cl);
    } else {
        loadClass($cl);
    }

    my $oldclass = ref($self);
    bless ($self, $cl);

    if ($self->{_logprefix} eq $oldclass)
    {
        $self->{_logprefix} = $cl;
    } 
    return $self;
}

sub getFunctions # EXPERIMENTAL!
{
    my ($self, %args) = @_;

    my $package = ref($self);
    
    no strict 'refs';
    my $ftable = \%{ $package . '::' };
    
    my %ancestors = ( $package => $package );
    map { $ancestors{$_} = $_ } @{ $ftable->{ISA} };
#    webdump(\%ancestors);
    
    my $rv = {};
    foreach my $k (sort keys %$ftable)
    {
        my $v = $ftable->{$k};
        my $code = *{$v}{'CODE'} || next;  
        $rv->{$k} = $code;

#        if ($v =~ m/([^*]+)::[^:]+$/)
#        {
#            my $pfx = $1;
#            # if ($ancestors{$pfx})
#        } 
        # $self->sendOutput(text => "<li>$k // $v</li>\n");
    }
    # $self->sendOutput(text => "$package - ok \n");
    return $rv;
}

1;
