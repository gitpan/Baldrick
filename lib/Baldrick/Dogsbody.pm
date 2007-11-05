
# Baldrick::Dogsbody - this should be overridden with a class that does the 
# actual work involved in processing a web hit.

# v0.1 2005/10 hucke@cynico.net
# v0.2 2006/06 moved most of new() to init(); cleanup; rename members.
# v0.7 2007/08 new template adapter setup.

package Baldrick::Dogsbody;

use lib '..';
use Data::Dumper;
use Baldrick::Util;

use strict;

our @ISA = qw(Baldrick::Turnip);
our $DUMP_ORDINAL = 1;

sub init # ( %args )
{
	my ($self, %args) = @_;

    eval {
        $self->SUPER::init(%args, 
            copyRequired => [ qw(request app session definition) ],
            copyOptional => [  qw(config command userloader 
                default_cmd default_args cmd_parm 
                errortemplate templatedir cmdAliases
                parentHandler) ],
            copyDefaults => {
                errortemplate => 'error.tt',
                cmdAliases => { },
            }
        ); 
    };
    if ($@)
    {
        die("Dogsbody Initialisation error: $@  (perhaps init() was called without arguments?");
    } 

    if (my $dir = $self->{_definition}->{'working-directory'})
    {
        chdir($dir);
    }

    if (my $lf = $self->{_definition}->{logfile})
    {
        $self->openLog(file => $lf);
    } 

	# this can be set to 1 when processing commands to halt processing 
    # of further commands.
	$self->{_done} = 0;	

	my $app = $self->{_app};		

    my $out = $self->_initTemplateAdapter(app => $app, request => $self->getRequest());

	$self->{_currentUser} = new Baldrick::User();

	# if _command (part after ':' in path config file) begins
	# with '?', allow it to be overridden by user-specified command.
	if ($self->{_command} =~ m/^\?(.*)/)
	{
		my $defcmd = $1;
		my $cmd = $self->getRequest()->getParameter('cmd');
		if ($cmd)
		{
			$self->{_command} = $cmd;
		} else {
			$self->{_command} = $defcmd;
		} 
	} 

	$self->{_validator} = $args{validator} || new Baldrick::InputValidator(
		request => $self->{_request},
        creator => $self
	);
	$out->addObject( $self->{_validator}, "validator");

    ## Output Headers.
    $self->{_responseHeaders} = [ ]; 
   
	return $self;
}

sub _initTemplateAdapter
{
    my ($self, %args) = @_;

    my $app = $args{app} || 0;
    my $req = requireArg(\%args, 'request');

    # find a named TemplateAdapter config section - in our config, or app's config.
    my $adapterName =  $self->getDefinitionItem('template-adapter') || 'default';
    my $cfg = $self->getConfig($adapterName, section => 'TemplateAdapter') || 
        ($app ? $app->getConfig($adapterName, section => 'TemplateAdapter') : 0);

    my $def = $self->getDefinition();
    my $tbase = $def->{'template-base'} ? $def->{'template-base'} 
        : $app ? $app->getConfig('template-base', section => 'Baldrick') 
        : 'templates';

    my $tdir = $self->{_templatedir};
    my $subs = {
        TEMPLATE_BASE => $tbase, 
        MODULE_TEMPLATES => $self->{_templatedir}, 
        DOCUMENT_ROOT => $req->getDocumentRoot(),
        SCRIPT_DIR => $req->getBaseDirectory()
    };

    my $adapter = 0; 
    if ($cfg)
    {
        $adapter = Baldrick::TemplateAdapterBase::factoryCreateObject(
            name => $adapterName, config => $cfg, creator => $self,
            substitutions => $subs,
        );
    } elsif ($app) {
        $adapter = $app->getDefaultTemplateAdapter(creator => $self,
            substitutions => $subs
        );
    } else {
        $adapter = Baldrick::TemplateAdapterBase::factoryCreateObject(
            name => 'default', config => { }, creator => $self,
            substitutions => $subs,
        );
    } 
	$self->{_out} = $adapter;

    $adapter->addObject( $self, "handler");
    $adapter->addObject( $self->getRequest(), "req");
    $adapter->addObject( $self->getRequest()->getContents(), "request");
    $adapter->addObject( $self->getUserLoader(), "userloader");

    my $ssn = $self->getSession();
    $adapter->addObject( $ssn, "sess");
    $adapter->addObject( $ssn->getContents(), "session");

    return $adapter;
}

sub getCommandAliases
{
    return $_[0]->{_cmdAliases};
}

sub addCommandAlias
{
    my ($self, $left, $right) = @_;

    my $ca = $self->getCommandAliases();
    $ca->{$left} = $right;
    return $ca;
}

sub debugDump
{
    my ($self, $what) = @_;
   
    $what =~ tr/a-z/A-Z/;

    foreach my $ch (split (//, $what))
    {
        if ($ch eq 'R')
        {
            $self->sendOutput( dump => $self->getRequest()); 
        } elsif ($ch eq 'C') {
            $self->sendOutput( dump => $self->getRequest()->getContents()); 
        } elsif ($ch eq 'S') {
            $self->sendOutput( dump => $self->getSession());
        }
    }  
}

sub getTemplate
{
	my ($self, $filename, %args) = @_;

    # if full path specified, use it.
    return $filename if ($filename =~ m#^/# && -f $filename);   

	my $out = $self->getOut();
	my $ext = $out->getPreferredSuffix();
    my $paths = $out->getIncludePath();
   
    my @badpaths; 
    foreach my $p (@$paths)
    {
        my $fullpath = "$p/$filename.$ext";
        return $fullpath if (-f $fullpath);
        
        $fullpath = "$p/$filename";
        return $fullpath if (-f $fullpath);

        push (@badpaths, $fullpath);
    } 

    return $filename if (-f $filename);

	$self->setError("no template found matching $filename / $filename.$ext; searched paths "
        . join(";", @badpaths), uplevel => 1);
	return 0;
}


sub finish # ()
{
	my ($self) = @_;
	return 0 if ($self->{_finished});

    # $self->getOut()->finish();    already done in afterRun()
    $self->SUPER::finish();
 	
	foreach my $k qw(_request _app _session _out)
	{
		delete $self->{$k};
	}
	$self->{_finished} = 1;
}

sub DESTROY # ()
{
	my ($self) = @_;
	$self->finish();
}

### ACCESSORS ###
sub getParentHandler    { return $_[0]->{_parentHandler}; }
sub getValidator  	{ return $_[0]->{_validator}; }
sub getCommand    	{ return $_[0]->{_currentCommand}; }
sub getCurrentUser	{ 
	my ($self) = @_;
	if (! $self->{_currentUser})
	{
		$self->{_currentUser} = new Baldrick::User();
	}
	return $self->{_currentUser};
}

sub getDefinition	{ return $_[0]->{_definition}; }
sub getSession		{ return $_[0]->{_session}; }
sub getApp 			{ return $_[0]->{_app}; }
sub getOut 			{ return $_[0]->{_out}; }
sub getRequest 		{ return $_[0]->{_request}; }
sub getUserLoader	{ return $_[0]->{_userloader}; }

sub getDefinitionItem	
{ 
    my ($self, $k) = @_;
    my $defs = $self->getDefinition();
    return $defs->{$k};    
}

sub getDatabase
{
    my ($self) = @_;
    my $dbname = $self->getDefinitionItem('database') || 'main';

    return ($self->getApp()->getDatabase($dbname) );
}

##########

sub doHeader
{
	my ($self, %args) = @_;

    return 0 if ($self->{_didheader});          # already done.

	my $req = $self->getRequest();
    if ($req)
    {
	    $req->doHeader(headerlist => $self->getResponseHeaders(), %args);
        $self->{_didheader} = 1;
        $Baldrick::Util::DID_WEBHEAD = 1;
    } else {
        webhead();
        print "<b>SERIOUS ERROR: Request not defined, Dogsbody incomplete</b>";
    } 
    return 1;
}

sub sendXML
{
	my ($self, %args) = @_;
	if ($args{startxml})
	{
		$self->sendOutput(ctype => 'text/xml',
			text => qq!<?xml version="1.0" encoding="utf-8"?>\n!);
	} else {
		$self->sendOutput(%args, ctype => 'text/xml');
	}
}

sub sendOutput # ( text=>(text) | template=>filename | dump => object | error => message |find_template => basename ) 
#	
{
    my ($self, %args) = @_;

    my $what = requireAny(\%args, 
        [ qw(error text textref dump template find_template) ]
    );

	my $request = $self->{_request};
	$self->doHeader(%args);

    if (my $wt = $args{wraptag})
    {
	    # remember: request->sendOutput() wants a POINTER to the text!
        my $fred = "<$wt>";
		$request->sendOutput( \$fred );
    } 

    if ($what eq 'error')
    {
		$self->{_errortemplate} ||= 'error';
        $self->getOut()->putInternal('errorMessage', $args{$what} || 'unknown error');
        $self->sendOutput(template => $self->{_errortemplate}); 
	} elsif ($what eq 'dump') {
		my @caller = caller();
        my $ord = ++$DUMP_ORDINAL;
        my $type = ("".ref($args{dump})) || 'object';
        my $output = qq#<div class="webdump_head"><a onClick="javascript:var foo=document.getElementById('webdump$ord');foo.style.display=foo.style.display ? '' : 'none';">$type</a> dumped from $caller[0] $caller[2]</div>\n#;
        $output .= qq#<div id="webdump$ord" class="webdump_body">#;
		$output .= "<pre>" . Dumper($args{dump}) . "</pre>\n";
        $output .= qq#</div>#;
		$request->sendOutput(\$output);
	} elsif ($what eq 'text') {
	    # remember: request->sendOutput() wants a POINTER to the text!
		$request->sendOutput( \$args{$what} );
    } elsif ($what eq 'textref') {
		$request->sendOutput( $args{ $what } );
    } elsif ($what eq 'template' || $what eq 'find_template') {
        my $template = $args{$what};

        my $fullpath = $self->getTemplate($template);
        if ($fullpath)
        {
		    my $outref = $self->getOut()->processFile( $fullpath );
    		$request->sendOutput( $outref );
        } else {
            $self->abort("could not find template $template in path", uplevel => 1);
        }
	} else {
        $self->sendOutput(text => 'ERROR: sendOutput() called without valid parameters');   
        return -1;
    } 
    $self->{_didOutput}++;

    if (my $wt = $args{wraptag})
    {
	    # remember: request->sendOutput() wants a POINTER to the text!
        $wt =~ s/\s+.*//;
        my $fred = "</$wt>";
		$request->sendOutput( \$fred );
    } 
    return 0;
}

sub _resolveCommandAlias
{
    my ($self, $cmdArgs) = @_;

    my $ca = $self->getCommandAliases() || return -1;
    my $cmd = $cmdArgs->{cmd};
    if (defined($ca->{$cmd}))
    {
        my $newcmd = $ca->{$cmd};
		if ($newcmd =~ m/^([^:]+):(.*)/)
        {
            $cmdArgs->{cmd} = $1;
            $cmdArgs->{cmdargs} ||= $2;
        } else {
            $cmdArgs->{cmd} = $newcmd;
        } 
    } 
    return 0;
}

sub run # (%args)
# Main entry point.  Will grab list of commands from CGI (usually in 'cmd'
# variable), then call the handler for each.
{
	my ($self, %args) = @_;

	return 0 if ($self->{_done});

	eval {
		my @cmdlist = $self->getCommandList();

        $self->prepareRun(commandlist => \@cmdlist);

		if ($#cmdlist < 0)
		{
			if ($self->{_default_cmd} )
			{
				my %temp = ( 
					cmd => $self->{_default_cmd}, 
					cmdargs => $self->{_default_args},
				);
				push (@cmdlist, \%temp);
			} else {
				return $self->handleDefaultCommand( cmd => 'DEFAULT', args => "" );
			}
		} 
	
        my $def = $self->getDefinition();
		for (my $c=0; ($c<=$#cmdlist) && (! $self->{_done} ); $c++)
		{
            my $cmd = $cmdlist[$c]->{cmd};
			my %argsForCmd = (
				cmd => $cmd,
				cmdargs => $cmdlist[$c]->{cmdargs},
				cmdcount => 1+ $#cmdlist,
				cmdindex => $c,
				last => ($c == $#cmdlist) ? 1 : 0,
				cmdlist => \@cmdlist
			);

            $self->_resolveCommandAlias(\%argsForCmd);

			if ($c == 0)
			{
				$self->beginRun(%argsForCmd);
			} 

            $self->writeLog("handling command '$cmd'");
            if (my $ct= $def->{"command-trace"})
            {
                if ($ct eq 'user')
                {
                    $self->sendOutput(text => "<li>command trace: cmd=$argsForCmd{cmd}</li>");
                } 
                
            } 

			$self->dispatchCommand ( %argsForCmd );

            $self->mutter("after command $argsForCmd{cmd}");

			if ( $self->{_done} || ($c == $#cmdlist))
			{
				$self->endRun(%argsForCmd);
			} 
		}
        $self->afterRun();
	};
	if ($@)
	{
		$self->abort($@);
	} 

	return 0;
}

sub checkModuleAccess		# return 0 if OK else error code.
{
	my ($self) = @_;

	my $def = $self->getDefinition();

	my $access = $def->{access};
	return 0 if (!$access);

	my $user = $self->getCurrentUser();

	foreach my $word (split(/\s+/, $access))
	{
		return 0 if (($word eq 'anonymous') && (! $user->isLoggedIn()) );
		return 0 if (($word eq 'valid-user') && $user->isLoggedIn() );
		return 0 if ($word eq 'all');

		# if starts with '!' then access is forbidden to this group, 
		# even if they'd be let in otherwise.

		my $inverting=0;

		if ($word =~ m/^!(.*)/)
		{
			$word=$1;
			$inverting=1;
		}  

		# based on arbitrary user characteristic "[" field=value "]"
		if ($word =~ m#^\[(.*)=(.*)\]#)
		{
			my $key = $1;
			my $val = $2;

			if ($user->{$key} eq $val)
			{
				return $inverting ?  'FORBIDDEN' : 0;
			} 
		} elsif ($word) { 
			if ($user->getGroup($1))
			{
				return $inverting ?  'FORBIDDEN' : 0;
			} 
		} 
	} 

	return 'NOACCESS';	# more complex return codes later?
}

sub loadCurrentUser
{
	my ($self) = @_;
    
   	my $user = $self->{_userloader}->loadCurrentUser (
       	session => $self->getSession(),
		request => $self->getRequest()
	);
    
	if (! $user)
	{
		$user = new Baldrick::User();
	}
	$self->{_currentUser} = $user;
	$self->getOut()->addObject($user, "user");
	return $user;
}

sub getResponseHeaders
{
    return $_[0]->{_responseHeaders};
}

sub addResponseHeader
{
    my ($self, %args) = @_;

    my $rh = $self->getResponseHeaders();
    if ($args{fullheader})
    {
        push (@$rh, $args{fullheader});
    } else {
        requireArg(\%args, 'fullheader');   # abort.
    }
    return 0;
}

sub initStandardResponseHeaders
{
    my ($self) = @_;

    my $def = $self->getDefinition();

    $self->addResponseHeader(fullheader => $self->getSession()->getHeader());

    # Now copy headers from responseheader-* in the definition.
    # (order is random, for now...)
    foreach my $k (keys %$def)
    {
        if (0== index($k, "responseheader-"))
        {
            $self->addResponseHeader(fullheader => $def->{$k});
        } 
    } 

    return 0;
}

# Run immediately after parsing of command line.
# Initialises output headers and loads user.
# May be overridden if desired, but subclass should probably call parent's prepareRun().
sub prepareRun
{
	my ($self, %args) = @_;

    # initialise HTTP headers.
    $self->initStandardResponseHeaders();

	# load current user, and react appropriately to any login errors.
	if ($self->{_userloader})
	{
		$self->loadCurrentUser();

		my $err = $self->{_userloader}->getLoginError();
		if ($err)
		{
			# FIX ME: do something like errorAccessFailure.
			$self->abort($err);
		}
	}

	my $accessfail = $self->checkModuleAccess();
	if ( $accessfail )
	{
		$self->errorAccessFailure(%args, failuretype => $accessfail);
		return -1;
	}
	return 0;
}

# beginRun and endRun: these are run before the first command
# and after the last command, with the same arguments as the
# first/last commands in the list.  They should be used for
# setup/cleanup if needed.  
sub beginRun { return 0; }

sub endRun { return 0; }

# Do final cleanup at end of run.
sub afterRun
{
	my ($self)= @_;

    my $ssn = $self->getSession();

    my $def = $self->getDefinition();
    if (my $counter = $def->{'session-page-counter'})
    {
        $ssn->put($counter, 1+  $ssn->get($counter, defaultvalue => 0));
        $self->getSession()->finish();
    } 
    $ssn->finish();

	if (! $self->{_didOutput} )
	{
		my $cgi = $self->getRequest()->getParameters();
		$self->sendOutput(error => 
			"Processing of command \"$cgi->{cmd}\" terminated without generating any output.");
	} 

	return 0;
}


sub errorAccessFailure
{
	my ($self, %args) = @_;

	my $action = $self->getDefinition()->{'access-failure-action'};
	my $message = $self->getDefinition()->{'access-failure-message'} || 
		"Sorry, you don't have permission to use this module.  Perhaps you need to log in.";

	$self->getOut()->putInternal("errorMessage", $message);

	my ($cmd, $cmdarg) = split(/\s+/, $action);
	if ($cmd eq 'redirect' && $cmdarg)
	{
		$self->doRedirect($cmdarg);
		$self->{_done} = 1;	
	} elsif ($cmd eq 'template' && $cmdarg) {
		$self->sendOutput(template => $cmdarg);
		$self->{_done} = 1;	
	} elsif ($cmd) {
		$cmd =~ s/[^a-z0-9-_]//g;
		$self->dispatchCommand(cmd => $cmd, args => $cmdarg, cmdlist => [ $cmd ], 
			cmdcount => 1, cmdindex => 0);
		$self->{_done} = 1;	
	} else {
		 $self->abort($message);
	} 
}

sub doRedirect
{
	my ($self, $where, %args) = @_;

#	print "Location: $where\n";

    my %redirs = (
        301 => 'Moved Permanently', 
        302 => 'Found',
        303 => 'See Other',
        304 => 'Not Modified',
        307 => 'Temporary Redirect'
    );
    my $code = $args{code} || 301;
    my $msg = $redirs{$code} || $redirs{301};

	my $req = $self->getRequest();
    if ($req->didHeader())
    {
        $self->sendOutput(text => qq#This page has moved <a href="$where">here</a>.#);
    } else {
    	$req->doHeader(session => $self->getSession(),
		    headerlist => [ 
			    "Status: $code $msg",
			    "Location: $where"
		    ]
	    );
    }

	$self->{_didOutput} = 1;
}

sub dispatchCommand # ( %args) 
# Command dispatcher.  Transmogrifies user-provided command such as
# 'add-to-cart' into function name handleAddToCart() and calls that method.  
# opt cmd => command to execute, only alphanum, '_', '-' acceptable.
# opt args => optional argument to that command.
# opt cmdlist => LISTREF
# opt cmdcount => size of cmdlist
# opt cmdindex => index into cmdlist
{
	my ($self, %args) = @_;
	my $class = ref($self);

	my $cmd = $args{cmd};	# command (without arg) that came from CGI
	$self->{_currentCommand} = $cmd;

	my $func = $self->_transformCommand($cmd);
	if ($func)
	{
		$func = 'handle' . $func;
	} else {
		$func = 'handleDefaultCommand';
	}

    if (! $self->can($func))
    {
	    return $self->handleUnknownCommand( func => $func, %args );
    } 

	# build perl statement to call our function.
	my $runme = 'return ($self->' . $func . '(%args))';
	$@='';
	my $rv = eval $runme;

	if ($@)
	{
		# Can't locate object method "handleFred" via package 
		# "Baldrick::Dogsbody" at (eval 19) line 1.

		my $err = $@;
		if ( $err =~ m/locate object method "$func"/)
		{
			return $self->handleUnknownCommand( func => $func, %args );
		} else {
			return $self->setError($@, fatal => 1, no_stderr => 1);
		}
	} else {
		return $rv;
	}
}

sub _transformCommand # ($cmd)
# return command transformed into partial function name (caller should
# add 'handle' prefix).
# ex. codpiece => Codpiece
# ex. add-to-cart => AddToCart
# ex. ^*# => exception
{
	my ($self, $cmd) = @_;

	# $cmd =~ tr/A-Z/a-z/;	# lowercase it.

	# untaint it.
	if ($cmd =~ m/([A-Za-z0-9-_]+)/)	# strip all but a-z, -, _
	{
		$cmd=$1;
	} else {
		$self->setError("unacceptable command syntax '$cmd'", fatal => 1);
	} 

	# Now convert to partial function name.
	my $upper = ord('A') - ord('a');
	my $capstate = 1;	# initial cap.

	# copy it into $rv letter-by-letter; with a _ or - being skipped but causing next letter to be caps.
	my $rv = '';
	my $lim = length($cmd);
	for (my $i=0; $i<$lim; $i++)
	{
		my $ch = substr($cmd, $i, 1);
		if ($ch eq '-' || $ch eq '_')
		{
			$capstate=1;
		} else {
			if ($capstate > 0)
			{
				if ( (ord($ch) >= ord('0')) && (ord($ch)<=ord('9')))
				{
					# digit - use as-is.
					$rv .= $ch;
				} elsif ( (ord($ch) >= ord('A')) && (ord($ch)<=ord('Z'))) {
					# already cap, copy as-is
					$rv .= chr( ord($ch) + $upper);
				} elsif ( (ord($ch) >= ord('a')) && (ord($ch)<=ord('z'))) {
					# letter - ucase it.
					$rv .= chr( ord($ch) + $upper);
				} 
				$capstate=0;
			} else {
				$rv .= $ch;
			}
		}
	} 

	# This is for loop prevention.
	$rv = '' if ($rv eq 'DefaultCommand');
	$rv = '' if ($rv eq 'UnknownCommand');
	return ($rv);
}

sub handleUnknownCommand # ( func => handleXXX, cmd => XXX, ...)
# This is called when 'cmd' is gibberish (doesn't map to a handleXXX function).
#
# By default this calls setError and throws an exception; you may wish
# to override to give a different error message or to do something useful.
{
	my ($self, %args) = @_;

	$self->abort(sprintf(
        "Cannot locate handler %s->%s() for command '%s'",
        ref($self), $args{func} || 'ERR-UNKN-FUNC', $args{cmd})
    );
}

sub handleDefaultCommand
{
	my ($self, %args) = @_;

	$self->abort("No default command was defined.");
}

sub handleDummy
# This is for handling dummy requests, like the ones Apache generates
# to itself, or Nagios monitoring plugins.  It can be invoked as a 
# function of _INTERNAL_ by a UserAgent
{
    my ($self, %args) = @_;
    $self->sendOutput(text => sprintf( "OK\n<br>\n\n<br>\n%s\n<br>\nBaldrick v%s<br>\n", $self->getRequest()->getServerName(), $Baldrick::Baldrick::VERSION)
    );
}

sub getCommandList # () return LIST of { cmd=> ..., cmdargs => ... }
# given cgi input containing cmd => [ cmd0 [:arg0] [ | cmd1[:arg1] ] ]
# split into list of commands and optional arguments.
{
	my ($self) = @_;

	my $req = $self->getRequest();
	my $parm = $self->{_cmd_parm} || 'cmd';
	my $cmdlist = $self->{_command} || $req->getParameter($parm);

	my @rv;
	my @clist = split (/\|/, $cmdlist);
	
	for (my $i=0; $i<=$#clist; $i++)
	{
		my $longcmd = $clist[$i];
		my %parsed = (
			cmd => $longcmd,
			cmdargs => '',
		);
		if ($longcmd =~ m/^([^:]+):(.*)/)
		{
			$parsed{cmd} = $1;
			$parsed{cmdargs} = $2;
		}
		push (@rv, \%parsed);
	}
	return @rv;
}

sub abort
# no_output - don't generate error page (assume it's been done already), just do the
#    logfile and termination stuff.
{
	my ($self, $msg, %args) = @_;

	return 0 if ($self->{_DID_ABORT});  # this prevents loops if there's a problem with template handling.
	$self->{_DID_ABORT} = 1;

    unless ($args{no_output})
    {
        eval {
            $self->sendOutput(error => $msg);
    	};
    	if ($@)
    	{
    		$self->sendOutput(text => "<p><h2>error:</h2> <p>$msg</p>\n");
		    $self->sendOutput(text => "<p><b>additional error processing error template:</b> $@</p>\n");
	    }
    }

	$args{uplevel}++;
	Baldrick::Turnip::abort($self, $msg, %args); 
}

sub setError
{
	my ($self, $msg, %args) = @_;
	if ($args{fatal})
	{
		$self->doHeader();
	} 

	$args{uplevel} ||= 0;
    $args{uplevel} += 1;
    if ($args{critical})
    {
        $args{notify_mail} ||= 
            $self->getDefinitionItem('errornotify') || 
            $self->getApp()->getConfig("site-admin-email");
    } 
	Baldrick::Turnip::setError($self, $msg, %args);
}

sub handleNoModuleDefinedError
{
	my ($self, %args) = @_;

	my $req = $self->getRequest();
	my $path = $req->getPath();

	$self->sendOutput(text => "<h2>Baldrick: No module configured at address '$path'.  You need to edit the 'PathMap' section in baldrick.cfg.</h2>\n");

	return 0;
}

sub getConfig
# Enhances normal getConfig() with twiddle-eval functionality;
# if config option value begins with ~xx:, run the rest of it thru
# the template processor specified with 'xx'.
{
	my ($self, $cfgkey, %args) = @_;

	my $rv = Baldrick::Turnip::getConfig($self, $cfgkey, %args);
	if ('~' eq substr($rv,0,1))
	{
		# ~tt~
		if ($rv =~ m/^\~([a-z]+):(.*)/) 
		{
			my $evaluator = $1;
			my $expr = $2;

			return $self->getOut($evaluator)->processString($expr);
		} else {
			return $rv;
		}
	} else {
		return $rv;
	}
}

sub writeLog
{
	my ($self, @stuff) = @_;

	my $req = $self->getRequest();
	my $lp = sprintf("[%s]", $req->getRemoteIP());

    if ($self->{_logToUser})
    {
        $self->sendOutput(
            text => qq!<span class="baldrick_log_user">! . $stuff[0] . "</span><br>");
    } 
	return Baldrick::Turnip::writeLog($self, @stuff, logprefix => $lp);
}

sub sendToModule
{
    my ($self, %args) = @_;

    my $rv = $self->getApp()->sendToModule(
        parentHandler => $self, 
        %args 
    );
    $self->{_didOutput} = 1;    # WRONG WRONG!  But the child handler isn't accessible here.
    return $rv;
}
1;
