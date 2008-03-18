
package Baldrick::UserLoader;

# Abstract base class for DBUserLoader and LDAPUserLoader.

use Data::Dumper;		
use strict;
use Baldrick::Util;

our @ISA = qw(Baldrick::Turnip);

our %defaults = (
	'addr-id-fieldname' => 'address_id',
	'addr-id-pseudo-value' => -999, 

    'authuid-user-field' => 'userid',
	'sessionkey-authuid' => '_bdk_authuid',
	'sessionkey-authname' => '_bdk_authname',
	'sessionkey-authtime' => '_bdk_authtime',
	'sessionkey-authemail' => '_bdk_authemail',

	# for Login section.
    'loginform-name' => '_edmund', 
    'loginform-pass' => '_percy',
    'loginform-remember' => '_bob', 
    'loginform-action' => '_login',
    'loginform-action-value-login' => 'who-is-it',
    'loginform-action-value-logout' => 'run-away',

	'url-create-account' => 'myaccount?cmd=create-account',
    'url-forgot-password'  => 'myaccount?cmd=forgot-password',
    'url-edit-profile' => 'myaccount?cmd=edit-profile',

    'sessionkey-loginfailures' => '_bdk_login_failures',

	'error-no-password' => 'You have no password set.  Please use the "forgot password" link to add one to your account.',
    'error-no-user' => 'Username or email is unknown.',
    'error-password-incorrect' => 'Incorrect password.',
    'error-too-many-failures' => 'Too many failed login attempts by you today.',
);

our @canonicalFields = qw(userid email username);
our @passwordMethods = qw(clear crypt md5);

sub init	# ( %args )
# args:
# userclass => string	REQUIRED
# and either of
# 	app => (B'k:App object)
# 	config => hash-tree
{
	my ($self, %args) = @_;

	$self->_construct(\%args, [ qw(userclass) ], required => 1 );

	$self->{_config_defaults} = \%defaults;

	if ($args{app})
	{
		my $app = $args{app};
		my $branchname = "UserClass/" . $self->{_userclass};
		$self->{_config} = $app->getConfig($branchname);
	} else {
		$self->_construct(\%args, [ qw(config) ], required => 1 );
	}

	return $self;
}

sub loadUser # (%args) return Baldrick::User or 0.
# Load a user from the database (or LDAP, or whatever).  A simple wrapper
# for loadUsers(), which subclasses must implement.
# args: 
#	email | userid | username | ident (one required).
# see also loadUsers() for more args.
{
	my ($self, %args) = @_;

	my $kf = Baldrick::Util::requireAny(\%args, [ qw(email userid username ident) ] );
	my $kv = $args{$kf};

	if ($kf eq 'ident')
	{
		delete ($args{ident});

		if ($kv =~ m/^\d+$/)
		{
			return $self->loadUser(%args, userid => $kv);
		} elsif ($kv =~ m/^[^@\s]+@[^@\s]+$/) {
			# exactly one @, no spaces: smells like email.
			return $self->loadUser(%args, email  => $kv);
		} else {
			# some miscellaneous rubbish, probably a username.
			return $self->loadUser(%args, username => $kv);
		}
	} 

	my $users = $self->loadUsers(%args);
	if ($#$users == 0)
	{
		# ONE FOUND.
		return $users->[0];
	} elsif ($#$users < 0) {	
		# NONE FOUND.
		return 0;
	} else {
		# MANY FOUND.
		$self->setError("Multiple users found with $kf=$kv\n");
		return 0;
	}
}

sub _getVirtualFieldMap
{
    my ($self) = @_;

    return $self->getConfig('VirtualFields');
    # return \%rv;
}

sub _getRealFieldName # ( $virtualfield )
# virtual fields are things like email, username, id; these may be represented
# in the database structure as something else.  Return the actual field name
# for our virtual name (which, by default, is the same thing).
{
    my ($self, $fn) = @_;
    return $self->getConfig($fn, section => 'VirtualFields', 
            defaultvalue => $fn);
}

sub makeUsersFromData # (rows => \@rawdata, init_args => ..)
# Given a list of hashrefs containing user data (from a database query or somesuch),
# make a user object out of each one, and handle virtual fieldname mappings.
{
    my ($self, %args) = @_;
    
    my $rows = requireArg(\%args, 'rows');
    
    # Virtual Field Names - copy each real field into its alias (within loop below)
    my $vmap = $self->_getVirtualFieldMap();

    my $objclass = $self->getUserObjectClass();
    my @users;
    my $initargs = $args{init_args} || {};
    my $loadargs = $args{load_args} || { fieldlist => '*' };

    for (my $i=0; $i<=$#$rows; $i++)
    {
        my $user = createObject($objclass);

        $user->init( %$initargs, creator => $self )
          unless ($args{no_init});  # this will init group/addr listrefs.
        
        $user->loadFrom($rows->[$i], %$loadargs);

        push (@users, $user);

        # copy real fieldnames into virtual fieldnames. 
        foreach my $outfield ( keys %$vmap )
        {
            my $val='';
            my @subfields = split(/\s+/, $vmap->{$outfield});
            foreach my $sf (@subfields)
            {
                $val .= ' ' if ($val);
                $val .= $user->{ $sf };
            }
            
            $user->{$outfield} = $val;
        } 
    }

    return \@users;
}

sub _importPseudoAddresses # ($userlist)
# build an AddressList entry by poaching fields from the main user record
# (for those sites that don't want to maintain a separate address table).
{
	my ($self, $userlist) = @_;
	
	my $pseudo = $self->getConfig("Addresses/pseudo-address-fields");
	return 0 if (!$pseudo);
	
	my @fields = split(/[\s,]+/, $pseudo);

    my $aidfield = $self->getConfig(
        "Addresses/user-address-field-addrid", 
		defaultvalue => $defaults{'addr-id-fieldname'}
	);

	foreach my $u (@$userlist)
	{
		my %newaddr = (
			$aidfield => $defaults{'addr-id-pseudo-value'}
		);
		foreach my $fn (@fields)
		{
			$newaddr{$fn} = $u->{$fn};
			next if ($fn eq 'id');
			next if ($fn eq 'userid');
			next if ($fn eq 'user_id');
			# don't delete it 2006-10-02 delete $u->{$fn};
		} 
		push (@{ $u->{AddressList} }, \%newaddr);
	} 
}

sub storeLoginToSession # ( $user, $session, %args )
# Save user information to session object.
{
	my ($self, %args) = @_;

	my $session = $args{session};
	my $user = $args{user};

	# Get the unique ID of this user.  The fieldname is usually 'userid'
	# but can be overridden.
	my $idfield = $self->_getAuthUIDSourceField();
	
	my $idvalue = $user->{ $idfield };		
	die("cannot find user id in '$idfield'")
		if (!$idvalue);

	# put _bdk_authuid or somesuch!
	# look for config stuff in here.
	my $cfg = $self->getConfig("Login", defaultvalue => \%defaults);

	$session->put( $self->getSessionKey('authuid'), $idvalue);

	$session->put( $self->getSessionKey('authtime'), time());

	$session->put( $self->getSessionKey('authemail'), $user->getEmail());

	$session->put( $self->getSessionKey('authname'), $user->getUsername());

	return 0;
}

sub getLoginFormField
# Return a fieldname for the login fields.  Intended to be called from
# the template that prints the login form, and from the functions that
# handle it.
{
	my ($self, $label) = @_;

	my $cfg = $self->getConfig("Login", defaultvalue => \%defaults);
	my $rv = $self->getConfig("loginform-$label", 
		config => $cfg,
		defaults => \%defaults
	);

	$self->abort("cannot lookup $label") if (!$rv);

	return $rv;
}

sub isReservedField
{
    my ($self, $fieldname) = @_;

    my $cfg = $self->getConfig("Login", defaultvalue => \%defaults);

    my @keylist = keys %defaults;

    foreach my $k (@keylist)
    {
        if ($k =~ m/loginform-/)
        {
            if (defined ($cfg->{$k}))
            {
                return 1 if ($cfg->{$k} eq $fieldname); 
            } else {
                return 1 if ($defaults{$k} eq $fieldname); 
            }
        } 
    } 

    return 0;
}

sub getURL
# get URLs for such things as create account, forget password...
{
	my ($self, $label) = @_;

	my $cfg = $self->getConfig("Login", defaultvalue => \%defaults);
	my $rv = $self->getConfig("url-$label", 
		config => $cfg,
		defaults => \%defaults
	);
	return $rv;
}

sub getSessionKey
{
	my ($self, $label) = @_;

	my $cfg = $self->getConfig("Login", defaultvalue => \%defaults);
	return $self->getConfig("sessionkey-$label", 
		config => $cfg,
        defaults => \%defaults
	);
}

sub _getLoggedInUserIDFromSession
# Return a user id or 0.
{
    my ($self, %args) = @_;

    my $session = requireArg(\%args, 'session');
    my $authuidkey = $self->getSessionKey('authuid');   # SESSION fieldname.
    return $session->get($authuidkey) || 0;
}

sub _removeAuthFromSession
{
	my ($self, %args) = @_;
	my $session = requireArg(\%args, 'session');

	$session->del( $self->getSessionKey('authuid') );
	$session->del( $self->getSessionKey('authtime') );
	$session->del( $self->getSessionKey('authemail') );
	$session->del( $self->getSessionKey('authname') );
    return 0;
}

sub _loadUserFromSession
# Return logged-in user or 0.
{
    my ($self, %args) = @_;

    my $authuid = $self->_getLoggedInUserIDFromSession(%args);   
    return 0 if (!$authuid);

    # USER IS AUTHENTICATED; LOAD HIM NOW. 
    my $idfield = $self->_getAuthUIDSourceField(); # userid | email | username

    my $user = $self->loadUser($idfield => $authuid, everything => 1);
    if (!$user)
    {
        $self->abort("cannot load user with id '$idfield'='$authuid'\n");
    }

    $user->setLoggedIn(1);
    return $user;
}

sub loadCurrentUser # request => .., session => ..
# MAIN ENTRY POINT FROM DogsBody
{
    my ($self, %args) = @_;

    my $wasLoggedIn = 0;
    my $user = $self->_loadUserFromSession(%args);
    if ($user && $user->isLoggedIn() )
    {
        $wasLoggedIn = 1;
        $user->setPreviousLoginState(1);
    } 

	if (my $request = requireArg(\%args, 'request'))
    {
	    # Now check to see if login/logout is being attempted.
    	# (even if user already logged in, this lets him change identities).
        my $actionfield = $self->getLoginFormField('action');
	    my $action   = $request->get( $actionfield, firstvalue => 1, defaultvalue => '' );

        if ($action eq $self->getLoginFormField('action-value-logout')) 
        {
            # LOG OUT.  
            # do logout event on user loaded from session (if any).
            if ($user)
            {
                $user->onLogout(%args, userloader => $self);
                $user->finish();
                $user = 0;
            } 
    
            # Clear the session file's login info.
            $self->_removeAuthFromSession(%args);
        } elsif ($action eq $self->getLoginFormField('action-value-login')) {
            # LOG IN (if password checks out), forgetting the previously loaded uesr.
            $user = $self->handleLogin(%args);
            if ($user)
            {   
                if ( $user->isa('Baldrick::User'))
                {
                    $user->setPreviousLoginState(0);    # FRESH LOGIN.
                    $user->onLogin(%args, userloader => $self); # LOGIN EVENT.
                }
                # FALL THRU AND RETURN $USER
            } # ELSE... handleLogin returned 0
        } elsif ($action) {
            $self->setError(
                "Unknown action value '$action' present in '$actionfield', doing nothing!"
            );
        } 
    } 

    if ($user)
    {
        if ($user->{ERROR_ONLOGIN})
        {
            $self->writeLog(sprintf("error on login for user %s: %s", 
                $user->{email}, $user->getError()), 
                warning => 1);
            $user = 0;
        } else {
            return $user;
        }
    } 

    # either no user was found in session, or user in session was discarded
    # because LOGOUT was performed.
    my $dummy = $self->getNullUser();
    $dummy->setPreviousLoginState($wasLoggedIn);
    return $dummy;
}

sub getNullUser
{
    my ($self) = @_;

    my $classname = $self->getUserObjectClass(null_user => 1);

    my $user = dynamicNew($classname);
    $user->init(null_user => 1);
    $user->analyse(null_user => 1);
    return $user;
}

sub getUserObjectClass  # (null_user => 0|1)
{
    my ($self, %args) = @_;

    if ($args{null_user})
    # if null_user is true, we return config's null-user-object-class only if defined.
    {
        my $rv = $self->getConfig('null-user-object-class');
        return $rv if ($rv);
    } 
    
    # for non-null users, or null users in the absense of null-user-object-class def:
    return $self->getConfig('user-object-class', defaultvalue  => 'Baldrick::User');
}
 
sub _getAuthUIDSourceField  # return the database/ldap/whatever fieldname for user id.
{
	my ($self) = @_;

	my $k = 'authuid-user-field';

	my $rv = $self->getConfig($k, section => 'Login', 
        defaultvalue => $self->{_defaultkey} );
	return $rv || $defaults{$k};
}


sub handleLogin # Return user object or 0 if failed.
{
	my ($self, %args) = @_;

	my $request = requireArg(\%args, 'request');
	my $session = requireArg(\%args, 'session');

	my $unamefield = $self->getLoginFormField('name');
	my $passfield  = $self->getLoginFormField('pass');

	return 0 if (!$unamefield || !$passfield);

	# $name could be email, username, realname, userid...
	my $name = $request->get($unamefield) || return 0;;
	my $password = $request->get($passfield) || return 0;

    if ($name =~ m/\0/ || $password =~ m/\0/)
    {
        $self->abort("a NUL character was detected in the username or password fields.  This indicates the fields may have been duplicated in the input form");
    } 

	$name =~ s/^\s+//g;		# no spaces at begin/end
	$name =~ s/\s+$//g;

	return 0 if (!$name || !$password);	# blank - login not attempted.

	# config file 'login-with' has list of key fields to be searched in order.
	my @fieldlist = split(/\s+/, $self->getConfig(
		"Login/login-with", 
		defaultvalue => 'email userid username'
	));

	my $usersfound=0;

	my %goodfields = ( email => 1, userid => 1, username => 1 );
	foreach my $identfield (@fieldlist)
	{
		if (!$goodfields{$identfield})
		{
			$self->abort("'login-with' contains bogus label '$identfield'");
		} 

		# only email has an '@', where it's mandatory.
		next if ( ($identfield eq 'email') && ($name !~ m/@/) );
		next if ( ($identfield ne 'email') && ($name =~ m/@/) );

		# skip non-numerics for userid (and numerics for everything else)
		next if ( ($identfield eq 'userid') && ($name !~ m/^\d+$/) );
		next if ( ($identfield ne 'userid') && ($name =~ m/^\d+$/) );

        my $nameFixed = $name;
        if (my $transform = $self->getConfig("Login/transform-$identfield"))
        {
            $nameFixed = applyStringTransforms($nameFixed, $transform);
        } 

		my $userlist = $self->loadUsers( $identfield => $nameFixed, everything => 1);

		if ($#$userlist > 0)
		{
            # permit-shared-email, permit-shared-userid: default to FALSE.
            # if true, then multiple users can have same email/userid, and
            # the password will be checked against each.  NOT RECOMMENDED.
            if (!  $self->getConfig("permit-shared-$identfield", bool => 1, 
                    section => 'Login'))
            {
			    $self->abort("Multiple users found with '$identfield' matching '$name'.
                  Login not permitted.  Please contact the system administrator.");
		    } 
        } 
            

		# There may have been multiple users returned - loop through each.
		foreach my $thisuser (@$userlist)
		{
			++$usersfound;
			my $rc = $self->validateLoginAttempt(
				user => $thisuser, password => $password,
				session => $session, request => $request
            );
			if ($rc == 0) 
            {     #HAPPY!
				$thisuser->setLoggedIn(1);
				$self->storeLoginToSession(user => $thisuser, session => $session);
				my $remember = $self->getLoginFormField("remember");
				if ($remember && $request->get($remember))
				{
					$request->getResponse()->setCookie('username', $name);
				} 
				return $thisuser;
			} 
		}
        return 0;
	} 

	$self->putLoginError('no-user');
	return 0;
}

sub checkMaxFailuresPerSession
# return 0 if ok, -1 if too many failures already.
{
	my ($self, %args) = @_;

	# ensure we haven't seen too many failures in this session.
	my $maxattempts = $self->getConfig('max-failures-per-session', 
					section => 'Login', defaultvalue => 10);
	$maxattempts = 4 if ($maxattempts < 4);
	
	my $failkey = $self->getSessionKey('loginfailures') || return 0;

	my $attempts = $args{session}->get($failkey);
	if ($attempts >= $maxattempts)
	{
		$self->putLoginError('too-many-failures');
		return -1;
	} 
	return 0;
}

sub preparePasswordForStorage
{
	my ($self, $password) = @_;

	my $cleartext = $password;

	my $method = $self->getConfig("Login/password-method", required => 1,	# NO DEFAULT.
        limitvalues => \@passwordMethods );	# NO DEFAULT.

	# my $submethod = $self->getConfig("Login/password-submethod");
	my $passexpr = $self->getConfig("Login/password-expression");
	if ($passexpr)
	{
		# wikipedia style: $uid-$pass
		# FIX ME: get TemplateAdapter...
		# my $out = ...
		# $out->addObject($self, "ThisUser");	# cannot use User, it's reserved...
		# $self->{ENTERED_PASSWORD} = $password;
		# $cleartext = $out->processString($passexpr);
		# $out->removeObject("ThisUser");
		# delete $self->{ENTERED_PASSWORD};
	} 

	if ($method eq 'clear') 
	{
		return $cleartext;
	} elsif ($method eq 'md5') {
        # input:cleartext   store:5ab677ec767735cebd67407005786016
		my $foo = 'use ' . 'Digest::MD5 qw(md5 md5_hex md5_base64)';
		eval $foo;
		if ($@)
		{
			$self->abort("error loading Digest::MD5 module: $@");
		}
		return md5_hex($cleartext);
	} elsif ($method eq 'crypt') {
        # input:cleartext   store:aaQ/RB/6vF.oM
		my $stext = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
		my $salt = substr($stext, int(rand(length($stext))), 1);
		$salt .= substr($stext, int(rand(length($stext))), 1);
		my $rv = crypt($cleartext, $salt);
		# print STDERR "crypt [$password] to [$rv] with [$salt]\n"; 
		return $rv;
	} else {
		$self->abort("Password method not defined in 'Login' section of configuration file.  ".
		 "Valid entries are: crypt clear md5");
	} 	
}

sub checkPassword # return 'ok' on success, else error type.
# return codes:
#   ok: SUCCESS.
#   no-password: user has no password of record and therefore cannot log in.
#   password-incorrect: password entered doesn't match user's password of record.
{
	my ($self, %args) = @_;

	my $user = Baldrick::Util::requireArg(\%args, 'user');
	my $pass = Baldrick::Util::requireArg(\%args, 'password');

    # password-method is clear / md5 / crypt
	my $method = $self->getConfig("Login/password-method", required => 1,
        limitvalues => \@passwordMethods );	# NO DEFAULT.

    # password-field is the field in the User object to find the stored pass in.
	my $pwfield= $self->getConfig("Login/password-field", required => 1);	# NO DEFAULT.

	my $storedpass = $user->{$pwfield};
	return 'no-password' if (!$storedpass);

    if ($method eq 'clear') 
	{
		return 'ok' if ($pass eq $storedpass);
        return 'password-incorrect';
	} elsif ($method eq 'md5') {
        # Load an optional module.
		my $foo = 'use ' . 'Digest::MD5 qw(md5 md5_hex md5_base64)';
		eval $foo;
		if ($@)
		{
			$self->abort("error loading Digest::MD5 module: $@");
		}
		my $crypted = md5_hex($pass);
		return 'ok' if ($crypted eq $storedpass);
		return 'password-incorrect';
	} elsif ($method eq 'crypt') {
		my $crypted = crypt($pass, $storedpass);
		# print STDERR "crypt compare /$crypted/ /$storedpass/\n";
		return 'ok' if ($crypted eq $storedpass);
		return 'password-incorrect';
	} else {
        return $self->abort("bad pw method $method");
	} 	

    # Shouldn't be reachable, but...
    return 'password-incorrect';
}

sub _tryAdminBackdoor
# PASSWORD BACK DOOR FEATURE.
# For testing, you can enable a password/IP# combination that will provide
# access to ANY account, as configfile: <Login> backdoor-192.168.0.14 = admin-password
{
    my ($self, %args) = @_;

    my $request = $args{request} || return 0;

    my $ip = $request->getRemoteIP() || return 0;

    my $backdoor =  $self->getConfig("Login/backdoor-$ip") || return 0;
    if ($backdoor && ($backdoor eq $args{password}))
	{
        $self->writeLog(
            "NOTICE: admin backdoor used from '$ip' for user $args{user}->{email}.", 
            notice => 1);
		return 'SUCCESS'; 
	} 	

    # Fail to match; let real password logic resume.
    return 0;
}

sub validateLoginAttempt
#   Takes appropriate action based on checkPassword() results: manipulates 
#       failures counter, sets error messages.  
#   Also implements an 'admin backdoor' feature for testing.
#   returns 0 on successful login, -1 on failure.
{
	my ($self, %args) = @_;

	return -1 if ($self->checkMaxFailuresPerSession(%args));

	my $user = $args{user}          ||die();
	my $pass = $args{password}      ||die();
	my $session = $args{session}    || die();
    
    return 0 if ('SUCCESS' eq $self->_tryAdminBackdoor(%args));

    # Test the password.
    my $err = $self->checkPassword( %args );
	my $failkey = $self->getSessionKey('loginfailures');

	if ($err eq 'ok')
	{
		# PASSWORD IS GOOD
		$session->put($failkey, 0) if ($failkey);	# CLEAR FAILURES COUNTER.
		return 0;	# 0= SUCCESS !
	} else {
	    # PASSWORD IS BAD
	    $self->putLoginError($err);

	    if ($failkey && ($failkey ne 'none'))   # INCREMENT FAILURES COUNTER.
	    {
		    $session->put($failkey, 1 + $session->get($failkey));
	    } 
        return -1;		# nonzero = failure!
    }
    return -1;		# nonzero = failure!
}

sub getLoginError
{
	my ($self) = @_;
	return $self->{loginError};
}

sub putLoginError
{
	my ($self, $cause) = @_;

	$self->{loginError} = $self->getConfig("error-$cause", 
			section => 'Login', defaults => \%defaults);
	if (!$self->{loginError})
	{	
		$self->{loginError} = "Unknown error logging in: $cause";
	} 
	return $self->{loginError};
}
1;
