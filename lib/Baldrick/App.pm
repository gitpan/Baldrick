# 
# Baldrick::App is the main entry point to the Baldrick library.
# It loads the config file, loads and manages persistent objects
# (Baldrick::Database, Baldrick::UserLoader), and maps incoming 
# requests to the appropriate Module (request handler).
#
# v0.1 2005/04 began.
# v0.2 2005/07 split App from Request; added database management
# v0.3 2005/10 some reorganising and debugging...
# v0.5 2006/06 user loaders; new multi-module architecure. (MAJOR REV.)
# v0.70 2007/08 moved template init to dogsbody
# v0.72 2007/08 moved dogsbody init to DungGatherer, added sendToModule

package Baldrick::App;

use Data::Dumper;
use Baldrick::Util;
use FileHandle;
use Getopt::Long;
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(getcwd);

use strict;

our @ISA = qw(Baldrick::Turnip);

our $DEFAULT_TARGET = "_INTERNAL_:no-module-defined-error";

our %globalappstats;	# count opens/closes.
our $startupOptions = {
    savedinputs => '',
    config => '', 
    configpath => 'etc',    # directory to look for other configs in
};
our %texts = (
    baf => 'Baldrick Application Framework',
    err_start => 'FATAL STARTUP ERROR'
);

our %_APP_OBJECTS;  # map of PID to Object (currently only ever has one)

sub _globalInit
{
	$|=1;	# flush IO right away.

	$Data::Dumper::Maxdepth = 3;
	$Data::Dumper::Sortkeys = 1;

    my $status = GetOptions (
        # "foo=i" => \$foo,    # numeric
        "savedinputs=s"   => \$startupOptions->{savedinputs},
        "config=s"   => \$startupOptions->{config},
        "configpath=s"   => \$startupOptions->{configpath},
    );
   
    return 0;
}

sub new	## ( %args )
{
    _globalInit();

    return Baldrick::Turnip::new(@_, force_init => 1);
}

sub toString
{
    my ($self) = @_;
    my $now = [ Time::HiRes::gettimeofday() ];
    my $age = $self->{_createtime} ? 
        Time::HiRes::tv_interval($self->{_createtime}, $now) : 'UNKNOWN';

    return sprintf('%s [addr=%p handled=%d max=%d age=%.2fms %s] ' . POSIX::getcwd() , 
        ref($self), $self, $self->{_requestsHandled}, 
        $self->{_maxrequests}, $age*1000, $self->{_servername},
    );
}

sub init # () 
# called by constructor, creates various resource objects - databases, userloaders
{
	my ($self, %args) = @_;

    $self->setState('startup');

    $self->{_times} = [ ];
    $self->{_createtime} ||= $args{createtime} || [ Time::HiRes::gettimeofday() ];
    $self->{_startupdir} ||= POSIX::getcwd();

    setAppObject($self);

    $self->SUPER::init(%args,
        copyDefaults => { 
            configfile => $startupOptions->{config} || $ENV{BALDRICK_CONFIG_FILE} || 'baldrick.cfg', 
            servername => $ENV{SERVER_NAME},    # might change later under mod_perl
            maxrequests => 1,       # this is used only for the run() entry point!
            workdir => $ENV{BALDRICK_WORKDIR} || $self->{_startupdir}, 
            mode => 'cgi'
        }
    );

    $self->{_requestsHandled} = 0;			# count of requests handled (won't exceed 1 for now)
    $self->{_databases} = { };				# map of label => dbhandle
	$self->{_userLoaders} = { };			# user loader objects (classname => object).
    $self->{_handlerFactories} = { };       # request handler factories.
    $self->{_prog} 			= $0;			# program name for error msgs
	$self->{_prog}          =~ s#.*/##;	# basename.
    $self->{_currentRequest} = 0;

    $self->setConfigRoot( {} ); # so errorPage doesn't choke if config load fails.

    eval {
        $self->cdWork();

        $self->setState('load-config');
	    my $config = loadConfigFile(
            $self->{_configfile}, 
            config_path => $ENV{BALDRICK_CONFIG_PATH} || $startupOptions->{configpath}, 
            want_object => 1
        );

	    $self->{_config_object} = $config;  
        $self->setConfigRoot( $config->{config} );
        $self->{_admin_email} = $self->getConfig("site-admin-email", section => 'Baldrick');

        $self->setState('config-loaded');
    	$self->_initRandom();

    	# initialisation successful.
        $self->setState('initialised');
        $self->cdStartup();
    }; 
    if ($@)
    { 
        $self->errorPage($@, 
            headline => "<h1>Baldrick::App::init() ERROR:</h1>\n",
        );

        if (my $em = $self->{_admin_email} )
        {
            $self->_errorNotify(
                email => $em,  
                subject => "$self->{_servername} - $self->{_prog} - $texts{fse}", 
                text => "$texts{baf} - $texts{fse}\n$@\n\n"
		    );
        }
        print STDERR $@;
        exit (-1);
    } 
    return $self;
}

sub cdWork  # cd to working directory $self->{_workdir}
{
    my ($self) = @_;
    if (my $dir = $self->{_workdir})
    {
        chdir($dir) || $self->abort("cannot chdir() to '$dir': $!");
    }
    return 0;
}

sub cdStartup   # cd to whatever dir we were in on startup.
{
    my ($self) = @_;
    if (my $dir = $self->{_startupdir})
    {
        chdir($dir) || $self->abort("cannot chdir() to '$dir': $!");
    }
    return 0;
}

sub pushTime
{
    my ($self, $label) = @_;
    my $times = $self->{_times};
    push (@$times, { 
        label => $label, 
        now => [ Time::HiRes::gettimeofday ] 
    } );
}

sub setState
{
    my ($self, $label) = @_;

    $self->pushTime($label);
    $self->{_state} = $label;
}

sub cleanupResources
{
    my ($self) = @_;

	if (my $loaders = $self->{_userLoaders})
    {
        foreach my $ul (keys %$loaders)
        {
            next unless ($loaders->{$ul});
            $loaders->{$ul}->finish(); 
            delete $loaders->{$ul};
        } 
    } 

	# CLOSE DATABASES.
	my $dbs = $self->{_databases};
	my @dblist = keys (%$dbs);
	foreach my $dname (@dblist)
	{
		$self->closeDatabase($dname) if ($dbs->{$dname});
	}

	################################################
}

sub finish # ()
# Free up resources.  Doesn't terminate the program.
{
	my ($self) = @_;
	return if ($self->isFinished());

    $self->cleanupResources();

    discardAppObject();

    $self->{_printer} = 0;
    $self->{_finished} = 1;
    $self->setState('finished');

    delete $self->{_userLoaders};
    delete $self->{_databases};    

    my $timelog = $self->getConfig('timelog', section => 'Baldrick');
    $self->doTimeLog($timelog) if ($timelog);
}

sub doPrint
{
    my ($self, $msg) = @_;
    if ($self->{_printer})
    {
        $self->{_printer}->print($msg);
    } else {
        print $msg;
    }
    return 0;
}

sub doTimeLog
{
    my ($self, $logfile) = @_;

    return 0 if (!$logfile);

    my $times = $self->{_times};
    my $outstr = '';

    for (my $i=0; $i<$#$times; $i++)
    {
        my $elapsed = Time::HiRes::tv_interval(
            $times->[$i]->{now}, 
            $times->[$i+1]->{now});
        $outstr .= sprintf("%s:%.2f ", $times->[$i]->{label},
            1000*$elapsed);
    }

    my $total = Time::HiRes::tv_interval(
        $times->[0]->{now},
        $times->[$#$times]->{now}
    );
    $outstr .= sprintf("%s:%.2f ", 'total', 1000*$total);  

    if (my $fh = new FileHandle(">>$logfile"))
    {
        print $fh "$self->{_prog} $outstr\n";
        $fh->close();
    }
    return 0;
}

### REQUEST HANDLING ###################################################################

sub canDoMoreRequests
{
    my ($self) = @_;

    # if maxrequests > 0, check to see if we're about to exceed it.
    if (my $mr = $self->{_maxrequests})
    {
        return 0 if ( ($mr>0) && 
            ($self->{_requestsHandled} >= $mr));
    } 
    return 1;
}

sub getNextRequest # (%args) return Baldrick::Request
# Read one HTTP request and return a Baldrick::Request object.  
# 'args' passed to Request constructor as-is.
#   args: apachereq, mode 
{
	my ($self, %args) = @_;

    return 0 unless ($self->canDoMoreRequests());

	my $req = new Baldrick::Request(%args, force_init => 1);
   
    if (my $fn = $startupOptions->{savedinputs})
    {
        $req->loadFromFile($fn);
        $startupOptions->{savedinputs} = '';
    } else {
   	    $req->load();
    } 

    $self->{_currentRequest} = $req;
    return $req;
}

sub run # (%args).
# %args passed to handleRequest as-is.
# main entry point, implementing the request-handling loop.
# This is a simple wrapper for handleRequest().
{
	my ($self, %args) = @_;

	my $count=0;
    $self->setState('getrequest');
    while (my $req = $self->getNextRequest())
	{
		$self->handleRequest($req, %args);
		$self->finishRequest($req);
		++$count;
        $Baldrick::Util::DID_WEBHEAD = 0;
	} 
	return $count;
}

sub getModuleTarget # ( $request )
# uses global: $DEFAULT_TARGET ("_INTERNAL_:no-module-defined-error")
{
	my ($self, $request) = @_;

	# load PathMap config section.
	# 	/full-url => module-name
	#	url-end => module-name

	my $map = $self->getConfig("PathMap");
	return $DEFAULT_TARGET if (!$map);

	my @paths = (
		$request->getPath(full => 1), 
		$request->getPath()
	);

	foreach my $path (@paths)
	{
		my $basename = $path;
		$basename =~ s#.*/##;

		# First pass: exact match.
		foreach my $k (keys %$map)
		{
			return $map->{$k} if ($path eq $k);
			return $map->{$k} if ($basename eq $k);
		} 

		# second pass: match suffix
		foreach my $k (keys %$map)
		{
			my $k2=$k;
			$k2 =~ s#.*/##;
			return $map->{$k} if ($path eq $k2);
		} 
	}

	# failure: return a default if defined in file...
	return $map->{'default'} if ($map->{'default'});

	# else return default default.
	return $DEFAULT_TARGET;
} 

sub getModuleDefinition # ($modulename) return hashref.
# Get the config file section "Module/<modulename>", or a default.
{
	my ($self, $modulename, %args) = @_;

	my $rv = $self->getConfig("Module/$modulename");
	if (!$rv)
	{
        my $err = "Module '$modulename' is not defined.";
		if ($modulename eq '_INTERNAL_')
		{
			return ({});	# defaults for each line within will suffice.
		} elsif ($args{softfail}) {
			$self->setError($err);
            return 0;
        } else {
			$self->abort($err);
		}
	} 
    
    if ($rv->{inherit})
    {
        $self->abort("Too many levels of inheritance for $modulename - possible loop?")
            if ($args{nesting} > 99);

        my $basemodule = $self->getModuleDefinition($rv->{inherit}, 
            nesting => 1+$args{nesting});
        foreach my $k (keys %$basemodule)
        {   
            next if (defined ($rv->{$k}) );
            $rv->{$k} = $basemodule->{$k};
        } 
    } 
	return $rv;
}

sub _setupModuleInfo
{
    my ($self, %args) = @_;

    my $req = $args{request} || die();

    my $moduleInfo = {
        STEP => 'find target'
    };

    # Load user agent section which may override module name and other parms.
    my $uaSection = $self->_loadUserAgentSection( $req );
    if ($args{module})
    {
        $moduleInfo->{module} = $args{module};
        $moduleInfo->{command} = $args{command};
    } else {
        my $target;
        if ($uaSection && defined($uaSection->{module}))
        {
            $target = $uaSection->{module};
        } else {
            $target = $self->getModuleTarget( $req );
        } 

        # split at ':' if present; take second half of target as command name.
        if ((my $pos = index($target, ':')) > -1)
        {
            $moduleInfo->{module} = substr($target, 0, $pos );        
            $moduleInfo->{command} = substr($target, $pos + 1 );        
        } else {
            $moduleInfo->{module} = $target;
        } 
    }

	# Get module definition (config file <Module XYZ>...</Module> section).
	# This is required for any module name but _INTERNAL_.
    $moduleInfo->{STEP} = 'load module definition';
	if (my $moddef = $self->getModuleDefinition( $moduleInfo->{module} ))
    {
        if ($uaSection)
        {
            my %foo = %$moddef; # clone it.
            map { $foo{$_} = $uaSection->{$_} } (keys %$uaSection);
            $moduleInfo->{definition} = \%foo;
        } else {
            $moduleInfo->{definition} = $moddef;
        } 
    } else {
        die("cannot load definition for module " . $moduleInfo->{module});
    } 

    return $moduleInfo; 
}

sub getHandlerFactory
{
    my ($self, %args) = @_;

    my $moduleInfo = $args{moduleInfo} || { };
    my $classname = $args{classname} || $moduleInfo->{"handler-factory"} || 'Baldrick::DungGatherer', 
    my $poolname  = $moduleInfo->{'handler-factory-pool-name'} || $args{classname};

    my $allpools = $self->{_handlerFactories};
    $allpools->{ $poolname } ||= { };

    my $pool = $allpools->{ $poolname };

    # find one that's not in use.
    # FIXME: this is very simple and stupid right now!
    foreach my $k (keys %$pool)
    {
        my $factory = $pool->{$k};
        unless ($factory->{active})
        {
            $factory->{active} = 1;     
            return $factory;
        } 
    } 

    # None found!  Create one...

    my $factory = dynamicNew($classname);
    $factory->init(framework => $self, moduleInfo => $moduleInfo);
    $factory->{active} = 1; # prevent race condition - don't put in pool right away.
    $pool->{ "".$factory."-$$" } = $factory;

    return $factory;
}

sub sendToModule # (parent => dogsbody, module => 'module name', [command => 'command'] )
{
    my ($self, %args) = @_;

    my $module = requireArg(\%args, 'module');  # new handler's name.
    my $parent = requireArg(\%args, 'parentHandler');  # original handler.

    my $request = $parent->getRequest();
    if (++$request->{_RETARGETED} > 20)
    {
        return $parent->abort("sendToModule($module): too many internal redirects - possible loop.");
    } 

    return $self->handleRequest($request, 
        parentHandler => $parent, 
        module => $module, command => $args{command},
        session => $parent->getSession(), 
    ); 
}

sub handleRequest
{
	my ($self, $request, %args) = @_;

    $self->setState('servicing');
    $self->cdWork();
    my $factory = 0;
	my $dogsbody = 0;
	my $moduleInfo = 0;

	eval {
        $moduleInfo = $self->_setupModuleInfo(request => $request, %args);
        $moduleInfo->{parentHandler} = $args{parentHandler} if (defined ($args{parentHandler}));

        $factory = $self->getHandlerFactory( 
            moduleinfo => $moduleInfo
        );

        ##### PER_REQUEST STUFF HERE ####
        # start request; create session, userloader...
        $factory->startRequest(
            moduleinfo => $moduleInfo, 
            framework => $self, 
            request => $request, 
            %args   # may include session/userloader objects to reuse.
        );

        $moduleInfo->{STEP} = "initialising handler";

		$dogsbody = $factory->createHandler(framework => $self);
        delete $moduleInfo->{STEP};
	};
	if ($@)
	{
		my $errors = $@;
        my $savedFile = $request->saveInputs(fileprefix => 
            $moduleInfo->{definition}->{"input-save-path"} || "/tmp/$moduleInfo->{module}."
        );
 
        $self->_errorNotify(
            email => $moduleInfo->{definition}->{errornotify}, 
            subject => "Initialisation error in app $moduleInfo->{module}", 
            text => "Baldrick Application Framework cannot load module $moduleInfo->{module}\n\n" .
                "$errors\n\noccurred in phase: $moduleInfo->{STEP}\n" .
                ($savedFile ? "\nInputs saved as $savedFile " : "")
		);
        $errors =~ s/\n/<br>\n/g;
		return ( $self->abort("$moduleInfo->{STEP}: $errors", 
            request => $request, 
            headline => "$self->{_servername} MODULE INITIALISATION ERROR")
        );
	} 

    # The rest of this is outside the eval() because the dogsbody's own error handler is 
    # assumed to be working correctly.
	$dogsbody->run();
	$dogsbody->finish();
    $factory->finishRequest($dogsbody);

    $self->{_requestsHandled}++ unless ($args{parentHandler});
    $self->cdStartup();
    return 0;
}

sub _errorNotify
{
    my ($self, %args) = @_;
    my $to = $args{email} || return -1;
    my $now = easyfulltime();

    eval {
	    Baldrick::Util::sendMail(
            to => $to, 
            subject => $args{subject},
            text => $args{text} . "\nHost $ENV{SERVER_NAME} at time $now\n\n"
        );
    };
}

sub finishRequest # ($req)
{
	my ($self, $req) = @_;
	
    $self->setState('didrequest');
	$req->finish( fromapp => 1 );

	## If we aren't capable of handling multiple requests, then bypass some of the 
	## cleanup - it isn't necessary and wastes time.  

    # ...cleanup?
#    my $shouldCleanup = !$self->canDoMoreRequests();
#    if ($shouldCleanup)
#    {
        $self->cleanupResources();
#    } 
	
	return 0;
}

# DATABASES #####################################################################################

sub openDatabase # ( $label, [%opts] ) return Baldrick::Database
# Open a labeled database from <Databases> section of config file, and store in 
# hashref _databases  {name => dbh} for later retrieval
# opt	config => $config-hash	-- use alternate config section.
{
	my ($self, $name, %args) = @_;

    my $section = $self->getConfig($name, section => 'Database');
    if (!$section || ! ref($section) )
    {
        $self->setError("No config section for Database '$name'",
            fatal => !$args{softfail}
        );
        return 0;
    } 
	
	my $db = new Baldrick::Database( config => $section, name => $name );
	$db->open();
	
	$self->{_databases}->{$name} = $db;
	$globalappstats{database_open}++;
	
	return $db;
}

sub getDatabase
{
	my ($self, $label) = @_;
	my $dbs = $self->{_databases};

	if ( defined($dbs->{$label}) ) 
    {
        if (my $thisdb = $dbs->{$label})
        {
            if ($thisdb->isFresh())
            {
                return $thisdb;
            } else {
                $thisdb->close();
                delete $dbs->{$label};
            }
        } 
	} 
	return $self->openDatabase($label);
	
}

sub closeDatabase # ( $label )
{
	my ($self, $label ) = @_;
	my $dbs = $self->{_databases};
	if (defined $dbs->{$label})
	{
		my $db = $dbs->{$label};
		if ($db)
		{
			$db->close();
			$globalappstats{database_close}++;	
		}
		delete $dbs->{$label};
	} else {
		$self->setError ("WARNING: database '$label' is undefined; doing nothing.");
	}
	return 0;
}

#### USER LOADERS. ################################################################

sub getUserLoader # ( $classname ) return listref
{
	my ($self, $classname) = @_;

	return 0 if ($classname eq 'none');

	$classname ||= 'default';

	my $loaders = $self->{_userLoaders};
	if (! $loaders->{$classname})
	{
		$loaders->{$classname} = $self->_initUserLoader($classname);
	}
	return $loaders->{$classname};
}

sub _initUserLoader # ($userclass) # return loader object.
# create a Baldrick::UserLoader (or similar) object 
{
	my ($self, $userclass) = @_;

	my $config = $self->getConfig("UserClass/$userclass", required => 1);

	my $loaderclass = $self->getConfig("user-loader-class", 
		defaultvalue => 'Baldrick::DBUserLoader', 
		config => $config
	);
	
	return 0 if ($loaderclass eq 'none');

	### Now dynamicly create the class.
	my $loader= dynamicNew($loaderclass);

	$loader->init( userclass => $userclass, app => $self, 
		config => $self->getConfigRoot() 
	);
	return $loader;
}

sub errorPage
{
	my ($self, $msg, %args) = @_;

	$args{headline} ||= 'error';
    $args{headline} =~ tr/a-z/A-Z/;

    if ($args{request})
    {
	    $args{request}->doHeader();
    } else {
        webhead();
    }

  	$msg =~ s/: /: <br>&nbsp; &nbsp; /g;

	print qq|<html><head><title>$args{headline}</title></head>\n|;
	print qq|<body>\n|;
	print qq|<h2 align="center" style="color:#800000">$args{headline}</h2>|;

	print qq|<div style="margin: auto; width: 80%; border: 6px solid #a00000; min-height:200px; padding:20px; font-size:90%;" valign="middle">\n|;
	print qq|$msg\n|;
	print qq|</div>\n|;

	print qq|<p align="center"><a style="text-decoration:none; color: #800000; font-weight: bold" 
		href="javascript:history.go(-1)">GO BACK</a></p>|;
	print qq|</body></html>\n|;
    return 0;
}

sub abort # ($msg, %opts)
{
	my ($self, $msg, %args) = @_;

	chomp($msg);
    $self->errorPage($msg, %args);

	my $fullmsg = sprintf("%s FATAL ERROR: %s\n", $self->{_prog}, $msg);

	$args{uplevel}++;
	$self->setError($fullmsg, %args);	

	$self->finish();	# close database & other resources.
	exit(1);
}

sub _initRandom
# Seed the random number generator based upon remote addr, PID, time of day, and previous value.
{
    my ($self, %args) = @_;

    my $method = $args{method} || $self->getConfig('random-seed-method', 
        section => 'Baldrick', 
        defaultvalue => 'urandom'
    );

    my $seed = undef;

    if ($method eq 'timeofday')
    {
        my ($sec, $usec) = Time::HiRes::gettimeofday();
        $seed = ($usec << 16) ^ $sec;
    } elsif ($method eq 'pid-time') {
        my ($sec, $usec) = Time::HiRes::gettimeofday();
        $seed = $$ ^ ($usec << 16) ^ $sec;
    } elsif ($method eq 'none') {
        # modern perls do a urandom read on startup; don't need another.
        return 0;
    } elsif ($method eq 'urandom' || $method eq 'dev-random') {
        my $fh = new FileHandle(
            $method eq 'dev-random' ? "/dev/random" : "/dev/urandom"
        );

        my $smeg = "0000";
        sysread($fh, $smeg, 4, 0);
        $fh->close();

        $seed = unpack('L', $smeg);
        # printf ("%08x - %08x %08x\n", $val, rand($val), rand($val));
    } 
#    my $addr = $ENV{REMOTE_ADDR} ?
#        unpack('L', Socket::inet_aton($ENV{REMOTE_ADDR}) ) :
#        2130706433;   # (= 127.0.0.1)

    if (defined($seed))
    {
        srand($seed);
    } else {
        $self->abort("cannot initialise random number generator! please try again in a few seconds.");
    } 
}

sub _loadUserAgentSection
# new 0.7: allow for UserAgent section to override settings from Module sections.
# This is most useful for responding to robot requests or Apache's 
# "internal dummy connection"
{
    my ($self, $req) = @_;

    my $basenode = $self->getConfig('UserAgent') || return 0;

    my $ua = $req->getUserAgent();
    foreach my $sname (sort (keys(%$basenode)))
    {
        my $section = $basenode->{$sname};
        my $pat = $section->{"match-pattern"} || next;
        return $section if ($ua =~ m#$pat#);
    } 
    return 0;   # no match.
}

#################### STATICS #########################################

sub getDebugStats # () STATIC
{
	return ( \%globalappstats );
} 

sub getAppObject # () STATIC
# Intended to be called from other objects that don't have a pointer
# to the App.
{
    my ($id) = @_;

    $id = $$ if (!$id);

    my $rv = $_APP_OBJECTS{$id};
    if ($rv && $rv->isFinished())
    {
        discardAppObject();
        return 0;
    } 
    return $rv;
}

sub discardAppObject
{
    $_APP_OBJECTS{$$} = 0;
}

sub setAppObject
{
    $_APP_OBJECTS{$$} = $_[0];
}

1;
