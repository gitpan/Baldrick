# 
# Baldrick::Util - misc functions.

# v0.1 2005/10 hucke@cynico.net

package Baldrick::Util;

use strict;
use Exporter;
use FileHandle;
use Data::Dumper;
use Config::General;

our @ISA = qw(Exporter);
our @EXPORT = qw(listToHash mergeHashTrees requireArg requireArgs requireAny 
    dumpObject dynamicNew uniquifyList easydate easytime easyfulltime 
    sendMail validEmail cloneObject createObject loadClass
    assembleDate webdump webhead webprint seekTruth parseOptionList wordsplit 
    replaceDateWords round parseTimeSpan randomiseList
    loadConfigFile applyStringTransforms escapeURL escapeHTML
);

our $WEBDUMP_ORDINAL = 1000;

sub listToHash # ($listref, $keyfield, %opts)
# opt unique - fatal error if duplicate keys found.
{
	my ($list, $keyfield, %opts) = @_;
	my %out;
	
	foreach my $item (@$list)
	{
		my $val = $item->{$keyfield};
		if (defined($out{$val}))
		{
			if ($opts{unique})
			{
				die("non-unique key value for $keyfield ($val)");
			} 
		} 
		$out{$val} = $item;
	} 

	return \%out;
}

sub mergeHashTrees # 
{
    my ($one, $two) = @_;
    foreach my $k (keys %$two)
    {
        if (! defined($one->{$k}) )
        {
            $one->{$k} = $two->{$k};
        } elsif (ref ($one->{$k})  && ref($two->{$k}) ) {
            mergeHashTrees($one->{$k}, $two->{$k});
        } else {
            $one->{$k} = $two->{$k};
        }
    }
    return $one;
}

sub requireArg # (\%arghash, $argname)	STATIC
{
	my ($args, $name) = @_;

	my @caller = caller();
	my @caller1 = caller(1);

	if (defined ($args->{$name}))
	{
		return $args->{$name};
	} else {
		my $dump = '<ul>';
        map { $dump .= "<li>$_ = $args->{$_}</li>"; } keys (%$args);
		$dump .= '</ul>';
        
		die("required argument '$name' was missing at " . 
			"$caller[0]:$caller[2], $caller1[0]:$caller1[2]\n\n$dump\n");
	}
}

sub requireArgs # (\%arghash, \@required-list)	STATIC
# Use to verify that required arguments are present for a function taking arguments by hash
# ex. requireArgs( \%opts, [ qw(dbh colour size) ] )
{
	my ($args, $required, %opts) = @_;

	my @caller = caller();
	my @caller1 = caller(1);

    # die("need list for requireArgs()") unless (ref($required));
	foreach my $arg (@$required)
	{
		if (!defined ($args->{$arg}))
		{
			die("required argument '$arg' was missing at " . 
				"$caller[0]:$caller[2], $caller1[0]:$caller1[2]\n");
		}
	}
	return 0;
}

sub requireAny # (\%arghash, \@required-list)	STATIC return fieldname
{
	my ($args, $required, %opts) = @_;

	my @caller = caller();
	my @caller1 = caller(1);
	foreach my $fn  (@$required)
	{
		return $fn if (defined ($args->{$fn}));
	}

	die("requires one of of these: " . join(", ", @$required) . " at " . 
		"$caller[0]:$caller[2], $caller1[0]:$caller1[2]\n");
}


sub dumpObject
# opt intro => something to start with like <ul>
# opt prefix => prefix for each line
# opt suffix => suffix for each line
# opt outro => something to end with like </ul>
# opt listhtml => shorthand for intro/outro/prefix/suffix that gives us an HTML list.
# opt dontprint => 0/1 - if true don't print, just return it.
{
	my ($obj, %opts) = @_;
	
	my $rv = '';

	# whence = filename::function() [line]
	my @caller = caller();
	my $bn = $caller[1];
	$bn =~ s#.*/##;
	my $whence = "$bn::$caller[0]() [$caller[2]]";
	
	if (defined ($opts{listhtml}))
	{
		$opts{prefix} = "<li>";
		$opts{suffix} = "</li>";
		$opts{intro} = qq!<h4>$obj at $whence </h4><ul>!;
		$opts{outro} = "</ul>";
	}
	
	$rv .= "$opts{intro}\n" if (defined $opts{intro});

	eval { 
		foreach my $k (sort(keys(%$obj)))
		{
			$rv .= $opts{prefix} if (defined($opts{prefix}));
			$rv .= "$k = $obj->{$k}";
			$rv .= $opts{suffix} if (defined($opts{suffix}));
			$rv .= "\n";
		} 
	};
	if ($@)
	{
		$rv .= "<b>fail to eval as hash: $@</b>\n";
	} 
	$rv .= "$opts{outro}\n" if (defined $opts{outro});
	print $rv unless ($opts{dontprint});
	return $rv;
}

sub dynamicNew { return createObject(@_); }     # deprecated

sub loadClass
{
	my ($classname, %args) = @_;
	$classname =~ s/[^A-Za-z0-9_:]//g;
	
	eval "use $classname;\n";
	if ($@)
	{
	    die("createObject: Failed to load perlmod '$classname':\n$@")
                unless ($args{softfail_use});
    }
    return 0;
}

sub createObject    # classname, %args
# create an object of any arbitrary class.
{
    my ($classname, %args) = @_;

	$classname =~ s/[^A-Za-z0-9_:]//g;

	my $rv = { };
    
    unless ($args{no_use})
    {
		loadClass($classname, %args);
    }

    my $perl = '$rv = new ' . $classname . '();';
    eval $perl;

	## OTHER METHOD: 
	#############################################3
	#	eval {
	#		bless ($rv, $classname);
	#	};
	if ($@)
	{
		die("createObject: could not create class '$classname': $@");
	} 

    if ($args{force_init} || $args{init_args})
    {
        my $ia = $args{init_args} || { force_init => 1 };
        $rv->init(%$ia);
    }
    return $rv;
}

sub uniquifyList # ($listref) return $listref
{
	my ($list) = @_;

	my %temp;
	foreach my $foo (@$list)
	{
		$temp{$foo} = 1;
	} 
	my @rv = keys (%temp);
	return \@rv;
}

sub easydate
{
	my ($when) = $_[0] || time();
	my @lt = localtime($when);
	return sprintf("%4d-%02d-%02d", 1900+$lt[5], 1+$lt[4], $lt[3]);
}

sub easytime
{
	my ($when) = $_[0] || time();
	my @lt = localtime($when);
	return sprintf("%02d:%02d:%02d", $lt[2], $lt[1], $lt[0]);
}

sub easyfulltime
{
	my ($when) = $_[0] || time();
	my @lt = localtime($when);
	return sprintf("%4d-%02d-%02d %02d:%02d:%02d", 
        1900+$lt[5], 1+$lt[4], $lt[3], $lt[2], $lt[1], $lt[0]
    );
}

sub sendMail
{
	my (%args) = @_;

	my $to = requireArg(\%args, 'to');
	requireAny(\%args, [ qw(text textref filename) ]);

	my $fh = new FileHandle("|/usr/sbin/sendmail -t");
	if (! $fh)
	{
		die("cannot invoke sendmail: $!");
    }
    
	print $fh "To: $to\n";
	print $fh "Cc: $args{cc}\n" if ($args{cc});
	print $fh "Bcc: $args{bcc}\n" if ($args{bcc});
	print $fh "Subject: $args{subject}\n" if ($args{subject});
	print $fh "\n" if ($args{noheaders});

	if ($args{text})
	{
		print $fh $args{text};
	} elsif ($args{textref}) {
		my $tr = $args{textref};
		print $fh $$tr;
	} elsif ($args{filename}) {
           if (! -f $args{filename})
           {
               die("cannot open input file $args{filename}: $!");
           } else {
               my $infile = new FileHandle($args{filename});
               while (my $line = <$infile>)
               {
                   print $fh $line;
               }
               $infile->close();
           }
    } 
	$fh->close();
	return 0;
}

sub validEmail
{
	my ($addr) = @_;

	my ($un, $dom, $shit) = split(/@/, $addr);
	return 0 if ($shit);
	return 0 if (!$dom);
	return 0 if (!$un);

	return 0 if ( $dom =~ m/[\s!'";:\|\\]/);
	return 0 if ( $un =~ m/[\s!'";:\|\\]/);

	return 0 if ( $dom !~ m/^[a-z0-9_\.-]+\.[a-z0-9]+$/);
	return 1;
}

sub max
{
	my ($a, $b) = @_;
	return ($a>$b) ? $a : $b;
}

sub min
{
	my ($a, $b) = @_;
	return ($a<$b) ? $a : $b;
}

sub assembleDate
{
	my ($y, $m, $d) = @_;

	my @mlengths = (0, 
		31, 28, 31, 	30, 31, 30,
		31, 31,	30,		31, 30, 31 
	);

	$m = 1 if ($m<1);
	$m = 12 if ($m>12);

	my $maxday = $mlengths[$m];
	if ($m==2)
	{
		if ($y % 4 != 0)
		{
			# NOP.
		} elsif ($y % 400 == 0) {
			$maxday++;	# div by 400 = leapyear.
		} elsif ($y %100 == 0) {
			# NOP.	
		} else {
			$maxday++;	# div by 4 = leapyear.
		} 
	} 

	$d=1 if ($d<1);
	$d=$maxday if ($d>$maxday);
	
	return sprintf("%04d-%02d-%02d", $y, $m, $d);
}

our $DID_WEBHEAD = 0;

sub _prvwebprint # Guts of webhead/webprint/webdump.  
# Prints stuff to App or STDOUT.
{
    my ($txt, %args) = @_;

    $txt = escapeHTML($txt) if ($args{escape});

    eval {
        my $app = Baldrick::App::getAppObject();
        if ($app)
        {
            $app->doPrint($txt); 
            return 0;
        } 
    }; 
    if ($@)
    {
        # just print the old-fashioned way if $app couldn't do it.
	    print $txt;
    }
    return 0;
}

sub webhead # ( )   FOR DEBUGGING NOT FOR PRODUCTION.
# TODO: integrate better with Dogsbody::doHeader() 
{
	my (%args) = @_;

    return 0 if ($DID_WEBHEAD);

    my $txt = "Content-type: " . ($args{ctype} || "text/html"); 
    _prvwebprint("$txt\n\n", %args);
    $DID_WEBHEAD = 1;
}

sub webprint # (text) FOR DEBUGGING NOT FOR PRODUCTION
{
    my ($txt, %args) = @_;
    webhead(%args);
    return _prvwebprint($txt, %args);
}

sub webdump
# A dumper for debugging, perhaps before headers have been printed.
# Not for production use.
{
	my ($obj, %args) = @_;	

	webhead();
    my @caller = caller(1);

    my $depth = $Data::Dumper::Maxdepth;
    if ($args{shallow})
    {
        $Data::Dumper::Maxdepth = 1;
    } 

    $Data::Dumper::Useqq  = 1;
	foreach my $w ( ($obj) )
	{
        my $type = ("".ref( $w )) || 'object';
        my $ord = ++ $WEBDUMP_ORDINAL;
        my $output = qq#<div class="webdump_head"><a onClick="javascript:var foo=document.getElementById('webdump$ord');foo.style.display=foo.style.display ? '' : 'none';">$type</a> dumped from $caller[3]() $caller[2]</div>\n#;
        $output .= qq#<div id="webdump$ord" class="webdump_body">#;
        $output .= "<pre>" . Dumper($w) . "</pre>\n";
        $output .= qq#</div>#;

        if (my $hl = $args{hl})
        {
            $output =~ s#([^\n]+$hl[^\n]+)#<b><font size="+1">$1</font></b>#g;
        } 
        _prvwebprint($output, %args);
        # $Data::Dumper::Purity = 1;
	}

    $Data::Dumper::Maxdepth = $depth;
}

sub seekTruth
{
    my ($what) = @_;
    		
	return 0 if ($what eq '');
	return 0 if ($what eq '0');
	return 1 if ($what > 0);
	
	$what =~ tr/A-Z/a-z/;	
	return 0 if (($what eq 'false') || ($what eq 'no')  || ($what eq 'off'));
	return 1 if (($what eq 'true')  || ($what eq 'yes') || ($what eq 'on'));
	
    return 0;
}

sub parseOptionList # ( "a:123 b:456") returns hashref {a=>123, b=>456...}
{
    my ($in, %args) = @_;

    my %out;
    my @F = split(/\s+/, $in);
    foreach my $foo (@F)
    {
        my $x = index($foo, ':');
        if ($x>0)
        {
            $out{ substr($foo, 0, $x) } = substr($foo, $x+1);
        } else {
            $out{$foo} = $args{defaultvalue} || 'DEFAULT';
        }
    } 
 
    return \%out;
}

sub wordsplit
{
    my ($text, $max) = @_;
    my @out;
    my $line = '';

    foreach my $word (split (/[\s\t\r\n]+/, $text))
    {
        my $len = length($line);
        my $wordlen = length($word);
        if ($wordlen > $max)
        {
            $word = substr($word, 0, $max); # throw rest of it away.
            $wordlen = length($word);
        }

        if ($len + $wordlen + 1 <= $max)
        {
            $line .= " " if ($line);
            $line .= $word;
        } else {
            push (@out, $line) if ($line);
            $line = $word;
        }
    } # end foreach
    push (@out, $line) if ($line);
    return @out;
}


sub replaceDateWords    # (string, %options)
# options:
# time => time() [or current time]
# localtime => \@localtime [or localtime from time above]
# prefix => .., suffix => .. -- pfx/sfx in format string, will be replaced
{
    my ($instr, %args) = @_;

    my @lt;
    if (my $xx = $args{localtime})
    {
        @lt = @$xx;
    } else {
        my $basetime = $args{time} || time();
        @lt = localtime( $basetime );
    }

    my @subst = (
        # WARNING: MUST EVALUATE IN A PARTICULAR ORDER... 
        # LONG LABELS FIRST!
        # today=07-09-29 longdate=2007-09-29 shortdate=070929 date=20070929
        # time=15:31:22 shorttime = 153122 shortyear=07
        TODAY     => sprintf("%02d-%02d-%02d", 1900+$lt[5], 1+$lt[4], $lt[3]), 
        LONGDATE  => sprintf("%04d-%02d-%02d", 1900+$lt[5], 1+$lt[4], $lt[3]), 
        SHORTDATE => sprintf("%02d%02d%02d",   1900+$lt[5], 1+$lt[4], $lt[3]), 
        SHORTTIME => sprintf("%02d%02d%02d",   $lt[2], $lt[1], $lt[0]),
        SHORTYEAR => sprintf("%02d", ($lt[5] % 100) ),
             
        # SHORT LABELS AFTER.
        DATE    => sprintf("%04d%02d%02d", 1900+$lt[5], 1+$lt[4], $lt[3]), 
        TIME    => sprintf("%02d:%02d:%02d", $lt[2], $lt[1], $lt[0]), 
        HOUR    => sprintf("%02d", $lt[2]),
        MINUTE  => sprintf("%02d", $lt[1]),
        SECOND  => sprintf("%02d", $lt[0]),
        DAY     => sprintf("%02d", $lt[3]),
        MONTH   => sprintf("%02d", 1 + $lt[4]),
        YEAR    => sprintf("%04d", 1900 + $lt[5]),
    );

    for (my $i=0; $i<=$#subst; $i+=2)
    {
        my $k = $subst[$i];
        my $v = $subst[$i+1];

        my $fred = $args{prefix} . $k . $args{suffix};
        $instr =~ s/$fred/$v/;
    } 
    return $instr;
}

sub round
{
    my ($num, $precision) = @_;

    return int($num+0.5) if ( $precision < 1);  

    my $fmt = "%." . int($precision) . "f";
    return sprintf($fmt, $num);

    ## NOTREACHED.
    my $mult = 1;
    while ($precision>0)
    {
        $mult=$mult*10;
        $precision--;
    }  

    $num = ($mult * $num) + 0.5;
    return (int($num) / $mult);
}

our %timeUnits = (
    s => 1, sec => 1, second => 1, 
    m => 60, min => 60, minute => 60,
    h => 3600, hr => 3600, hour => 3600,
    d => 86400, day => 86400,
    w => 604800, wk => 604800, week => 604800,
    microfortnight => 1.2096,
    millifortnight => 1209.6,
    fortnight => 1209600, 
    mon => 2592000, month => 2492000
);

sub parseTimeSpan   # (str) return seconds
# parseTimeSpan: convert times like "4hr", "3d", "75s" to seconds.
{
    my ($str) = @_;

    return 0 if (!$str);

    if ($str =~ m/\s*^(\d+)\s*([a-z]*)\s*$/i)
    {
        my $number = $1;
        my $unit = $2;
   
        return $number if (!$unit);
 
        if ($timeUnits{$unit})
        {
            return $number * $timeUnits{$unit};
        } elsif ($timeUnits{$unit . 's'}) {
            return $number * $timeUnits{$unit . 's'};
        } else {
            die("cannot parse time string '$str': unknown unit '$unit'");
        } 
    } else {
        die("cannot parse time string '$str'");
    }
}

sub cloneObject
{
    my ($obj) = @_;

    my $what = ref($obj);

    if (! $what)
    {
        return $obj;
    } elsif ($what eq 'ARRAY') {
        my @rv;
        foreach my $x (@$obj)
        {
            push (@rv, ref($x) ? cloneObject($x) : $x );
        }
        return \@rv;
    } elsif ($what eq 'HASH') {
        # FALL THRU.
    } elsif ($obj->isa('FileHandle')) {
        # for filehandles, were merely copy it rather than clone it.
        return $obj; 
    } ## else it's a blessed object.

    # now it is either a blessed or unblessed hash.
    my %rv;
    foreach my $k (keys %$obj)
    {
        my $v = $obj->{$k};
        $rv{$k} = ref($v) ? cloneObject($v) : $v;
    } 

    if ($what ne 'HASH')
    {
        bless(\%rv, $what);
    } 
    return \%rv;
}

sub randomiseList   # returns new list in random order.  Doesn't change original.
{
    my ($list) = @_;

    my %temp;
    
    foreach my $e (@$list)
    {
        my $pos;
        do {
            $pos = rand();
        } while (defined ($temp{$pos})); 
        $temp{$pos} = $e;
    } 
    my @outkeys = sort(keys %temp);
    my @outlist = map { $temp{$_} } @outkeys;
    return \@outlist;
}

sub loadConfigFile
{
    my ($fn, %args) = @_;
 
    my $parserOpts = $args{parserOpts} || {
        -UseApacheInclude => 1,
        -IncludeRelative => 1,
        -BackslashEscape => 1,
        -SplitPolicy => 'equalsign', 
        -CComments => 0, 
    };
    $parserOpts->{'-ConfigPath'} ||= $args{config_path} || 'etc';

    my $cfg = new Config::General(%$parserOpts, -ConfigFile => $fn);
    # my $all = $cfg->getall(); ??not useful

    return $cfg if ($args{want_object});
    return $cfg->{config};
}

sub applyStringTransforms # ( $string , "transform1; transform2; ...")
# Given a semicolon-separated list of string operations, apply each in 
# sequence to the input string.  
#   Operations are: downcase upcase ltrim rtrim trim nospaces underspaces datesub
{
    my ($instr, $transforms, %args) = @_;

    my $outstr = $instr;
    foreach my $op (split(/\s*;\s*/, $transforms))
    {
        # manipulate case
        if ($op eq 'downcase')
        {
            $outstr =~ tr/A-Z/a-z/;
        } elsif ($op eq 'upcase') {
            $outstr =~ tr/a-z/A-Z/;

        # manipulate space
        } elsif ($op eq 'ltrim') {
            $outstr =~ s/^[\s\t]+//;
        } elsif ($op eq 'rtrim') {
            $outstr =~ s/[\s\t]+$//;
        } elsif ($op eq 'trim') {
            $outstr =~ s/^[\s\t]+//;
            $outstr =~ s/[\s\t]+$//;
        } elsif ($op eq 'nospaces') {
            $outstr =~ s/[\s\t]+//g;
        } elsif ($op eq 'underspaces') {
            $outstr =~ s/[\s\t]/_/g;
    
        # misc
        } elsif ($op eq 'datesub') {
            $outstr = replaceDateWords($outstr, %args);
        } else {
            print STDERR "Unrecognized applyStringTransforms() op: $op";
        } 
    } 
    return $outstr;
}

sub escapeURL
{
    my ($text) = @_;
    # $text =~ s/\+/%2b/g; $text =~ s/\s/+/g;
    
    $text =~ s/([^A-Za-z0-9-_])/sprintf("%%%02X", ord($1))/seg;
    return $text;
}

sub escapeHTML
{
    my ($text) = @_;
    $text =~ s/&/&amp;/g;   # MUST BE FIRST.

    $text =~ s/"/&quot;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    return $text;
}

1;
