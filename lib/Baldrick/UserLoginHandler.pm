
#
# This is the default handler for essential user account actions that are 
# performed WITHOUT LOGGING IN:
#
# 	FORGOT PASSWORD - This creates an entry in a table with big random numbers
#		and mails the user a URL that contains these numbers.
#	RESET PASSWORD - this is the second half of FORGOT PASSWORD; the big random
#		numbers are checked, and, if correct, the user can change password.
#
# Additionally, it can handle the login/logout process - though these are 
# often handled silently by other programs, this is a convenient default location
# for these actions:
#	LOGIN	- though any other program can do login as part of the normal processing
#	LOGOUT	- though any other program can do login as part of the normal processing

package Baldrick::UserLoginHandler;

use Data::Dumper;
use FileHandle;

use strict;
use vars qw(@ISA $VERSION);

@ISA = qw(Baldrick::Dogsbody Baldrick::Turnip);
$VERSION = 0.1;

our %defaults = (
	ResetPassword => {
		method => 'session',	# session|database|file
		'digit-clusters' => 6,# 4-digit groups in key
		'key-lifetime' => 2*3600,
		# DATABASE METHOD.
	},
);

sub init # ( %args )
{
	my ($self, %args) = @_;

	$self->Baldrick::Dogsbody::init(%args, 
		default_cmd => 'login', 
		templatedir => 'userlogin'
	);

	return $self;
}

sub handleLogIn  { return handleLogin (@_) }
sub handleLogOut { return handleLogout(@_) }
sub handleRp	 { return handleResetPassword(@_) }

sub handleLogout
{
	my ($self, %args) = @_;

	my $ul = $self->getUserLoader();
	my $olduser = $self->getCurrentUser();
    
    $self->getOut()->addObject("OldUser", $olduser);

    $self->{_currentUser} = 0;
    $self->loadCurrentUser();
     
	# Now we must delete the login command, ere we get into a loop.
	# (The login form that might be on the logout page might otherwise
	# send back 'cmd=logout' at the login request!)
	delete $self->getRequest()->getParameters()->{cmd};
	$self->sendOutput(template => $self->getTemplate('logout'));
}

sub handleLogin
# handleLogin doesn't actually do anything.
# Login is handled automatically if the right parameters are present 
# (see the <Login>..</Login> section of the User config section).
# What we can do here is see if that login that happened at the 
# beginning of the present run was successful, and present appropriate
# pages.
{
	my ($self, %args) = @_;
	
	my $user = $self->getCurrentUser();
	if ($user->isLoggedIn())
	{
		$self->sendOutput(template => $self->getTemplate('login-successful'));
	} else {
		$self->sendOutput(template => $self->getTemplate('login-failed'));
	} 
}

sub handleChangePassword
{
	my ($self, %args) = @_;

	my $parms = $self->getRequest()->getParameters();

	my $thiscode = $parms->{code};
	my $codeinfo = $self->lookupResetCodeInfo($thiscode);
	if (! $codeinfo)
	{
		$self->abort("Reset code not found.");
	}	

	my $uid = $codeinfo->{userid};
	my $ul = $self->getUserLoader();
	my $user = $ul->loadUser(userid => $uid);
	if (! $user)
	{
		$self->abort("User not found.");
	}

	$codeinfo->{code} ||= $codeinfo->{key}; ## FIX ME.
	my $pass = $parms->{newpass1};

	if (length ($pass) < 5 || length ($pass)>16)
	{
		$self->abort("password must be 5-16 characters in length");
	} 

	if (0 == $ul->changePasswordForUser(user => $user, password => $pass))
	{
		$self->sendOutput(template => $self->getTemplate('password-changed'));
	} else {
		$self->abort("Failed to change password: " .
			$ul->getError());
	}
}

sub handleResetPassword
{
	my ($self, %args) = @_;

	my $parms = $self->getRequest()->getParameters();

	my $thiscode = $parms->{code};
	my $codeinfo = $self->lookupResetCodeInfo($thiscode);
	if (! $codeinfo)
	{
		$self->abort("Reset code not found.");
	}	

	my $uid = $codeinfo->{userid};
	my $ul = $self->getUserLoader();
	my $user = $ul->loadUser(userid => $uid);
	if (! $user)
	{
		$self->abort("User not found.");
	}

	$codeinfo->{code} ||= $codeinfo->{key}; ## FIX ME.
	$self->getOut()->addObject($user, "thisuser");
	$self->getOut()->addObject($codeinfo, "reset");
	$self->sendOutput(template => $self->getTemplate('enter-new-password'));
}

sub handleForgotPassword
# If Username/Email not present in input, show a form pointing back to ForgotPassword.
# If Username/Email present in input, create big-random-number entry and mail the user.
{
	my ($self, %args) = @_;

	my $parms = $self->getRequest()->getParameters();

	my $unem = $parms->{username};
	my $captcha = $parms->{captcha};

	if (!$unem || !$captcha)
	{
		my $sess = $self->getSession();
		my $md5  = $sess->createCaptcha('reset');
        my $path = $sess->getCaptchaPath('reset');
        $self->getOut()->putInternal("captcha", $path);

		$self->sendOutput(template => $self->getTemplate('forgot-password'));
		return 0;
	} 

	if ($captcha)
	{
    	my $result = $self->getSession()->checkCaptcha('reset',  $captcha);
		if ($result < 0)
		{
			delete $parms->{captcha};

        	$self->getOut()->putInternal("ErrorMessage", 
				"Incorrect puzzle response, please try again.");
			return $self->handleForgotPassword(%args);
		} 
	}

	my $ul = $self->getUserLoader();
	my $user = $ul->loadUser(ident => $unem);
	if (! $user)
	{
		$self->getOut()->putInternal("ErrorMessage", 
			"I cannot find any user with name/email/id '$unem'"
		);
	
		# & show the same form again.
		$self->sendOutput(template => $self->getTemplate('forgot-password'));
		return 0;
	} 

	$self->getOut()->addObject($user, "thisuser");

	my $resetinfo = $self->_createPasswordResetEntry($user);

	$self->getOut()->addObject($resetinfo, "reset");
	my $mailtext = $self->getOut()->processFile(
		$self->getTemplate('reset-password-mailing')
	);

	my $fh = new FileHandle("|/usr/sbin/sendmail -t");
	if ($fh)
	{
		print $fh "To: $user->{email}\n";
		print $fh $$mailtext;
		$fh->close();
	} else {
		$self->abort("no sendmail; $!");
	}
	# $self->sendOutput(dump => $resetinfo);
	$self->sendOutput(template => $self->getTemplate('forgot-password-sentmail'));
}

sub lookupResetCodeInfo
{
	my ($self, $code) = @_;

	my $dbname = $self->getConfig('database', 
		section => 'ResetPassword', defaults => \%defaults
	);

	my $table = $self->getConfig('reset-table', 
		section => 'ResetPassword', defaults => \%defaults
	);

	my $keyfield = $self->getConfig('reset-key-field', 
		section => 'ResetPassword', defaults => \%defaults
	);

	my $sql = sprintf("select * from %s where %s = ?",
		$table, $keyfield);

	my $db = $self->getApp()->getDatabase($dbname);
	my $results = $db->query(sql => $sql, sqlargs => [ $code ]);
	return $results->[0];
}

sub _createPasswordResetEntry
{
	my ($self, $user) = @_;

	my $dbname = $self->getConfig('database', 
		section => 'ResetPassword', defaults => \%defaults
	);

	my $clusters = $self->getConfig('digit-clusters', 
		section => 'ResetPassword', defaults => \%defaults
	);

	my $table = $self->getConfig('reset-table', 
		section => 'ResetPassword', defaults => \%defaults
	);
	my $keyfield = $self->getConfig('reset-key-field', 
		section => 'ResetPassword', defaults => \%defaults
	);

	my $db = $self->getApp()->getDatabase($dbname);

	my %rv;

	$rv{lifetime} = $self->getConfig('key-lifetime', 
    	section => 'ResetPassword', defaults => \%defaults
    );
	$rv{lifetime_mins} = int ($rv{lifetime} / 60);

	$self->_cleanupPasswordResets (database => $db, table => $table, 
		age => $rv{lifetime});

	my $key = '';
	for (my $try =0; ! $key && ($try < 100); $try++)
	{
		$key = $self->_generatePasswordResetKey(clusters => $clusters);
		if ($self->_resetKeyExists(key => $key, database => $db,
			table => $table, keyfield => $keyfield))
		{
			$key = 0;	# TRY AGAIN.
		} else {
			if (0 != $self->_insertResetKey(key => $key, database => $db,
				table => $table, keyfield => $keyfield, user => $user))
			{
				$key=0;
			} 
		}
	} 

	$rv{key} = $key;

	return \%rv;
}

sub _cleanupPasswordResets
{
	my ($self, %args) = @_;

	my $timefield = $self->getConfig('reset-time-field',
    	section => 'ResetPassword', defaults => \%defaults
    );

	my $h = $args{age}/3600; $args{age}=$args{age} % 3600;
	my $m = $args{age}/60;   $args{age}=$args{age} % 60;
	my $s = $args{age}%60;

	my $limit = sprintf("%d:%d:%d", $h,$m,$s);

	# FIX ME: this is probably for postgresql only!  and what of unix time format?
	my $sql = sprintf("DELETE from %s where (current_timestamp - %s) > ?",
		$args{table}, $timefield
	);

	$args{database}->query(nofetch => 1, sql => $sql,
		sqlargs => [ $limit ] );
	return 0;
}

sub _insertResetKey
{
	my ($self, %args) = @_;

	my $idfield = $self->getConfig('reset-userid-field',
    	section => 'ResetPassword', defaults => \%defaults
    );
	my $timefield = $self->getConfig('reset-time-field',
    	section => 'ResetPassword', defaults => \%defaults
    );

	my $ident = $args{user}->{userid};
	my $time = Baldrick::Util::easydate() . " " . Baldrick::Util::easytime();

	my $sql = sprintf("INSERT INTO %s (%s, %s, %s) VALUES (?,?,?)", 
		$args{table}, 
		$args{keyfield}, $idfield, $timefield,
	);

	my $rc = $args{database}->query(nofetch => 1,
		sql => $sql,
		sqlargs => [ $args{key}, $ident, $time ] 
	);

	return ($rc==1) ? 0 : -1;
}

sub _resetKeyExists
{
	my ($self, %args) = @_;

	my $sql = sprintf("SELECT * from %s WHERE %s=?",
		$args{table}, $args{keyfield});

	# $self->sendOutput(text => $sql);

	my $results = $args{database}->query(
		sql => $sql,
		sqlargs => [ $args{key} ]
	);

	if ($results && $#$results >=0)
	{
		return 1;
	}

	return 0;
}

sub _generatePasswordResetKey # ( clusters => $clusters)
# Create a random key of the form ffff-ffff-ffff... with $clusters digit clusters.
{
	my ($self, %args) = @_;
	my $clusters = $args{clusters} || 6;

	my $rv = '';
	for (my $i=0; $i<$clusters; $i++)
	{
		$rv .= '-' if ($rv);
		$rv .= sprintf("%04x", int(rand(0xffff)));
	} 
	return $rv;
}

1;
